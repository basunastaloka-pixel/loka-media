import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;

import '../services/app_localizations.dart';
import '../services/drive_folder_link.dart';
import '../services/google_drive_service.dart';

enum _DriveFolderTab { connectedDrive, addFolderLink }

class DriveFolderSelection {
  final String id;
  final String name;
  final String? parentId;
  final String accountEmail;

  const DriveFolderSelection({
    required this.id,
    required this.name,
    required this.parentId,
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
  ({String id, String name, String? parentId})? _linkedFolder;
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
    _selectFolder(
      _path.last.id,
      _path.last.name,
      _path.length > 1 ? _path[_path.length - 2].id : 'root',
    );
  }

  void _selectFolder(String id, String name, String? parentId) {
    Navigator.pop(
      context,
      DriveFolderSelection(
        id: id,
        name: name,
        parentId: parentId,
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
        _linkedFolder = (id: id, name: name, parentId: folder.parents?.first);
        _folderLinkController.clear();
      });
    } on FormatException catch (error) {
      if (mounted) {
        setState(
          () => _folderLinkErrorMessage = context.tr(error.message.toString()),
        );
      }
    } on DriveFolderLinkException catch (error) {
      if (mounted) {
        final lines = <String>[];
        if (error.mayBeDriveFileScopeLimitation) {
          lines.add(
            context.tr(
              'This folder was not created by Loka Files, so Drive does not allow access with current permission.',
            ),
          );
          if (error.httpStatus == 404) {
            lines.add(
              context.tr(
                'Drive does not distinguish a missing folder from one hidden by the current permission.',
              ),
            );
          }
        } else {
          lines.add(context.tr('Unable to validate this folder.'));
        }
        lines.addAll([
          context.tr('Folder ID: {id}', {'id': error.folderId}),
          context.tr('HTTP status: {status}', {
            'status': error.httpStatus ?? context.tr('not available'),
          }),
          context.tr('Drive API error: {error}', {'error': error.apiError}),
          context.tr('Account: {account}', {'account': error.accountEmail}),
        ]);
        setState(() => _folderLinkErrorMessage = lines.join('\n'));
      }
    } catch (error) {
      if (mounted) {
        final email =
            widget.driveService.currentUser?.email ?? 'the connected account';
        final folderId = extractDriveFolderId(_folderLinkController.text);
        setState(
          () => _folderLinkErrorMessage =
              '${context.tr('Unable to validate this folder.')}\n'
              '${context.tr('Folder ID: {id}', {'id': folderId ?? context.tr('not available')})}\n'
              '${context.tr('HTTP status: {status}', {'status': context.tr('not available')})}\n'
              '${context.tr('Drive API error: {error}', {'error': error})}\n'
              '${context.tr('Account: {account}', {'account': email})}',
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
            title: Text(context.tr('Create New Folder')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _folderNameController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: context.tr('Folder name'),
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
                child: Text(context.tr('Cancel')),
              ),
              FilledButton(
                onPressed: isCreating
                    ? null
                    : () async {
                        final name = _folderNameController.text.trim();
                        if (name.isEmpty) {
                          setDialogState(
                            () => errorMessage = context.tr(
                              'Enter a folder name.',
                            ),
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
                            errorMessage = context.tr(
                              'Unable to create folder: {error}',
                              {'error': error},
                            );
                          });
                        }
                      },
                child: isCreating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(context.tr('Create')),
              ),
            ],
          ),
        );
      },
    );
    if (createdFolder != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('Folder "{folder}" created.', {
              'folder': createdFolder.name ?? '',
            }),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mediaQuery = MediaQuery.of(context);
    final title = _activeTab == _DriveFolderTab.connectedDrive
        ? _path.last.name
        : context.tr('Add Folder Link');
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
                            tooltip: context.tr('Parent folder'),
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
                          tooltip: context.tr('Close'),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SegmentedButton<_DriveFolderTab>(
                      segments: [
                        ButtonSegment(
                          value: _DriveFolderTab.connectedDrive,
                          label: Text(context.tr('My Connected Drive')),
                        ),
                        ButtonSegment(
                          value: _DriveFolderTab.addFolderLink,
                          label: Text(context.tr('Add Folder Link')),
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
                          child: Text(context.tr('Cancel')),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: canSelect
                              ? _activeTab == _DriveFolderTab.connectedDrive
                                    ? _selectCurrentFolder
                                    : () => _selectFolder(
                                        _linkedFolder!.id,
                                        _linkedFolder!.name,
                                        _linkedFolder!.parentId,
                                      )
                              : null,
                          child: Text(context.tr('Select Folder')),
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
            label: Text(context.tr('Create New Folder')),
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
          context.tr('Add Google Drive Folder Editor Link'),
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
          decoration: InputDecoration(
            hintText: context.tr(
              'Paste Google Drive folder link here - https://drive.google.com/drive/folders/...',
            ),
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
                : Text(context.tr('Use This Folder')),
          ),
        ),
        if (_linkedFolder case final linkedFolder?) ...[
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: Text(linkedFolder.name),
            subtitle: Text(context.tr('Folder link validated')),
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
          Text(context.tr(_errorMessage!), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _loadCurrentFolder,
            icon: const Icon(Icons.refresh),
            label: Text(context.tr('Retry')),
          ),
        ],
      );
    }
    if (_folders.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(context.tr('No subfolders in this location.')),
        ),
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
            folder.name ?? context.tr('Unnamed folder'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: _newFolderIds.contains(folder.id)
              ? TextButton(
                  onPressed: folder.id == null || folder.name == null
                      ? null
                      : () => _selectFolder(
                          folder.id!,
                          folder.name!,
                          _path.last.id,
                        ),
                  child: Text(context.tr('Select')),
                )
              : const Icon(Icons.chevron_right),
          onTap: () => _openFolder(folder),
        );
      },
    );
  }
}
