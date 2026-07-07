/// Pure-Dart snap index over a DXF plan **underlay** (B12).
///
/// The imported CAD floor plan is display-only today; this turns its parsed
/// vector geometry ([DxfDrawing]) into a queryable snap surface so a riser or a
/// run can latch onto a shaft wall / corridor line instead of being eyeballed.
///
/// The index lives in **sheet-px space** — the same content-box coordinates the
/// [DxfSheetPage] painter draws in (CAD world → content, Y flipped down) — so a
/// screen-radius query (14 px ÷ zoom) works directly. Geometry is grid-bucketed
/// for O(neighbourhood) queries; a query returns the single best
/// [UnderlaySnapCandidate], with **endpoint beating intersection beating
/// nearest-on-segment** at equal distance.
///
/// This file is PURE and INTEGRATION-FREE: no Flutter imports, no providers, no
/// gesture wiring. It only depends on the pure-Dart engine ([DxfDrawing]) and
/// `dart:math`. Another layer builds the index from the cached per-sheet drawing
/// and threads its candidates into the existing snap precedence.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/dxf_drawing.dart';

/// The kind of geometric feature a snap latched onto, in precedence order:
/// an [endpoint] (segment end / shared corner) beats an [intersection] (two
/// segments crossing) beats a point [onSegment] (nearest along a wall), when
/// two candidates sit at the same distance.
enum UnderlaySnapKind { endpoint, intersection, onSegment }

/// One snap result in sheet-px space: the snapped [x]/[y], what [kind] of
/// feature it is, and its Euclidean [distance] from the query point.
class UnderlaySnapCandidate {
  final double x;
  final double y;
  final UnderlaySnapKind kind;
  final double distance;
  const UnderlaySnapCandidate({
    required this.x,
    required this.y,
    required this.kind,
    required this.distance,
  });

  @override
  String toString() =>
      'UnderlaySnapCandidate(($x, $y), $kind, d=$distance)';
}

/// A straight segment in sheet-px space (already transformed off the DXF world).
class UnderlaySegment {
  final double x1, y1, x2, y2;
  const UnderlaySegment(this.x1, this.y1, this.x2, this.y2);
}

/// Maps a DXF **world** point (Y up, file units) to **sheet-px** (Y down,
/// content box) exactly the way [DxfSheetPage]'s painter does:
/// `sx = (wx − minX)·scale`, `sy = (maxY − wy)·scale`. Build one with
/// [UnderlayTransform.forSheet] from the drawing bounds + the sheet's content
/// size so the snap surface lands precisely on the painted linework.
class UnderlayTransform {
  final double minX;
  final double maxY;
  final double scale;
  const UnderlayTransform._(
      {required this.minX, required this.maxY, required this.scale});

  /// Derive the world→content uniform scale the importer/renderer use
  /// (`content / extent`, width-led, height fallback, 1.0 for a degenerate box).
  factory UnderlayTransform.forSheet(
    DxfBounds bounds,
    double contentWidthPx,
    double contentHeightPx,
  ) {
    final w = bounds.width, h = bounds.height;
    double scale;
    if (w > _eps) {
      scale = contentWidthPx / w;
    } else if (h > _eps) {
      scale = contentHeightPx / h;
    } else {
      scale = 1.0;
    }
    return UnderlayTransform._(
        minX: bounds.minX, maxY: bounds.maxY, scale: scale);
  }

  double sx(double wx) => (wx - minX) * scale;
  double sy(double wy) => (maxY - wy) * scale;
}

const double _eps = 1e-9;

/// Distance tolerance under which two candidates are "equal" and the kind
/// precedence (endpoint > intersection > onSegment) decides the winner.
const double _tieEps = 1e-6;

/// Default grid bucket edge in sheet-px. A neighbourhood query touches only the
/// cells overlapping its radius, so this trades memory (smaller ⇒ finer) against
/// per-query fan-out (larger ⇒ more segments scanned).
const double _kDefaultBucket = 32.0;

/// Default max chord length (sheet-px) when flattening a circle/arc to segments.
const double _kDefaultChord = 4.0;

/// Hard cap on samples per curve so a huge circle can't explode the index.
const int _kMaxCurveSamples = 720;

/// A grid-bucketed spatial index of straight segments in sheet-px space,
/// answering nearest-feature snap queries.
class UnderlaySnapIndex {
  // Parallel segment arrays (sheet-px).
  final List<double> _x1;
  final List<double> _y1;
  final List<double> _x2;
  final List<double> _y2;

