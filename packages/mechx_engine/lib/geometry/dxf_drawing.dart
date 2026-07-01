/// Pure-Dart DXF reader for using a CAD floor plan as a calibratable canvas
/// background — the vector sibling of the PDF importer. It parses the `ENTITIES`
/// section (expanding `INSERT` block references from the `BLOCKS` section) into
/// display primitives in the file's own coordinate space, with the overall
/// bounding box.
///
/// Scope: the geometry an architectural floor plan is actually made of — `LINE`,
/// `LWPOLYLINE`, the old `POLYLINE`/`VERTEX` pair, `CIRCLE`, `ARC`, and `INSERT`
/// (translate · rotate · scale of a block). Text, dimensions, hatches, splines
/// and 3D entities are skipped (a background plan doesn't need them, and the
/// engineer calibrates + redraws MEP on top). It is a DISPLAY substrate, never a
/// source of calculation — like the PDF page it stands in for, real-world length
/// comes from the per-sheet scale calibration, not the DXF units.
///
/// Zero Flutter imports; runnable under `dart test`.
library;

import 'dart:math' as math;

/// A 2D point in the DXF file's own coordinate space (Y up, as in CAD).
class DxfPoint {
  final double x;
  final double y;
  const DxfPoint(this.x, this.y);
}

/// A connected run of straight segments. [closed] joins the last point back to
/// the first (a closed `LWPOLYLINE`/`POLYLINE`). Arc bulges are read as straight
/// chords (a background-fidelity simplification).
class DxfPolyline {
  final List<DxfPoint> points;
  final bool closed;
  const DxfPolyline(this.points, {this.closed = false});
}

/// A full circle.
class DxfCircle {
  final DxfPoint center;
  final double radius;
  const DxfCircle(this.center, this.radius);
}

/// A circular arc, [startDeg]→[endDeg] counter-clockwise (DXF convention).
class DxfArc {
  final DxfPoint center;
  final double radius;
  final double startDeg;
  final double endDeg;
  const DxfArc(this.center, this.radius, this.startDeg, this.endDeg);
}

/// Axis-aligned bounding box over every emitted primitive.
class DxfBounds {
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;
  const DxfBounds(this.minX, this.minY, this.maxX, this.maxY);

  double get width => maxX - minX;
  double get height => maxY - minY;
}

/// The parsed drawing: display primitives + the bounding box. The primitives
/// stay in the file's coordinate space (Y up); a renderer normalises them into a
/// Y-down content box of size [bounds.width] × [bounds.height].
class DxfDrawing {
  final List<DxfPolyline> polylines;
  final List<DxfCircle> circles;
  final List<DxfArc> arcs;
  final DxfBounds bounds;

  const DxfDrawing({
    required this.polylines,
    required this.circles,
    required this.arcs,
    required this.bounds,
  });

  bool get isEmpty => polylines.isEmpty && circles.isEmpty && arcs.isEmpty;
}

/// A code/value record — DXF files are a flat stream of (group code, value)
/// pairs, one of each per pair of lines.
class _Pair {
  final int code;
  final String value;
  const _Pair(this.code, this.value);

  double get d => double.tryParse(value.trim()) ?? 0.0;
}

/// 2×3 affine transform `[[a c e],[b d f]]`: `x' = a·x + c·y + e`,
/// `y' = b·x + d·y + f`. Used to bake `INSERT` translate/rotate/scale (and
/// nested inserts) into the emitted primitives.
class _Xform {
  final double a, b, c, d, e, f;
  const _Xform(this.a, this.b, this.c, this.d, this.e, this.f);
  static const _Xform identity = _Xform(1, 0, 0, 1, 0, 0);

  DxfPoint apply(double x, double y) =>
      DxfPoint(a * x + c * y + e, b * x + d * y + f);

  /// `this` applied AFTER [o] (this ∘ o).
  _Xform compose(_Xform o) => _Xform(
        a * o.a + c * o.b,
        b * o.a + d * o.b,
        a * o.c + c * o.d,
        b * o.c + d * o.d,
        a * o.e + c * o.f + e,
        b * o.e + d * o.f + f,
      );

