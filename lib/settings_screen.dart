import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_tour_screen.dart';
import 'models/local_delete_mode.dart';
import 'models/target_folder.dart';
import 'services/app_update_service.dart';
import 'services/app_localizations.dart';
import 'services/google_drive_service.dart';
import 'services/pro_entitlement_service.dart';
import 'pro_paywall.dart';
import 'widgets/drive_folder_picker.dart';
import 'main.dart';

class SettingsScreen extends StatefulWidget {
  final List<TargetFolder> initialFolders;
  final Function(List<TargetFolder>) onSave;
  final GoogleDriveService driveService;

  const SettingsScreen({
    super.key,
    required this.initialFolders,
    required this.onSave,
    required this.driveService,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  static const _appUpdateChannel = MethodChannel('pilah_foto/app_update');
  static const _lastUpdateCheckKey = 'loka_media_last_update_check';
  static const _pendingUpdatedVersionKey = 'loka_media_pending_updated_version';

  late List<TargetFolder> _folders;
  late List<TextEditingController> _controllers;
  final AppUpdateService _appUpdateService = AppUpdateService();
  ThemeMode _selectedThemeMode = ThemeMode.system;
  LocalDeleteMode _deleteMode = LocalDeleteMode.moveToTrash;
  bool _isDeleteModeLoading = true;
  SharedPreferences? _preferences;
  Future<void> _deleteModeLoad = Future<void>.value();
  bool _isDriveBusy = false;
  bool _isCheckingForUpdate = false;
  bool _isDownloadingUpdate = false;
  String? _currentVersion;
  String? _latestVersion;
  AppUpdateRelease? _cachedRelease;
  File? _cachedApk;
  int _downloadedBytes = 0;
  int _downloadTotalBytes = 0;
  bool _awaitingInstallPermissionSettings = false;
  final ProEntitlementService _proService = ProEntitlementService.instance;
  ProEntitlements _proEntitlements = const ProEntitlements();
  bool _isShowingProPaywall = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsFlutterBinding.ensureInitialized();
    _folders = widget.initialFolders
        .map(
          (folder) => TargetFolder(
            label: folder.label,
            path: folder.path,
            driveFolderId: folder.driveFolderId,
            driveFolderName: folder.driveFolderName,
            driveFolderParentId: folder.driveFolderParentId,
            driveAccountEmail: folder.driveAccountEmail,
          ),
        )
        .toList();

    // Initialize each text field with its folder label.
    _controllers = _folders
        .map((f) => TextEditingController(text: f.label))
        .toList();
    _deleteModeLoad = _loadDeleteMode();
    unawaited(_refreshInstalledVersion());
    unawaited(_loadProEntitlements());
  }

  Future<SharedPreferences> _getPreferences() async {
    WidgetsFlutterBinding.ensureInitialized();
    final preferences = _preferences;
    if (preferences != null) return preferences;

    final initializedPreferences = await SharedPreferences.getInstance();
    _preferences = initializedPreferences;
    return initializedPreferences;
  }

  Future<void> _loadDeleteMode() async {
    try {
      final preferences = await _getPreferences();
      if (!mounted) return;
      setState(() {
        _deleteMode = LocalDeleteMode.fromPreference(
          preferences.getString(LocalDeleteMode.preferenceKey),
        );
        _isDeleteModeLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isDeleteModeLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('Unable to load delete mode: {error}', {'error': error}),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (var controller in _controllers) {
      controller.dispose();
    }
    _appUpdateService.close();
    super.dispose();
  }

  Future<void> _pickFolderForIndex(int index) async {
    String? selectedDirectory = await FilePicker.getDirectoryPath();
    if (selectedDirectory != null) {
      String autoFolderName = selectedDirectory
          .split(Platform.pathSeparator)
          .last;
      if (autoFolderName.isEmpty) {
        autoFolderName = selectedDirectory.split('/').last;
      }

      setState(() {
        _folders[index].path = selectedDirectory;
        _folders[index].label = autoFolderName;
        _folders[index].driveFolderId = null;
        _folders[index].driveFolderName = null;
        _folders[index].driveFolderParentId = null;
        _folders[index].driveAccountEmail = null;
        _controllers[index].text = autoFolderName;
      });
    }
  }

  Future<void> _connectDrive() async {
    if (!await _requireProFeature(ProFeature.drive)) return;
    setState(() => _isDriveBusy = true);
    try {
      final account = await widget.driveService.signIn();
      if (!mounted) return;
      if (account == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('Google Drive connection was cancelled.')),
          ),
        );
      } else {
        setState(() {});
      }
    } catch (error) {
      if (mounted) {
        if (error is GoogleDriveConnectionException) {
          _showConnectionError(error.message);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.tr('Unable to connect Google Drive: {error}', {
                  'error': error,
                }),
              ),
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isDriveBusy = false);
    }
  }

  Future<void> _loadProEntitlements() async {
    final status = await _proService.loadLocalStatus();
    if (mounted) setState(() => _proEntitlements = status);
  }

  Future<bool> _requireProFeature(ProFeature feature) async {
    if (_isShowingProPaywall) return false;
    final status = await _proService.refreshFor(feature);
    if (!mounted) return false;
    setState(() => _proEntitlements = status);
    if (status.allows(feature)) return true;

    _isShowingProPaywall = true;
    try {
      await showDialog<ProPaywallResult>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ProPaywall(
          service: _proService,
          requiredFeature: feature,
          expiredTrial: status.trialExpired,
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

  void _showConnectionError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.tr(message))));
  }

