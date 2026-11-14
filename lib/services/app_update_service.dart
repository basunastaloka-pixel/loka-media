import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppUpdateRelease {
  final String version;
  final String assetName;
  final String apkDownloadUrl;
  final int assetSize;

  const AppUpdateRelease({
    required this.version,
    required this.assetName,
    required this.apkDownloadUrl,
    required this.assetSize,
  });
}

class AppUpdateService {
  static final _latestReleaseUri = Uri.https(
    'api.github.com',
    '/repos/basunastaloka-pixel/loka-media/releases/latest',
  );

  final http.Client _client;

  AppUpdateService({http.Client? client}) : _client = client ?? http.Client();

  Future<String> getCurrentVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  Future<AppUpdateRelease?> checkForUpdate({
    required String manufacturer,
    required List<String> supportedAbis,
  }) async {
    final currentVersion = await getCurrentVersion();
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
    if (compareVersions(version, currentVersion) <= 0) return null;

    final assetName = selectApkAssetName(
      version,
      manufacturer: manufacturer,
      supportedAbis: supportedAbis,
    );
    final assets = decoded['assets'];
    if (assets is! List) {
      throw const FormatException(
        'The latest GitHub release has no APK assets.',
      );
    }
    for (final asset in assets) {
      if (asset is! Map<String, dynamic> || asset['name'] != assetName) {
        continue;
      }
      final downloadUrl = asset['browser_download_url'];
      final assetSize = asset['size'];
      if (downloadUrl is! String || assetSize is! int || assetSize <= 0) {
        throw FormatException('The release asset $assetName is invalid.');
      }
      return AppUpdateRelease(
        version: version,
        assetName: assetName,
        apkDownloadUrl: downloadUrl,
        assetSize: assetSize,
      );
    }
    throw FormatException(
      'The latest GitHub release does not include $assetName.',
    );
  }

  Future<File> downloadApk(
    AppUpdateRelease release, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
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
    if (await apkFile.exists()) await apkFile.delete();

    var receivedBytes = 0;
    var sinkClosed = false;
    final sink = apkFile.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        onProgress?.call(receivedBytes, release.assetSize);
      }
      await sink.flush();
      await sink.close();
      sinkClosed = true;
      if (receivedBytes != release.assetSize ||
          !await isValidApkFile(apkFile)) {
        throw const FormatException('The downloaded file is not a valid APK.');
      }
      return apkFile;
    } catch (error, stackTrace) {
      if (!sinkClosed) await sink.close();
      if (await apkFile.exists()) await apkFile.delete();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  static Future<bool> isValidApkFile(File file) async {
    if (!await file.exists()) return false;
    final bytes = await file.readAsBytes();
    return isValidApkBytes(bytes);
  }

  static bool isValidApkBytes(List<int> bytes) {
    if (bytes.length < 22) return false;
    final data = ByteData.sublistView(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    final minimumEocdOffset = bytes.length - 22 - 0xFFFF;
    final firstEocdOffset = minimumEocdOffset < 0 ? 0 : minimumEocdOffset;
    var eocdOffset = -1;
    for (var offset = bytes.length - 22; offset >= firstEocdOffset; offset--) {
      if (_readUint32(data, offset) == 0x06054B50 &&
          offset + 22 + _readUint16(data, offset + 20) == bytes.length) {
        eocdOffset = offset;
        break;
      }
    }
    if (eocdOffset < 0 ||
        _readUint16(data, eocdOffset + 4) != 0 ||
        _readUint16(data, eocdOffset + 6) != 0 ||
        _readUint16(data, eocdOffset + 8) !=
            _readUint16(data, eocdOffset + 10)) {
      return false;
    }

    final entryCount = _readUint16(data, eocdOffset + 10);
    final directorySize = _readUint32(data, eocdOffset + 12);
    final directoryOffset = _readUint32(data, eocdOffset + 16);
    if (entryCount == 0 ||
        directoryOffset + directorySize > eocdOffset ||
        directoryOffset + directorySize < directoryOffset) {
      return false;
    }

    var offset = directoryOffset;
    var hasManifest = false;
    for (var entry = 0; entry < entryCount; entry++) {
      if (offset + 46 > directoryOffset + directorySize ||
          _readUint32(data, offset) != 0x02014B50) {
        return false;
      }
      final filenameLength = _readUint16(data, offset + 28);
      final extraLength = _readUint16(data, offset + 30);
      final commentLength = _readUint16(data, offset + 32);
      final compressedSize = _readUint32(data, offset + 20);
      final uncompressedSize = _readUint32(data, offset + 24);
      final localHeaderOffset = _readUint32(data, offset + 42);
      final nextOffset =
          offset + 46 + filenameLength + extraLength + commentLength;
      if (nextOffset > directoryOffset + directorySize ||
          localHeaderOffset + 30 > directoryOffset ||
          _readUint32(data, localHeaderOffset) != 0x04034B50) {
        return false;
      }
      final localFilenameLength = _readUint16(data, localHeaderOffset + 26);
      final localExtraLength = _readUint16(data, localHeaderOffset + 28);
      final contentOffset =
          localHeaderOffset + 30 + localFilenameLength + localExtraLength;
      if (contentOffset + compressedSize > directoryOffset) return false;
      final filename = String.fromCharCodes(
        bytes.sublist(offset + 46, offset + 46 + filenameLength),
      );
      if (filename == 'AndroidManifest.xml' && uncompressedSize > 0) {
        hasManifest = true;
      }
      offset = nextOffset;
    }
    return hasManifest && offset == directoryOffset + directorySize;
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

  static String selectApkAssetName(
    String version, {
    required String manufacturer,
    required List<String> supportedAbis,
  }) {
    final useArmeabiV7a =
        manufacturer.trim().toLowerCase() == 'huawei' ||
        (supportedAbis.isNotEmpty &&
            supportedAbis.first.toLowerCase() == 'armeabi-v7a');
    final suffix = useArmeabiV7a ? '-armeabi-v7a' : '';
    return 'Loka-Files-v${_normalizeVersion(version)}$suffix.apk';
  }

  static String formatVersionLabel(
    String currentVersion, {
    String? latestVersion,
  }) {
    final current = 'Current version: v${_normalizeVersion(currentVersion)}';
    if (latestVersion == null) return current;
    return '$current | Latest: v${_normalizeVersion(latestVersion)}';
  }

  static int _readUint16(ByteData data, int offset) =>
      offset + 2 <= data.lengthInBytes
      ? data.getUint16(offset, Endian.little)
      : -1;

  static int _readUint32(ByteData data, int offset) =>
      offset + 4 <= data.lengthInBytes
      ? data.getUint32(offset, Endian.little)
      : -1;

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
