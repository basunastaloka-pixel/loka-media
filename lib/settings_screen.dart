import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import 'models/target_folder.dart';
import 'services/google_drive_service.dart';
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

class _SettingsScreenState extends State<SettingsScreen> {
  late List<TargetFolder> _folders;
  late List<TextEditingController> _controllers;
  ThemeMode _selectedThemeMode = ThemeMode.system;
  bool _isDriveBusy = false;

  @override
  void initState() {
    super.initState();
    _folders = widget.initialFolders
        .map(
          (folder) => TargetFolder(
            label: folder.label,
            path: folder.path,
            driveFolderId: folder.driveFolderId,
            driveFolderName: folder.driveFolderName,
            driveAccountEmail: folder.driveAccountEmail,
          ),
        )
        .toList();

    // Diperbaiki: Menggunakan f.label agar teks di TextField sesuai dengan nama foldernya
    _controllers = _folders
        .map((f) => TextEditingController(text: f.label))
        .toList();
  }

  @override
  void dispose() {
    for (var controller in _controllers) {
      controller.dispose();
    }
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
        _folders[index].driveAccountEmail = null;
        _controllers[index].text = autoFolderName;
      });
    }
  }

  Future<void> _connectDrive() async {
    setState(() => _isDriveBusy = true);
    try {
      final account = await widget.driveService.signIn();
      if (!mounted) return;
      if (account == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Google Drive connection was cancelled.'),
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
            SnackBar(content: Text('Unable to connect Google Drive: $error')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isDriveBusy = false);
    }
  }

  void _showConnectionError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _disconnectDrive() async {
    setState(() => _isDriveBusy = true);
    try {
      await widget.driveService.disconnect();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to disconnect Google Drive: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _isDriveBusy = false);
    }
  }

  Future<void> _pickDriveFolderForIndex(int index) async {
    if (!widget.driveService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect Google Drive first.')),
      );
      return;
    }

    final selection = await showDialog<DriveFolderSelection>(
      context: context,
      builder: (context) =>
          DriveFolderPickerModal(driveService: widget.driveService),
    );
    if (selection == null || !mounted) return;

    setState(() {
      final folder = _folders[index];
      folder
        ..path = ''
        ..driveFolderId = selection.id
        ..driveFolderName = selection.name
        ..driveAccountEmail = selection.accountEmail
        ..label = selection.name;
      _controllers[index].text = selection.name;
    });
  }

  void _addNewSlot() {
    setState(() {
      _folders.add(TargetFolder(label: 'New Category', path: ''));
      _controllers.add(TextEditingController(text: 'New Category'));
    });
  }

  void _removeSlot(int index) {
    setState(() {
      _controllers[index].dispose();
      _controllers.removeAt(index);
      _folders.removeAt(index);
    });
  }

  void _saveAndClose() {
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
        title: const Text('Target folders'),
        actions: [
          TextButton.icon(
            onPressed: _saveAndClose,
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Save'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            color: Theme.of(context).colorScheme.surface,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.brightness_6_outlined, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Appearance',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                DropdownButton<ThemeMode>(
                  value: _selectedThemeMode,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(
                      value: ThemeMode.system,
                      child: Text('System'),
                    ),
                    DropdownMenuItem(
                      value: ThemeMode.light,
                      child: Text('Light'),
                    ),
                    DropdownMenuItem(
                      value: ThemeMode.dark,
                      child: Text('Dark'),
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
          _buildDriveConnectionCard(),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer
                  .withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Choose a destination on this device or in Google Drive. Local photos can be moved to either destination.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              itemCount: _folders.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
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
                                decoration: const InputDecoration(
                                  labelText: 'Folder name',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton.filledTonal(
                              onPressed: () => _removeSlot(index),
                              icon: const Icon(Icons.delete_outline, size: 20),
                              tooltip: 'Remove folder',
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
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primaryContainer,
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: Text(
                                            'Drive',
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
                                          child: Text(
                                            folder.driveFolderName ??
                                                'Selected folder',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                            overflow: TextOverflow.ellipsis,
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
                              icon: const Icon(Icons.folder_open, size: 15),
                              label: const Text('Local'),
                              style: OutlinedButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () => _pickDriveFolderForIndex(index),
                              icon: const Icon(Icons.add_to_drive_outlined),
                              tooltip: 'Choose Google Drive folder',
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _addNewSlot,
              icon: const Icon(Icons.add),
              label: const Text('Add folder'),
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
                  const Text(
                    'Google Drive',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    account?.email ?? 'Not connected',
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
                child: const Text('Connect'),
              )
            else
              TextButton(
                onPressed: _disconnectDrive,
                child: const Text('Disconnect'),
              ),
          ],
        ),
      ),
    );
  }

  String _destinationDescription(TargetFolder folder) {
    if (folder.isDriveDestination) {
      return 'Drive · ${folder.driveFolderName ?? 'Selected folder'}';
    }
    return folder.path.isEmpty ? 'No destination selected' : folder.path;
  }
}
