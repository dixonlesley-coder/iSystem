import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// An affine view transform for the canvas: uniform [scale] then [offset]
/// (screen px). Pure and immutable — the math is unit-tested and is the
/// correctness anchor for the 60/120 fps canvas (§4). The widget layer only
/// wires gestures to produce new transforms.
///
/// Mapping: `screen = world * scale + offset`.
@immutable
class ViewportTransform {
  final double scale;
  final Offset offset;

  const ViewportTransform({this.scale = 1.0, this.offset = Offset.zero});

  static const double minScale = 0.02;
  static const double maxScale = 64.0;

  Offset worldToScreen(Offset world) => world * scale + offset;
  Offset screenToWorld(Offset screen) => (screen - offset) / scale;

  ViewportTransform copyWith({double? scale, Offset? offset}) =>
      ViewportTransform(scale: scale ?? this.scale, offset: offset ?? this.offset);

  /// Translate the view by [deltaScreen] pixels (panning).
  ViewportTransform panned(Offset deltaScreen) =>
      copyWith(offset: offset + deltaScreen);

  /// Set the absolute [newScale] while keeping the world point currently under
  /// [focalScreen] anchored at the same screen pixel (zoom-to-cursor).
  ViewportTransform zoomedTo(double newScale, Offset focalScreen) {
    final clamped = newScale.clamp(minScale, maxScale).toDouble();
    final world = screenToWorld(focalScreen);
    // Solve: world * clamped + newOffset == focalScreen
    final newOffset = focalScreen - world * clamped;
    return ViewportTransform(scale: clamped, offset: newOffset);
  }

  /// Multiply the current scale by [factor] about [focalScreen].
  ViewportTransform zoomedBy(double factor, Offset focalScreen) =>
      zoomedTo(scale * factor, focalScreen);

  /// Fit a [contentSize] (world px) centred within [viewportSize] (screen px),
  /// leaving [padding] px around it.
  static ViewportTransform fit(
    Size contentSize,
    Size viewportSize, {
    double padding = 12,
  }) {
    if (contentSize.width <= 0 ||
        contentSize.height <= 0 ||
        viewportSize.width <= 0 ||
        viewportSize.height <= 0) {
      return const ViewportTransform();
    }
    final availW = math.max(1.0, viewportSize.width - padding * 2);
    final availH = math.max(1.0, viewportSize.height - padding * 2);
    final scale = math
        .min(availW / contentSize.width, availH / contentSize.height)
        .clamp(minScale, maxScale)
        .toDouble();
    final scaledW = contentSize.width * scale;
    final scaledH = contentSize.height * scale;
    final offset = Offset(
      (viewportSize.width - scaledW) / 2,
      (viewportSize.height - scaledH) / 2,
    );
    return ViewportTransform(scale: scale, offset: offset);
  }

  /// 100% scale, content top-left placed at [origin].
  static ViewportTransform actualSize(Size contentSize, Size viewportSize) {
    final offset = Offset(
      (viewportSize.width - contentSize.width) / 2,
      (viewportSize.height - contentSize.height) / 2,
    );
    return ViewportTransform(scale: 1.0, offset: offset);
  }

  @override
  bool operator ==(Object other) =>
      other is ViewportTransform &&
      other.scale == scale &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(scale, offset);

  @override
  String toString() =>
      'ViewportTransform(scale: ${scale.toStringAsFixed(3)}, offset: $offset)';
}
