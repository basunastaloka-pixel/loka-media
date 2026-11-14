import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'drive_folder_link.dart';
import 'windows_desktop_oauth.dart';

class DriveAccount {
  final String id;
  final String email;

  const DriveAccount({required this.id, required this.email});
}

class GoogleDriveConnectionException implements Exception {
  final String code;
  final String message;

  const GoogleDriveConnectionException(this.code, this.message);

  @override
  String toString() => message;
}

class DriveDestinationFolderException implements Exception {
  final String? folderName;
  final bool wasRecreated;

  const DriveDestinationFolderException({
    this.folderName,
    this.wasRecreated = false,
  });

  @override
  String toString() => wasRecreated && folderName != null
      ? "Folder '$folderName' was recreated in Drive. Please re-pick the destination."
      : 'Destination folder not found. It may have been moved or deleted in '
            'Drive. Check the folder and try again.';
}

class GoogleDriveService {
  static const _pickerChannel = MethodChannel('pilah_foto/google_drive_picker');
  static const _signInDiagnosticsChannel = MethodChannel(
    'pilah_foto/google_sign_in_diagnostics',
  );
  static const _windowsDesktopClientId = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_ID',
  );
  static const _googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );
  static const _driveScope = 'https://www.googleapis.com/auth/drive.file';
  static const _androidDriveScopes = [
    _driveScope,
    'openid',
    'email',
    'profile',
  ];
  static const _requestedScopes = 'openid email profile $_driveScope';
  static const _folderMimeType = 'application/vnd.google-apps.folder';
  static const _authorizationEndpoint =
      'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenEndpoint = 'https://oauth2.googleapis.com/token';
  static const _tokenInfoEndpoint = 'https://oauth2.googleapis.com/tokeninfo';

  static const _refreshTokenKey = 'pilah_google_refresh_token';
  static const _accessTokenKey = 'pilah_google_access_token';
  static const _accessTokenExpiryKey = 'pilah_google_access_token_expiry';
  static const _accountIdKey = 'pilah_google_account_id';
  static const _accountEmailKey = 'pilah_google_account_email';

  static final _secureStorage = FlutterSecureStorage();
  static Future<void>? _googleSignInInitialization;

  DriveAccount? _currentUser;
  GoogleSignInAccount? _googleAccount;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _accessTokenExpiresAt;
  drive.DriveApi? _driveApi;
  http.Client? _authenticatedClient;
  DateTime? _authenticatedAt;
  final Map<String, Future<Uint8List?>> _thumbnailCache = {};

  DriveAccount? get currentUser => _currentUser;
  bool get isConnected =>
      _currentUser != null && _driveApi != null && _accessToken != null;

  Future<DriveAccount?> restoreSession() async {
    _clearApi();
    if (Platform.isAndroid) return _restoreAndroidSession();
    if (Platform.isWindows) return _restoreWindowsSession();
    return null;
  }

  Future<DriveAccount?> _restoreWindowsSession() async {
    final refreshToken = await _secureStorage.read(key: _refreshTokenKey);
    final email = await _secureStorage.read(key: _accountEmailKey);
    if (refreshToken == null || email == null) return null;

    _refreshToken = refreshToken;
    _currentUser = DriveAccount(
      id: await _secureStorage.read(key: _accountIdKey) ?? email,
      email: email,
    );
    final storedAccessToken = await _secureStorage.read(key: _accessTokenKey);
    final storedExpiry = int.tryParse(
      await _secureStorage.read(key: _accessTokenExpiryKey) ?? '',
    );
    if (storedAccessToken != null &&
        storedExpiry != null &&
        DateTime.fromMillisecondsSinceEpoch(storedExpiry)
            .isAfter(DateTime.now().add(const Duration(minutes: 2)))) {
      _accessToken = storedAccessToken;
      _accessTokenExpiresAt = DateTime.fromMillisecondsSinceEpoch(storedExpiry);
    } else {
      await _refreshAccessToken();
    }
    _installClient();
    return _currentUser;
  }

  Future<DriveAccount?> signIn() async {
    if (Platform.isAndroid) return _signInAndroid();
    if (Platform.isWindows) return _signInWindowsDesktop();
    throw UnsupportedError(
      'Google Drive sign-in is currently supported on Android and Windows.',
    );
  }

  Future<DriveAccount?> _restoreAndroidSession() async {
    final oldRefreshToken = await _secureStorage.read(key: _refreshTokenKey);
    if (oldRefreshToken != null) {
      await _deleteStoredTokens();
    }

    final storedAccessToken = await _secureStorage.read(key: _accessTokenKey);
    final email = await _secureStorage.read(key: _accountEmailKey);
    final storedExpiry = int.tryParse(
      await _secureStorage.read(key: _accessTokenExpiryKey) ?? '',
    );
    if (storedAccessToken != null &&
        email != null &&
        storedExpiry != null &&
        DateTime.fromMillisecondsSinceEpoch(storedExpiry)
            .isAfter(DateTime.now().add(const Duration(minutes: 2)))) {
      _accessToken = storedAccessToken;
      _accessTokenExpiresAt = DateTime.fromMillisecondsSinceEpoch(storedExpiry);
      _currentUser = DriveAccount(
        id: await _secureStorage.read(key: _accountIdKey) ?? email,
        email: email,
      );
      _installClient();
      return _currentUser;
    }

    await _ensureGoogleSignInInitialized();
    final attempt = GoogleSignIn.instance.attemptLightweightAuthentication();
    final account = attempt == null ? null : await attempt;
    if (account == null) return null;

    final authorization = await account.authorizationClient
        .authorizationForScopes(_androidDriveScopes);
    if (authorization == null) {
      await _deleteStoredTokens();
      return null;
    }

    await _saveAndroidAuthorization(account, authorization);
    _installClient();
    return _currentUser;
  }

  Future<DriveAccount?> _signInAndroid() async {
    try {
      await _ensureGoogleSignInInitialized();
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: _androidDriveScopes,
      );
      final authorization = await account.authorizationClient.authorizeScopes(
        _androidDriveScopes,
      );
      await _saveAndroidAuthorization(account, authorization);
      _installClient();
      return _currentUser;
    } on GoogleSignInException catch (error) {
      await _logAndroidSignInFailure(
        errorCode: error.code.toString(),
        details: error.description ?? error.toString(),
      );
      final description = error.description ?? '';
      final isConfigurationError =
          error.code == GoogleSignInExceptionCode.clientConfigurationError ||
          description.contains('28444') ||
          description.toLowerCase().contains('developer console');
      if (isConfigurationError) {
        throw const GoogleDriveConnectionException(
          'google_sign_in_configuration_error',
          'Google Sign-In is not configured correctly. Verify the Android '
              'package name, signing certificate SHA-1, and Web OAuth client ID.',
        );
      }
      if (error.code == GoogleSignInExceptionCode.canceled) {
        await GoogleSignIn.instance.signOut();
        return null;
      }
      throw GoogleDriveConnectionException(
        'google_sign_in_failed',
        'Google Sign-In failed: ${error.description ?? error.code}.',
      );
    } on PlatformException catch (error) {
      await _logAndroidSignInFailure(
        errorCode: error.code,
        details: error.message ?? error.toString(),
      );
      throw GoogleDriveConnectionException(
        'google_sign_in_failed',
        'Google Sign-In failed: ${error.message ?? error.code}.',
      );
    }
  }

  Future<void> _ensureGoogleSignInInitialized() {
    final existingInitialization = _googleSignInInitialization;
    if (existingInitialization != null) return existingInitialization;

    final serverClientId = _googleServerClientId.trim();
    final initialization = serverClientId.isEmpty
        ? GoogleSignIn.instance.initialize()
        : GoogleSignIn.instance.initialize(serverClientId: serverClientId);
    _googleSignInInitialization = initialization;
    return initialization;
  }

  Future<void> _logAndroidSignInFailure({
    required String errorCode,
    required String details,
  }) async {
    if (!kDebugMode) return;

    var packageName = 'unavailable';
    var signingSha1 = 'unavailable';
    var effectiveClientId = _googleServerClientId.trim();
    try {
      final diagnostics = await _signInDiagnosticsChannel
          .invokeMapMethod<String, Object?>('getAndroidSignInDiagnostics');
      final reportedPackage = diagnostics?['packageName'];
      final reportedSha1 = diagnostics?['signingSha1'];
      final reportedClientId = diagnostics?['defaultWebClientId'];
      if (reportedPackage is String && reportedPackage.isNotEmpty) {
        packageName = reportedPackage;
      }
      if (reportedSha1 is String && reportedSha1.isNotEmpty) {
        signingSha1 = reportedSha1;
      }
      if (effectiveClientId.isEmpty &&
          reportedClientId is String &&
          reportedClientId.isNotEmpty) {
        effectiveClientId = reportedClientId;
      }
    } on PlatformException catch (error) {
      debugPrint(
        'Google Sign-In diagnostics unavailable: '
        '${error.code}: ${error.message ?? ''}',
      );
    } on MissingPluginException catch (error) {
      debugPrint('Google Sign-In diagnostics unavailable: $error');
    }

    debugPrint(
      'Google Sign-In failure: errorCode=$errorCode; details=$details; '
      'package=$packageName; signingSha1=$signingSha1; '
      'serverClientId=${_maskClientId(effectiveClientId)}',
    );
  }

  String _maskClientId(String clientId) {
    if (clientId.isEmpty) return 'not-configured';
    const appClientSuffix = '.apps.googleusercontent.com';
    final separator = clientId.indexOf('-');
    final suffixStart = clientId.lastIndexOf(appClientSuffix);
    if (separator >= 0 && suffixStart > separator) {
      final clientKey = clientId.substring(separator + 1, suffixStart);
      if (clientKey.length <= 8) return 'configured (masked)';
      return '${clientId.substring(0, separator + 1)}'
          '${clientKey.substring(0, 4)}...'
          '${clientKey.substring(clientKey.length - 4)}'
          '$appClientSuffix';
    }
    if (clientId.length <= 12) return 'configured (masked)';
    return '${clientId.substring(0, 4)}...'
        '${clientId.substring(clientId.length - 4)}';
  }

  Future<void> _saveAndroidAuthorization(
    GoogleSignInAccount account,
    GoogleSignInClientAuthorization authorization,
  ) async {
    if (authorization.accessToken.isEmpty) {
      throw const FormatException(
        'Google Sign-In did not return a Drive access token.',
      );
    }

    _googleAccount = account;
    _currentUser = DriveAccount(id: account.id, email: account.email);
    _accessToken = authorization.accessToken;
    _refreshToken = null;
    _accessTokenExpiresAt = DateTime.now().add(const Duration(minutes: 50));
    await _persistTokens();
  }

  Future<void> _refreshAndroidAccessToken() async {
    await _ensureGoogleSignInInitialized();
    var account = _googleAccount;
    if (account == null) {
      final attempt = GoogleSignIn.instance.attemptLightweightAuthentication();
      account = attempt == null ? null : await attempt;
    }
    if (account == null) {
      throw const GoogleDriveConnectionException(
        'google_account_signed_out',
        'Reconnect your Google account to continue using Drive.',
      );
    }

    final authorization = await account.authorizationClient
        .authorizationForScopes(_androidDriveScopes);
    if (authorization == null) {
      throw const GoogleDriveConnectionException(
        'drive_authorization_expired',
        'Reconnect your Google account to restore Drive access.',
      );
    }
    await _saveAndroidAuthorization(account, authorization);
  }

  Future<DriveAccount?> _signInWindowsDesktop() async {
    if (_windowsDesktopClientId.trim().isEmpty) {
      throw const GoogleDriveConnectionException(
        'missing_windows_desktop_client_id',
        'The Windows Desktop OAuth client ID is not configured.',
      );
    }

    final verifier = createPkceCodeVerifier();
    final state = createOAuthState();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}';
    final authorizationUri = Uri.parse(_authorizationEndpoint).replace(
      queryParameters: {
        'client_id': _windowsDesktopClientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': _requestedScopes,
        'state': state,
        'code_challenge': createPkceCodeChallenge(verifier),
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'consent select_account',
      },
    );

    try {
      final callbackFuture = waitForOAuthCallback(server)
          .timeout(const Duration(minutes: 3));
      final launched = await launchUrl(
        authorizationUri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw const GoogleDriveConnectionException(
          'browser_unavailable',
          'Unable to open a browser to connect to Google Drive.',
        );
      }

      final request = await callbackFuture;
      final callbackUri = request.uri;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..headers.set('Cache-Control', 'no-store');
      request.response.write(
        '<!doctype html><meta charset="utf-8">'
        '<title>PilahFoto</title>'
        '<p>Sign-in complete. You can return to PilahFoto.</p>',
      );
      await request.response.close();

      if (callbackUri.path != '/') {
        throw const FormatException('OAuth callback path was invalid.');
      }
      if (callbackUri.queryParameters['state'] != state) {
        throw const GoogleDriveConnectionException(
          'oauth_state_mismatch',
          'The OAuth response did not match the sign-in request.',
        );
      }
      final authError = callbackUri.queryParameters['error'];
      if (authError == 'access_denied') return null;
      if (authError != null) {
        throw GoogleDriveConnectionException(
          'oauth_authorization_failed',
          'Google OAuth failed: $authError',
        );
      }
      final code = callbackUri.queryParameters['code'];
      if (code == null || code.isEmpty) {
        throw const FormatException(
          'Google OAuth callback did not contain an authorization code.',
        );
      }

      final tokenParameters = createAuthorizationCodeTokenParameters(
        clientId: _windowsDesktopClientId,
        code: code,
        codeVerifier: verifier,
        redirectUri: redirectUri,
      );
      final tokenResponse = await http
          .post(
            Uri.parse(_tokenEndpoint),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: tokenParameters,
          )
          .timeout(const Duration(seconds: 30));
      final tokens = _decodeTokenResponse(tokenResponse);
      final accessToken = _requiredString(tokens, 'access_token');
      final refreshToken = _requiredString(tokens, 'refresh_token');
      final idToken = _requiredString(tokens, 'id_token');
      final account = await _getAccountFromIdToken(idToken);
      final expiresIn = _requiredInt(tokens, 'expires_in');

      _accessToken = accessToken;
      _refreshToken = refreshToken;
      _accessTokenExpiresAt = DateTime.now().add(Duration(seconds: expiresIn));
      _currentUser = account;
      await _persistTokens();
      _installClient();
      return account;
    } on TimeoutException {
      throw const GoogleDriveConnectionException(
        'oauth_timeout',
        'Google sign-in did not complete within 3 minutes. Please try again.',
      );
    } finally {
      await server.close(force: true);
    }
  }

  Future<DriveAccount> _getAccountFromIdToken(String idToken) async {
    final response = await http
        .get(
          Uri.parse(_tokenInfoEndpoint)
              .replace(queryParameters: {'id_token': idToken}),
        )
        .timeout(const Duration(seconds: 30));
    final info = _decodeTokenResponse(response);
    final audience = info['aud'];
    final email = info['email'];
    final id = info['sub'];
    final issuer = info['iss'];
    final emailVerified = info['email_verified'];
    final expiry = int.tryParse(info['exp']?.toString() ?? '');
    if (audience != _windowsDesktopClientId ||
        email is! String ||
        email.isEmpty ||
        (emailVerified != true && emailVerified != 'true') ||
        expiry == null ||
        expiry <= DateTime.now().millisecondsSinceEpoch ~/ 1000 ||
        (issuer != 'accounts.google.com' &&
            issuer != 'https://accounts.google.com')) {
      throw const GoogleDriveConnectionException(
        'invalid_identity_token',
        'Google returned invalid account information.',
      );
    }
    return DriveAccount(id: id is String ? id : email, email: email);
  }

  Map<String, dynamic> _decodeTokenResponse(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Google OAuth returned invalid JSON.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final description = decoded['error_description'];
      final error = decoded['error'];
      throw GoogleDriveConnectionException(
        'oauth_http_${response.statusCode}',
        'Google OAuth failed: ${description is String ? description : error ?? response.statusCode}.',
      );
    }
    return decoded;
  }

  String _requiredString(Map<String, dynamic> response, String key) {
    final value = response[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Google OAuth response is missing $key.');
    }
    return value;
  }

  int _requiredInt(Map<String, dynamic> response, String key) {
    final value = response[key];
    if (value is int && value > 0) return value;
    if (value is num && value > 0) return value.toInt();
    throw FormatException('Google OAuth response is missing $key.');
  }

  Future<void> _refreshAccessToken() async {
    if (Platform.isAndroid) {
      await _refreshAndroidAccessToken();
      return;
    }
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Google Drive token refresh is currently supported on Android and Windows.',
      );
    }
    if (_windowsDesktopClientId.trim().isEmpty) {
      throw const GoogleDriveConnectionException(
        'missing_windows_desktop_client_id',
        'The Windows Desktop OAuth client ID is not configured.',
      );
    }
    final refreshToken = _refreshToken;
    if (refreshToken == null) {
      throw const GoogleDriveConnectionException(
        'missing_refresh_token',
        'Your Google Drive session has expired. Reconnect your Google account.',
      );
    }

    final tokenParameters = <String, String>{
      'client_id': _windowsDesktopClientId,
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    };
    final response = await http
        .post(
          Uri.parse(_tokenEndpoint),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: tokenParameters,
        )
        .timeout(const Duration(seconds: 30));
    final tokens = _decodeTokenResponse(response);
    _accessToken = _requiredString(tokens, 'access_token');
    final rotatedRefreshToken = tokens['refresh_token'];
    if (rotatedRefreshToken is String && rotatedRefreshToken.isNotEmpty) {
      _refreshToken = rotatedRefreshToken;
    }
    _accessTokenExpiresAt = DateTime.now().add(
      Duration(seconds: _requiredInt(tokens, 'expires_in')),
    );
    await _persistTokens();
  }

  Future<void> disconnect() async {
    try {
      if (Platform.isAndroid) {
        await _ensureGoogleSignInInitialized();
        await GoogleSignIn.instance.disconnect();
      }
    } finally {
      try {
        await _deleteStoredTokens();
      } finally {
        _clearApi();
      }
    }
  }

  void close() {
    _clearApi();
  }

  Future<void> _persistTokens() async {
    final user = _currentUser;
    final accessToken = _accessToken;
    final refreshToken = _refreshToken;
    final expiresAt = _accessTokenExpiresAt;
    if (user == null || accessToken == null || expiresAt == null) {
      throw StateError('Cannot persist an incomplete Google OAuth session.');
    }

    if (refreshToken == null) {
      await _secureStorage.delete(key: _refreshTokenKey);
    } else {
      await _secureStorage.write(key: _refreshTokenKey, value: refreshToken);
    }
    await _secureStorage.write(key: _accessTokenKey, value: accessToken);
    await _secureStorage.write(
      key: _accessTokenExpiryKey,
      value: '${expiresAt.millisecondsSinceEpoch}',
    );
    await _secureStorage.write(key: _accountIdKey, value: user.id);
    await _secureStorage.write(key: _accountEmailKey, value: user.email);
  }

  Future<void> _deleteStoredTokens() async {
    await _secureStorage.delete(key: _refreshTokenKey);
    await _secureStorage.delete(key: _accessTokenKey);
    await _secureStorage.delete(key: _accessTokenExpiryKey);
    await _secureStorage.delete(key: _accountIdKey);
    await _secureStorage.delete(key: _accountEmailKey);
  }

  void _installClient() {
    final accessToken = _accessToken;
    if (accessToken == null) {
      throw StateError('Google OAuth did not provide an access token.');
    }
    _authenticatedClient?.close();
    final client = _BearerTokenClient(() => _accessToken!);
    _authenticatedClient = client;
    _driveApi = drive.DriveApi(client);
    _authenticatedAt = DateTime.now();
    _thumbnailCache.clear();
  }

  void _clearApi() {
    _authenticatedClient?.close();
    _authenticatedClient = null;
    _authenticatedAt = null;
    _driveApi = null;
    _currentUser = null;
    _googleAccount = null;
    _accessToken = null;
    _refreshToken = null;
    _accessTokenExpiresAt = null;
    _thumbnailCache.clear();
  }

  Future<drive.DriveApi> _requireApi() async {
    if (_currentUser == null) {
      throw StateError('Connect a Google Drive account in Settings first.');
    }
    final authenticatedAt = _authenticatedAt;
    if (_driveApi == null ||
        authenticatedAt == null ||
        DateTime.now().difference(authenticatedAt) >
            const Duration(minutes: 45)) {
      await _refreshAccessToken();
      _installClient();
    }
    return _driveApi!;
  }

  Future<List<drive.File>> getFolders({String parentId = 'root'}) {
    return _listChildren(
      parentId,
      "mimeType = 'application/vnd.google-apps.folder'",
    );
  }

  Future<drive.File> getFolderFromLink(String link) async {
    final folderId = extractDriveFolderId(link);
    if (folderId == null) {
      throw const FormatException(
        'Link looks incomplete. Copy the full link from Drive Share.',
      );
    }

    final api = await _requireApi();
    final folder = await api.files.get(
      folderId,
      supportsAllDrives: true,
      $fields: 'id,name,mimeType,trashed,parents,capabilities(canAddChildren)',
    ) as drive.File;
    if (folder.id != folderId ||
        folder.name == null ||
        folder.mimeType != _folderMimeType ||
        folder.trashed == true ||
        folder.capabilities?.canAddChildren != true) {
      throw StateError(
        'The linked folder is not available for uploads by this account.',
      );
    }
    return folder;
  }

  Future<drive.File> validateDestinationFolder(
    String folderId, {
    String? folderName,
    String? parentId,
  }) async {
    late final drive.File folder;
    try {
      final api = await _requireApi();
      folder = await api.files.get(
        folderId,
        supportsAllDrives: true,
        $fields:
            'id,name,mimeType,trashed,parents,capabilities(canAddChildren)',
      ) as drive.File;
    } catch (error) {
      final message = error.toString().toLowerCase();
      if (message.contains('404') || message.contains('not found')) {
        return _findRecreatedDestinationFolder(
          folderName: folderName,
          parentId: parentId,
        );
      }
      if (message.contains('403') || message.contains('forbidden')) {
        throw const DriveDestinationFolderException();
      }
      rethrow;
    }

    if (folder.id != folderId ||
        folder.name == null ||
        folder.mimeType != _folderMimeType ||
        folder.trashed == true ||
        folder.capabilities?.canAddChildren != true) {
      throw const DriveDestinationFolderException();
    }
    return folder;
  }

  Future<drive.File> _findRecreatedDestinationFolder({
    required String? folderName,
    required String? parentId,
  }) async {
    if (folderName == null || folderName.isEmpty || parentId == null) {
      throw DriveDestinationFolderException(
        folderName: folderName,
        wasRecreated: folderName != null,
      );
    }

    final escapedName = folderName
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'");
    final candidates = await _listChildren(
      parentId,
      "mimeType = '$_folderMimeType' and name = '$escapedName'",
    );
    final matches = candidates
        .where(
          (folder) =>
              folder.name == folderName &&
              folder.id != null &&
              folder.mimeType == _folderMimeType &&
              folder.trashed != true &&
              folder.capabilities?.canAddChildren == true,
        )
        .toList();
    if (matches.length != 1) {
      throw DriveDestinationFolderException(
        folderName: folderName,
        wasRecreated: true,
      );
    }
    return matches.single;
  }

  Future<drive.File?> pickExistingFolder() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Google Drive Picker is available on Android.');
    }
    final account = _currentUser;
    if (account == null) {
      throw StateError('Connect a Google Drive account in Settings first.');
    }

    final selection = await _pickerChannel.invokeMapMethod<String, Object?>(
      'pickExistingDriveFolder',
      {'accountEmail': account.email},
    );
    if (selection == null) return null;

    final pickedFileIds = selection['pickedFileIds'];
    final accessToken = selection['accessToken'];
    if (pickedFileIds is! String || accessToken is! String) {
      throw const FormatException('Google Picker returned an invalid result.');
    }
    final folderId = pickedFileIds
        .split(',')
        .map((id) => id.trim())
        .firstWhere((id) => id.isNotEmpty, orElse: () => '');
    if (folderId.isEmpty) return null;

    final uri = Uri.https(
      'www.googleapis.com',
      '/drive/v3/files/${Uri.encodeComponent(folderId)}',
      {'fields': 'id,name,mimeType'},
    );
    final response = await http.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Unable to read the selected Drive folder (${response.statusCode}).',
        uri: uri,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Google Drive returned invalid folder details.',
      );
    }
    final folder = drive.File.fromJson(decoded);
    if (folder.id != folderId ||
        folder.name == null ||
        folder.mimeType != _folderMimeType) {
      throw StateError('Google Picker did not return a valid folder.');
    }
    return folder;
  }

  Future<drive.File> createFolder({
    required String name,
    required String parentId,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Folder name cannot be empty.');
    }

    final api = await _requireApi();
    final folder = await api.files.create(
      drive.File(
        name: trimmedName,
        mimeType: 'application/vnd.google-apps.folder',
        parents: [parentId],
      ),
      supportsAllDrives: true,
      $fields: 'id,name,mimeType,parents',
    );
    if (folder.id == null || folder.name == null) {
      throw StateError(
        'Google Drive did not return the created folder details.',
      );
    }
    return folder;
  }

  Future<List<drive.File>> getMediaFiles({required String parentId}) {
    return _listChildren(
      parentId,
      "(mimeType contains 'image/' or mimeType contains 'video/')",
    );
  }

  Future<List<drive.File>> _listChildren(
    String parentId,
    String typeQuery,
  ) async {
    final api = await _requireApi();
    final files = <drive.File>[];
    String? pageToken;

    do {
      final response = await api.files.list(
        q: "'$parentId' in parents and trashed = false and $typeQuery",
        pageSize: 1000,
        pageToken: pageToken,
        orderBy: 'name',
        supportsAllDrives: true,
        includeItemsFromAllDrives: true,
        $fields: 'nextPageToken,files(id,name,mimeType,modifiedTime,thumbnailLink,parents,size,trashed,capabilities(canAddChildren))',
      );
      files.addAll(response.files ?? const []);
      pageToken = response.nextPageToken;
    } while (pageToken != null);

    return files;
  }

  Future<drive.File> uploadFile({
    required File file,
    required String fileName,
    required String parentId,
    String? idempotencyKey,
  }) async {
    final api = await _requireApi();
    if (!await file.exists()) {
      throw FileSystemException('Source file no longer exists', file.path);
    }

    return api.files.create(
      drive.File(
        name: fileName,
        parents: [parentId],
        appProperties: idempotencyKey == null
            ? null
            : {'pilahFotoUploadId': idempotencyKey},
      ),
      uploadMedia: drive.Media(
        file.openRead(),
        await file.length(),
        contentType: _mimeType(fileName),
      ),
      supportsAllDrives: true,
      $fields: 'id,name,mimeType,parents',
    );
  }

  Future<drive.File?> findUploadedFileByTaskId(String taskId) async {
    final api = await _requireApi();
    final response = await api.files.list(
      q:
          "appProperties has { key='pilahFotoUploadId' and value='$taskId' } "
          "and trashed = false",
      pageSize: 1,
      supportsAllDrives: true,
      includeItemsFromAllDrives: true,
      $fields: 'files(id,name,mimeType,parents,appProperties)',
    );
    final files = response.files;
    return files == null || files.isEmpty ? null : files.first;
  }

  Future<drive.File> moveFileToFolder({
    required String fileId,
    required String targetFolderId,
  }) async {
    final api = await _requireApi();
    final file = await api.files.get(
      fileId,
      supportsAllDrives: true,
      $fields: 'id,parents',
    ) as drive.File;
    final parents = file.parents ?? const <String>[];
    if (parents.contains(targetFolderId)) {
      return file;
    }

    final oldParents = parents.where((parent) => parent != targetFolderId);
    return api.files.update(
      drive.File(),
      fileId,
      addParents: targetFolderId,
      removeParents: oldParents.isEmpty ? null : oldParents.join(','),
      supportsAllDrives: true,
      $fields: 'id,name,mimeType,parents',
    );
  }

  Future<Uint8List?> getThumbnailBytes(String fileId) {
    return _thumbnailCache.putIfAbsent(fileId, () async {
      final api = await _requireApi();
      final file = await api.files.get(
        fileId,
        supportsAllDrives: true,
        $fields: 'thumbnailLink',
      ) as drive.File;
      final thumbnailLink = file.thumbnailLink;
      if (thumbnailLink == null) return null;

      final response = await _authenticatedClient!.get(
        Uri.parse(thumbnailLink),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Unable to load Google Drive thumbnail (${response.statusCode}).',
          uri: Uri.parse(thumbnailLink),
        );
      }
      return response.bodyBytes;
    });
  }

  String _mimeType(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'm4v' => 'video/x-m4v',
      'avi' => 'video/x-msvideo',
      _ => 'application/octet-stream',
    };
  }
}

class _BearerTokenClient extends http.BaseClient {
  final String Function() _accessToken;
  final http.Client _inner = http.Client();

  _BearerTokenClient(this._accessToken);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer ${_accessToken()}';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
