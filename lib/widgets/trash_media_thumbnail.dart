import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../services/app_localizations.dart';
import '../services/local_trash_service.dart';
import 'video_preview_layout.dart';

class TrashMediaThumbnail extends StatelessWidget {
  const TrashMediaThumbnail({super.key, required this.item, this.size});

  final LocalTrashItem item;
  final double? size;

  static const _storageChannel = MethodChannel('loka_files/storage');
  static final Map<String, Future<_VideoThumbnailData?>> _videoThumbnailCache =
      {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (item.isVideo)
              FutureBuilder<_VideoThumbnailData?>(
                future: _videoThumbnailCache.putIfAbsent(
                  item.filePath,
                  () => _loadVideoThumbnail(item.filePath),
                ),
                builder: (context, snapshot) {
                  final bytes = snapshot.data?.bytes;
                  if (bytes == null || snapshot.hasError) {
                    return _buildFallback(theme);
                  }
                  return Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _buildFallback(theme),
                  );
                },
              )
            else
              Image.file(
                File(item.filePath),
                fit: BoxFit.cover,
                cacheWidth:
                    ((size ?? 300) * MediaQuery.devicePixelRatioOf(context))
                        .round(),
                errorBuilder: (_, _, _) => _buildFallback(theme),
              ),
            if (item.isVideo)
              Positioned(
                right: 5,
                bottom: 5,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    child: FutureBuilder<_VideoThumbnailData?>(
                      future: _videoThumbnailCache.putIfAbsent(
                        item.filePath,
                        () => _loadVideoThumbnail(item.filePath),
                      ),
                      builder: (context, snapshot) {
                        final duration = item.videoDurationMilliseconds > 0
                            ? item.videoDurationMilliseconds
                            : snapshot.data?.durationMilliseconds ?? 0;
                        return Text(
                          _formatDuration(duration),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFallback(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            item.isVideo ? Icons.video_file_outlined : Icons.image_outlined,
            color: theme.colorScheme.onSurfaceVariant,
            size: (size ?? 100) * 0.28,
          ),
          const SizedBox(height: 3),
          Text(
            item.fileName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 9),
          ),
          Text(
            formatTrashFileSize(item.fileSizeBytes),
            maxLines: 1,
            style: TextStyle(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }

  static Future<_VideoThumbnailData?> _loadVideoThumbnail(String path) async {
    try {
      final result = await _storageChannel.invokeMapMethod<String, Object?>(
        'getVideoThumbnail',
        {'path': path},
      );
      final bytes = result?['bytes'];
      if (bytes is! Uint8List || bytes.isEmpty) return null;
      final duration = result?['durationMilliseconds'];
      return _VideoThumbnailData(
        bytes: bytes,
        durationMilliseconds: duration is int ? duration : 0,
      );
    } on PlatformException catch (error, stackTrace) {
      debugPrint('[Trash] Could not load video thumbnail: $error\n$stackTrace');
      return null;
    } on MissingPluginException catch (error, stackTrace) {
      debugPrint(
        '[Trash] Video thumbnails are unavailable: $error\n$stackTrace',
      );
      return null;
    }
  }

  static String _formatDuration(int milliseconds) {
    final totalSeconds = milliseconds ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final hours = minutes ~/ 60;
    if (hours > 0) {
      return '$hours:${(minutes % 60).toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class _VideoThumbnailData {
  const _VideoThumbnailData({
    required this.bytes,
    required this.durationMilliseconds,
  });

  final Uint8List bytes;
  final int durationMilliseconds;
}

String formatTrashFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unitIndex = -1;
  do {
    size /= 1024;
    unitIndex++;
  } while (size >= 1024 && unitIndex < units.length - 1);
  return '${size.toStringAsFixed(1)} ${units[unitIndex]}';
}

class TrashVideoPreviewDialog extends StatefulWidget {
  const TrashVideoPreviewDialog({super.key, required this.file});

  final File file;

  @override
  State<TrashVideoPreviewDialog> createState() =>
      _TrashVideoPreviewDialogState();
}

class _TrashVideoPreviewDialogState extends State<TrashVideoPreviewDialog> {
  late final Player _player;
  late final VideoController _controller;
  StreamSubscription<String>? _errorSubscription;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _errorSubscription = _player.stream.error.listen((error) {
      if (error.isNotEmpty && mounted) {
        setState(() => _errorMessage = 'Unable to play this video.');
      }
    });
    unawaited(_openVideo());
  }

  Future<void> _openVideo() async {
    try {
      if (!await widget.file.exists()) {
        throw FileSystemException(
          'The video is unavailable.',
          widget.file.path,
        );
      }
      await _controller.platform.future;
      await _player.open(
        Media(Uri.file(widget.file.path).toString()),
        play: true,
      );
      await _controller.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 30),
      );
    } on FileSystemException catch (error, stackTrace) {
      _reportError(error, stackTrace);
    } on PlatformException catch (error, stackTrace) {
      _reportError(error, stackTrace);
    } on TimeoutException catch (error, stackTrace) {
      _reportError(error, stackTrace);
    }
  }

  void _reportError(Object error, StackTrace stackTrace) {
    debugPrint('[Trash] Could not preview video: $error\n$stackTrace');
    if (mounted) setState(() => _errorMessage = 'Unable to play this video.');
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
      child: _errorMessage == null
          ? StreamBuilder<VideoParams>(
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
                      maxSize: Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      ),
                    );
                    return SizedBox(
                      width: size.width,
                      height: size.height,
                      child: AspectRatio(
                        aspectRatio: aspectRatio,
                        child: Video(controller: _controller),
                      ),
                    );
                  },
                );
              },
            )
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.tr(_errorMessage!),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
    );
  }
}
