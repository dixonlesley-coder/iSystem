import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart';

import '../../data/dxf_import.dart' show dxfContentSize, dxfMappingBounds;
import '../../data/file_stamped_cache.dart';
import '../../data/dxf_text.dart';
import '../../store/models/sheet.dart';
import '../strings/app_strings.dart';
import 'sheet_page_states.dart';

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
/// Parsing is cached per path. A drawing not yet in the cache is parsed OFF the
/// UI isolate ([Isolate.run] — the engine's `parseDxf` is pure Dart), showing
/// the sheet-paper [SheetLoadingPage] meanwhile, so opening a large plan never
/// freezes a frame; a cached drawing paints on the first frame as before. A
/// read/parse failure renders the token [SheetLoadErrorPage] (with 'Replace
/// plan…' when the host wires [onReplacePlan]) rather than throwing.
class DxfSheetPage extends StatefulWidget {
  final Sheet sheet;

  /// Supersample factor — matches [PdfSheetPage]. 3× keeps deep-zoom linework
  /// sharp while keeping the rasterised layer bounded.
  static const double _superSample = 3.0;

  /// Round 24 — called (once per detected change, after the frame) when the
  /// file's LIVE extent no longer matches the sheet's import-time
  /// [Sheet.dxfFrame] — the plan was revised in place — AND differs from the
  /// extent already acknowledged on [Sheet.dxfLiveFrameAck]. The host records
  /// the live extent and marks the calibration stale; the drawing keeps
  /// painting through the stored frame.
  final void Function(String sheetId, DxfBounds live)? onFrameChanged;

  /// Re-point the sheet at another file — offered on the load-error page.
  final VoidCallback? onReplacePlan;

  const DxfSheetPage(
      {super.key, required this.sheet, this.onFrameChanged, this.onReplacePlan});

  @override
  State<DxfSheetPage> createState() => _DxfSheetPageState();

  /// Parse cache keyed by file path AND the file's size/mtime stamp (Round
  /// 10): a floor-plan DXF parses once and is reused across rebuilds / sheet
  /// revisits, but a plan revised IN PLACE (same path) re-parses instead of
  /// painting the stale revision. A `null` value = parsed-but-empty/failed.
  static final FileStampedCache<DxfDrawing?> _cache =
      FileStampedCache<DxfDrawing?>(_parseFile);

  /// Read + parse [path] (null on any failure). Pure Dart — safe to run on a
  /// background isolate.
  static DxfDrawing? _parseFile(String path) {
    try {
      return parseDxf(readDxfTextSync(path));
    } catch (_) {
      return null;
    }
  }

  static DxfDrawing? _load(String path) => _cache.get(path);

  /// In-flight background parses, one per path (two sheets of one file — or a
  /// rebuild mid-parse — share a single isolate run).
  static final Map<String, Future<DxfDrawing?>> _inFlight = {};

  /// The drawing for [path], parsed on a background isolate when it is not
  /// already cached fresh; the result lands in the same stamped cache the
  /// synchronous paths ([cachedDrawing], the underlay snap) read.
  static Future<DxfDrawing?> loadAsync(String path) {
    final (hit, value) = _cache.peek(path);
    if (hit) return Future.value(value);
    return _inFlight[path] ??= () async {
      final stamp = fileStamp(path);
      try {
        final drawing = await Isolate.run(() => _parseFile(path));
        _cache.store(path, stamp, drawing);
        return drawing;
      } catch (_) {
        _cache.store(path, stamp, null);
        return null;
      } finally {
        unawaited(_inFlight.remove(path));
      }
    }();
  }

  /// Test seam: prime the cache so a widget test can render without disk I/O.
  static void cacheForTest(String path, DxfDrawing? drawing) =>
      _cache.prime(path, drawing);

  /// The parsed drawing for [path] the painter uses, loading + caching it on
  /// first access (null when the file is missing / empty / unparseable). The
  /// B12 underlay snap index is built from THIS same cached drawing, so the snap
  /// surface always matches the painted linework — no re-parse. Pure disk read;
  /// safe to call off the paint path.
  static DxfDrawing? cachedDrawing(String path) => _load(path);
}

class _DxfSheetPageState extends State<DxfSheetPage> {
  DxfDrawing? _reported;

  /// The path whose drawing [_drawing] holds, and whether it has loaded.
  String? _loadedPath;
  bool _loaded = false;
  DxfDrawing? _drawing;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(DxfSheetPage old) {
    super.didUpdateWidget(old);
    if (old.sheet.dxfPath != widget.sheet.dxfPath) _resolve();
  }

  /// Use the cached drawing at once when it is fresh (no placeholder frame —
  /// a revisited sheet paints immediately); otherwise parse in the background
  /// and show the loading page until it lands.
  void _resolve() {
    final path = widget.sheet.dxfPath;
    _loadedPath = path;
    if (path == null) {
      _loaded = true;
      _drawing = null;
      return;
    }
    final (hit, value) = DxfSheetPage._cache.peek(path);
    if (hit) {
      _loaded = true;
      _drawing = value;
      return;
    }
    _loaded = false;
    _drawing = null;
    DxfSheetPage.loadAsync(path).then((drawing) {
      if (!mounted || _loadedPath != path) return;
      setState(() {
        _loaded = true;
        _drawing = drawing;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.sheet.dxfPath;
    final strings = MechXStrings.of(context);
    if (path == null) {
      return SheetLoadErrorPage(
        message: strings(StringKey.sheetNoSourcePath),
        onReplacePlan: widget.onReplacePlan,
      );
    }
    if (!_loaded) return const SheetLoadingPage();
    final drawing = _drawing;
    if (drawing == null || drawing.isEmpty) {
      return SheetLoadErrorPage(
        message: strings(StringKey.sheetDxfLoadFailed),
        detail: path,
        onReplacePlan: widget.onReplacePlan,
      );
    }
    final frame = dxfMappingBounds(widget.sheet, drawing.bounds);
    final stored = widget.sheet.dxfFrame;
    final ack = widget.sheet.dxfLiveFrameAck;
    final cb = widget.onFrameChanged;
    final live = drawing.bounds;
    if (cb != null &&
        stored != null &&
        !identical(_reported, drawing) &&
        stored.differsFrom(live) &&
        (ack == null || ack.differsFrom(live))) {
      _reported = drawing;
      final id = widget.sheet.id;
      WidgetsBinding.instance.addPostFrameCallback((_) => cb(id, live));
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
          painter: _DxfPainter(drawing: drawing, frame: frame, scale: ss),
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

  /// Round 24 — the world frame the content maps from (the sheet's import
  /// frame, else the live bounds).
  final DxfBounds frame;

  /// Extra supersample factor folded into the world→content map (the SizedBox is
  /// laid out this many times larger than the content slot).
  final double scale;

  _DxfPainter({required this.drawing, required this.frame, required this.scale});

  static const Color _paper = Color(0xFFFFFFFF);
  static const Color _ink = Color(0xFF3A3F46);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _paper);

    final b = frame;
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
      old.drawing != drawing ||
      old.scale != scale ||
      old.frame.minX != frame.minX ||
      old.frame.maxX != frame.maxX ||
      old.frame.minY != frame.minY ||
      old.frame.maxY != frame.maxY;
}