  Future<void> _disconnectDrive() async {
    setState(() => _isDriveBusy = true);
    try {
      await widget.driveService.disconnect();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('Unable to disconnect Google Drive: {error}', {
                'error': error,
              }),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isDriveBusy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_onAppResumed());
    }
  }

  Future<void> _refreshInstalledVersion() async {
    try {
      final version = await _appUpdateService.getCurrentVersion();
      if (!mounted) return;
      setState(() => _currentVersion = version);
      final preferences = await _getPreferences();
      final pendingVersion = preferences.getString(_pendingUpdatedVersionKey);
      if (pendingVersion == null ||
          AppUpdateService.compareVersions(version, pendingVersion) < 0) {
        return;
      }
      await preferences.remove(_pendingUpdatedVersionKey);
      if (!mounted) return;
      setState(() {
        _latestVersion = null;
        _cachedRelease = null;
        _cachedApk = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('Updated to v{version}. Please re-open the app.', {
              'version': pendingVersion.replaceFirst(RegExp(r'^[vV]'), ''),
            }),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('Unable to load the app version: {error}', {
                'error': error,
              }),
            ),
          ),
        );
      }
    }
  }

  Future<void> _onAppResumed() async {
    if (_awaitingInstallPermissionSettings) {
      _awaitingInstallPermissionSettings = false;
      try {
        final canInstall =
            await _appUpdateChannel.invokeMethod<bool>('canInstallApks') ??
            false;
        if (canInstall && _cachedApk != null && _cachedRelease != null) {
          await _installCachedUpdate(_cachedRelease!, _cachedApk!);
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.tr(
                  'Install unknown apps is still disabled for Loka Files.',
                ),
              ),
            ),
          );
        }
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.tr('Unable to continue the update: {error}', {
                  'error': error,
                }),
              ),
            ),
          );
        }
      }
    }
    await _refreshInstalledVersion();
  }

  Future<void> _checkForUpdate() async {
    if (_isCheckingForUpdate || _isDownloadingUpdate) return;
    setState(() => _isCheckingForUpdate = true);
    try {
      final deviceInfo = await _appUpdateChannel
          .invokeMapMethod<Object?, Object?>('getDeviceInfo');
      final manufacturer = deviceInfo?['manufacturer'];
      final supportedAbis = deviceInfo?['supportedAbis'];
      if (manufacturer is! String || supportedAbis is! List) {
        throw const FormatException(
          'Android device information is unavailable.',
        );
      }
      final release = await _appUpdateService.checkForUpdate(
        manufacturer: manufacturer,
        supportedAbis: supportedAbis.whereType<String>().toList(),
      );
      final preferences = await _getPreferences();
      final saved = await preferences.setInt(
        _lastUpdateCheckKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      if (!saved) {
        throw StateError('The last update check time could not be saved.');
      }
      if (!mounted) return;
      setState(() {
        _latestVersion = release?.version;
        _cachedRelease = release;
      });

      if (release == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('You are on the latest version.'))),
        );
        return;
      }

      final shouldUpdate = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            context.tr('New version {version} available', {
              'version': release.version,
            }),
          ),
          content: Text(
            context.tr('Download {asset} and install this update now?', {
              'asset': release.assetName,
            }),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.tr('Later')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.tr('Update')),
            ),
          ],
        ),
      );
      if (shouldUpdate == true) {
        await _downloadAndInstallUpdate(release);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('Unable to check for updates: {error}', {
                'error': error,
              }),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isCheckingForUpdate = false);
    }
  }

  Future<void> _downloadAndInstallUpdate(AppUpdateRelease release) async {
    if (_isCheckingForUpdate || _isDownloadingUpdate) return;
    setState(() => _isDownloadingUpdate = true);
    File? apkFile;
    try {
      final cachedApk = _cachedApk;
      if (_cachedRelease?.version == release.version &&
          _cachedRelease?.assetName == release.assetName &&
          cachedApk != null) {
        if (await AppUpdateService.isValidApkFile(cachedApk)) {
          apkFile = cachedApk;
        } else {
          if (await cachedApk.exists()) await cachedApk.delete();
          _cachedApk = null;
        }
      }
      apkFile ??= await _appUpdateService.downloadApk(
        release,
        onProgress: (received, total) {
          if (mounted) {
            setState(() {
              _downloadedBytes = received;
              _downloadTotalBytes = total;
            });
          }
        },
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr(
                'Download failed. Please try again or download from GitHub Releases.',
              ),
            ),
          ),
        );
      }
      return;
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingUpdate = false;
          _downloadedBytes = 0;
          _downloadTotalBytes = 0;
        });
      }
    }

    if (!mounted) return;
    final downloadedApk = apkFile;
    setState(() {
      _cachedApk = downloadedApk;
      _cachedRelease = release;
      _isDownloadingUpdate = true;
    });
    try {
      final canInstall =
          await _appUpdateChannel.invokeMethod<bool>('canInstallApks') ?? false;
      if (!mounted) return;
      if (!canInstall) {
        final openSettings = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.tr('Allow app updates')),
            content: Text(
              context.tr(
                'To update inside the app, allow Install unknown apps for Loka Files.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(context.tr('Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(context.tr('Open Settings')),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (openSettings == true) {
          _awaitingInstallPermissionSettings = true;
          await _appUpdateChannel.invokeMethod<void>('openInstallSettings');
        }
        return;
      }
      await _installCachedUpdate(release, downloadedApk);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('Unable to install the update: {error}', {
                'error': error,
              }),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isDownloadingUpdate = false);
    }
  }

  Future<void> _installCachedUpdate(
    AppUpdateRelease release,
    File apkFile,
  ) async {
    if (!await AppUpdateService.isValidApkFile(apkFile)) {
      if (await apkFile.exists()) await apkFile.delete();
      _cachedApk = null;
      throw const FormatException('The downloaded file is not a valid APK.');
    }
    final preferences = await _getPreferences();
    final saved = await preferences.setString(
      _pendingUpdatedVersionKey,
      release.version,
    );
    if (!saved) {
      throw StateError('The update version could not be saved.');
    }
    try {
      await _appUpdateChannel.invokeMethod<void>('installApk', {
        'path': apkFile.path,
      });
    } catch (_) {
      await preferences.remove(_pendingUpdatedVersionKey);
      rethrow;
    }
  }

  String get _downloadProgressLabel {
    final total = _downloadTotalBytes;
    final received = _downloadedBytes;
    final percentage = total == 0 ? 0 : (received * 100 ~/ total);
    final receivedMb = received / (1024 * 1024);
    final totalMb = total / (1024 * 1024);
    return context.tr('Downloading {percent}% ({received} / {total} MB)', {
      'percent': percentage,
      'received': receivedMb.toStringAsFixed(1),
      'total': totalMb.toStringAsFixed(1),
    });
  }

  Future<void> _pickDriveFolderForIndex(int index) async {
    if (!widget.driveService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('Connect Google Drive first.'))),
      );
      return;
    }

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
          child: DriveFolderPickerModal(driveService: widget.driveService),
        ),
      ),
    );
    if (selection == null || !mounted) return;

    setState(() {
      final folder = _folders[index];
      folder
        ..path = ''
        ..driveFolderId = selection.id
        ..driveFolderName = selection.name
        ..driveFolderParentId = selection.parentId
        ..driveAccountEmail = selection.accountEmail
        ..label = selection.name;
      _controllers[index].text = selection.name;
    });
  }

  Future<void> _selectLanguage(AppLanguage language) async {
    try {
      await PilahFotoApp.setLanguage(context, language);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('Unable to save language: {error}', {'error': error}),
            ),
          ),
        );
      }
    }
  }

  Future<void> _showAppTour() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AppTourScreen(
          onCompleted: () async {
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  Future<void> _addNewSlot() async {
    if (!await _requireProFeature(ProFeature.addButtons)) return;
    setState(() {
      final label = context.tr('New Category');
      _folders.add(TargetFolder(label: label, path: ''));
      _controllers.add(TextEditingController(text: label));
    });
  }

  void _removeSlot(int index) {
    setState(() {
      _controllers[index].dispose();
      _controllers.removeAt(index);
      _folders.removeAt(index);
    });
  }

  Future<void> _saveAndClose() async {
    await _deleteModeLoad;
    if (!mounted) return;
    try {
      final preferences = await _getPreferences();
      const key = LocalDeleteMode.preferenceKey;
      final value = _deleteMode.preferenceValue;
      if (!LocalDeleteMode.isValidPreferenceKey(key) ||
          value.isEmpty ||
          !const {'moveToTrash', 'deletePermanently'}.contains(value)) {
        throw ArgumentError('Delete Mode preference key or value is invalid.');
      }
      final saved = await preferences.setString(key, value);
      if (!saved) {
        throw StateError('The platform did not confirm the saved value.');
      }
    } catch (error, stackTrace) {
      debugPrint('[Settings] Failed to save Delete Mode: $error\n$stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('Unable to save Delete Mode: {error}', {'error': error}),
          ),
        ),
      );
      return;
    }
    if (!mounted) return;

    for (int i = 0; i < _folders.length; i++) {
      _folders[i].label = _controllers[i].text.trim().isEmpty
          ? 'Folder ${i + 1}'
          : _controllers[i].text.trim();
    }
    widget.onSave(_folders);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('Target folders')),
        actions: [
          TextButton.icon(
            onPressed: _saveAndClose,
            icon: const Icon(Icons.check, size: 18),
            label: Text(context.tr('Save')),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            color: Theme.of(context).colorScheme.surface,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.brightness_6_outlined, size: 18),
                    SizedBox(width: 8),
                    Text(
                      context.tr('Appearance'),
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                DropdownButton<ThemeMode>(
                  value: _selectedThemeMode,
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(
                      value: ThemeMode.system,
                      child: Text(context.tr('System')),
                    ),
                    DropdownMenuItem(
                      value: ThemeMode.light,
                      child: Text(context.tr('Light')),
                    ),
                    DropdownMenuItem(
                      value: ThemeMode.dark,
                      child: Text(context.tr('Dark')),
                    ),
                  ],
                  onChanged: (ThemeMode? mode) {
                    if (mode != null) {
                      setState(() => _selectedThemeMode = mode);
                      PilahFotoApp.setThemeMode(context, mode);
                    }
                  },
                ),
              ],
            ),
          ),
          Card(
            margin: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.language),
                  title: Text(context.tr('Language')),
                  trailing: DropdownButton<AppLanguage>(
                    value: AppLanguage.fromLocale(
                      Localizations.localeOf(context),
                    ),
                    underline: const SizedBox.shrink(),
                    items: AppLanguage.values
                        .map(
                          (language) => DropdownMenuItem(
                            value: language,
                            child: Text(language.displayName),
                          ),
                        )
                        .toList(),
                    onChanged: (language) {
                      if (language != null) _selectLanguage(language);
                    },
                  ),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.tour_outlined),
                  title: Text(context.tr('Show App Tour again')),
                  subtitle: Text(
                    context.tr(
                      'Learn the basics of sorting and Drive uploads.',
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showAppTour,
                ),
              ],
            ),
          ),
          _buildDriveConnectionCard(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  _currentVersion == null
                      ? context.tr('Current version: Loading...')
                      : _latestVersion == null
                      ? context.tr('Current version: v{version}', {
                          'version': _currentVersion!.replaceFirst(
                            RegExp(r'^[vV]'),
                            '',
                          ),
                        })
                      : context.tr(
                          'Current version: v{current} | Latest: v{latest}',
                          {
                            'current': _currentVersion!.replaceFirst(
                              RegExp(r'^[vV]'),
                              '',
                            ),
                            'latest': _latestVersion!.replaceFirst(
                              RegExp(r'^[vV]'),
                              '',
                            ),
                          },
                        ),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                TextButton.icon(
                  onPressed: _isCheckingForUpdate || _isDownloadingUpdate
                      ? null
                      : _latestVersion == null
                      ? _checkForUpdate
                      : () => _downloadAndInstallUpdate(_cachedRelease!),
                  icon: _isCheckingForUpdate || _isDownloadingUpdate
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.system_update_alt, size: 18),
                  label: Text(
                    _isDownloadingUpdate
                        ? _downloadProgressLabel
                        : _latestVersion == null
                        ? context.tr('Check for Update')
                        : context.tr('Update'),
                  ),
                ),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer
                  .withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.tr(
                      'Choose a destination on this device or in Google Drive. Local photos can be moved to either destination.',
                    ),
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('Delete Mode'),
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  context.tr(
                    'Applies only to local files after a successful Google Drive upload.',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                RadioGroup<LocalDeleteMode>(
                  groupValue: _deleteMode,
                  onChanged: (mode) {
                    if (!_isDeleteModeLoading && mode != null) {
                      setState(() => _deleteMode = mode);
                    }
                  },
                  child: Column(
                    children: [
                      RadioListTile<LocalDeleteMode>(
                        value: LocalDeleteMode.moveToTrash,
                        title: Text(context.tr('Move to Trash')),
                        subtitle: Text(context.tr('Restorable for 30 days.')),
                        enabled: !_isDeleteModeLoading,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                      RadioListTile<LocalDeleteMode>(
                        value: LocalDeleteMode.deletePermanently,
                        title: Text(context.tr('Delete Permanently')),
                        subtitle: Text(context.tr('Cannot be undone.')),
                        enabled: !_isDeleteModeLoading,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWideScreen = constraints.maxWidth >= 900;
              return Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isWideScreen ? 1080 : 680,
                  ),
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: isWideScreen ? 2 : 1,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 8,
                      mainAxisExtent: 128,
                    ),
                    itemCount: _proEntitlements.canAddButtons
                        ? _folders.length
                        : _folders.length
                              .clamp(
                                0,
                                ProEntitlementService.freeTargetButtonLimit,
                              )
                              .toInt(),
                    itemBuilder: (context, index) {
                      final folder = _folders[index];
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _controllers[index],
                                      decoration: InputDecoration(
                                        labelText: context.tr('Folder name'),
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  IconButton.filledTonal(
                                    onPressed: () => _removeSlot(index),
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 20,
                                    ),
                                    tooltip: context.tr('Remove folder'),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(
                                    folder.isDriveDestination
                                        ? Icons.cloud_outlined
                                        : Icons.folder_outlined,
                                    size: 16,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: folder.isDriveDestination
                                        ? Row(
                                            children: [
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primaryContainer,
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  context.tr('Drive'),
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onPrimaryContainer,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      folder.driveFolderName ??
                                                          context.tr(
                                                            'Selected folder',
                                                          ),
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .onSurfaceVariant,
                                                      ),
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                    if (folder.driveFolderId !=
                                                        null)
                                                      Text(
                                                        'ID: ${_shortDriveFolderId(folder.driveFolderId!)}',
                                                        style: TextStyle(
                                                          fontSize: 10,
                                                          color: Theme.of(context)
                                                              .colorScheme
                                                              .onSurfaceVariant,
                                                        ),
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          )
                                        : Text(
                                            _destinationDescription(folder),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                  ),
                                  const SizedBox(width: 4),
                                  OutlinedButton.icon(
                                    onPressed: () => _pickFolderForIndex(index),
                                    icon: const Icon(
                                      Icons.folder_open,
                                      size: 15,
                                    ),
                                    label: Text(context.tr('Local')),
                                    style: OutlinedButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () =>
                                        _pickDriveFolderForIndex(index),
                                    icon: const Icon(
                                      Icons.add_to_drive_outlined,
                                    ),
                                    tooltip: context.tr(
                                      'Choose Google Drive folder',
                                    ),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _addNewSlot,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.add),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _proEntitlements.canAddButtons
                          ? context.tr('Add folder')
                          : context.tr('Add Button - Pro {price}', {
                              'price': ProProduct.addButtons.priceLabel,
                            }),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (!_proEntitlements.canAddButtons) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.lock_outline, size: 18),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              context.tr('Loka Files v{version}', {
                'version': _currentVersion ?? '...',
              }),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDriveConnectionCard() {
    final account = widget.driveService.currentUser;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.cloud_outlined),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr('Google Drive'),
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    account?.email ??
                        (_proEntitlements.canUseDrive
                            ? context.tr('Not connected')
                            : context.tr('Connect Drive · Pro {price}', {
                                'price': ProProduct.drive.priceLabel,
                              })),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (_isDriveBusy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (account == null)
              OutlinedButton(
                onPressed: _connectDrive,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_proEntitlements.canUseDrive) ...[
                      const Icon(Icons.lock_outline, size: 16),
                      const SizedBox(width: 4),
                    ],
                    Text(context.tr('Connect')),
                  ],
                ),
              )
            else
              TextButton(
                onPressed: _disconnectDrive,
                child: Text(context.tr('Disconnect')),
              ),
          ],
        ),
      ),
    );
  }

  String _destinationDescription(TargetFolder folder) {
    if (folder.isDriveDestination) {
      return context.tr('Drive · {folder}', {
        'folder': folder.driveFolderName ?? context.tr('Selected folder'),
      });
    }
    return folder.path.isEmpty
        ? context.tr('No destination selected')
        : folder.path;
  }

  String _shortDriveFolderId(String id) => id.length <= 12
      ? id
      : '${id.substring(0, 8)}…${id.substring(id.length - 4)}';
}
