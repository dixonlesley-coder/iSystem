import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mechx_engine/geometry/dxf_drawing.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:pdfrx/pdfrx.dart';

import '../store/models/sheet.dart';

/// How far the raster underlay pixels are blended toward white (0 = verbatim,
/// 1 = fully white). ~60 % keeps the plan legible but unmistakably background
/// — the honesty rule: the underlay must read as background, never competing
/// with the network ink.
const double kUnderlayFade = 0.6;

/// The raster underlay's longest rendered side, in pixels — enough detail for
/// an A3 print without an unbounded pdfium allocation.
const double kUnderlayMaxRenderPx = 1600.0;

/// Parse cache keyed by file path — a floor-plan DXF parses once and is reused
/// across exports (mirrors `DxfSheetPage`'s canvas cache; that one is private
/// to the widget). A `null` value = parsed-but-empty/failed.
final Map<String, DxfDrawing?> _dxfCache = {};

DxfDrawing? _loadDxf(String path) {
  if (_dxfCache.containsKey(path)) return _dxfCache[path];
  DxfDrawing? drawing;
  try {
    drawing = parseDxf(File(path).readAsStringSync());
  } catch (_) {
    drawing = null;
  }
  return _dxfCache[path] = drawing;
}

/// Build the floor-plan UNDERLAY for [sheet] — the substrate the engineer drew
/// on, handed to the plan export engines so the printed drawing carries the
/// plan beneath the network (CAD-OUTPUT-UX-REVIEW A1).
///
/// - A DXF-backed sheet yields the VECTOR form: the parsed [DxfDrawing] plus
///   the sheet's content frame ([Sheet.sizePx]), so the engine reproduces the
///   exact canvas fit and the underlay lands in the same frame as the nodes.
/// - A PDF-backed sheet yields the RASTER form: the page rendered offscreen at
///   its own aspect (longest side capped at [kUnderlayMaxRenderPx]) and
///   pre-FADED toward white here — the engine embeds the pixels verbatim.
/// - A placeholder sheet, a missing file, or any parse/render failure returns
///   null: the export proceeds underlay-less, never throws.
Future<PlanUnderlay?> buildPlanUnderlay(Sheet sheet) async {
  try {
    final dxfPath = sheet.dxfPath;
    if (dxfPath != null) {
      final drawing = _loadDxf(dxfPath);
      if (drawing == null || drawing.isEmpty) return null;
      return VectorPlanUnderlay(
        drawing: drawing,
        sheetWidthPx: sheet.sizePx.width,
        sheetHeightPx: sheet.sizePx.height,
      );
    }
    final pdfPath = sheet.pdfPath;
    if (pdfPath == null) return null; // placeholder sheet — no substrate
    // Checked BEFORE pdfrx: a missing source must short-circuit here (pdfium
    // reports its failures from a worker isolate, out of this try's reach).
    if (!File(pdfPath).existsSync()) return null;
    return await _renderPdfUnderlay(pdfPath, sheet);
  } catch (_) {
    return null;
  }
}

Future<PlanUnderlay?> _renderPdfUnderlay(String path, Sheet sheet) async {
  final w = sheet.sizePx.width, h = sheet.sizePx.height;
  if (w <= 0 || h <= 0) return null;
  // Render at the sheet's own aspect, longest side capped — the same page the
  // canvas shows, just offscreen.
  final k = kUnderlayMaxRenderPx / math.max(w, h);
  final doc = await PdfDocument.openFile(path);
  try {
    if (sheet.pageIndex < 0 || sheet.pageIndex >= doc.pages.length) return null;
    final img = await doc.pages[sheet.pageIndex]
        .render(fullWidth: w * k, fullHeight: h * k);
    if (img == null) return null;
    try {
      return RasterPlanUnderlay(
        rgbPixels: fadeBgraToRgb(img.pixels, img.width, img.height),
        pixelWidth: img.width,
        pixelHeight: img.height,
        sheetWidthPx: w,
        sheetHeightPx: h,
      );
    } finally {
      img.dispose();
    }
  } finally {
    await doc.dispose();
  }
}

/// Convert pdfrx's BGRA8888 [bgra] pixels to the raw RGB8 rows the engine
/// embeds, blending every channel toward white by [fade]:
/// `c' = c·(1 − fade) + 255·fade`. Alpha is dropped (the page renders on a
/// white background). Pure and synchronous, so it is unit-testable.
Uint8List fadeBgraToRgb(Uint8List bgra, int width, int height,
    {double fade = kUnderlayFade}) {
  final keep = 1.0 - fade;
  // Per-channel lookup table — 256 entries beat 3 float ops per subpixel on a
  // ~1.8-Mpx render.
  final lut = Uint8List(256);
  for (var c = 0; c < 256; c++) {
    lut[c] = (c * keep + 255 * fade).round().clamp(0, 255);
  }
  final out = Uint8List(width * height * 3);
  var o = 0;
  for (var i = 0; i + 3 < bgra.length && o + 2 < out.length; i += 4) {
    out[o++] = lut[bgra[i + 2]]; // R
    out[o++] = lut[bgra[i + 1]]; // G
    out[o++] = lut[bgra[i]]; // B
  }
  return out;
}
