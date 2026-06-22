import '../units.dart';

/// Per-sheet pixel ↔ real-world mapping (§10: *horizontal length = pixels ×
/// calibrated scale* — geometry is the single source of truth for length).
/// Pure, immutable value type.
class ScaleCalibration {
  /// Real metres represented by one PDF pixel.
  final double metersPerPixel;

  const ScaleCalibration(this.metersPerPixel)
      : assert(metersPerPixel > 0, 'scale must be positive');

  /// Calibrate from a reference segment the engineer marked on the drawing: a
  /// known [realDistance] spanning [pixelDistance] pixels on the sheet.
  factory ScaleCalibration.fromReference({
    required double pixelDistance,
    required Length realDistance,
  }) {
    assert(pixelDistance > 0, 'reference pixel distance must be positive');
    return ScaleCalibration(realDistance.meters / pixelDistance);
  }

  /// Real length of a [pixels] span on this sheet.
  Length lengthForPixels(double pixels) => Length(pixels * metersPerPixel);

  /// Pixel span representing a real [length] on this sheet.
  double pixelsForLength(Length length) => length.meters / metersPerPixel;

  /// Real area of a [pixelArea] (px²) region — for room/zone areas.
  Area areaForPixels(double pixelArea) =>
      Area(pixelArea * metersPerPixel * metersPerPixel);

  @override
  bool operator ==(Object other) =>
      other is ScaleCalibration && other.metersPerPixel == metersPerPixel;

  @override
  int get hashCode => metersPerPixel.hashCode;

  @override
  String toString() =>
      'ScaleCalibration(${metersPerPixel.toStringAsExponential(4)} m/px)';
}