  // Grid: cell (cx,cy) → segment indices, packed into a dense integer key
  // relative to the index's cell origin.
  final Map<int, List<int>> _buckets;
  final double _bucketSize;
  final int _minCellX;
  final int _minCellY;
  final int _gridW;
  final int _gridH;

  UnderlaySnapIndex._(
    this._x1,
    this._y1,
    this._x2,
    this._y2,
    this._buckets,
    this._bucketSize,
    this._minCellX,
    this._minCellY,
    this._gridW,
    this._gridH,
  );

  /// Number of indexed segments.
  int get segmentCount => _x1.length;

  /// True when nothing was indexed (empty/degenerate drawing) — [query] is null.
  bool get isEmpty => _x1.isEmpty;

  /// Build directly from sheet-px [segments] (zero-length ones are dropped).
  factory UnderlaySnapIndex.fromSegments(
    List<UnderlaySegment> segments, {
    double bucketSize = _kDefaultBucket,
  }) {
    final x1 = <double>[];
    final y1 = <double>[];
    final x2 = <double>[];
    final y2 = <double>[];
    for (final s in segments) {
      final dx = s.x2 - s.x1, dy = s.y2 - s.y1;
      if (dx * dx + dy * dy <= _eps * _eps) continue; // drop degenerate
      x1.add(s.x1);
      y1.add(s.y1);
      x2.add(s.x2);
      y2.add(s.y2);
    }
    return _build(x1, y1, x2, y2, bucketSize <= 0 ? _kDefaultBucket : bucketSize);
  }

  /// Build from a parsed [drawing], mapping every primitive to sheet-px through
  /// [transform]; circles and arcs are flattened to chords no longer than
  /// [chordTolerancePx] (a background-fidelity approximation, like the renderer).
  factory UnderlaySnapIndex.fromDrawing(
    DxfDrawing drawing, {
    required UnderlayTransform transform,
    double bucketSize = _kDefaultBucket,
    double chordTolerancePx = _kDefaultChord,
  }) {
    final segs = <UnderlaySegment>[];
    final chord = chordTolerancePx <= 0 ? _kDefaultChord : chordTolerancePx;

    for (final pl in drawing.polylines) {
      final pts = pl.points;
      if (pts.length < 2) continue;
      for (var i = 0; i + 1 < pts.length; i++) {
        segs.add(_mapSeg(pts[i], pts[i + 1], transform));
      }
      if (pl.closed && pts.length > 2) {
        segs.add(_mapSeg(pts.last, pts.first, transform));
      }
    }
    for (final c in drawing.circles) {
      _sampleCircle(segs, c.center, c.radius, transform, chord);
    }
    for (final a in drawing.arcs) {
      _sampleArc(segs, a, transform, chord);
    }
    return UnderlaySnapIndex.fromSegments(segs, bucketSize: bucketSize);
  }

  static UnderlaySegment _mapSeg(
          DxfPoint a, DxfPoint b, UnderlayTransform t) =>
      UnderlaySegment(t.sx(a.x), t.sy(a.y), t.sx(b.x), t.sy(b.y));

  static void _sampleCircle(List<UnderlaySegment> out, DxfPoint c, double r,
      UnderlayTransform t, double chord) {
    if (r <= _eps) return;
    final rPx = r * t.scale;
    final n = _sampleCount(2 * math.pi * rPx, chord, 8);
    double px = t.sx(c.x + r), py = t.sy(c.y);
    final x0 = px, y0 = py;
    for (var i = 1; i <= n; i++) {
      final ang = 2 * math.pi * i / n;
      final wx = c.x + r * math.cos(ang);
      final wy = c.y + r * math.sin(ang);
      final nx = (i == n) ? x0 : t.sx(wx);
      final ny = (i == n) ? y0 : t.sy(wy);
      out.add(UnderlaySegment(px, py, nx, ny));
      px = nx;
      py = ny;
    }
  }

  static void _sampleArc(List<UnderlaySegment> out, DxfArc a,
      UnderlayTransform t, double chord) {
    if (a.radius <= _eps) return;
    var sweep = a.endDeg - a.startDeg;
    while (sweep <= 0) {
      sweep += 360;
    }
    final rPx = a.radius * t.scale;
    final arcLen = rPx * sweep * math.pi / 180.0;
    final n = _sampleCount(arcLen, chord, 2);
    final rad0 = a.startDeg * math.pi / 180.0;
    final sweepRad = sweep * math.pi / 180.0;
    double px = t.sx(a.center.x + a.radius * math.cos(rad0));
    double py = t.sy(a.center.y + a.radius * math.sin(rad0));
    for (var i = 1; i <= n; i++) {
      final ang = rad0 + sweepRad * i / n;
      final nx = t.sx(a.center.x + a.radius * math.cos(ang));
      final ny = t.sy(a.center.y + a.radius * math.sin(ang));
      out.add(UnderlaySegment(px, py, nx, ny));
      px = nx;
      py = ny;
    }
  }

