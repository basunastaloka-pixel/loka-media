import 'package:photo_manager/photo_manager.dart';

class GalleryService {
  // Request access to the device's gallery.
  static Future<bool> requestPermission() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    return ps.isAuth;
  }

  // Retrieve the most recent photos and videos from the gallery.
  static Future<List<AssetEntity>> fetchRecentAssets({int limit = 100}) async {
    final bool isAuth = await requestPermission();
    if (!isAuth) return [];

    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
    );

    if (paths.isEmpty) return [];

    // Use the primary album (Recents / All Photos).
    final AssetPathEntity recentAlbum = paths.first;
    return await recentAlbum.getAssetListRange(start: 0, end: limit);
  }
}