  /// Representative scale (mean axis length) for radii.
  double get scale {
    final sx = math.sqrt(a * a + b * b);
    final sy = math.sqrt(c * c + d * d);
    return (sx + sy) / 2.0;
  }

  /// Rotation contributed by the linear part, in degrees, for arc angles.
  double get rotationDeg => math.atan2(b, a) * 180.0 / math.pi;
}

/// A block definition: its base point + the raw entity-pair slice (parsed lazily
/// at each `INSERT` so the placing transform can be applied).
class _Block {
  final double baseX;
  final double baseY;
  final List<_Pair> pairs;
  const _Block(this.baseX, this.baseY, this.pairs);
}

/// Accumulates emitted primitives + the running bounding box. Capped so a
/// pathological / deeply-nested file can't exhaust memory.
class _Acc {
  final List<DxfPolyline> polylines = [];
  final List<DxfCircle> circles = [];
  final List<DxfArc> arcs = [];
  bool _has = false;
  double minX = 0, minY = 0, maxX = 0, maxY = 0;
  int count = 0;

  static const int _maxPrimitives = 400000;

  bool get full => count >= _maxPrimitives;

  void _grow(double x, double y) {
    if (!_has) {
      minX = maxX = x;
      minY = maxY = y;
      _has = true;
    } else {
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }

  void addPolyline(DxfPolyline p) {
    if (full || p.points.isEmpty) return;
    polylines.add(p);
    count++;
    for (final pt in p.points) {
      _grow(pt.x, pt.y);
    }
  }

  void addCircle(DxfCircle c) {
    if (full) return;
    circles.add(c);
    count++;
    _grow(c.center.x - c.radius, c.center.y - c.radius);
    _grow(c.center.x + c.radius, c.center.y + c.radius);
  }

  void addArc(DxfArc a) {
    if (full) return;
    arcs.add(a);
    count++;
    // Conservative box: the full circle (cheap, never under-estimates).
    _grow(a.center.x - a.radius, a.center.y - a.radius);
    _grow(a.center.x + a.radius, a.center.y + a.radius);
  }
}

/// Parse a DXF document's text [contents] into a [DxfDrawing]. Returns `null`
/// when the file contains no drawable geometry (caller surfaces a friendly
/// error). Never throws on malformed input — unrecognised entities are skipped.
DxfDrawing? parseDxf(String contents) {
  final pairs = _tokenize(contents);
  if (pairs.isEmpty) return null;

  final blocks = _collectBlocks(pairs);
  final acc = _Acc();

  // Walk the top-level ENTITIES section (identity transform).
  final ent = _sectionRange(pairs, 'ENTITIES');
  if (ent != null) {
    _parseEntities(pairs, ent.start, ent.end, _Xform.identity, blocks, 0, acc);
  } else {
    // Some exporters omit the section wrapper — parse the whole stream as a
    // best-effort fallback (block defs are still skipped via the depth/zero
    // base handling below).
    _parseEntities(pairs, 0, pairs.length, _Xform.identity, blocks, 0, acc);
  }

  if (acc.polylines.isEmpty && acc.circles.isEmpty && acc.arcs.isEmpty) {
    return null;
  }
  return DxfDrawing(
    polylines: acc.polylines,
    circles: acc.circles,
    arcs: acc.arcs,
    bounds: DxfBounds(acc.minX, acc.minY, acc.maxX, acc.maxY),
  );
}

/// Split the raw text into (code, value) pairs. Strict DXF is exactly one code
/// line then one value line; we resync past stray blank/garbage lines so a
/// slightly malformed file still reads.
List<_Pair> _tokenize(String contents) {
  final lines = contents.split('\n');
  final pairs = <_Pair>[];
  var i = 0;
  while (i + 1 < lines.length) {
    final code = int.tryParse(lines[i].trim());
    if (code == null) {
      i++; // not a code line — skip and resync
      continue;
    }
    pairs.add(_Pair(code, lines[i + 1].replaceAll('\r', '')));
    i += 2;
  }
  return pairs;
}

class _Range {
  final int start;
  final int end; // exclusive
  const _Range(this.start, this.end);
}

/// Find the [start, end) pair-index range INSIDE a named section (between the
/// `2/<name>` header and the matching `0/ENDSEC`).
_Range? _sectionRange(List<_Pair> pairs, String name) {
  for (var i = 0; i < pairs.length; i++) {
    if (pairs[i].code == 0 && pairs[i].value.trim() == 'SECTION') {
      // The section name is the next 2/ pair.
      if (i + 1 < pairs.length &&
          pairs[i + 1].code == 2 &&
          pairs[i + 1].value.trim() == name) {
        final start = i + 2;
        for (var j = start; j < pairs.length; j++) {
          if (pairs[j].code == 0 && pairs[j].value.trim() == 'ENDSEC') {
            return _Range(start, j);
          }
        }
        return _Range(start, pairs.length);
      }
    }
  }
  return null;
}

/// Collect every `BLOCK` definition in the BLOCKS section: name → base point +
/// its entity-pair slice (between the `BLOCK` header and `ENDBLK`).
Map<String, _Block> _collectBlocks(List<_Pair> pairs) {
  final blocks = <String, _Block>{};
  final range = _sectionRange(pairs, 'BLOCKS');
  if (range == null) return blocks;

  var i = range.start;
  while (i < range.end) {
    if (pairs[i].code == 0 && pairs[i].value.trim() == 'BLOCK') {
      var name = '';
      double bx = 0, by = 0;
      var j = i + 1;
      // Header pairs run until the first nested entity (code 0).
      while (j < range.end && pairs[j].code != 0) {
        switch (pairs[j].code) {
          case 2:
            name = pairs[j].value.trim();
            break;
          case 10:
            bx = pairs[j].d;
            break;
          case 20:
            by = pairs[j].d;
            break;
        }
        j++;
      }
      // Body runs until ENDBLK.
      final bodyStart = j;
      while (j < range.end &&
          !(pairs[j].code == 0 && pairs[j].value.trim() == 'ENDBLK')) {
        j++;
      }
      if (name.isNotEmpty) {
        blocks[name] = _Block(bx, by, pairs.sublist(bodyStart, j));
      }
      i = j + 1;
    } else {
      i++;
    }
  }
  return blocks;
}

const int _maxInsertDepth = 8;

/// Walk an entity-pair slice [start, end), emitting transformed primitives into
/// [acc]. Each entity is the code-0 marker plus the pairs up to the next code 0.
void _parseEntities(
  List<_Pair> pairs,
  int start,
  int end,
  _Xform xform,
  Map<String, _Block> blocks,
  int depth,
  _Acc acc,
) {
  var i = start;
  while (i < end && !acc.full) {
    if (pairs[i].code != 0) {
      i++;
      continue;
    }
    final type = pairs[i].value.trim();
    // Slice this entity's pairs: code-0 marker through the next code 0.
    var j = i + 1;
    while (j < end && pairs[j].code != 0) {
      j++;
    }
    final body = pairs.sublist(i + 1, j);

    switch (type) {
      case 'LINE':
        _emitLine(body, xform, acc);
        break;
      case 'LWPOLYLINE':
        _emitLwPolyline(body, xform, acc);
        break;
      case 'POLYLINE':
        // Old-style polyline: vertices follow as VERTEX entities until SEQEND.
        final closed = _flagBit(body, 70, 1);
        final vEnd = _emitOldPolyline(pairs, j, end, xform, closed, acc);
        j = vEnd; // resume after SEQEND
        break;
      case 'CIRCLE':
        _emitCircle(body, xform, acc);
        break;
      case 'ARC':
        _emitArc(body, xform, acc);
        break;
      case 'INSERT':
        _emitInsert(body, xform, blocks, depth, acc);
        break;
      default:
        break; // TEXT, DIMENSION, HATCH, SPLINE, 3D… skipped
    }
    i = j;
  }
}

double? _first(List<_Pair> body, int code) {
  for (final p in body) {
    if (p.code == code) return p.d;
  }
  return null;
}

String? _firstStr(List<_Pair> body, int code) {
  for (final p in body) {
    if (p.code == code) return p.value.trim();
  }
  return null;
}

bool _flagBit(List<_Pair> body, int code, int bit) {
  final v = _first(body, code);
  if (v == null) return false;
  return (v.toInt() & bit) != 0;
}

void _emitLine(List<_Pair> body, _Xform x, _Acc acc) {
  final x1 = _first(body, 10), y1 = _first(body, 20);
  final x2 = _first(body, 11), y2 = _first(body, 21);
  if (x1 == null || y1 == null || x2 == null || y2 == null) return;
  acc.addPolyline(DxfPolyline([x.apply(x1, y1), x.apply(x2, y2)]));
}

void _emitLwPolyline(List<_Pair> body, _Xform x, _Acc acc) {
  final pts = <DxfPoint>[];
  double? px;
  for (final p in body) {
    if (p.code == 10) {
      px = p.d;
    } else if (p.code == 20 && px != null) {
      pts.add(x.apply(px, p.d));
      px = null;
    }
  }
  if (pts.isEmpty) return;
  acc.addPolyline(DxfPolyline(pts, closed: _flagBit(body, 70, 1)));
}

/// Emit an old-style POLYLINE's VERTEX run starting at pair index [start];
/// returns the index just past SEQEND.
int _emitOldPolyline(
  List<_Pair> pairs,
  int start,
  int end,
  _Xform x,
  bool closed,
  _Acc acc,
) {
  final pts = <DxfPoint>[];
  var i = start;
  while (i < end) {
    if (pairs[i].code != 0) {
      i++;
      continue;
    }
    final type = pairs[i].value.trim();
    if (type == 'SEQEND') {
      i++;
      break;
    }
    if (type == 'VERTEX') {
      var j = i + 1;
      double? vx, vy;
      while (j < end && pairs[j].code != 0) {
        if (pairs[j].code == 10) vx = pairs[j].d;
        if (pairs[j].code == 20) vy = pairs[j].d;
        j++;
      }
      if (vx != null && vy != null) pts.add(x.apply(vx, vy));
      i = j;
    } else {
      break; // unexpected — stop the vertex run
    }
  }
  if (pts.isNotEmpty) acc.addPolyline(DxfPolyline(pts, closed: closed));
  return i;
}

void _emitCircle(List<_Pair> body, _Xform x, _Acc acc) {
  final cx = _first(body, 10), cy = _first(body, 20), r = _first(body, 40);
  if (cx == null || cy == null || r == null) return;
  acc.addCircle(DxfCircle(x.apply(cx, cy), r * x.scale));
}

void _emitArc(List<_Pair> body, _Xform x, _Acc acc) {
  final cx = _first(body, 10), cy = _first(body, 20), r = _first(body, 40);
  final a0 = _first(body, 50), a1 = _first(body, 51);
  if (cx == null || cy == null || r == null || a0 == null || a1 == null) return;
  final rot = x.rotationDeg;
  acc.addArc(DxfArc(x.apply(cx, cy), r * x.scale, a0 + rot, a1 + rot));
}

void _emitInsert(
  List<_Pair> body,
  _Xform x,
  Map<String, _Block> blocks,
  int depth,
  _Acc acc,
) {
  if (depth >= _maxInsertDepth) return;
  final name = _firstStr(body, 2);
  if (name == null) return;
  final block = blocks[name];
  if (block == null) return;

  final ix = _first(body, 10) ?? 0;
  final iy = _first(body, 20) ?? 0;
  final sx = _first(body, 41) ?? 1.0;
  final sy = _first(body, 42) ?? 1.0;
  final rot = (_first(body, 50) ?? 0.0) * math.pi / 180.0;
  final cos = math.cos(rot), sin = math.sin(rot);

  // insert ∘ rotate ∘ scale ∘ translate(-base), all pre-multiplied.
  // p' = insert + R·S·(p - base)
  final ax = cos * sx;
  final bx = sin * sx;
  final cx = -sin * sy;
  final dy = cos * sy;
  // translate(-base) folded into e/f.
  final ex = ix - (ax * block.baseX + cx * block.baseY);
  final fy = iy - (bx * block.baseX + dy * block.baseY);
  final insert = _Xform(ax, bx, cx, dy, ex, fy);
  final child = x.compose(insert);

  _parseEntities(block.pairs, 0, block.pairs.length, child, blocks, depth + 1,
      acc);
}
