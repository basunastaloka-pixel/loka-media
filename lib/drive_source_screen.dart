import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;

import 'models/target_folder.dart';
import 'services/google_drive_service.dart';

class DriveSourceScreen extends StatefulWidget {
  final GoogleDriveService driveService;
  final List<TargetFolder> targetFolders;
  final Future<List<TargetFolder>> Function() onEditTargets;

  const DriveSourceScreen({
    super.key,
    required this.driveService,
    required this.targetFolders,
    required this.onEditTargets,
  });

  @override
  State<DriveSourceScreen> createState() => _DriveSourceScreenState();
}

class _DriveSourceScreenState extends State<DriveSourceScreen> {
  final List<({String id, String name})> _path = [
    (id: 'root', name: 'My Drive'),
  ];
  late List<TargetFolder> _targetFolders;
  List<drive.File> _folders = [];
  List<drive.File> _mediaFiles = [];
  final Set<String> _movingFileIds = {};
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _targetFolders = List.of(widget.targetFolders);
    _loadCurrentFolder();
  }

  List<TargetFolder> get _driveTargets => _targetFolders
      .where(
        (target) =>
            target.isDriveDestination &&
            (target.driveAccountEmail == null ||
                target.driveAccountEmail ==
                    widget.driveService.currentUser?.email),
      )
      .toList();

  Future<void> _loadCurrentFolder() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final results = await Future.wait([
        widget.driveService.getFolders(parentId: _path.last.id),
        widget.driveService.getMediaFiles(parentId: _path.last.id),
      ]);
      if (!mounted) return;
      setState(() {
        _folders = results[0];
        _mediaFiles = results[1];
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

  void _goBack() {
    if (_path.length > 1) {
      setState(() => _path.removeLast());
      _loadCurrentFolder();
    } else {
      Navigator.pop(context);
    }
  }

  Future<void> _moveFile(drive.File file, TargetFolder target) async {
    final fileId = file.id;
    final targetFolderId = target.driveFolderId;
    if (fileId == null || targetFolderId == null) return;
    if (targetFolderId == _path.last.id) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This file is already in that folder.')),
      );
      return;
    }

    setState(() => _movingFileIds.add(fileId));
    try {
      await widget.driveService.moveFileToFolder(
        fileId: fileId,
        targetFolderId: targetFolderId,
      );
      if (!mounted) return;
      setState(() {
        _mediaFiles.removeWhere((media) => media.id == fileId);
        _movingFileIds.remove(fileId);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${file.name ?? 'File'} moved to ${target.label}.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _movingFileIds.remove(fileId));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Unable to move file: $error')));
    }
  }

  Future<void> _editTargets() async {
    final folders = await widget.onEditTargets();
    if (mounted) setState(() => _targetFolders = List.of(folders));
  }

  @override
  Widget build(BuildContext context) {
    final accountEmail = widget.driveService.currentUser?.email ?? '';

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: _goBack,
          icon: const Icon(Icons.arrow_back),
          tooltip: _path.length > 1 ? 'Parent folder' : 'Back to albums',
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _path.last.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            Text(
              accountEmail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _editTargets,
            icon: const Icon(Icons.tune),
            tooltip: 'Configure Drive destinations',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? _buildErrorState()
          : _buildContents(),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 36),
            const SizedBox(height: 12),
            Text(_errorMessage!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _loadCurrentFolder,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContents() {
    if (_folders.isEmpty && _mediaFiles.isEmpty) {
      return const Center(child: Text('This Drive folder is empty.'));
    }

    return CustomScrollView(
      slivers: [
        if (_folders.isNotEmpty) ...[
          _buildSectionHeader('FOLDERS', _folders.length),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildFolderTile(_folders[index]),
              childCount: _folders.length,
            ),
          ),
        ],
        if (_mediaFiles.isNotEmpty) ...[
          _buildSectionHeader('PHOTOS & VIDEOS', _mediaFiles.length),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildMediaTile(_mediaFiles[index]),
              childCount: _mediaFiles.length,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(String label, int count) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(
          '$label  /  $count',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildFolderTile(drive.File folder) {
    return ListTile(
      onTap: () => _openFolder(folder),
      leading: const Icon(Icons.folder_outlined),
      title: Text(
        folder.name ?? 'Unnamed folder',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }

  Widget _buildMediaTile(drive.File file) {
    final fileId = file.id;
    final isMoving = fileId != null && _movingFileIds.contains(fileId);
    final destinations = _driveTargets;

    return ListTile(
      leading: SizedBox(
        width: 52,
        height: 52,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: fileId == null
              ? _mediaPlaceholder(file)
              : FutureBuilder<Uint8List?>(
                  future: widget.driveService.getThumbnailBytes(fileId),
                  builder: (context, snapshot) {
                    if (snapshot.hasData && snapshot.data != null) {
                      return Image.memory(
                        snapshot.data!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            _mediaPlaceholder(file),
                      );
                    }
                    return _mediaPlaceholder(file);
                  },
                ),
        ),
      ),
      title: Text(
        file.name ?? 'Untitled media',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        file.mimeType?.startsWith('video/') == true ? 'Video' : 'Photo',
      ),
      trailing: isMoving
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : destinations.isEmpty
          ? IconButton(
              onPressed: _editTargets,
              icon: const Icon(Icons.drive_file_move_outlined),
              tooltip: 'Set a Drive destination',
            )
          : PopupMenuButton<TargetFolder>(
              tooltip: 'Move to Drive folder',
              onSelected: (target) => _moveFile(file, target),
              itemBuilder: (context) => destinations
                  .map(
                    (target) =>
                        PopupMenuItem(value: target, child: Text(target.label)),
                  )
                  .toList(),
              icon: const Icon(Icons.drive_file_move_outlined),
            ),
    );
  }

  Widget _mediaPlaceholder(drive.File file) {
    final isVideo = file.mimeType?.startsWith('video/') == true;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        isVideo ? Icons.movie_outlined : Icons.image_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
