import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'drive_folder_link.dart';
import 'drive_oauth_pkce.dart';

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

class GoogleDriveService {
  static const _pickerChannel = MethodChannel('pilah_foto/google_drive_picker');
  static const _desktopClientId = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_ID',
  );
  static const _driveScope = 'https://www.googleapis.com/auth/drive.file';
  static const _requestedScopes = 'openid email $_driveScope';
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

  DriveAccount? _currentUser;
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
    if (_desktopClientId.trim().isEmpty) {
      throw const GoogleDriveConnectionException(
        'missing_desktop_client_id',
        'Google Desktop OAuth client ID is not configured. Launch the app '
            'with --dart-define=GOOGLE_DESKTOP_CLIENT_ID=<client-id>.',
      );
    }

    final verifier = createPkceCodeVerifier();
    final state = createOAuthState();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}';
    final authorizationUri = Uri.parse(_authorizationEndpoint).replace(
      queryParameters: {
        'client_id': _desktopClientId,
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
      final callbackFuture = server.first.timeout(const Duration(minutes: 3));
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
        clientId: _desktopClientId,
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
    if (audience != _desktopClientId ||
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
    if (_desktopClientId.trim().isEmpty) {
      throw const GoogleDriveConnectionException(
        'missing_desktop_client_id',
        'Google Desktop OAuth client ID is not configured.',
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
      'client_id': _desktopClientId,
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
    await _secureStorage.delete(key: _refreshTokenKey);
    await _secureStorage.delete(key: _accessTokenKey);
    await _secureStorage.delete(key: _accessTokenExpiryKey);
    await _secureStorage.delete(key: _accountIdKey);
    await _secureStorage.delete(key: _accountEmailKey);
    _clearApi();
  }

  void close() {
    _clearApi();
  }

  Future<void> _persistTokens() async {
    final user = _currentUser;
    final accessToken = _accessToken;
    final refreshToken = _refreshToken;
    final expiresAt = _accessTokenExpiresAt;
    if (user == null ||
        accessToken == null ||
        refreshToken == null ||
        expiresAt == null) {
      throw StateError('Cannot persist an incomplete Google OAuth session.');
    }

    await _secureStorage.write(key: _refreshTokenKey, value: refreshToken);
    await _secureStorage.write(key: _accessTokenKey, value: accessToken);
    await _secureStorage.write(
      key: _accessTokenExpiryKey,
      value: '${expiresAt.millisecondsSinceEpoch}',
    );
    await _secureStorage.write(key: _accountIdKey, value: user.id);
    await _secureStorage.write(key: _accountEmailKey, value: user.email);
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
      throw const FormatException('Enter a valid Google Drive folder link.');
    }

    final api = await _requireApi();
    final folder = await api.files.get(
      folderId,
      supportsAllDrives: true,
      $fields: 'id,name,mimeType',
    ) as drive.File;
    if (folder.id != folderId ||
        folder.name == null ||
        folder.mimeType != _folderMimeType) {
      throw const FormatException(
        'The link does not point to an accessible Google Drive folder.',
      );
    }
    return folder;
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
        $fields: 'nextPageToken,files(id,name,mimeType,modifiedTime,thumbnailLink,parents,size)',
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
