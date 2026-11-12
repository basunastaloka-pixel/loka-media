import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;

import '../services/google_drive_service.dart';

class DriveFolderSelection {
  final String id;
  final String name;
  final String accountEmail;

  const DriveFolderSelection({
    required this.id,
    required this.name,
    required this.accountEmail,
  });
}

class DriveFolderPickerModal extends StatefulWidget {
  final GoogleDriveService driveService;

  const DriveFolderPickerModal({super.key, required this.driveService});

  @override
  State<DriveFolderPickerModal> createState() => _DriveFolderPickerModalState();
}

class _DriveFolderPickerModalState extends State<DriveFolderPickerModal> {
  final TextEditingController _folderNameController = TextEditingController();
  final List<({String id, String name})> _path = [
    (id: 'root', name: 'My Drive'),
  ];
  List<drive.File> _folders = [];
  final Set<String> _newFolderIds = {};
  final Set<String> _pickerFolderIds = {};
  bool _isLoading = true;
  bool _isPickingExistingFolder = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadCurrentFolder();
  }

  @override
  void dispose() {
    _folderNameController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentFolder() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final folders = await widget.driveService.getFolders(
        parentId: _path.last.id,
      );
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
        _isLoading = false;
      });
    }
  }

  void _openFolder(drive.File folder) {
    final id = folder.id;
    final name = folder.name;
    if (id == null || name == null) return;
    setState(() => _path.add((id: id, name: name)));
    _loadCurrentFolder();
  }

  void _goToParent() {
    if (_path.length <= 1) return;
    setState(() => _path.removeLast());
    _loadCurrentFolder();
  }

  void _selectCurrentFolder() {
    _selectFolder(_path.last.id, _path.last.name);
  }

  void _selectFolder(String id, String name) {
    Navigator.pop(
      context,
      DriveFolderSelection(
        id: id,
        name: name,
        accountEmail: widget.driveService.currentUser!.email,
      ),
    );
  }

  Future<void> _pickExistingFolder() async {
    setState(() => _isPickingExistingFolder = true);
    try {
      final folder = await widget.driveService.pickExistingFolder();
      if (folder == null || !mounted) return;
      final id = folder.id;
      if (id == null || folder.name == null) {
        throw StateError('Google Picker returned incomplete folder details.');
      }

      setState(() {
        _pickerFolderIds.add(id);
        if (!_folders.any((existing) => existing.id == id)) {
          _folders = [..._folders, folder]
            ..sort(
              (left, right) => (left.name ?? '').toLowerCase().compareTo(
                (right.name ?? '').toLowerCase(),
              ),
            );
        }
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Tidak dapat memilih folder Drive: $error')),
      );
    } finally {
      if (mounted) setState(() => _isPickingExistingFolder = false);
    }
  }

  Future<void> _createFolder() async {
    _folderNameController.clear();
    final createdFolder = await showDialog<drive.File>(
      context: context,
      builder: (dialogContext) {
        var isCreating = false;
        String? errorMessage;

        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Buat Folder Baru'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _folderNameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Nama folder',
                    border: OutlineInputBorder(),
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) {
                    if (errorMessage != null) {
                      setDialogState(() => errorMessage = null);
                    }
                  },
                ),
                if (errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: isCreating
                    ? null
                    : () => Navigator.pop(dialogContext),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: isCreating
                    ? null
                    : () async {
                        final name = _folderNameController.text.trim();
                        if (name.isEmpty) {
                          setDialogState(
                            () => errorMessage = 'Masukkan nama folder.',
                          );
                          return;
                        }

                        setDialogState(() {
                          isCreating = true;
                          errorMessage = null;
                        });
                        try {
                          final folder = await widget.driveService.createFolder(
                            name: name,
                            parentId: _path.last.id,
                          );
                          if (mounted) {
                            setState(() {
                              _folders = [..._folders, folder]
                                ..sort(
                                  (left, right) =>
                                      (left.name ?? '').toLowerCase().compareTo(
                                        (right.name ?? '').toLowerCase(),
                                      ),
                                );
                              _newFolderIds.add(folder.id!);
                            });
                          }
                          if (!dialogContext.mounted) return;
                          Navigator.pop(dialogContext, folder);
                        } catch (error) {
                          if (!dialogContext.mounted) return;
                          setDialogState(() {
                            isCreating = false;
                            errorMessage = 'Folder tidak dapat dibuat: $error';
                          });
                        }
                      },
                child: isCreating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Buat'),
              ),
            ],
          ),
        );
      },
    );
    if (createdFolder != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Folder "${createdFolder.name}" dibuat.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Row(
        children: [
          if (_path.length > 1)
            IconButton(
              onPressed: _goToParent,
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Parent folder',
              visualDensity: VisualDensity.compact,
            )
          else
            const Icon(Icons.cloud_outlined),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _path.last.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        height: 340,
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.driveService.currentUser?.email ?? '',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: _createFolder,
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 18,
                    ),
                    label: const Text('+ Buat Folder Baru'),
                  ),
                  TextButton.icon(
                    onPressed: _isPickingExistingFolder
                        ? null
                        : _pickExistingFolder,
                    icon: _isPickingExistingFolder
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.drive_file_move_outline, size: 18),
                    label: const Text('Pilih Folder Lama'),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildFolderList()),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selectCurrentFolder,
          child: const Text('Select this folder'),
        ),
      ],
    );
  }

  Widget _buildFolderList() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_errorMessage!, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _loadCurrentFolder,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_folders.isEmpty) {
      return const Center(child: Text('No subfolders in this location.'));
    }

    return ListView.separated(
      itemCount: _folders.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final folder = _folders[index];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.folder_outlined),
          title: Text(
            folder.name ?? 'Unnamed folder',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing:
              _newFolderIds.contains(folder.id) ||
                  _pickerFolderIds.contains(folder.id)
              ? TextButton(
                  onPressed: folder.id == null || folder.name == null
                      ? null
                      : () => _selectFolder(folder.id!, folder.name!),
                  child: const Text('Select'),
                )
              : const Icon(Icons.chevron_right),
          onTap: () => _openFolder(folder),
        );
      },
    );
  }
}