  static int _sampleCount(double lengthPx, double chord, int floor) {
    final n = (lengthPx / chord).ceil();
    if (n < floor) return floor;
    if (n > _kMaxCurveSamples) return _kMaxCurveSamples;
    return n;
  }

  static UnderlaySnapIndex _build(
    List<double> x1,
    List<double> y1,
    List<double> x2,
    List<double> y2,
    double bs,
  ) {
    if (x1.isEmpty) {
      return UnderlaySnapIndex._(x1, y1, x2, y2, const {}, bs, 0, 0, 0, 0);
    }
    // Overall extent → cell origin, padded by one cell for fp safety.
    var minX = x1[0], minY = y1[0], maxX = x1[0], maxY = y1[0];
    for (var i = 0; i < x1.length; i++) {
      minX = math.min(minX, math.min(x1[i], x2[i]));
      maxX = math.max(maxX, math.max(x1[i], x2[i]));
      minY = math.min(minY, math.min(y1[i], y2[i]));
      maxY = math.max(maxY, math.max(y1[i], y2[i]));
    }
    final minCellX = _floorDiv(minX, bs) - 1;
    final minCellY = _floorDiv(minY, bs) - 1;
    final maxCellX = _floorDiv(maxX, bs) + 1;
    final maxCellY = _floorDiv(maxY, bs) + 1;
    final gridW = maxCellX - minCellX + 1;
    final gridH = maxCellY - minCellY + 1;

    final buckets = <int, List<int>>{};
    void addToCell(int cx, int cy, int idx) {
      final rx = (cx - minCellX).clamp(0, gridW - 1);
      final ry = (cy - minCellY).clamp(0, gridH - 1);
      (buckets[ry * gridW + rx] ??= <int>[]).add(idx);
    }

    for (var i = 0; i < x1.length; i++) {
      _walkCells(x1[i], y1[i], x2[i], y2[i], bs, (cx, cy) => addToCell(cx, cy, i));
    }

    return UnderlaySnapIndex._(
        x1, y1, x2, y2, buckets, bs, minCellX, minCellY, gridW, gridH);
  }

  /// The best snap within [radius] px of (`px`,`py`), or null if nothing is in
  /// range (or the index is empty). [radius] is the standard 14-screen-px pick
  /// tolerance divided by the current zoom.
  UnderlaySnapCandidate? query(double px, double py, double radius) {
    if (isEmpty || radius <= 0) return null;

    // Gather segments in every cell overlapping the query's bounding box.
    final cx0 = _floorDiv(px - radius, _bucketSize);
    final cx1 = _floorDiv(px + radius, _bucketSize);
    final cy0 = _floorDiv(py - radius, _bucketSize);
    final cy1 = _floorDiv(py + radius, _bucketSize);

    final nearby = <int>{};
    for (var cy = cy0; cy <= cy1; cy++) {
      final ry = cy - _minCellY;
      if (ry < 0 || ry >= _gridH) continue;
      for (var cx = cx0; cx <= cx1; cx++) {
        final rx = cx - _minCellX;
        if (rx < 0 || rx >= _gridW) continue;
        final list = _buckets[ry * _gridW + rx];
        if (list != null) nearby.addAll(list);
      }
    }
    if (nearby.isEmpty) return null;

    final r2 = radius * radius;
    UnderlaySnapCandidate? best;
    void consider(double x, double y, UnderlaySnapKind kind, double dist) {
      if (dist > radius + _tieEps) return;
      if (best == null || _better(dist, kind, best!)) {
        best = UnderlaySnapCandidate(x: x, y: y, kind: kind, distance: dist);
      }
    }

    final idx = nearby.toList(growable: false);
    for (final i in idx) {
      final ax = _x1[i], ay = _y1[i], bx = _x2[i], by = _y2[i];
      // Endpoints.
      final da = _dist(px, py, ax, ay);
      if (da * da <= r2 + _tieEps) {
        consider(ax, ay, UnderlaySnapKind.endpoint, da);
      }
      final db = _dist(px, py, bx, by);
      if (db * db <= r2 + _tieEps) {
        consider(bx, by, UnderlaySnapKind.endpoint, db);
      }
      // Nearest point along the segment.
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      var t = len2 <= _eps ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / len2;
      if (t < 0) t = 0;
      if (t > 1) t = 1;
      final nx = ax + t * dx, ny = ay + t * dy;
      final dn = _dist(px, py, nx, ny);
      if (dn * dn <= r2 + _tieEps) {
        consider(nx, ny, UnderlaySnapKind.onSegment, dn);
      }
    }

    // Pairwise intersections among the neighbourhood set.
    for (var a = 0; a < idx.length; a++) {
      final i = idx[a];
      for (var b = a + 1; b < idx.length; b++) {
        final j = idx[b];
        final p = _intersect(
            _x1[i], _y1[i], _x2[i], _y2[i], _x1[j], _y1[j], _x2[j], _y2[j]);
        if (p == null) continue;
        final d = _dist(px, py, p[0], p[1]);
        if (d * d <= r2 + _tieEps) {
          consider(p[0], p[1], UnderlaySnapKind.intersection, d);
        }
      }
    }

    return best;
  }

