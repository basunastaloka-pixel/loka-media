import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;

import '../services/google_drive_service.dart';

enum _DriveFolderTab { connectedDrive, addFolderLink }

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
  final TextEditingController _folderLinkController = TextEditingController();
  final List<({String id, String name})> _path = [
    (id: 'root', name: 'My Drive'),
  ];
  List<drive.File> _folders = [];
  final Set<String> _newFolderIds = {};
  _DriveFolderTab _activeTab = _DriveFolderTab.connectedDrive;
  ({String id, String name})? _linkedFolder;
  bool _isLoading = true;
  bool _isUsingFolderLink = false;
  String? _folderLinkErrorMessage;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadCurrentFolder();
  }

  @override
  void dispose() {
    _folderNameController.dispose();
    _folderLinkController.dispose();
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

  Future<void> _useFolderLink() async {
    if (_isUsingFolderLink) return;
    setState(() {
      _isUsingFolderLink = true;
      _folderLinkErrorMessage = null;
      _linkedFolder = null;
    });

    try {
      final folder = await widget.driveService.getFolderFromLink(
        _folderLinkController.text.trim(),
      );
      final id = folder.id;
      final name = folder.name;
      if (id == null || name == null) {
        throw StateError('Google Drive returned incomplete folder details.');
      }

      if (!mounted) return;
      setState(() {
        _linkedFolder = (id: id, name: name);
        _folderLinkController.clear();
      });
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _folderLinkErrorMessage = error.message.toString());
      }
    } catch (error) {
      if (mounted) {
        final email =
            widget.driveService.currentUser?.email ?? 'the connected account';
        setState(
          () => _folderLinkErrorMessage =
              'Unable to access this folder. Check that the link is complete '
              'and that this folder is shared as Editor with the connected '
              'Google account ($email). If the folder belongs to another '
              'account, share it to this account first.',
        );
      }
    } finally {
      if (mounted) setState(() => _isUsingFolderLink = false);
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
            title: const Text('Create New Folder'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _folderNameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Folder name',
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
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: isCreating
                    ? null
                    : () async {
                        final name = _folderNameController.text.trim();
                        if (name.isEmpty) {
                          setDialogState(
                            () => errorMessage = 'Enter a folder name.',
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
                            errorMessage = 'Unable to create folder: $error';
                          });
                        }
                      },
                child: isCreating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create'),
              ),
            ],
          ),
        );
      },
    );
    if (createdFolder != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Folder "${createdFolder.name}" created.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mediaQuery = MediaQuery.of(context);
    final title = _activeTab == _DriveFolderTab.connectedDrive
        ? _path.last.name
        : 'Add Folder Link';
    final canSelect =
        _activeTab == _DriveFolderTab.connectedDrive || _linkedFolder != null;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 600,
              maxHeight: mediaQuery.size.height * 0.9,
            ),
            child: Material(
              color: colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Row(
                      children: [
                        if (_activeTab == _DriveFolderTab.connectedDrive &&
                            _path.length > 1)
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
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                          tooltip: 'Close',
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SegmentedButton<_DriveFolderTab>(
                      segments: const [
                        ButtonSegment(
                          value: _DriveFolderTab.connectedDrive,
                          label: Text('My Connected Drive'),
                        ),
                        ButtonSegment(
                          value: _DriveFolderTab.addFolderLink,
                          label: Text('Add Folder Link'),
                        ),
                      ],
                      selected: {_activeTab},
                      onSelectionChanged: (selection) {
                        setState(() => _activeTab = selection.first);
                      },
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      child: _activeTab == _DriveFolderTab.connectedDrive
                          ? _buildConnectedDriveContent(colorScheme)
                          : _buildFolderLinkContent(colorScheme),
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: canSelect
                              ? _activeTab == _DriveFolderTab.connectedDrive
                                    ? _selectCurrentFolder
                                    : () => _selectFolder(
                                        _linkedFolder!.id,
                                        _linkedFolder!.name,
                                      )
                              : null,
                          child: const Text('Select Folder'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConnectedDriveContent(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.driveService.currentUser?.email ?? '',
          style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: _createFolder,
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('Create New Folder'),
          ),
        ),
        const SizedBox(height: 8),
        _buildFolderList(),
      ],
    );
  }

  Widget _buildFolderLinkContent(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Add Google Drive Folder Editor Link',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _folderLinkController,
          keyboardType: TextInputType.url,
          onChanged: (_) {
            if (_linkedFolder != null || _folderLinkErrorMessage != null) {
              setState(() {
                _linkedFolder = null;
                _folderLinkErrorMessage = null;
              });
            }
          },
          decoration: const InputDecoration(
            hintText: 'Paste Google Drive folder link here - https://drive.google.com/drive/folders/...',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        if (_folderLinkErrorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            _folderLinkErrorMessage!,
            style: TextStyle(color: colorScheme.error, fontSize: 12),
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _isUsingFolderLink ? null : _useFolderLink,
            child: _isUsingFolderLink
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Use This Folder'),
          ),
        ),
        if (_linkedFolder case final linkedFolder?) ...[
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: Text(linkedFolder.name),
            subtitle: const Text('Folder link validated'),
          ),
        ],
      ],
    );
  }

  Widget _buildFolderList() {
    if (_isLoading) {
      return const SizedBox(
        height: 180,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_errorMessage != null) {
      return Column(
        children: [
          Text(_errorMessage!, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _loadCurrentFolder,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      );
    }
    if (_folders.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: Text('No subfolders in this location.')),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
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
          trailing: _newFolderIds.contains(folder.id)
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
