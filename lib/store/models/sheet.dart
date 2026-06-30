import 'package:flutter/widgets.dart';

/// A single drawing sheet (a PDF page, or a placeholder page until a PDF is
/// imported in P1). [sizePx] is the content's natural pixel size — used to
/// fit/centre the canvas. Calibration (px → real length) lands in P1.
@immutable
class Sheet {
  final String id;
  final String name;

  /// Path to the source PDF on disk, or null for a placeholder page (P0) or a
  /// DXF-backed sheet (see [dxfPath]).
  final String? pdfPath;

  /// Path to the source DXF (CAD vector floor plan) on disk, or null. A sheet is
  /// backed by EITHER a PDF page ([pdfPath]) OR a DXF drawing ([dxfPath]) — never
  /// both; an absent value on both is the P0 placeholder page.
  final String? dxfPath;
  final int pageIndex;

  /// Natural content size in pixels.
  final Size sizePx;

  const Sheet({
    required this.id,
    required this.name,
    this.pdfPath,
    this.dxfPath,
    this.pageIndex = 0,
    this.sizePx = const Size(1684, 1190), // ~A3 landscape placeholder
  });

  bool get isPlaceholder => pdfPath == null && dxfPath == null;

  Sheet copyWith({
    String? name,
    String? pdfPath,
    String? dxfPath,
    int? pageIndex,
    Size? sizePx,
  }) =>
      Sheet(
        id: id,
        name: name ?? this.name,
        pdfPath: pdfPath ?? this.pdfPath,
        dxfPath: dxfPath ?? this.dxfPath,
        pageIndex: pageIndex ?? this.pageIndex,
        sizePx: sizePx ?? this.sizePx,
      );

  @override
  bool operator ==(Object other) =>
      other is Sheet &&
      other.id == id &&
      other.name == name &&
      other.pdfPath == pdfPath &&
      other.dxfPath == dxfPath &&
      other.pageIndex == pageIndex &&
      other.sizePx == sizePx;

  @override
  int get hashCode =>
      Object.hash(id, name, pdfPath, dxfPath, pageIndex, sizePx);
}
