import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppUpdateRelease {
  final String version;
  final String apkDownloadUrl;

  const AppUpdateRelease({required this.version, required this.apkDownloadUrl});
}

class AppUpdateService {
  static final _latestReleaseUri = Uri.https(
    'api.github.com',
    '/repos/basunastaloka-pixel/loka-media/releases/latest',
  );

  final http.Client _client;

  AppUpdateService({http.Client? client}) : _client = client ?? http.Client();

  Future<AppUpdateRelease?> checkForUpdate() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final response = await _client
        .get(
          _latestReleaseUri,
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'LokaMedia',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'GitHub returned status ${response.statusCode} while checking for updates.',
        uri: _latestReleaseUri,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('GitHub returned an invalid release.');
    }
    final tagName = decoded['tag_name'];
    if (tagName is! String || tagName.isEmpty) {
      throw const FormatException(
        'The latest GitHub release has no version tag.',
      );
    }

    final version = _normalizeVersion(tagName);
    if (compareVersions(version, packageInfo.version) <= 0) return null;

    final assets = decoded['assets'];
    if (assets is! List) {
      throw const FormatException(
        'The latest GitHub release has no APK assets.',
      );
    }
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;
      final name = asset['name'];
      final downloadUrl = asset['browser_download_url'];
      if (name is String &&
          name.toLowerCase().endsWith('.apk') &&
          downloadUrl is String) {
        return AppUpdateRelease(version: version, apkDownloadUrl: downloadUrl);
      }
    }
    throw const FormatException(
      'The latest GitHub release does not include an APK.',
    );
  }

  Future<File> downloadApk(AppUpdateRelease release) async {
    final uri = Uri.tryParse(release.apkDownloadUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.contains('/releases/download/')) {
      throw const FormatException('The APK download URL is invalid.');
    }

    final request = http.Request('GET', uri)
      ..headers['User-Agent'] = 'LokaMedia';
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'GitHub returned status ${response.statusCode} while downloading the update.',
        uri: uri,
      );
    }

    final temporaryDirectory = await getTemporaryDirectory();
    final apkFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}loka-media-update.apk',
    );
    final sink = apkFile.openWrite();
    await response.stream.pipe(sink);
    if (!await apkFile.exists() || await apkFile.length() == 0) {
      throw const FileSystemException('The downloaded APK is empty.');
    }
    return apkFile;
  }

  void close() => _client.close();

  static int compareVersions(String left, String right) {
    final leftParts = _versionParts(left);
    final rightParts = _versionParts(right);
    for (var index = 0; index < 4; index++) {
      final leftPart = index < leftParts.length ? leftParts[index] : 0;
      final rightPart = index < rightParts.length ? rightParts[index] : 0;
      if (leftPart != rightPart) return leftPart.compareTo(rightPart);
    }
    return 0;
  }

  static String _normalizeVersion(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
    _versionParts(normalized);
    return normalized;
  }

  static List<int> _versionParts(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final numericVersion = normalized.split(RegExp(r'[-+]')).first;
    if (!RegExp(r'^\d+(?:\.\d+){1,3}$').hasMatch(numericVersion)) {
      throw FormatException('Invalid version: $value');
    }
    return numericVersion.split('.').map(int.parse).toList();
  }
}
