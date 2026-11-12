import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drive_source_screen.dart';
import 'models/target_folder.dart';
import 'services/drive_upload_queue.dart';
import 'services/google_drive_service.dart';
import 'settings_screen.dart';

enum MediaTypeFilter { all, photos, videos }

class SortHistory {
  final AssetEntity photo;
  final String targetLabel;
  final String? originalPath;
  final String? movedPath;
  final bool undoable;

  SortHistory({
    required this.photo,
    required this.targetLabel,
    this.originalPath,
    this.movedPath,
    this.undoable = true,
  });
}

class SortScreen extends StatefulWidget {
  const SortScreen({super.key});

  @override
  State<SortScreen> createState() => _SortScreenState();
}

class _SortScreenState extends State<SortScreen> with WidgetsBindingObserver {
  final GoogleDriveService _driveService = GoogleDriveService();

  static const List<Color> _folderPastelColors = [
    Color(0xFFF0C7B5),
    Color(0xFFC9DCCB),
    Color(0xFFC8D9EE),
    Color(0xFFDECDED),
    Color(0xFFF1E1AF),
    Color(0xFFBFE0D9),
  ];

  List<AssetPathEntity> _albums = [];
  AssetPathEntity? _selectedAlbum;

  bool _albumListView = false;
  List<AssetEntity> _rawPhotos = [];
  List<AssetEntity> _allPhotos = [];

  bool _isLoadingAlbums = false;
  bool _isLoadingPhotos = false;
  bool _isMovingFile = false;

  bool _isAscending = false;
  MediaTypeFilter _mediaFilter = MediaTypeFilter.all;

  List<TargetFolder> targetFolders = [
    TargetFolder(label: 'Folder 1', path: ''),
    TargetFolder(label: 'Folder 2', path: ''),
    TargetFolder(label: 'Folder 3', path: ''),
    TargetFolder(label: 'Folder 4', path: ''),
  ];

  Map<String, int> movedCounts = {};

