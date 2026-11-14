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
  final DateTime originalDate;
  final int fileSizeBytes;
  final int videoDurationMilliseconds;

  const LocalTrashItem({
    required this.id,
    required this.fileName,
    required this.filePath,
    required this.originalPath,
    required this.deletedAt,
    DateTime? originalDate,
    this.fileSizeBytes = 0,
    this.videoDurationMilliseconds = 0,
  }) : originalDate = originalDate ?? deletedAt;

  LocalTrashItem copyWith({
    DateTime? originalDate,
    int? fileSizeBytes,
    int? videoDurationMilliseconds,
  }) {
    return LocalTrashItem(
      id: id,
      fileName: fileName,
      filePath: filePath,
      originalPath: originalPath,
      deletedAt: deletedAt,
      originalDate: originalDate ?? this.originalDate,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      videoDurationMilliseconds:
          videoDurationMilliseconds ?? this.videoDurationMilliseconds,
    );
  }

  int get remainingDays {
    final remaining = deletedAt
        .add(const Duration(days: 30))
        .difference(DateTime.now());
    return remaining.inSeconds <= 0
        ? 0
        : (remaining.inSeconds / Duration.secondsPerDay).ceil();
  }

  bool get isVideo =>
      videoDurationMilliseconds > 0 ||
      const {
        'mp4',
        'mov',
        'm4v',
        'avi',
        'mkv',
        'webm',
        '3gp',
        '3g2',
        'ts',
        'mpg',
        'mpeg',
        'm2ts',
        'mts',
        'wmv',
        'flv',
        'ogv',
      }.contains(fileName.split('.').last.toLowerCase());

  Map<String, Object> toJson() => {
    'id': id,
    'fileName': fileName,
    'filePath': filePath,
    'originalPath': originalPath,
    'deletedAt': deletedAt.toIso8601String(),
    'originalDate': originalDate.toIso8601String(),
    'fileSizeBytes': fileSizeBytes,
    'videoDurationMilliseconds': videoDurationMilliseconds,
  };

  factory LocalTrashItem.fromJson(Map<String, dynamic> json) {
    final deletedAt = DateTime.parse(json['deletedAt'] as String);
    return LocalTrashItem(
      id: json['id'] as String,
      fileName: json['fileName'] as String,
      filePath: json['filePath'] as String,
      originalPath: json['originalPath'] as String,
      deletedAt: deletedAt,
      originalDate: json['originalDate'] is String
          ? DateTime.parse(json['originalDate'] as String)
          : deletedAt,
      fileSizeBytes: json['fileSizeBytes'] is int
          ? json['fileSizeBytes'] as int
          : 0,
      videoDurationMilliseconds: json['videoDurationMilliseconds'] is int
          ? json['videoDurationMilliseconds'] as int
          : 0,
    );
  }
}

enum TrashSortOrder {
  newestDeleted,
  oldestDeleted,
  newestOriginal,
  oldestOriginal,
}

class LocalTrashService {
  static const _itemsKey = 'loka_files_trash_items';
  static const _sortOrderKey = 'loka_files_trash_sort_order';
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

  Future<TrashSortOrder> getSortOrder() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString(_sortOrderKey);
    return TrashSortOrder.values.firstWhere(
      (order) => order.name == value,
      orElse: () => TrashSortOrder.newestDeleted,
    );
  }

  Future<void> saveSortOrder(TrashSortOrder order) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString(_sortOrderKey, order.name);
    if (!saved) throw StateError('The Trash sort order could not be saved.');
  }

  Future<List<LocalTrashItem>> listItems({TrashSortOrder? sortOrder}) async {
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
      final fileSizeBytes = await file.length();
      final updatedItem = item.copyWith(fileSizeBytes: fileSizeBytes);
      if (updatedItem.fileSizeBytes != item.fileSizeBytes) changed = true;
      activeItems.add(updatedItem);
    }

    if (changed) await _saveItems(preferences, activeItems);
    return sortItems(activeItems, sortOrder ?? await getSortOrder());
  }

  Future<LocalTrashItem> moveAssetToTrash(AssetEntity asset) async {
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
      originalDate: asset.createDateTime,
      fileSizeBytes: await source.length(),
      videoDurationMilliseconds: asset.duration,
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
    return item;
  }

  static List<LocalTrashItem> sortItems(
    List<LocalTrashItem> items,
    TrashSortOrder order,
  ) {
    final sortedItems = List<LocalTrashItem>.of(items);
    final useOriginalDate = switch (order) {
      TrashSortOrder.newestOriginal || TrashSortOrder.oldestOriginal => true,
      _ => false,
    };
    final descending = switch (order) {
      TrashSortOrder.newestDeleted || TrashSortOrder.newestOriginal => true,
      _ => false,
    };
    sortedItems.sort((left, right) {
      final leftDate = useOriginalDate ? left.originalDate : left.deletedAt;
      final rightDate = useOriginalDate ? right.originalDate : right.deletedAt;
      final comparison = leftDate.compareTo(rightDate);
      return descending ? -comparison : comparison;
    });
    return sortedItems;
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
