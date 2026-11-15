import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drive_source_screen.dart';
import 'models/local_delete_mode.dart';
import 'models/target_folder.dart';
import 'services/drive_upload_queue.dart';
import 'services/google_drive_service.dart';
import 'services/local_trash_service.dart';
import 'services/pro_entitlement_service.dart';
import 'services/sort_position.dart';
import 'pro_paywall.dart';
import 'settings_screen.dart';
import 'trash_screen.dart';
import 'services/app_localizations.dart';
import 'widgets/drive_folder_picker.dart';
import 'widgets/video_preview_layout.dart';

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

class _SortScreenState extends State<SortScreen>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin<SortScreen> {
  final GoogleDriveService _driveService = GoogleDriveService();
  final ScrollController _albumScrollController = ScrollController(
    keepScrollOffset: true,
  );

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
  AssetPathEntity? _pausedAlbum;

  bool _albumListView = false;
  List<AssetEntity> _rawPhotos = [];
  List<AssetEntity> _allPhotos = [];

  bool _isLoadingAlbums = false;
  bool _isLoadingPhotos = false;
  bool _isMovingFile = false;
  bool _isSettingsOpen = false;
  bool _destinationHintVisible = false;
  int _destinationHintGeneration = 0;
  DateTime _ignoreTargetTapUntil = DateTime.fromMillisecondsSinceEpoch(0);

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
  DateTime? _lastHomeBackAt;
  final List<SortHistory> _history = [];
  final Set<String> _deletingDriveBatches = {};
  Timer? _driveBatchPollTimer;
  Future<void> _driveQueueTail = Future<void>.value();
  String? _activeDriveBatchId;
  int _driveQueueSequence = 0;
  bool _isCheckingDriveBatches = false;
  bool _isAppResumed = true;
  final ProEntitlementService _proService = ProEntitlementService.instance;
  ProEntitlements _proEntitlements = const ProEntitlements();
  Timer? _trialExpiryTimer;
  bool _isShowingProPaywall = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _driveBatchPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_processCompletedDriveBatches()),
    );
    _loadSavedFolders();
    unawaited(_loadLocalProStatus());
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
      unawaited(_showStartupProPaywall());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _albumScrollController.dispose();
    _driveBatchPollTimer?.cancel();
    _trialExpiryTimer?.cancel();
    _sealCurrentDriveBatch();
    _driveService.close();
    super.dispose();
  }

  Future<void> _restoreDriveSession() async {
    try {
      final needsLegacyCheck = await _proService.needsLegacyDriveCheck();
      final hadSavedDriveAccount = await _driveService.hasStoredAccount();
      await _driveService.restoreSession();
      if (needsLegacyCheck) {
        await _proService.completeLegacyDriveCheck(
          wasConnected: hadSavedDriveAccount,
        );
      }
      if (mounted) setState(() {});
      await _loadLocalProStatus();
      await _showStartupProPaywall();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr(
                'Unable to restore the Google Drive session: {error}',
                {'error': error},
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _loadLocalProStatus() async {
    final status = await _proService.loadLocalStatus();
    if (!mounted) return;
    setState(() => _proEntitlements = status);
    _scheduleTrialExpiry(status);
  }

  void _scheduleTrialExpiry(ProEntitlements status) {
    _trialExpiryTimer?.cancel();
    final trialEnd = status.trialEndsAt;
    if (trialEnd == null || !trialEnd.isAfter(DateTime.now())) return;
    _trialExpiryTimer = Timer(
      trialEnd.difference(DateTime.now()),
      () => unawaited(_showStartupProPaywall()),
    );
  }

  Future<void> _showStartupProPaywall() async {
    if (!mounted || !_isAppResumed || _isShowingProPaywall) return;
    final expired = await _proService.needsTrialExpiredPaywall();
    final initial = !expired && await _proService.needsInitialPaywall();
    if (!mounted) return;
    if (!expired && !initial) return;
    if (expired) await _proService.markTrialExpiredPaywallSeen();
    if (!mounted) return;
    _isShowingProPaywall = true;
    try {
      await showDialog<ProPaywallResult>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ProPaywall(
          service: _proService,
          initial: initial,
          expiredTrial: expired,
        ),
      );
      await _loadLocalProStatus();
    } finally {
      _isShowingProPaywall = false;
    }
  }

  Future<bool> _requireProFeature(ProFeature feature) async {
    if (_isShowingProPaywall) return false;
    final status = await _proService.refreshFor(feature);
    if (!mounted) return false;
    setState(() => _proEntitlements = status);
    if (status.allows(feature)) return true;

    final expired = status.trialExpired;
    if (expired && await _proService.needsTrialExpiredPaywall()) {
      await _proService.markTrialExpiredPaywallSeen();
    }
    if (!mounted) return false;
    _isShowingProPaywall = true;
    try {
      await showDialog<ProPaywallResult>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ProPaywall(
          service: _proService,
          requiredFeature: feature,
          expiredTrial: expired,
          verificationError: status.verificationError,
        ),
      );
    } finally {
      _isShowingProPaywall = false;
    }
    final updated = await _proService.loadLocalStatus();
    if (mounted) setState(() => _proEntitlements = updated);
    return updated.allows(feature);
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
          SnackBar(
            content: Text(
              context.tr('Permission to access the gallery was denied.'),
            ),
          ),
        );
      }
      return;
    }

    final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: true,
      filterOption: FilterOptionGroup(
        orders: const [OrderOption(type: OrderOptionType.createDate)],
      ),
    );

    setState(() {
      _albums = albums;
      _isLoadingAlbums = false;
    });
  }

  Future<void> _selectFolder(AssetPathEntity album) async {
    _sealCurrentDriveBatch();
    if (_pausedAlbum?.id == album.id) {
      setState(() {
        _selectedAlbum = album;
        _pausedAlbum = null;
        _isLoadingPhotos = false;
      });
      return;
    }

    _pausedAlbum = null;
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
    _applyFilterAndSort(resetProgress: true);

    setState(() {
      _isLoadingPhotos = false;
    });
  }

  void _applyFilterAndSort({bool resetProgress = false}) {
    _sealCurrentDriveBatch();
    final previousOrder = _allPhotos.map((asset) => asset.id).toList();
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

    final nextOrder = temp.map((asset) => asset.id).toList();
    setState(() {
      _allPhotos = temp;
      currentIndex = resetProgress
          ? 0
          : resolveSortPosition(
              previousOrder: previousOrder,
              currentIndex: currentIndex,
              nextOrder: nextOrder,
            );
      if (resetProgress) {
        _history.clear();
        movedCounts.clear();
      }
    });
  }

  void _toggleSortOrder() {
    _dismissDestinationHint();
    setState(() {
      _isAscending = !_isAscending;
      _applyFilterAndSort();
    });
  }

  Future<void> _confirmStartOver() async {
    if (_isMovingFile || _allPhotos.isEmpty) return;
    final shouldStartOver = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(
          context.tr(
            'Start sorting from the first photo again? Current position will be reset.',
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.tr('Yes, Start Over')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Cancel')),
          ),
        ],
      ),
    );
    if (shouldStartOver != true || !mounted) return;

    _dismissDestinationHint();
    _sealCurrentDriveBatch();
    setState(() {
      currentIndex = resolveSortPosition(
        previousOrder: _allPhotos.map((asset) => asset.id).toList(),
        currentIndex: currentIndex,
        nextOrder: _allPhotos.map((asset) => asset.id).toList(),
        startOver: true,
      );
    });
  }

  void _kembaliKePilihFolder() {
    _dismissDestinationHint();
    _sealCurrentDriveBatch();
    setState(() {
      _selectedAlbum = null;
      _pausedAlbum = null;
      _rawPhotos = [];
      _allPhotos = [];
      _mediaFilter = MediaTypeFilter.all;
    });
    _fetchAlbums();
  }

  void _returnToAlbumsPreservingSort() {
    final album = _selectedAlbum;
    if (album == null) return;
    _dismissDestinationHint();
    _sealCurrentDriveBatch();
    setState(() {
      _pausedAlbum = album;
      _selectedAlbum = null;
      _isLoadingPhotos = false;
    });
  }

  void _handleSystemBack() {
    if (_selectedAlbum != null) {
      _returnToAlbumsPreservingSort();
      return;
    }

    final now = DateTime.now();
    final previousBack = _lastHomeBackAt;
    if (previousBack != null &&
        now.difference(previousBack) <= const Duration(seconds: 2)) {
      unawaited(SystemNavigator.pop());
      return;
    }
    _lastHomeBackAt = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(context.tr('Press Back again to exit')),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  void _playVideoDialog(AssetEntity asset) async {
    File? file;
    try {
      file = await asset.originFile;
    } on PlatformException catch (error) {
      debugPrint('[VideoPlayback] Could not access the original video: $error');
    } on FileSystemException catch (error) {
      debugPrint('[VideoPlayback] Could not access the original video: $error');
    }

    if (file == null || !await file.exists()) {
      try {
        file = await asset.file;
      } on PlatformException catch (error) {
        debugPrint('[VideoPlayback] Could not access the video file: $error');
      } on FileSystemException catch (error) {
        debugPrint('[VideoPlayback] Could not access the video file: $error');
      }
    }

    final videoFile = file;
    if (!mounted) return;
    if (videoFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('Unable to access this video file.')),
        ),
      );
      return;
    }
    final videoExists = await videoFile.exists();
    if (!mounted) return;
    if (!videoExists) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('Unable to access this video file.')),
        ),
      );
      return;
    }

    showDialog(
      context: context,
      barrierColor: Colors.black,
      builder: (context) => VideoPlayerModal(file: videoFile),
    );
  }

  Future<void> pindahFolder(TargetFolder target) async {
    if (currentIndex >= _allPhotos.length || _isMovingFile) return;

    if (DateTime.now().isBefore(_ignoreTargetTapUntil)) {
      _ignoreTargetTapUntil = DateTime.fromMillisecondsSinceEpoch(0);
      return;
    }

    if (!target.isConfigured) {
      _showDestinationRequiredBanner(target);
      return;
    }

    if (target.isDriveDestination) {
      final hasDriveAccess = await _requireProFeature(ProFeature.drive);
      if (!mounted || !hasDriveAccess) return;
    }

    if (target.isDriveDestination && !_driveService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('Connect Google Drive in Settings first.')),
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
            context.tr(
              'Reconnect Google Drive as {account} to use this destination.',
              {'account': target.driveAccountEmail!},
            ),
          ),
        ),
      );
      return;
    }

    if (target.isDriveDestination) {
      setState(() => _isMovingFile = true);
      try {
        final folder = await _driveService.validateDestinationFolder(
          target.driveFolderId!,
          folderName: target.driveFolderName,
          parentId: target.driveFolderParentId,
        );
        if (folder.id != target.driveFolderId) {
          target
            ..driveFolderId = folder.id
            ..driveFolderName = folder.name
            ..driveFolderParentId = folder.parents?.isNotEmpty == true
                ? folder.parents!.first
                : target.driveFolderParentId;
          await _saveFoldersToPrefs();
          if (mounted) setState(() {});
        }
      } catch (error) {
        if (!mounted) return;
        setState(() => _isMovingFile = false);
        if (error is DriveDestinationFolderException && error.wasRecreated) {
          await _showDriveFolderRecreatedDialog(target, error);
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is DriveDestinationFolderException
                  ? _destinationErrorMessage(error)
                  : context.tr(
                      'Unable to verify the Drive destination: {error}',
                      {'error': error},
                    ),
            ),
          ),
        );
        return;
      }
      if (!mounted) return;
      if (Platform.isAndroid) {
        setState(() => _isMovingFile = false);
        _queueDriveUpload(target);
        return;
      }
    }

    if (!_isMovingFile) setState(() => _isMovingFile = true);

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

        final preferences = await SharedPreferences.getInstance();
        final deleteMode = LocalDeleteMode.fromPreference(
          preferences.getString(LocalDeleteMode.preferenceKey),
        );
        final deletedIds = await _removeUploadedDriveAssets([
          currentAsset.id,
        ], deleteMode);
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
      var displayError = error;
      if (target.isDriveDestination) {
        try {
          await _driveService.validateDestinationFolder(target.driveFolderId!);
        } on DriveDestinationFolderException catch (destinationError) {
          displayError = destinationError;
        } catch (_) {
          // Keep the original upload error when the destination remains accessible.
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            displayError is DriveDestinationFolderException
                ? _destinationErrorMessage(displayError)
                : context.tr('Failed to move file: {error}', {
                    'error': displayError,
                  }),
          ),
        ),
      );
    }
  }

  Future<void> _moveCurrentToTrash() async {
    if (_isMovingFile || currentIndex >= _allPhotos.length) return;
    final asset = _allPhotos[currentIndex];
    setState(() => _isMovingFile = true);
    try {
      final item = await LocalTrashService().moveAssetToTrash(asset);
      if (!mounted) return;
      setState(() {
        _history.add(
          SortHistory(photo: asset, targetLabel: 'Trash', undoable: false),
        );
        movedCounts['Trash'] = (movedCounts['Trash'] ?? 0) + 1;
        currentIndex++;
        _isMovingFile = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('"{file}" moved to Trash. Restorable for 30 days.', {
              'file': item.fileName,
            }),
          ),
        ),
      );
      if (currentIndex >= _allPhotos.length) _sealCurrentDriveBatch();
    } catch (error) {
      if (!mounted) return;
      setState(() => _isMovingFile = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('Unable to move this item to Trash: {error}', {
              'error': error,
            }),
          ),
        ),
      );
    }
  }

  Future<void> _showDriveFolderRecreatedDialog(
    TargetFolder target,
    DriveDestinationFolderException error,
  ) async {
    final openPicker = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.tr('Destination folder not available')),
        content: Text(_destinationErrorMessage(error)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.tr('Open Drive picker')),
          ),
        ],
      ),
    );
    if (openPicker != true || !mounted) return;

    final selection = await showModalBottomSheet<DriveFolderSelection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: MediaQuery.removeViewInsets(
          context: sheetContext,
          removeBottom: true,
          child: DriveFolderPickerModal(driveService: _driveService),
        ),
      ),
    );
    if (selection == null || !mounted) return;

    target
      ..driveFolderId = selection.id
      ..driveFolderName = selection.name
      ..driveFolderParentId = selection.parentId
      ..driveAccountEmail = selection.accountEmail;
    try {
      await _saveFoldersToPrefs();
      if (mounted) setState(() {});
    } catch (saveError) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('Unable to save the Drive destination: {error}', {
                'error': saveError,
              }),
            ),
          ),
        );
      }
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
              context.tr('Could not queue {file} for Drive upload: {error}', {
                'file': asset.title ?? context.tr('media'),
                'error': error,
              }),
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
      if (readyBatches.isEmpty) return;
      final preferences = await SharedPreferences.getInstance();
      final deleteMode = LocalDeleteMode.fromPreference(
        preferences.getString(LocalDeleteMode.preferenceKey),
      );
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
          deletedAssetIds = await _removeUploadedDriveAssets(
            uploadedAssetIds,
            deleteMode,
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
        final missingDestinationCount = claimedBatches.fold<int>(
          0,
          (total, batch) => total + batch.missingDestinationCount,
        );
        final messages = <String>[];
        if (deletedCount > 0) {
          messages.add(
            deleteMode == LocalDeleteMode.moveToTrash
                ? context.tr('Moved {count} local item(s) to Trash.', {
                    'count': deletedCount,
                  })
                : context.tr('Permanently deleted {count} local item(s).', {
                    'count': deletedCount,
                  }),
          );
        }
        if (notDeletedCount > 0) {
          messages.add(
            context.tr(
              'The Drive upload finished, but {count} original(s) remain on this device.',
              {'count': notDeletedCount},
            ),
          );
        }
        if (failedCount > 0) {
          messages.add(
            context.tr(
              '{count} upload(s) failed; their original files were kept.',
              {'count': failedCount},
            ),
          );
        }
        if (missingDestinationCount > 0) {
          messages.add(
            _destinationErrorMessage(const DriveDestinationFolderException()),
          );
        }
        if (deletionError != null) {
          messages.add(
            context.tr('Bulk deletion could not be completed: {error}', {
              'error': deletionError,
            }),
          );
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

  Future<List<String>> _removeUploadedDriveAssets(
    List<String> assetIds,
    LocalDeleteMode deleteMode,
  ) async {
    if (assetIds.isEmpty) return const [];
    if (deleteMode == LocalDeleteMode.moveToTrash) {
      final assets = (await Future.wait(assetIds.map(AssetEntity.fromId)))
          .whereType<AssetEntity>()
          .toList();
      final movedIds = <String>[];
      final trashService = LocalTrashService();
      for (final asset in assets) {
        await trashService.moveAssetToTrash(asset);
        movedIds.add(asset.id);
      }
      return movedIds;
    }
    return PhotoManager.editor.deleteWithIds(assetIds);
  }

  void skipMedia() {
    _dismissDestinationHint();
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
    _dismissDestinationHint();
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

    final actionPhotoIndex = _allPhotos.indexWhere(
      (photo) => photo.id == lastAction.photo.id,
    );
    setState(() {
      if ((movedCounts[lastAction.targetLabel] ?? 0) > 0) {
        movedCounts[lastAction.targetLabel] =
            movedCounts[lastAction.targetLabel]! - 1;
      }
      currentIndex = actionPhotoIndex >= 0
          ? actionPhotoIndex
          : _allPhotos.isEmpty
          ? 0
          : currentIndex.clamp(0, _allPhotos.length - 1).toInt();
      _isMovingFile = false;
    });
  }

  String _destinationErrorMessage(DriveDestinationFolderException error) {
    if (error.wasRecreated && error.folderName != null) {
      return context.tr(
        "Folder '{folder}' was recreated in Drive. Please re-pick the destination.",
        {'folder': error.folderName!},
      );
    }
    return context.tr(
      'Destination folder not found. It may have been moved or deleted in Drive. Check the folder and try again.',
    );
  }

  Future<void> openSettings() async {
    _dismissDestinationHint();
    if (_isSettingsOpen) return;
    _isSettingsOpen = true;
    try {
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
          maintainState: true,
        ),
      );
    } finally {
      _isSettingsOpen = false;
      if (mounted) {
        final status = await _proService.loadLocalStatus();
        setState(() => _proEntitlements = status);
      }
    }
  }

  void _showDestinationRequiredBanner(TargetFolder target) {
    if (_destinationHintVisible) return;
    _destinationHintVisible = true;
    final generation = ++_destinationHintGeneration;
    final messenger = ScaffoldMessenger.of(context);
    final controller = messenger.showSnackBar(
      SnackBar(
        content: Text(
          context.tr('Choose a destination for "{folder}" in Settings first.', {
            'folder': target.label,
          }),
        ),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: context.tr('SETTINGS'),
          onPressed: () {
            _dismissDestinationHint();
            openSettings();
          },
        ),
      ),
    );
    controller.closed.then((_) {
      if (generation == _destinationHintGeneration) {
        _destinationHintVisible = false;
      }
    });
  }

  void _dismissDestinationHint() {
    _destinationHintGeneration++;
    if (_destinationHintVisible) {
      _destinationHintVisible = false;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
    _ignoreTargetTapUntil = DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> _openTrash() async {
    _dismissDestinationHint();
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => const TrashScreen(),
        maintainState: true,
      ),
    );
  }

  Future<List<TargetFolder>> _editTargets() async {
    await openSettings();
    return targetFolders;
  }

  Future<void> _openDriveSource() async {
    _dismissDestinationHint();
    final hasDriveAccess = await _requireProFeature(ProFeature.drive);
    if (!mounted || !hasDriveAccess) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (context) => DriveSourceScreen(
          driveService: _driveService,
          targetFolders: targetFolders,
          onEditTargets: _editTargets,
        ),
        maintainState: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleSystemBack();
      },
      child: _buildScreen(context),
    );
  }

  Widget _buildScreen(BuildContext context) {
    if (_selectedAlbum == null) {
      return Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Loka Files',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                context.tr('Choose an album to get started'),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                ),
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: _openTrash,
              icon: const Icon(Icons.delete_outline),
              label: Text(context.tr('Open Trash')),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
            if (_driveService.isConnected)
              IconButton(
                onPressed: _openDriveSource,
                icon: const Icon(Icons.cloud_outlined),
                tooltip: context.tr('Browse Google Drive'),
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
              tooltip: context.tr(
                _albumListView ? 'Show thumbnails' : 'Show as a list',
              ),
            ),
            IconButton(
              onPressed: openSettings,
              icon: const Icon(Icons.settings),
              tooltip: context.tr('Target folder settings'),
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
        appBar: AppBar(
          title: Text(context.tr('Loka Files • Sorting complete')),
          actions: [
            TextButton.icon(
              onPressed: _openTrash,
              icon: const Icon(Icons.delete_outline),
              label: Text(context.tr('Open Trash')),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle_outline, size: 80),
              const SizedBox(height: 16),
              Text(
                context.tr('All media in "{album}" have been processed.', {
                  'album': _selectedAlbum!.name,
                }),
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
                      title: Text(
                        e.key == 'Trash' || e.key == 'Skipped'
                            ? context.tr(e.key)
                            : e.key,
                      ),
                      trailing: Text(
                        context.tr('{count} items', {'count': e.value}),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: _isMovingFile || _allPhotos.isEmpty
                    ? null
                    : _confirmStartOver,
                icon: const Icon(Icons.restart_alt),
                label: Text(context.tr('Start Over')),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _kembaliKePilihFolder,
                icon: const Icon(Icons.folder_open),
                label: Text(context.tr('Select Another Folder')),
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
            onPressed: _returnToAlbumsPreservingSort,
            icon: const Icon(Icons.arrow_back),
            tooltip: context.tr('Back to albums'),
          ),
          title: Text(
            _selectedAlbum!.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            TextButton.icon(
              onPressed: _openTrash,
              icon: const Icon(Icons.delete_outline),
              label: Text(context.tr('Open Trash')),
            ),
          ],
        ),
        body: Column(
          children: [
            _buildSortAndFilterBar(),
            Expanded(
              child: Center(
                child: Text(
                  context.tr(
                    'No media matching this filter was found in this folder.',
                  ),
                ),
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
          onPressed: _returnToAlbumsPreservingSort,
          icon: const Icon(Icons.arrow_back),
          tooltip: context.tr('Back to albums'),
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
              context.tr('{remaining} of {total} items remaining', {
                'remaining': sisa,
                'total': total,
              }),
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _openTrash,
            icon: const Icon(Icons.delete_outline),
            tooltip: context.tr('Open Trash - restore items for up to 30 days'),
          ),
          PopupMenuButton<String>(
            tooltip: context.tr('Item actions'),
            enabled: !_isMovingFile,
            onSelected: (action) {
              if (action == 'moveToTrash') _moveCurrentToTrash();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'moveToTrash',
                child: Row(
                  children: [
                    const Icon(Icons.delete_outline),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(context.tr('Move to Trash')),
                        Text(
                          context.tr('Restorable for 30 days'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            onPressed: _history.isNotEmpty && _history.last.undoable
                ? undoLastAction
                : null,
            icon: const Icon(Icons.undo),
            tooltip: _history.isNotEmpty && !_history.last.undoable
                ? _history.last.targetLabel == 'Trash'
                      ? context.tr(
                          'Undo is unavailable for items moved to Trash; restore them from Trash',
                        )
                      : context.tr(
                          'Undo is not available for Google Drive transfers',
                        )
                : context.tr('Undo Move'),
          ),
          IconButton(
            onPressed: openSettings,
            icon: const Icon(Icons.settings_outlined),
            tooltip: context.tr('Target folders'),
          ),
        ],
      ),
      body: Listener(
        onPointerDown: (_) {
          if (!_destinationHintVisible) return;
          _destinationHintVisible = false;
          _destinationHintGeneration++;
          _ignoreTargetTapUntil = DateTime.now().add(
            const Duration(milliseconds: 300),
          );
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        },
        child: LayoutBuilder(
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
          key: const PageStorageKey<String>('sort-album-grid'),
          controller: _albumScrollController,
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
                              context.tr('{count} items', {
                                'count': snapshot.data ?? 0,
                              }),
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
      key: const PageStorageKey<String>('sort-album-list'),
      controller: _albumScrollController,
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
              builder: (context, snapshot) => Text(
                context.tr('{count} items', {'count': snapshot.data ?? 0}),
              ),
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
    _dismissDestinationHint();
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
    final visibleTargetCount = _proEntitlements.canAddButtons
        ? targetFolders.length
        : targetFolders.length
              .clamp(0, ProEntitlementService.freeTargetButtonLimit)
              .toInt();
    final itemCount =
        visibleTargetCount + (_proEntitlements.canAddButtons ? 0 : 1);

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
                  context.tr('MOVE TO FOLDER'),
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
                label: Text(
                  context.tr('Edit'),
                  style: const TextStyle(fontSize: 12),
                ),
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
                    itemCount: itemCount,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisExtent: 54,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemBuilder: (context, index) => index < visibleTargetCount
                        ? _buildTargetButton(index, compact: true)
                        : _buildLockedAddButton(compact: true),
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: itemCount,
                    separatorBuilder: (_, index) =>
                        index < visibleTargetCount - 1
                        ? const SizedBox(height: 8)
                        : const SizedBox.shrink(),
                    itemBuilder: (context, index) => index < visibleTargetCount
                        ? _buildTargetButton(index, compact: false)
                        : _buildLockedAddButton(compact: false),
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
              label: Text(
                context.tr('Skip for now'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLockedAddButton({required bool compact}) {
    return SizedBox(
      height: compact ? 54 : 60,
      child: OutlinedButton(
        onPressed: _isMovingFile
            ? null
            : () => _requireProFeature(ProFeature.addButtons),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                context.tr('Add Button - Pro {price}', {
                  'price': ProProduct.addButtons.priceLabel,
                }),
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: compact ? 9 : 12),
              ),
            ),
            const Positioned(left: 0, child: Icon(Icons.add, size: 16)),
            const Positioned(
              right: 0,
              child: Icon(Icons.lock_outline, size: 16),
            ),
          ],
        ),
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
                          ? context.tr('Drive · {folder}', {
                              'folder':
                                  folder.driveFolderName ??
                                  context.tr('Selected folder'),
                            })
                          : isConfigured
                          ? folder.path
                          : context.tr('Configure destination'),
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
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: _toggleSortOrder,
            icon: Icon(
              _isAscending ? Icons.south_rounded : Icons.north_rounded,
              size: 15,
            ),
            label: Text(
              context.tr(_isAscending ? 'OLDEST' : 'NEWEST'),
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
          _buildFilterMenu(controlBorderRadius),
          OutlinedButton.icon(
            onPressed: _isMovingFile || _allPhotos.isEmpty
                ? null
                : _confirmStartOver,
            icon: const Icon(Icons.restart_alt, size: 15),
            label: Text(
              context.tr('Start Over'),
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
        ],
      ),
    );
  }

  Widget _buildFilterMenu(BorderRadius controlBorderRadius) {
    final colorScheme = Theme.of(context).colorScheme;

    return PopupMenuButton<MediaTypeFilter>(
      tooltip: context.tr('Filter media type'),
      onSelected: _setMediaFilter,
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          value: MediaTypeFilter.all,
          checked: _mediaFilter == MediaTypeFilter.all,
          child: Text(context.tr('All media')),
        ),
        CheckedPopupMenuItem(
          value: MediaTypeFilter.photos,
          checked: _mediaFilter == MediaTypeFilter.photos,
          child: Text(context.tr('Photos')),
        ),
        CheckedPopupMenuItem(
          value: MediaTypeFilter.videos,
          checked: _mediaFilter == MediaTypeFilter.videos,
          child: Text(context.tr('Videos')),
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
              context.tr(switch (_mediaFilter) {
                MediaTypeFilter.all => 'All media',
                MediaTypeFilter.photos => 'Photos',
                MediaTypeFilter.videos => 'Videos',
              }).toUpperCase(),
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
  late final Player _player;
  late final VideoController _controller;
  StreamSubscription<String>? _errorSubscription;
  String? _playbackError;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _errorSubscription = _player.stream.error.listen((error) {
      if (error.isNotEmpty) _reportPlaybackError(error);
    });
    unawaited(_openLocalVideo());
  }

  Future<void> _openLocalVideo() async {
    try {
      if (!await widget.file.exists()) {
        throw FileSystemException(
          'The selected video file is unavailable.',
          widget.file.path,
        );
      }
      await _initializeLocalVideo().timeout(const Duration(seconds: 30));
    } on FileSystemException catch (error, stackTrace) {
      _reportPlaybackException(error, stackTrace);
    } on PlatformException catch (error, stackTrace) {
      _reportPlaybackException(error, stackTrace);
    } on TimeoutException catch (error, stackTrace) {
      _reportPlaybackException(error, stackTrace);
    }
  }

  Future<void> _initializeLocalVideo() async {
    await _controller.platform.future;
    await _player.open(
      Media(Uri.file(widget.file.path).toString()),
      play: true,
    );
    await _controller.waitUntilFirstFrameRendered;
  }

  void _reportPlaybackError(String error) {
    debugPrint('[VideoPlayback] $error');
    _showPlaybackError();
  }

  void _reportPlaybackException(Object error, StackTrace stackTrace) {
    debugPrint('[VideoPlayback] Could not initialize local video: $error');
    debugPrintStack(stackTrace: stackTrace);
    _showPlaybackError();
  }

  void _showPlaybackError() {
    if (!mounted || _playbackError != null) return;
    setState(() {
      _playbackError = context.tr(
        'Unable to play this video. Please try again or open it in your Gallery app.',
      );
    });
  }

  @override
  void dispose() {
    final errorSubscription = _errorSubscription;
    if (errorSubscription != null) unawaited(errorSubscription.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: EdgeInsets.zero,
      constraints: BoxConstraints(
        maxWidth: screenSize.width * 0.9,
        maxHeight: screenSize.height * 0.9,
      ),
      child: _playbackError == null
          ? _buildVideoContent()
          : _buildPlaybackError(screenSize),
    );
  }

  Widget _buildVideoContent() {
    return StreamBuilder<VideoParams>(
      stream: _player.stream.videoParams,
      initialData: _player.state.videoParams,
      builder: (context, snapshot) {
        final aspectRatio = videoDisplayAspectRatio(
          snapshot.data ?? const VideoParams(),
        );
        if (aspectRatio == null) {
          return const Center(child: CircularProgressIndicator());
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final size = videoPreviewSizeForAspectRatio(
              aspectRatio: aspectRatio,
              maxSize: Size(constraints.maxWidth, constraints.maxHeight),
            );
            return SizedBox(
              width: size.width,
              height: size.height,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AspectRatio(
                    aspectRatio: aspectRatio,
                    child: Video(
                      controller: _controller,
                      fit: BoxFit.contain,
                      aspectRatio: aspectRatio,
                    ),
                  ),
                  Positioned(top: 8, right: 8, child: _buildCloseButton()),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPlaybackError(Size screenSize) {
    return SizedBox(
      width: screenSize.width * 0.8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(alignment: Alignment.topRight, child: _buildCloseButton()),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
            child: Text(
              _playbackError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCloseButton() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.black54,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: const Icon(Icons.close, color: Colors.white, size: 28),
        onPressed: () => Navigator.pop(context),
      ),
    );
  }
}