  int currentIndex = 0;
  final List<SortHistory> _history = [];
  final Set<String> _deletingDriveBatches = {};
  Timer? _driveBatchPollTimer;
  Future<void> _driveQueueTail = Future<void>.value();
  String? _activeDriveBatchId;
  int _driveQueueSequence = 0;
  bool _isCheckingDriveBatches = false;
  bool _isAppResumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _driveBatchPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_processCompletedDriveBatches()),
    );
    _loadSavedFolders();
    _requestStoragePermissions();
    _fetchAlbums();
    _restoreDriveSession();
    unawaited(_processCompletedDriveBatches());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppResumed = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _sealCurrentDriveBatch();
    } else if (_isAppResumed) {
      unawaited(_processCompletedDriveBatches());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _driveBatchPollTimer?.cancel();
    _sealCurrentDriveBatch();
    _driveService.close();
    super.dispose();
  }

  Future<void> _restoreDriveSession() async {
    try {
      await _driveService.restoreSession();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not restore Google Drive session: $error'),
          ),
        );
      }
    }
  }

  Future<void> _requestStoragePermissions() async {
    if (Platform.isAndroid) {
      if (!await Permission.manageExternalStorage.isGranted) {
        await Permission.manageExternalStorage.request();
      }
    }
  }

  Future<void> _loadSavedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final String? savedJson = prefs.getString('saved_target_folders');
    if (savedJson != null) {
      final List<dynamic> decoded = jsonDecode(savedJson);
      setState(() {
        targetFolders = decoded.map((e) => TargetFolder.fromJson(e)).toList();
      });
    }
  }

  Future<void> _saveFoldersToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(
      targetFolders.map((e) => e.toJson()).toList(),
    );
    await prefs.setString('saved_target_folders', encoded);
  }

  Future<void> _fetchAlbums() async {
    setState(() => _isLoadingAlbums = true);

    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) {
      setState(() => _isLoadingAlbums = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Gallery permission denied.')),
        );
      }
      return;
    }

    final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: true,
    );

    setState(() {
      _albums = albums;
      _isLoadingAlbums = false;
    });
  }

  Future<void> _selectFolder(AssetPathEntity album) async {
    _sealCurrentDriveBatch();
    setState(() {
      _selectedAlbum = album;
      _isLoadingPhotos = true;
    });

    final int totalCount = await album.assetCountAsync;
    final List<AssetEntity> assets = await album.getAssetListRange(
      start: 0,
      end: totalCount,
    );

    _rawPhotos = assets;
    _applyFilterAndSort();

    setState(() {
      _isLoadingPhotos = false;
    });
  }

  void _applyFilterAndSort() {
    _sealCurrentDriveBatch();
    List<AssetEntity> temp = List.from(_rawPhotos);

    if (_mediaFilter == MediaTypeFilter.photos) {
      temp = temp.where((item) => item.type == AssetType.image).toList();
    } else if (_mediaFilter == MediaTypeFilter.videos) {
      temp = temp.where((item) => item.type == AssetType.video).toList();
    }

    if (_isAscending) {
      temp.sort((a, b) => a.createDateTime.compareTo(b.createDateTime));
    } else {
      temp.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    }

    setState(() {
      _allPhotos = temp;
      currentIndex = 0;
      _history.clear();
      movedCounts.clear();
    });
  }

  void _toggleSortOrder() {
    setState(() {
      _isAscending = !_isAscending;
      _applyFilterAndSort();
    });
  }

  void _kembaliKePilihFolder() {
    _sealCurrentDriveBatch();
    setState(() {
      _selectedAlbum = null;
      _rawPhotos = [];
      _allPhotos = [];
      _mediaFilter = MediaTypeFilter.all;
    });
    _fetchAlbums();
  }

  void _playVideoDialog(AssetEntity asset) async {
    final File? file = await asset.file;
    if (file == null || !mounted) return;
    showDialog(
      context: context,
      builder: (context) => VideoPlayerModal(file: file),
    );
  }

  Future<void> pindahFolder(TargetFolder target) async {
    if (currentIndex >= _allPhotos.length || _isMovingFile) return;

    if (!target.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Choose a destination for "${target.label}" in Settings first.',
          ),
          action: SnackBarAction(label: 'SETTINGS', onPressed: openSettings),
        ),
      );
      return;
    }

    if (target.isDriveDestination && !_driveService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connect Google Drive in Settings first.'),
        ),
      );
      return;
    }

    if (target.isDriveDestination &&
        target.driveAccountEmail != null &&
        target.driveAccountEmail != _driveService.currentUser?.email) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Reconnect Google Drive as ${target.driveAccountEmail} to use this destination.',
          ),
        ),
      );
      return;
    }

    if (target.isDriveDestination && Platform.isAndroid) {
      _queueDriveUpload(target);
      return;
    }

    setState(() => _isMovingFile = true);

    final currentAsset = _allPhotos[currentIndex];
    String? originalPath;
    String? destinationPath;

    try {
      final sourceFile = await currentAsset.originFile;
      if (sourceFile == null || !await sourceFile.exists()) {
        throw FileSystemException('Unable to access the selected media file.');
      }

      originalPath = sourceFile.path;
      final fileName = originalPath.split(Platform.pathSeparator).last;

      if (target.isDriveDestination) {
        final uploadedFile = await _driveService.uploadFile(
          file: sourceFile,
          fileName: fileName,
          parentId: target.driveFolderId!,
        );
        if (uploadedFile.id == null) {
          throw StateError('Google Drive did not return an uploaded file ID.');
        }

        final deletedIds = await PhotoManager.editor.deleteWithIds([
          currentAsset.id,
        ]);
        if (!deletedIds.contains(currentAsset.id)) {
          throw StateError(
            'The file was uploaded, but could not be removed from this device. '
            'A copy remains in Google Drive.',
          );
        }
      } else {
        final destDir = Directory(target.path);
        if (!await destDir.exists()) {
          await destDir.create(recursive: true);
        }

        destinationPath = '${target.path}${Platform.pathSeparator}$fileName';
        if (await File(destinationPath).exists()) {
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          destinationPath =
              '${target.path}${Platform.pathSeparator}${timestamp}_$fileName';
        }

        await sourceFile.copy(destinationPath);
        await sourceFile.delete();
      }

      setState(() {
        _history.add(
          SortHistory(
            photo: currentAsset,
            targetLabel: target.label,
            originalPath: target.isDriveDestination ? null : originalPath,
            movedPath: destinationPath,
            undoable: !target.isDriveDestination,
          ),
        );
        movedCounts[target.label] = (movedCounts[target.label] ?? 0) + 1;
        currentIndex++;
        _isMovingFile = false;
      });
      if (currentIndex >= _allPhotos.length) {
        _sealCurrentDriveBatch();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _isMovingFile = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to move file: $error')));
    }
  }

  void _queueDriveUpload(TargetFolder target) {
    final asset = _allPhotos[currentIndex];
    final batchId = _activeDriveBatchId ??= DriveUploadQueue.createBatchId();
    final taskId = DriveUploadQueue.createTaskId(
      batchId,
      _driveQueueSequence++,
    );
    final targetFolderId = target.driveFolderId!;
    final accountEmail = _driveService.currentUser!.email;

    setState(() {
      _history.add(
        SortHistory(photo: asset, targetLabel: target.label, undoable: false),
      );
      movedCounts[target.label] = (movedCounts[target.label] ?? 0) + 1;
      currentIndex++;
    });

    _driveQueueTail = _driveQueueTail.then(
      (_) => _prepareAndEnqueueDriveUpload(
        asset: asset,
        batchId: batchId,
        taskId: taskId,
        targetLabel: target.label,
        accountEmail: accountEmail,
        targetFolderId: targetFolderId,
      ),
    );

    if (currentIndex >= _allPhotos.length) {
      _sealCurrentDriveBatch();
    }
  }

  Future<void> _prepareAndEnqueueDriveUpload({
    required AssetEntity asset,
    required String batchId,
    required String taskId,
    required String targetLabel,
    required String accountEmail,
    required String targetFolderId,
  }) async {
    File? stagedFile;
    try {
      final sourceFile = await asset.originFile;
      if (sourceFile == null || !await sourceFile.exists()) {
        throw FileSystemException('Unable to access the selected media file.');
      }

      final fileName = sourceFile.path.split(Platform.pathSeparator).last;
      final supportDirectory = await getApplicationSupportDirectory();
      final queueDirectory = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}drive_upload_queue',
      );
      await queueDirectory.create(recursive: true);
      stagedFile = File(
        '${queueDirectory.path}${Platform.pathSeparator}${taskId}_$fileName',
      );
      await sourceFile.copy(stagedFile.path);

      await DriveUploadQueue.enqueue(
        batchId: batchId,
        taskId: taskId,
        assetId: asset.id,
        targetLabel: targetLabel,
        accountEmail: accountEmail,
        sourcePath: stagedFile.path,
        fileName: fileName,
        parentId: targetFolderId,
      );
    } catch (error, stackTrace) {
      debugPrint('[DriveUpload] Could not queue $taskId: $error\n$stackTrace');
      try {
        await DriveUploadQueue.recordFailure(
          batchId: batchId,
          taskId: taskId,
          assetId: asset.id,
          targetLabel: targetLabel,
          error: error.toString(),
        );
      } catch (recordError, recordStackTrace) {
        debugPrint(
          '[DriveUpload] Could not record queue failure for $taskId: '
          '$recordError\n$recordStackTrace',
        );
      }
      if (stagedFile != null) {
        try {
          if (await stagedFile.exists()) await stagedFile.delete();
        } on FileSystemException catch (cleanupError) {
          debugPrint(
            '[DriveUpload] Could not remove staged file: $cleanupError',
          );
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not queue "${asset.title ?? 'media'}" for Drive upload: '
              '$error',
            ),
          ),
        );
      }
    }
  }

  void _sealCurrentDriveBatch() {
    final batchId = _activeDriveBatchId;
    if (batchId == null) return;
    _activeDriveBatchId = null;
    _driveQueueTail = _driveQueueTail
        .then((_) => DriveUploadQueue.sealBatch(batchId))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint(
            '[DriveUpload] Could not seal batch $batchId: '
            '$error\n$stackTrace',
          );
        });
  }

  Future<void> _processCompletedDriveBatches() async {
    if (!Platform.isAndroid ||
        !_isAppResumed ||
        _isCheckingDriveBatches ||
        !mounted) {
      return;
    }
    _isCheckingDriveBatches = true;

    try {
      final readyBatches = await DriveUploadQueue.getReadyBatches();
      final claimedBatches = <DriveUploadBatchResult>[];
      for (final batch in readyBatches) {
        if (!_deletingDriveBatches.add(batch.id)) continue;
        if (await DriveUploadQueue.markDeletionRequested(batch.id)) {
          claimedBatches.add(batch);
        } else {
          _deletingDriveBatches.remove(batch.id);
        }
      }
      if (claimedBatches.isEmpty) return;

      final uploadedAssetIds = claimedBatches
          .expand((batch) => batch.uploadedAssetIds)
          .toSet()
          .toList();
      var deletedAssetIds = <String>[];
      Object? deletionError;
      if (uploadedAssetIds.isNotEmpty) {
        try {
          deletedAssetIds = await PhotoManager.editor.deleteWithIds(
            uploadedAssetIds,
          );
        } catch (error, stackTrace) {
          deletionError = error;
          debugPrint(
            '[DriveUpload] Batch delete request failed: $error\n$stackTrace',
          );
        }
      }

      for (final batch in claimedBatches) {
        await DriveUploadQueue.completeBatch(batch.id);
        _deletingDriveBatches.remove(batch.id);
        for (final path in batch.stagedPaths) {
          try {
            final file = File(path);
            if (await file.exists()) await file.delete();
          } on FileSystemException catch (error) {
            debugPrint('[DriveUpload] Could not remove staged file: $error');
          }
        }
      }

      if (mounted) {
        final deletedCount = deletedAssetIds.toSet().length;
        final notDeletedCount = uploadedAssetIds.length - deletedCount;
        final failedCount = claimedBatches.fold<int>(
          0,
          (total, batch) => total + batch.failedCount,
        );
        final messages = <String>[];
        if (deletedCount > 0) {
          messages.add('Deleted $deletedCount local item(s).');
        }
        if (notDeletedCount > 0) {
          messages.add(
            'The Drive upload finished, but $notDeletedCount original(s) '
            'remain on this device.',
          );
        }
        if (failedCount > 0) {
          messages.add(
            '$failedCount upload(s) failed; their original files were kept.',
          );
        }
        if (deletionError != null) {
          messages.add('Bulk deletion could not be completed: $deletionError');
        }
        if (messages.isNotEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(messages.join(' '))));
        }
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[DriveUpload] Could not check completed upload batches: '
        '$error\n$stackTrace',
      );
    } finally {
      _isCheckingDriveBatches = false;
    }
  }

  void skipMedia() {
    if (currentIndex >= _allPhotos.length) return;
    setState(() {
      _history.add(
        SortHistory(photo: _allPhotos[currentIndex], targetLabel: 'Skipped'),
      );
      movedCounts['Skipped'] = (movedCounts['Skipped'] ?? 0) + 1;
      currentIndex++;
    });
    if (currentIndex >= _allPhotos.length) {
      _sealCurrentDriveBatch();
    }
  }

  Future<void> undoLastAction() async {
    if (_history.isEmpty || _isMovingFile) return;
    if (!_history.last.undoable) return;

    setState(() => _isMovingFile = true);
    final lastAction = _history.removeLast();

    if (lastAction.movedPath != null && lastAction.originalPath != null) {
      final movedFile = File(lastAction.movedPath!);
      if (await movedFile.exists()) {
        try {
          await movedFile.copy(lastAction.originalPath!);
          await movedFile.delete();
        } catch (e) {
          debugPrint('Undo move error: $e');
        }
      }
    }

    setState(() {
      if ((movedCounts[lastAction.targetLabel] ?? 0) > 0) {
        movedCounts[lastAction.targetLabel] =
            movedCounts[lastAction.targetLabel]! - 1;
      }
      currentIndex--;
      _isMovingFile = false;
    });
  }

  Future<void> openSettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (context) => SettingsScreen(
          initialFolders: targetFolders,
          driveService: _driveService,
          onSave: (updatedFolders) {
            setState(() {
              targetFolders = updatedFolders;
            });
            _saveFoldersToPrefs();
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<List<TargetFolder>> _editTargets() async {
    await openSettings();
    return targetFolders;
  }

  Future<void> _openDriveSource() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (context) => DriveSourceScreen(
          driveService: _driveService,
          targetFolders: targetFolders,
          onEditTargets: _editTargets,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedAlbum == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('PilahFoto', style: TextStyle(fontWeight: FontWeight.w700)),
              Text(
                'Choose an album to get started',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
              ),
            ],
          ),
          actions: [
            if (_driveService.isConnected)
              IconButton(
                onPressed: _openDriveSource,
                icon: const Icon(Icons.cloud_outlined),
                tooltip: 'Browse Google Drive',
              ),
            IconButton(
              onPressed: () {
                setState(() => _albumListView = !_albumListView);
              },
              icon: Icon(
                _albumListView
                    ? Icons.grid_view_rounded
                    : Icons.view_list_rounded,
              ),
              tooltip: _albumListView ? 'Show thumbnails' : 'Show as a list',
            ),
            IconButton(
              onPressed: openSettings,
              icon: const Icon(Icons.settings),
              tooltip: 'Target Folders Settings',
            ),
          ],
        ),
        body: _isLoadingAlbums
            ? const Center(child: CircularProgressIndicator())
            : _albumListView
            ? _buildAlbumList()
            : _buildAlbumGrid(),
      );
    }

    if (_isLoadingPhotos) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    int total = _allPhotos.length;
    int sisa = total - currentIndex;

    if (currentIndex >= total && total > 0) {
      return Scaffold(
        appBar: AppBar(title: const Text('PilahFoto • Complete')),
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle_outline, size: 80),
              const SizedBox(height: 16),
              Text(
                'All media in "${_selectedAlbum!.name}" processed!',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              Card(
                child: Column(
                  children: movedCounts.entries.map((e) {
                    return ListTile(
                      dense: true,
                      title: Text(e.key),
                      trailing: Text(
                        '${e.value} items',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _kembaliKePilihFolder,
                icon: const Icon(Icons.folder_open),
                label: const Text('Select Another Folder'),
              ),
            ],
          ),
        ),
      );
    }

    if (total == 0) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: _kembaliKePilihFolder,
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back to albums',
          ),
          title: Text(
            _selectedAlbum!.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: Column(
          children: [
            _buildSortAndFilterBar(),
            Expanded(
              child: Center(
                child: Text('No ${_mediaFilter.name} found in this folder.'),
              ),
            ),
          ],
        ),
      );
    }

    AssetEntity currentPhoto = _allPhotos[currentIndex];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: _kembaliKePilihFolder,
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to albums',
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _selectedAlbum!.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            Text(
              '$sisa of $total items left',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _history.isNotEmpty && _history.last.undoable
                ? undoLastAction
                : null,
            icon: const Icon(Icons.undo),
            tooltip: _history.isNotEmpty && !_history.last.undoable
                ? 'Undo is not available for Google Drive transfers'
                : 'Undo Move',
          ),
          IconButton(
            onPressed: openSettings,
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Target folders',
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 820) {
            return Column(
              children: [
                Expanded(
                  flex: 6,
                  child: Column(
                    children: [
                      _buildSortAndFilterBar(),
                      LinearProgressIndicator(value: currentIndex / total),
                      Expanded(child: _buildPhotoPreview(currentPhoto)),
                    ],
                  ),
                ),
                Expanded(flex: 4, child: _buildTargetPanel(compact: true)),
              ],
            );
          }

          return Row(
            children: [
              Expanded(
                flex: 6,
                child: Column(
                  children: [
                    _buildSortAndFilterBar(),
                    LinearProgressIndicator(value: currentIndex / total),
                    Expanded(child: _buildPhotoPreview(currentPhoto)),
                  ],
                ),
              ),
              Expanded(flex: 4, child: _buildTargetPanel(compact: false)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAlbumGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = (constraints.maxWidth / 82)
            .floor()
            .clamp(3, 6)
            .toInt();
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 0.95,
          ),
          itemCount: _albums.length,
          itemBuilder: (context, index) {
            final album = _albums[index];
            return Card(
              clipBehavior: Clip.antiAlias,
              margin: EdgeInsets.zero,
              child: InkWell(
                onTap: () => _selectFolder(album),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _buildAlbumThumbnail(album)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(7, 5, 7, 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            album.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          FutureBuilder<int>(
                            future: album.assetCountAsync,
                            builder: (context, snapshot) => Text(
                              '${snapshot.data ?? 0} items',
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontSize: 10,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAlbumList() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
      itemCount: _albums.length,
      separatorBuilder: (_, _) => const SizedBox(height: 7),
      itemBuilder: (context, index) {
        final album = _albums[index];
        return Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            onTap: () => _selectFolder(album),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 4,
            ),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 52,
                height: 52,
                child: _buildAlbumThumbnail(album),
              ),
            ),
            title: Text(
              album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            subtitle: FutureBuilder<int>(
              future: album.assetCountAsync,
              builder: (context, snapshot) =>
                  Text('${snapshot.data ?? 0} items'),
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
          ),
        );
      },
    );
  }

  Widget _buildAlbumThumbnail(AssetPathEntity album) {
    return FutureBuilder<List<AssetEntity>>(
      future: album.getAssetListRange(start: 0, end: 1),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data!.isNotEmpty) {
          return AssetEntityImage(
            snapshot.data!.first,
            isOriginal: false,
            thumbnailSize: const ThumbnailSize(200, 200),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (context, error, stackTrace) =>
                _buildAlbumPlaceholder(context),
          );
        }
        return _buildAlbumPlaceholder(context);
      },
    );
  }

  void _setMediaFilter(MediaTypeFilter filter) {
    setState(() {
      _mediaFilter = filter;
      _applyFilterAndSort();
    });
  }

  Widget _buildPhotoPreview(AssetEntity photo) {
    return Container(
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(18),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          alignment: Alignment.center,
          children: [
            AssetEntityImage(
              photo,
              key: ValueKey(photo.id),
              isOriginal: false,
              thumbnailSize: const ThumbnailSize(1200, 1200),
              fit: BoxFit.contain,
              width: double.infinity,
              height: double.infinity,
              errorBuilder: (context, error, stackTrace) {
                return const Center(
                  child: Icon(Icons.broken_image, size: 64, color: Colors.grey),
                );
              },
            ),
            if (photo.type == AssetType.video)
              GestureDetector(
                onTap: () => _playVideoDialog(photo),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow,
                    size: 64,
                    color: Colors.white,
                  ),
                ),
              ),
            if (_isMovingFile)
              Container(
                color: Colors.black45,
                child: const Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTargetPanel({required bool compact}) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.all(compact ? 10 : 14),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: compact
            ? Border(top: BorderSide(color: colorScheme.outlineVariant))
            : Border(left: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'MOVE TO FOLDER',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 0.7,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: openSettings,
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('Edit', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
          Expanded(
            child: compact
                ? GridView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: targetFolders.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisExtent: 54,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemBuilder: (context, index) =>
                        _buildTargetButton(index, compact: true),
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: targetFolders.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) =>
                        _buildTargetButton(index, compact: false),
                  ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: compact ? 42 : 46,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: skipMedia,
              icon: const Icon(Icons.skip_next),
              label: const Text(
                'Skip for now',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTargetButton(int index, {required bool compact}) {
    final folder = targetFolders[index];
    final count = movedCounts[folder.label] ?? 0;
    final isConfigured = folder.isConfigured;
    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = isConfigured
        ? _folderPastelColors[index % _folderPastelColors.length]
        : colorScheme.surfaceContainerHighest;

    return SizedBox(
      height: compact ? 54 : 60,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor,
          foregroundColor: isConfigured
              ? const Color(0xFF171717)
              : colorScheme.onSurfaceVariant,
          elevation: isConfigured ? 2 : 0,
          shadowColor: const Color(0xFF171717).withValues(alpha: 0.16),
          side: BorderSide(
            color: const Color(0xFF171717)
                .withValues(alpha: isConfigured ? 0.12 : 0.08),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
        ),
        onPressed: () => pindahFolder(folder),
        child: Row(
          children: [
            Icon(
              folder.isDriveDestination
                  ? Icons.cloud_upload_outlined
                  : isConfigured
                  ? Icons.folder_rounded
                  : Icons.create_new_folder_outlined,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!compact)
                    Text(
                      folder.isDriveDestination
                          ? 'Drive · ${folder.driveFolderName ?? 'Selected folder'}'
                          : isConfigured
                          ? folder.path
                          : 'Configure destination',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: isConfigured
                            ? const Color(0xFF424242)
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF171717),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumPlaceholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.photo_library_outlined,
        size: 36,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildSortAndFilterBar() {
    final colorScheme = Theme.of(context).colorScheme;
    final controlBorderRadius = BorderRadius.circular(4);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            onPressed: _toggleSortOrder,
            icon: Icon(
              _isAscending ? Icons.south_rounded : Icons.north_rounded,
              size: 15,
            ),
            label: Text(
              _isAscending ? 'OLDEST' : 'NEWEST',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: colorScheme.onSurfaceVariant,
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(borderRadius: controlBorderRadius),
              side: BorderSide(color: colorScheme.outlineVariant),
            ),
          ),
          const SizedBox(width: 6),
          _buildFilterMenu(controlBorderRadius),
        ],
      ),
    );
  }

  Widget _buildFilterMenu(BorderRadius controlBorderRadius) {
    final colorScheme = Theme.of(context).colorScheme;

    return PopupMenuButton<MediaTypeFilter>(
      tooltip: 'Filter media type',
      onSelected: _setMediaFilter,
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          value: MediaTypeFilter.all,
          checked: _mediaFilter == MediaTypeFilter.all,
          child: const Text('All media'),
        ),
        CheckedPopupMenuItem(
          value: MediaTypeFilter.photos,
          checked: _mediaFilter == MediaTypeFilter.photos,
          child: const Text('Photos'),
        ),
        CheckedPopupMenuItem(
          value: MediaTypeFilter.videos,
          checked: _mediaFilter == MediaTypeFilter.videos,
          child: const Text('Videos'),
        ),
      ],
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: controlBorderRadius,
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_list_rounded,
              size: 15,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Text(
              _mediaFilter.name.toUpperCase(),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            Icon(
              Icons.expand_more,
              size: 15,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class VideoPlayerModal extends StatefulWidget {
  final File file;
  const VideoPlayerModal({super.key, required this.file});

  @override
  State<VideoPlayerModal> createState() => _VideoPlayerModalState();
}

class _VideoPlayerModalState extends State<VideoPlayerModal> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  @override
  void initState() {
    super.initState();
    _player.open(Media(widget.file.path));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(24),
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Video(controller: _controller),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
