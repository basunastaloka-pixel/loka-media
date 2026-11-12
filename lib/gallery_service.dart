import 'package:photo_manager/photo_manager.dart';

class GalleryService {
  // Minta izin ke HP
  static Future<bool> requestPermission() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    return ps.isAuth;
  }

  // Ambil daftar foto & video terbaru dari galeri
  static Future<List<AssetEntity>> fetchRecentAssets({int limit = 100}) async {
    final bool isAuth = await requestPermission();
    if (!isAuth) return [];

    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
      type: RequestType.common, // Ambil Foto & Video
      onlyAll: true,
    );

    if (paths.isEmpty) return [];

    // Ambil album utama (Recents / Semua Foto)
    final AssetPathEntity recentAlbum = paths.first;
    return await recentAlbum.getAssetListRange(start: 0, end: limit);
  }
}