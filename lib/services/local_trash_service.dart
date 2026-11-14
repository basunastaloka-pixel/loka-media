import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalTrashItem {
  final String id;
  final String fileName;
  final String filePath;
  final String originalPath;
  final DateTime deletedAt;

  const LocalTrashItem({
    required this.id,
    required this.fileName,
    required this.filePath,
    required this.originalPath,
    required this.deletedAt,
  });

  int get remainingDays {
    final remaining = deletedAt
        .add(const Duration(days: 30))
        .difference(DateTime.now());
    return remaining.inSeconds <= 0
        ? 0
        : (remaining.inSeconds / Duration.secondsPerDay).ceil();
  }

  Map<String, Object> toJson() => {
    'id': id,
    'fileName': fileName,
    'filePath': filePath,
    'originalPath': originalPath,
    'deletedAt': deletedAt.toIso8601String(),
  };

  factory LocalTrashItem.fromJson(Map<String, dynamic> json) {
    return LocalTrashItem(
      id: json['id'] as String,
      fileName: json['fileName'] as String,
      filePath: json['filePath'] as String,
      originalPath: json['originalPath'] as String,
      deletedAt: DateTime.parse(json['deletedAt'] as String),
    );
  }
}

class LocalTrashService {
  static const _itemsKey = 'loka_files_trash_items';
  static const _storageChannel = MethodChannel('loka_files/storage');

  Future<String> _trashDirectoryPath() async {
    final documentsPath = Platform.isAndroid
        ? await _storageChannel.invokeMethod<String>(
            'getPublicDocumentsDirectory',
          )
        : (await getApplicationDocumentsDirectory()).path;
    if (documentsPath == null || documentsPath.isEmpty) {
      throw StateError('The Documents folder is not available.');
    }

    return [documentsPath, 'Loka Files', 'Trash'].join(Platform.pathSeparator);
  }

  Future<List<LocalTrashItem>> listItems() async {
    final preferences = await SharedPreferences.getInstance();
    final items = _readItems(preferences);
    final activeItems = <LocalTrashItem>[];
    var changed = false;
    final now = DateTime.now();

    for (final item in items) {
      final file = File(item.filePath);
      if (!await file.exists()) {
        changed = true;
        continue;
      }
      if (!item.deletedAt.add(const Duration(days: 30)).isAfter(now)) {
        await file.delete();
        changed = true;
        continue;
      }
      activeItems.add(item);
    }

    if (changed) await _saveItems(preferences, activeItems);
    activeItems.sort(
      (left, right) => right.deletedAt.compareTo(left.deletedAt),
    );
    return activeItems;
  }

  Future<void> moveAssetToTrash(AssetEntity asset) async {
    final source = await asset.originFile;
    if (source == null || !await source.exists()) {
      throw FileSystemException('Unable to access the selected media file.');
    }

    final directory = Directory(await _trashDirectoryPath());
    await directory.create(recursive: true);
    final noMediaFile = File(
      '${directory.path}${Platform.pathSeparator}.nomedia',
    );
    if (!await noMediaFile.exists()) await noMediaFile.create();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final fileName = source.path.split(Platform.pathSeparator).last;
    final trashedFile = File(
      '${directory.path}${Platform.pathSeparator}${id}_$fileName',
    );
    final item = LocalTrashItem(
      id: id,
      fileName: fileName,
      filePath: trashedFile.path,
      originalPath: source.path,
      deletedAt: DateTime.now(),
    );
    final preferences = await SharedPreferences.getInstance();
    final items = _readItems(preferences);

    await source.copy(trashedFile.path);
    try {
      await _saveItems(preferences, [...items, item]);
    } catch (_) {
      if (await trashedFile.exists()) await trashedFile.delete();
      rethrow;
    }
    final removedIds = await PhotoManager.editor.deleteWithIds([asset.id]);
    if (!removedIds.contains(asset.id)) {
      throw StateError('The original file could not be moved to Trash.');
    }
  }

  Future<void> restore(LocalTrashItem item) async {
    final trashedFile = File(item.filePath);
    if (!await trashedFile.exists()) {
      throw FileSystemException('This Trash item is no longer available.');
    }
    final originalFile = File(item.originalPath);
    await originalFile.parent.create(recursive: true);
    if (await originalFile.exists()) {
      throw FileSystemException(
        'A file already exists at the original location.',
        item.originalPath,
      );
    }

    await trashedFile.copy(originalFile.path);
    if (Platform.isAndroid) {
      await _storageChannel.invokeMethod<void>('scanRestoredFile', {
        'path': originalFile.path,
      });
    }
    await trashedFile.delete();
    await _removeItem(item.id);
  }

  Future<void> deletePermanently(LocalTrashItem item) async {
    final file = File(item.filePath);
    if (await file.exists()) await file.delete();
    await _removeItem(item.id);
  }

  Future<void> _removeItem(String id) async {
    final preferences = await SharedPreferences.getInstance();
    await _saveItems(
      preferences,
      _readItems(preferences).where((item) => item.id != id).toList(),
    );
  }

  List<LocalTrashItem> _readItems(SharedPreferences preferences) {
    final encoded = preferences.getString(_itemsKey);
    if (encoded == null) return [];
    final decoded = jsonDecode(encoded);
    if (decoded is! List) {
      throw const FormatException('The Trash index is invalid.');
    }
    return decoded
        .map(
          (entry) =>
              LocalTrashItem.fromJson(Map<String, dynamic>.from(entry as Map)),
        )
        .toList();
  }

  Future<void> _saveItems(
    SharedPreferences preferences,
    List<LocalTrashItem> items,
  ) async {
    final saved = await preferences.setString(
      _itemsKey,
      jsonEncode(items.map((item) => item.toJson()).toList()),
    );
    if (!saved) throw StateError('The Trash index could not be saved.');
  }
}
