import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'services/app_localizations.dart';
import 'services/local_trash_service.dart';
import 'widgets/trash_media_thumbnail.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  final LocalTrashService _trashService = LocalTrashService();
  final ScrollController _listScrollController = ScrollController();
  final ScrollController _gridScrollController = ScrollController();
  final Set<String> _busyItems = {};
  final Set<String> _selectedItems = {};
  List<LocalTrashItem> _items = [];
  TrashSortOrder _sortOrder = TrashSortOrder.newestDeleted;
  bool _isLoading = true;
  bool _isGridView = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  @override
  void dispose() {
    _listScrollController.dispose();
    _gridScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadItems() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final sortOrder = await _trashService.getSortOrder();
      final items = await _trashService.listItems(sortOrder: sortOrder);
      if (!mounted) return;
      setState(() {
        _sortOrder = sortOrder;
        _items = items;
        _selectedItems.removeWhere((id) => !items.any((item) => item.id == id));
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = context.tr('Unable to load Trash: {error}', {
          'error': error,
        });
        _isLoading = false;
      });
    }
  }

  Future<void> _changeSortOrder(TrashSortOrder order) async {
    try {
      await _trashService.saveSortOrder(order);
      if (!mounted) return;
      setState(() {
        _sortOrder = order;
        _items = LocalTrashService.sortItems(_items, order);
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('Unable to save Trash sort order: {error}', {
                'error': error,
              }),
            ),
          ),
        );
      }
    }
  }

  void _toggleViewMode() {
    setState(() {
      _isGridView = !_isGridView;
      if (!_isGridView) _selectedItems.clear();
    });
  }

  void _toggleSelection(LocalTrashItem item) {
    setState(() {
      if (!_selectedItems.add(item.id)) _selectedItems.remove(item.id);
    });
  }

  Future<void> _restore(LocalTrashItem item) async {
    await _runItemAction(
      [item],
      _trashService.restore,
      successMessage: context.tr('"{file}" was restored.', {
        'file': item.fileName,
      }),
      errorPrefix: context.tr('Unable to restore this file'),
    );
  }

  Future<void> _restoreSelected() async {
    final selected = _items
        .where((item) => _selectedItems.contains(item.id))
        .toList();
    if (selected.isEmpty) return;
    await _runItemAction(
      selected,
      _trashService.restore,
      successMessage: context.tr('{count} item(s) restored.', {
        'count': selected.length,
      }),
      errorPrefix: context.tr('Unable to restore selected files'),
    );
  }

  Future<void> _deletePermanently(LocalTrashItem item) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Delete permanently?')),
        content: Text(
          context.tr('This cannot be undone. Delete {file} permanently?', {
            'file': item.fileName,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.tr('Delete Permanently')),
          ),
        ],
      ),
    );
    if (shouldDelete != true || !mounted) return;
    await _runItemAction(
      [item],
      _trashService.deletePermanently,
      successMessage: context.tr('"{file}" was permanently deleted.', {
        'file': item.fileName,
      }),
      errorPrefix: context.tr('Unable to delete this file'),
    );
  }

  Future<void> _deleteSelectedPermanently() async {
    final selected = _items
        .where((item) => _selectedItems.contains(item.id))
        .toList();
    if (selected.isEmpty) return;
    if (selected.length == 1) {
      await _deletePermanently(selected.single);
      return;
    }
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Delete permanently?')),
        content: Text(
          context.tr(
            'This cannot be undone. Delete {count} selected files permanently?',
            {'count': selected.length},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.tr('Delete Permanently')),
          ),
        ],
      ),
    );
    if (shouldDelete != true || !mounted) return;
    await _runItemAction(
      selected,
      _trashService.deletePermanently,
      successMessage: context.tr('{count} item(s) permanently deleted.', {
        'count': selected.length,
      }),
      errorPrefix: context.tr('Unable to delete selected files'),
    );
  }

  Future<void> _runItemAction(
    List<LocalTrashItem> items,
    Future<void> Function(LocalTrashItem) action, {
    required String successMessage,
    required String errorPrefix,
  }) async {
    setState(() => _busyItems.addAll(items.map((item) => item.id)));
    try {
      for (final item in items) {
        await action(item);
      }
      if (!mounted) return;
      setState(() => _selectedItems.removeAll(items.map((item) => item.id)));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(successMessage)));
      await _loadItems();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('{prefix}: {error}', {
                'prefix': errorPrefix,
                'error': error,
              }),
            ),
          ),
        );
        await _loadItems();
      }
    } finally {
      _busyItems.removeAll(items.map((item) => item.id));
      if (mounted) setState(() {});
    }
  }

  Future<void> _preview(LocalTrashItem item) async {
    if (_selectedItems.isNotEmpty) {
      _toggleSelection(item);
      return;
    }
    if (item.isVideo) {
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black,
        builder: (_) => TrashVideoPreviewDialog(file: File(item.filePath)),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: InteractiveViewer(
          child: Image.file(
            File(item.filePath),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.tr('Unable to preview {file}.', {
                    'file': item.fileName,
                  }),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('Trash')),
        actions: [
          PopupMenuButton<TrashSortOrder>(
            tooltip: context.tr('Sort Trash'),
            initialValue: _sortOrder,
            onSelected: _changeSortOrder,
            itemBuilder: (context) => [
              _sortMenuItem(
                TrashSortOrder.newestDeleted,
                context.tr('Newest first'),
              ),
              _sortMenuItem(
                TrashSortOrder.oldestDeleted,
                context.tr('Oldest first'),
              ),
              _sortMenuItem(
                TrashSortOrder.newestOriginal,
                context.tr('Newest by original date'),
              ),
              _sortMenuItem(
                TrashSortOrder.oldestOriginal,
                context.tr('Oldest by original date'),
              ),
            ],
            icon: const Icon(Icons.sort),
          ),
          IconButton(
            onPressed: _toggleViewMode,
            tooltip: context.tr(
              _isGridView ? 'Show as a list' : 'Show as a grid',
            ),
            icon: Icon(
              _isGridView ? Icons.view_list_rounded : Icons.grid_view_rounded,
            ),
          ),
          IconButton(
            onPressed: _isLoading ? null : _loadItems,
            tooltip: context.tr('Refresh Trash'),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildRetentionNotice(context),
          Expanded(child: _buildContent(context)),
        ],
      ),
      bottomNavigationBar: _isGridView && _selectedItems.isNotEmpty
          ? _buildSelectionBar(context)
          : null,
    );
  }

  CheckedPopupMenuItem<TrashSortOrder> _sortMenuItem(
    TrashSortOrder order,
    String title,
  ) {
    return CheckedPopupMenuItem(
      value: order,
      checked: _sortOrder == order,
      child: Text(title),
    );
  }

  Widget _buildRetentionNotice(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        context.tr(
          'Files in Trash are kept for 30 days, then deleted permanently. Tap Restore to bring back.',
        ),
        style: TextStyle(fontSize: 12),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: _loadItems,
                child: Text(context.tr('Retry')),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(child: Text(context.tr('Your Trash is empty.')));
    }
    if (_isGridView) return _buildGridView(context);
    return _buildListView();
  }

  Widget _buildListView() {
    return ListView.separated(
      controller: _listScrollController,
      key: const PageStorageKey<String>('trash-list'),
      padding: const EdgeInsets.all(12),
      itemCount: _items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _buildListItem(_items[index]),
    );
  }

  Widget _buildListItem(LocalTrashItem item) {
    final isBusy = _busyItems.contains(item.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: isBusy ? null : () => _preview(item),
              child: TrashMediaThumbnail(item: item, size: 88),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildItemDetails(item, compact: false),
                  const SizedBox(height: 6),
                  if (isBusy)
                    const SizedBox(
                      height: 36,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else
                    Wrap(
                      spacing: 4,
                      runSpacing: 0,
                      children: [
                        TextButton.icon(
                          onPressed: () => _restore(item),
                          icon: const Icon(Icons.restore, size: 16),
                          label: Text(context.tr('Restore')),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => _deletePermanently(item),
                          icon: const Icon(Icons.delete_forever, size: 16),
                          label: Text(context.tr('Delete Permanently')),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGridView(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = (constraints.maxWidth / 180).floor().clamp(2, 5);
        return GridView.builder(
          controller: _gridScrollController,
          key: const PageStorageKey<String>('trash-grid'),
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.7,
          ),
          itemCount: _items.length,
          itemBuilder: (context, index) => _buildGridItem(_items[index]),
        );
      },
    );
  }

  Widget _buildGridItem(LocalTrashItem item) {
    final isSelected = _selectedItems.contains(item.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _preview(item),
        onLongPress: () => _toggleSelection(item),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: TrashMediaThumbnail(item: item)),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: _buildItemDetails(item, compact: true),
                ),
              ],
            ),
            if (isSelected)
              Positioned.fill(
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: 0.18),
                ),
              ),
            if (isSelected)
              const Positioned(
                top: 6,
                right: 6,
                child: Icon(Icons.check_circle, color: Colors.white),
              ),
            if (_busyItems.contains(item.id))
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x66000000),
                  child: Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemDetails(LocalTrashItem item, {required bool compact}) {
    final bodyStyle = Theme.of(context).textTheme.bodySmall;
    final remaining = item.remainingDays;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.fileName,
          maxLines: compact ? 2 : 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Text(
          context.tr('Folder: {folder}', {
            'folder': context.tr(_originalFolderName(item.originalPath)),
          }),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: bodyStyle,
        ),
        Text(
          context.tr('Deleted {date}', {
            'date': DateFormat('dd/MM/yyyy HH:mm').format(item.deletedAt),
          }),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: bodyStyle,
        ),
        Text(
          context.tr(
            remaining == 1 ? '{count} day left' : '{count} days left',
            {'count': remaining},
          ),
          style: bodyStyle?.copyWith(
            color: remaining <= 3
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Text(formatTrashFileSize(item.fileSizeBytes), style: bodyStyle),
      ],
    );
  }

  Widget _buildSelectionBar(BuildContext context) {
    final count = _selectedItems.length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busyItems.isEmpty ? _restoreSelected : null,
                icon: const Icon(Icons.restore),
                label: Text(context.tr('Restore ({count})', {'count': count})),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _busyItems.isEmpty
                    ? _deleteSelectedPermanently
                    : null,
                icon: const Icon(Icons.delete_forever),
                label: Text(context.tr('Delete Permanently')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _originalFolderName(String path) {
    final parts = path.replaceAll('\\', '/').split('/')
      ..removeWhere((part) => part.isEmpty);
    return parts.length > 1 ? parts[parts.length - 2] : 'Unknown folder';
  }
}
