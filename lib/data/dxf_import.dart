import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart';

import '../store/models/sheet.dart';
import 'dxf_text.dart';

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
///
/// Round 24 — [onWarning] receives a human message when the plan imported but
/// is INCOMPLETE (the parser's primitive / INSERT budget dropped geometry —
/// [DxfDrawing.truncated]), so the caller can say so instead of presenting a
/// silently partial plan.
Future<List<Sheet>> importDxf(String filePath,
    {void Function(String message)? onWarning}) async {
  final file = File(filePath);
  final basename = file.uri.pathSegments.last;
  final lower = basename.toLowerCase();
  final stem = lower.endsWith('.dxf')
      ? basename.substring(0, basename.length - 4)
      : basename;

  final contents = await readDxfText(filePath);
  final drawing = parseDxf(contents);
  if (drawing == null || drawing.isEmpty) {
    throw StateError('DXF "$basename" has no importable geometry.');
  }
  // Round 24 — a zero-area / non-finite extent would import as a 1 x 1 px
  // sheet that can never be seen or calibrated: refuse it honestly.
  if (!drawing.bounds.isUsable) {
    throw StateError('DXF "$basename" has no usable extent '
        '(zero-size or non-finite coordinates).');
  }
  if (drawing.truncated) onWarning?.call(dxfTruncatedMessage(basename));

  return [
    Sheet(
      id: '$stem#0',
      name: stem,
      dxfPath: filePath,
      pageIndex: 0,
      sizePx: dxfContentSize(drawing.bounds),
      // Round 24 — remember the world frame the content was normalised from.
      dxfFrame: drawing.bounds,
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

/// Round 24 — the world bounds a DXF [sheet] maps world → content through:
/// its import-time [Sheet.dxfFrame] when known (a plan revised in place keeps
/// its registration), else the [live] drawing bounds (legacy sheets).
DxfBounds dxfMappingBounds(Sheet sheet, DxfBounds live) =>
    sheet.dxfFrame ?? live;

/// Round 24 — the warning for a plan the DXF parser could only partly draw.
String dxfTruncatedMessage(String fileName) =>
    'Plan "$fileName" is very large: only part of its geometry is drawn '
    '(furniture / block-heavy file). Purge or explode blocks in CAD, or '
    'export the plan layers only, then re-import.';
