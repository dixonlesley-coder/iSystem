import 'package:flutter/widgets.dart';

/// A single drawing sheet (a PDF page, or a placeholder page until a PDF is
/// imported in P1). [sizePx] is the content's natural pixel size — used to
/// fit/centre the canvas. Calibration (px → real length) lands in P1.
@immutable
class Sheet {
  final String id;
  final String name;

  /// Path to the source PDF on disk, or null for a placeholder page (P0).
  final String? pdfPath;
  final int pageIndex;

  /// Natural content size in pixels.
  final Size sizePx;

  const Sheet({
    required this.id,
    required this.name,
    this.pdfPath,
    this.pageIndex = 0,
    this.sizePx = const Size(1684, 1190), // ~A3 landscape placeholder
  });

  bool get isPlaceholder => pdfPath == null;

  Sheet copyWith({
    String? name,
    String? pdfPath,
    int? pageIndex,
    Size? sizePx,
  }) =>
      Sheet(
        id: id,
        name: name ?? this.name,
        pdfPath: pdfPath ?? this.pdfPath,
        pageIndex: pageIndex ?? this.pageIndex,
        sizePx: sizePx ?? this.sizePx,
      );

  @override
  bool operator ==(Object other) =>
      other is Sheet &&
      other.id == id &&
      other.name == name &&
      other.pdfPath == pdfPath &&
      other.pageIndex == pageIndex &&
      other.sizePx == sizePx;

  @override
  int get hashCode => Object.hash(id, name, pdfPath, pageIndex, sizePx);
}
