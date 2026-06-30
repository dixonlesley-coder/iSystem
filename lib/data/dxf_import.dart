import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart';

import '../store/models/sheet.dart';

/// The longest side a DXF is normalised to, in content pixels. DXF coordinates
/// are in arbitrary CAD units (often millimetres → tens of thousands), so the
/// drawing is scaled UNIFORMLY into a sane content box (comparable to a PDF
/// page's ~1684 pt) — the canvas rasterises the page at this size, so an
/// un-normalised box would be both invisible and ruinously large. Calibration
/// (content-px → real length) is unaffected: the engineer still clicks two
/// points of a known dimension, whatever the normalisation factor.
const double kDxfTargetExtent = 1684.0;

/// Reads the DXF (CAD vector floor plan) at [filePath] and returns a single
/// [Sheet] backed by it — the vector sibling of [importPdf]. A DXF has no
/// "pages": the whole drawing is one sheet, scaled to fit [kDxfTargetExtent].
/// Real-world length still comes from the per-sheet scale calibration, not the
/// DXF units (identical to the PDF flow).
///
/// Throws if the file cannot be read or carries no drawable geometry.
Future<List<Sheet>> importDxf(String filePath) async {
  final file = File(filePath);
  final basename = file.uri.pathSegments.last;
  final lower = basename.toLowerCase();
  final stem = lower.endsWith('.dxf')
      ? basename.substring(0, basename.length - 4)
      : basename;

  final contents = await file.readAsString();
  final drawing = parseDxf(contents);
  if (drawing == null || drawing.isEmpty) {
    throw StateError('DXF "$basename" has no importable geometry.');
  }

  return [
    Sheet(
      id: '$stem#0',
      name: stem,
      dxfPath: filePath,
      pageIndex: 0,
      sizePx: dxfContentSize(drawing.bounds),
    ),
  ];
}

/// The normalised content size for a DXF whose geometry spans [bounds] —
/// the bounding box scaled uniformly so its longest side is [kDxfTargetExtent].
/// Shared by the importer (sizing the [Sheet]) and the renderer (mapping world
/// → content), so both agree on the scale. Degenerate (zero-extent) boxes clamp
/// to a positive size.
Size dxfContentSize(DxfBounds bounds) {
  final longest = bounds.width > bounds.height ? bounds.width : bounds.height;
  final k = longest > 0 ? kDxfTargetExtent / longest : 1.0;
  final w = bounds.width * k;
  final h = bounds.height * k;
  return Size(w > 1 ? w : 1, h > 1 ? h : 1);
}
