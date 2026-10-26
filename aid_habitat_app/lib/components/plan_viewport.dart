import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Display-only transform: never changes drawing coordinates or saved pages.
Matrix4 fitPlanViewport({
  required Size viewport,
  required Size canvas,
  Rect? contentBounds,
}) {
  if (viewport.isEmpty ||
      !viewport.width.isFinite ||
      !viewport.height.isFinite) {
    return Matrix4.identity();
  }
  if (contentBounds == null) {
    return Matrix4.identity()..setTranslationRaw(
      (viewport.width - canvas.width) / 2,
      (viewport.height - canvas.height) / 2,
      0,
    );
  }
  // Leave the drawing clear of the floating controls at the top and bottom.
  final horizontal = math.min(32.0, viewport.width * .1);
  final vertical = math.min(96.0, viewport.height * .2);
  final scale = math.min(
    4.0,
    math.min(
      (viewport.width - horizontal * 2) / math.max(1.0, contentBounds.width),
      (viewport.height - vertical * 2) / math.max(1.0, contentBounds.height),
    ),
  );
  return Matrix4.identity()
    ..setEntry(0, 0, scale)
    ..setEntry(1, 1, scale)
    ..setEntry(2, 2, scale)
    ..setTranslationRaw(
      viewport.width / 2 - contentBounds.center.dx * scale,
      viewport.height / 2 - contentBounds.center.dy * scale,
      0,
    );
}