  static bool _better(
      double dist, UnderlaySnapKind kind, UnderlaySnapCandidate cur) {
    if (dist < cur.distance - _tieEps) return true;
    if (dist > cur.distance + _tieEps) return false;
    return _priority(kind) < _priority(cur.kind);
  }

  static int _priority(UnderlaySnapKind k) {
    switch (k) {
      case UnderlaySnapKind.endpoint:
        return 0;
      case UnderlaySnapKind.intersection:
        return 1;
      case UnderlaySnapKind.onSegment:
        return 2;
    }
  }

  static double _dist(double x1, double y1, double x2, double y2) {
    final dx = x2 - x1, dy = y2 - y1;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Interior intersection of segment (a→b) and (c→d), or null if parallel /
  /// not crossing within both segments. Returns `[x, y]`.
  static List<double>? _intersect(double ax, double ay, double bx, double by,
      double cx, double cy, double dx, double dy) {
    final rX = bx - ax, rY = by - ay;
    final sX = dx - cx, sY = dy - cy;
    final rxs = rX * sY - rY * sX;
    if (rxs.abs() < _eps) return null; // parallel or degenerate
    final qpx = cx - ax, qpy = cy - ay;
    final t = (qpx * sY - qpy * sX) / rxs;
    final u = (qpx * rY - qpy * rX) / rxs;
    if (t < 0 || t > 1 || u < 0 || u > 1) return null;
    return [ax + t * rX, ay + t * rY];
  }

  static int _floorDiv(double v, double bs) => (v / bs).floor();

  /// Visit every grid cell the segment (x1,y1)→(x2,y2) passes through
  /// (Amanatides–Woo DDA), so an indexed segment is reachable from any cell it
  /// crosses — bounding query fan-out to the cells actually traversed.
  static void _walkCells(double x1, double y1, double x2, double y2, double bs,
      void Function(int cx, int cy) visit) {
    var cx = _floorDiv(x1, bs), cy = _floorDiv(y1, bs);
    final cxEnd = _floorDiv(x2, bs), cyEnd = _floorDiv(y2, bs);
    visit(cx, cy);
    if (cx == cxEnd && cy == cyEnd) return;

    final dx = x2 - x1, dy = y2 - y1;
    final stepX = dx > 0 ? 1 : (dx < 0 ? -1 : 0);
    final stepY = dy > 0 ? 1 : (dy < 0 ? -1 : 0);

    double tMaxX, tDeltaX, tMaxY, tDeltaY;
    if (stepX != 0) {
      final boundary = (stepX > 0 ? (cx + 1) * bs : cx * bs);
      tMaxX = (boundary - x1) / dx;
      tDeltaX = (bs / dx).abs();
    } else {
      tMaxX = double.infinity;
      tDeltaX = double.infinity;
    }
    if (stepY != 0) {
      final boundary = (stepY > 0 ? (cy + 1) * bs : cy * bs);
      tMaxY = (boundary - y1) / dy;
      tDeltaY = (bs / dy).abs();
    } else {
      tMaxY = double.infinity;
      tDeltaY = double.infinity;
    }

    final maxSteps = (cxEnd - cx).abs() + (cyEnd - cy).abs() + 4;
    var steps = 0;
    while (!(cx == cxEnd && cy == cyEnd) && steps++ < maxSteps) {
      if (tMaxX < tMaxY) {
        cx += stepX;
        tMaxX += tDeltaX;
      } else {
        cy += stepY;
        tMaxY += tDeltaY;
      }
      visit(cx, cy);
    }
  }
}
