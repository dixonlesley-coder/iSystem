import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart';

import '../../data/dxf_import.dart' show dxfContentSize;
import '../../store/models/sheet.dart';

/// Renders a DXF-backed [Sheet] as static vector linework filling its content
/// box — the vector sibling of [PdfSheetPage]. The drawing is normalised into
/// [Sheet.sizePx] (CAD units scaled uniformly, Y flipped to screen-down) so it
/// occupies exactly the same content slot a PDF page would, and the parent
/// [CanvasView] owns all pan/zoom.
///
/// **Resolution:** the parent rasterises this at the content-box size, then the
/// canvas zoom magnifies that raster — so, like [PdfSheetPage], we **supersample**
/// ([_superSample]× the content size, scaled back with a [FittedBox]) to keep
/// the linework crisp when zoomed in to place nodes.
///
/// Parsing is cached per path; a read/parse failure renders an inline message
/// rather than throwing.
class DxfSheetPage extends StatefulWidget {
  final Sheet sheet;

  /// Supersample factor — matches [PdfSheetPage]. 3× keeps deep-zoom linework
  /// sharp while keeping the rasterised layer bounded.
  static const double _superSample = 3.0;

  const DxfSheetPage({super.key, required this.sheet});

  @override
  State<DxfSheetPage> createState() => _DxfSheetPageState();

  /// Parse cache keyed by file path. A floor-plan DXF parses once and is reused
  /// across rebuilds / sheet revisits. A `null` value = parsed-but-empty/failed.
  static final Map<String, DxfDrawing?> _cache = {};

  static DxfDrawing? _load(String path) {
    if (_cache.containsKey(path)) return _cache[path];
    DxfDrawing? drawing;
    try {
      drawing = parseDxf(File(path).readAsStringSync());
    } catch (_) {
      drawing = null;
    }
    return _cache[path] = drawing;
  }

  /// Test seam: prime the cache so a widget test can render without disk I/O.
  static void cacheForTest(String path, DxfDrawing? drawing) =>
      _cache[path] = drawing;
}

class _DxfSheetPageState extends State<DxfSheetPage> {
  @override
  Widget build(BuildContext context) {
    final path = widget.sheet.dxfPath;
    if (path == null) {
      return const _ErrorPage('No DXF path on sheet.');
    }
    final drawing = DxfSheetPage._load(path);
    if (drawing == null || drawing.isEmpty) {
      return const _ErrorPage('Could not load DXF, or it has no geometry.');
    }

    final size = widget.sheet.sizePx;
    const ss = DxfSheetPage._superSample;
    // Paint at _superSample× the content size, then FittedBox scales the
    // high-res picture back down to the content slot — net size unchanged, only
    // the linework density rises, so a zoomed-in plan stays sharp.
    return FittedBox(
      fit: BoxFit.fill,
      child: SizedBox(
        width: size.width * ss,
        height: size.height * ss,
        child: CustomPaint(
          painter: _DxfPainter(drawing: drawing, scale: ss),
        ),
      ),
    );
  }
}

/// Paints the parsed [drawing] into a [size.width·scale] × [size.height·scale]
/// box: a white "paper" fill + dark hairline linework, mapping CAD world coords
/// (Y up) → content coords (Y down) uniformly.
class _DxfPainter extends CustomPainter {
  final DxfDrawing drawing;

  /// Extra supersample factor folded into the world→content map (the SizedBox is
  /// laid out this many times larger than the content slot).
  final double scale;

  _DxfPainter({required this.drawing, required this.scale});

  static const Color _paper = Color(0xFFFFFFFF);
  static const Color _ink = Color(0xFF3A3F46);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _paper);

    final b = drawing.bounds;
    // Uniform world→content scale (the same one the importer used to size the
    // sheet), times the supersample factor.
    final extentW = b.width, extentH = b.height;
    final contentSize = dxfContentSize(b);
    final kx = extentW > 1e-9 ? contentSize.width / extentW : 0.0;
    final ky = extentH > 1e-9 ? contentSize.height / extentH : 0.0;
    final k = (kx != 0.0 ? kx : ky) * scale;

    // world (x,y) → content: x'=(x-minX)·k, y'=(maxY-y)·k (flip Y to screen-down)
    Offset map(DxfPoint p) =>
        Offset((p.x - b.minX) * k, (b.maxY - p.y) * k);

    final ink = Paint()
      ..color = _ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = scale // ≈1 content px at display size
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    for (final pl in drawing.polylines) {
      if (pl.points.isEmpty) continue;
      final path = Path()..moveTo(map(pl.points.first).dx, map(pl.points.first).dy);
      for (var i = 1; i < pl.points.length; i++) {
        final o = map(pl.points[i]);
        path.lineTo(o.dx, o.dy);
      }
      if (pl.closed) path.close();
      canvas.drawPath(path, ink);
    }

    for (final c in drawing.circles) {
      canvas.drawCircle(map(c.center), c.radius * k, ink);
    }

    for (final a in drawing.arcs) {
      final centre = map(a.center);
      final r = a.radius * k;
      // DXF arcs sweep CCW (Y-up); after the Y flip, screen angle = -worldAngle.
      var sweepDeg = a.endDeg - a.startDeg;
      while (sweepDeg <= 0) {
        sweepDeg += 360;
      }
      final startRad = -a.startDeg * math.pi / 180.0;
      final sweepRad = -sweepDeg * math.pi / 180.0;
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: r),
        startRad,
        sweepRad,
        false,
        ink,
      );
    }
  }

  @override
  bool shouldRepaint(_DxfPainter old) =>
      old.drawing != drawing || old.scale != scale;
}

class _ErrorPage extends StatelessWidget {
  final String message;
  const _ErrorPage(this.message);

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFFFF3F3),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            message,
            style: const TextStyle(
              fontFamily: 'Roboto',
              fontSize: 14,
              color: Color(0xFFB00020),
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
