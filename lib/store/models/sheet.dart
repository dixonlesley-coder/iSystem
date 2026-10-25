import 'package:flutter/widgets.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart' show DxfBounds;

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

  /// Path to the ORIGINAL DWG on disk when this sheet came from a DWG import, or
  /// null. DWG is a binary CAD format we cannot read directly, so on import it is
  /// converted to DXF ([dxfPath] points at the converted file, which is what the
  /// canvas renders); [dwgPath] is kept purely as provenance (so a future reload
  /// can re-convert if the DXF cache is gone).
  final String? dwgPath;
  final int pageIndex;

  /// Natural content size in pixels.
  final Size sizePx;

  /// Round 24 — a DXF/DWG sheet's import-time WORLD frame: the drawing
  /// bounds its content was normalised from ([sizePx] = that box scaled so its
  /// longest side is `kDxfTargetExtent`). The renderer, snap surface and
  /// export underlay map world → content through THIS frame, so a plan
  /// revised in place keeps registering with the drawn work and the
  /// calibration (a changed extent marks the calibration stale instead of
  /// silently rescaling it), and 'Apply scale to all sheets' can rescale a
  /// metres-per-pixel figure between DXF sheets of different extent. Null on
  /// a PDF / placeholder sheet and on legacy files (live bounds are used).
  final DxfBounds? dxfFrame;

  /// Round 24 (r2) — the LIVE drawing extent last seen to differ from
  /// [dxfFrame] (a plan revised in place) and already flagged as a stale
  /// calibration. The change detector fires once per REAL change: a live
  /// extent equal to this acknowledged one is not re-flagged on a remount /
  /// reopen after 'Scale confirmed'. Null until a change is first seen.
  final DxfBounds? dxfLiveFrameAck;

  /// Round 33 (import-robustness-2-1) — the DXF HEADER `$INSUNITS` code the
  /// sheet was imported with (0 = unitless; 4 mm, 6 m, 1 in…; null = legacy /
  /// not a DXF). 'Apply scale to all sheets' converts between two DXFs of
  /// different units (and refuses when only one is known).
  final int? dxfInsUnits;

  const Sheet({
    required this.id,
    required this.name,
    this.pdfPath,
    this.dxfPath,
    this.dwgPath,
    this.pageIndex = 0,
    this.sizePx = const Size(1684, 1190), // ~A3 landscape placeholder
    this.dxfFrame,
    this.dxfLiveFrameAck,
    this.dxfInsUnits,
  });

  /// Round 24 — content pixels per DXF world unit for this sheet (null when
  /// the sheet is not a DXF with a known [dxfFrame]).
  double? get dxfContentPerWorld {
    final f = dxfFrame;
    if (dxfPath == null || f == null) return null;
    final longest = f.width > f.height ? f.width : f.height;
    if (!(longest > 0)) return null;
    final contentLongest =
        sizePx.width > sizePx.height ? sizePx.width : sizePx.height;
    return contentLongest / longest;
  }

  bool get isPlaceholder => pdfPath == null && dxfPath == null;

  Sheet copyWith({
    String? id,
    String? name,
    String? pdfPath,
    String? dxfPath,
    String? dwgPath,
    int? pageIndex,
    Size? sizePx,
    DxfBounds? dxfFrame,
    DxfBounds? dxfLiveFrameAck,
    int? dxfInsUnits,
  }) =>
      Sheet(
        id: id ?? this.id,
        name: name ?? this.name,
        pdfPath: pdfPath ?? this.pdfPath,
        dxfPath: dxfPath ?? this.dxfPath,
        dwgPath: dwgPath ?? this.dwgPath,
        pageIndex: pageIndex ?? this.pageIndex,
        sizePx: sizePx ?? this.sizePx,
        dxfFrame: dxfFrame ?? this.dxfFrame,
        dxfLiveFrameAck: dxfLiveFrameAck ?? this.dxfLiveFrameAck,
        dxfInsUnits: dxfInsUnits ?? this.dxfInsUnits,
      );

  @override
  bool operator ==(Object other) =>
      other is Sheet &&
      other.id == id &&
      other.name == name &&
      other.pdfPath == pdfPath &&
      other.dxfPath == dxfPath &&
      other.dwgPath == dwgPath &&
      other.pageIndex == pageIndex &&
      other.sizePx == sizePx &&
      _sameFrame(other.dxfFrame, dxfFrame) &&
      _sameFrame(other.dxfLiveFrameAck, dxfLiveFrameAck) &&
      other.dxfInsUnits == dxfInsUnits;

  static bool _sameFrame(DxfBounds? a, DxfBounds? b) =>
      identical(a, b) ||
      (a != null &&
          b != null &&
          a.minX == b.minX &&
          a.minY == b.minY &&
          a.maxX == b.maxX &&
          a.maxY == b.maxY);

  @override
  int get hashCode => Object.hash(id, name, pdfPath, dxfPath, dwgPath,
      pageIndex, sizePx, dxfFrame?.minX, dxfFrame?.maxX);
}
