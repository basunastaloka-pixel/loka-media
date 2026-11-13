import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

double? videoDisplayAspectRatio(VideoParams params) {
  final aspectRatio = params.aspect;
  if (aspectRatio != null && aspectRatio.isFinite && aspectRatio > 0) {
    return aspectRatio;
  }

  final width = params.dw ?? params.w;
  final height = params.dh ?? params.h;
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }

  final ratio = width / height;
  return params.rotate == 90 || params.rotate == 270 ? 1 / ratio : ratio;
}

Size videoPreviewSizeForAspectRatio({
  required double aspectRatio,
  required Size maxSize,
}) {
  if (aspectRatio > maxSize.width / maxSize.height) {
    return Size(maxSize.width, maxSize.width / aspectRatio);
  }
  return Size(maxSize.height * aspectRatio, maxSize.height);
}
