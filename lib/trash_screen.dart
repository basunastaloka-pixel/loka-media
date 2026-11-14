import 'package:flutter/material.dart';

import 'services/local_trash_service.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  final LocalTrashService _trashService = LocalTrashService();
  List<LocalTrashItem> _items = [];
  bool _isLoading = true;
  String? _errorMessage;
  final Set<String> _busyItems = {};

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final items = await _trashService.listItems();
      if (!mounted) return;
      setState(() {
        _items = items;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to load Trash: $error';
        _isLoading = false;
      });
    }
  }

  Future<void> _restore(LocalTrashItem item) async {
    if (!_busyItems.add(item.id)) return;
    setState(() {});
    try {
      await _trashService.restore(item);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${item.fileName}" was restored.')),
      );
      await _loadItems();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to restore this file: $error')),
        );
      }
    } finally {
      _busyItems.remove(item.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _deletePermanently(LocalTrashItem item) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: Text('"${item.fileName}" will be permanently deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );
    if (shouldDelete != true || !_busyItems.add(item.id)) return;
    setState(() {});
    try {
      await _trashService.deletePermanently(item);
      await _loadItems();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to delete this file: $error')),
        );
      }
    } finally {
      _busyItems.remove(item.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trash'),
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _loadItems,
            tooltip: 'Refresh Trash',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_errorMessage!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _loadItems,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : _items.isEmpty
          ? const Center(child: Text('Your Trash is empty.'))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final item = _items[index];
                final isBusy = _busyItems.contains(item.id);
                return Card(
                  child: ListTile(
                    leading: Icon(
                      _isVideo(item.fileName)
                          ? Icons.video_file_outlined
                          : Icons.image_outlined,
                    ),
                    title: Text(
                      item.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${item.remainingDays} '
                      '${item.remainingDays == 1 ? 'day' : 'days'} remaining',
                    ),
                    trailing: isBusy
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : PopupMenuButton<String>(
                            tooltip: 'Trash actions',
                            onSelected: (action) {
                              if (action == 'restore') {
                                _restore(item);
                              } else {
                                _deletePermanently(item);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'restore',
                                child: Text('Restore'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete Permanently'),
                              ),
                            ],
                          ),
                  ),
                );
              },
            ),
    );
  }

  bool _isVideo(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    return const {
      'mp4',
      'mov',
      'm4v',
      'avi',
      'mkv',
      'webm',
    }.contains(extension);
  }
}
