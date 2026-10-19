/// Pure-Dart DXF reader for using a CAD floor plan as a calibratable canvas
/// background — the vector sibling of the PDF importer. It parses the `ENTITIES`
/// section (expanding `INSERT` block references from the `BLOCKS` section) into
/// display primitives in the file's own coordinate space, with the overall
/// bounding box.
///
/// Scope: the geometry an architectural floor plan is actually made of — `LINE`,
/// `LWPOLYLINE`, the old `POLYLINE`/`VERTEX` pair, `CIRCLE`, `ARC`, and `INSERT`
/// (translate · rotate · scale of a block, including the `70/71/44/45`
/// column/row ARRAY form a DWG MINSERT is written as). Entities carry their
/// Object Coordinate System: an extrusion of (0,0,-1) — what AutoCAD writes for
/// MIRRORed ARC/CIRCLE/LWPOLYLINE/INSERT — is honoured as an X flip; any other
/// (truly 3D) extrusion falls back to reading the coordinates as world XY.
/// Paper-space entities (group `67 = 1`: the layout's title block / viewport
/// frame) are skipped — only model space is the plan. A block that (directly or
/// indirectly) inserts itself is not re-expanded, and INSERT expansion is
/// budgeted, so a malformed file cannot hang the parse. Text, dimensions, hatches, splines
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

  /// Round 24 — true when every coordinate is finite and the box has a
  /// positive extent on at least one axis (an importable plan).
  bool get isUsable =>
      minX.isFinite &&
      minY.isFinite &&
      maxX.isFinite &&
      maxY.isFinite &&
      (width > 0 || height > 0);

  /// Round 24 — true when [other] differs from this box by more than a
  /// relative [tolerance] of the larger extent (a plan revised in place whose
  /// geometry grew / shrank / moved).
  bool differsFrom(DxfBounds other, {double tolerance = 1e-6}) {
    final ext = math.max(math.max(width, height),
        math.max(other.width, other.height));
    final tol = (ext > 0 ? ext : 1.0) * tolerance;
    return (minX - other.minX).abs() > tol ||
        (minY - other.minY).abs() > tol ||
        (maxX - other.maxX).abs() > tol ||
        (maxY - other.maxY).abs() > tol;
  }
}

/// The parsed drawing: display primitives + the bounding box. The primitives
/// stay in the file's coordinate space (Y up); a renderer normalises them into a
/// Y-down content box of size [bounds.width] × [bounds.height].
class DxfDrawing {
  final List<DxfPolyline> polylines;
  final List<DxfCircle> circles;
  final List<DxfArc> arcs;
  final DxfBounds bounds;

  /// Round 24 — true when the primitive or INSERT budget stopped emission
  /// before the whole file was read: some geometry is NOT drawn (the bounds
  /// still cover it — a bounds-only pass continues past the cap). The import
  /// surfaces it; never a silent partial plan.
  final bool truncated;

  const DxfDrawing({
    required this.polylines,
    required this.circles,
    required this.arcs,
    required this.bounds,
    this.truncated = false,
  });

  bool get isEmpty => polylines.isEmpty && circles.isEmpty && arcs.isEmpty;
}

/// A code/value record — DXF files are a flat stream of (group code, value)
/// pairs, one of each per pair of lines.
class _Pair {
  final int code;
  final String value;
  const _Pair(this.code, this.value);

  double get d => df ?? 0.0;

  /// Round 24 — the value as a FINITE double, else null: Dart parses `1e999`
  /// as Infinity and `NaN` as NaN, and either would collapse the bounds (a
  /// 1 × 1 px sheet) or paint a line to infinity. A non-finite coordinate is
  /// treated as absent, so its entity is skipped.
  double? get df {
    final v = double.tryParse(value.trim());
    return (v != null && v.isFinite) ? v : null;
  }
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

  /// Determinant of the linear part — negative for a MIRRORING transform
  /// (which reverses an arc's sweep direction).
  double get det => a * d - b * c;

  /// True when the linear part is a pure rotation + uniform scale (no mirror,
  /// no shear) — arc angles then simply shift by [rotationDeg].
  bool get isConformal =>
      (a - d).abs() <= 1e-12 * (a.abs() + d.abs() + 1) &&
      (b + c).abs() <= 1e-12 * (b.abs() + c.abs() + 1);

  /// X flip `(x, y) → (−x, y)`: the OCS → WCS map for extrusion (0,0,−1).
  static const _Xform flipX = _Xform(-1, 0, 0, 1, 0, 0);
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

  /// INSERT instances expanded so far (each array cell counts). Budgeted
  /// separately from [count]: a geometry-free fan-out (A inserts B ×1000, B
  /// inserts C ×1000) emits nothing, so the primitive cap alone never trips.
  int inserts = 0;

  static const int _maxPrimitives = 400000;
  static const int maxInserts = 100000;

  bool get full => count >= _maxPrimitives;
  bool get insertsSpent => inserts >= maxInserts;

  /// Round 24 — set when a budget dropped geometry (see
  /// [DxfDrawing.truncated]).
  bool truncated = false;

  static bool _finitePt(DxfPoint p) => p.x.isFinite && p.y.isFinite;

  void _grow(double x, double y) {
    if (!x.isFinite || !y.isFinite) return;
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

  // Round 24 — past the primitive cap an entity is no longer STORED, but its
  // extent still grows the bounds (a cheap bounds-only pass), and the drawing
  // is flagged truncated. A primitive with a non-finite point is dropped.
  void addPolyline(DxfPolyline p) {
    if (p.points.isEmpty || !p.points.every(_finitePt)) return;
    if (full) {
      truncated = true;
    } else {
      polylines.add(p);
      count++;
    }
    for (final pt in p.points) {
      _grow(pt.x, pt.y);
    }
  }

  void addCircle(DxfCircle c) {
    if (!_finitePt(c.center) || !c.radius.isFinite) return;
    if (full) {
      truncated = true;
    } else {
      circles.add(c);
      count++;
    }
    _grow(c.center.x - c.radius, c.center.y - c.radius);
    _grow(c.center.x + c.radius, c.center.y + c.radius);
  }

  void addArc(DxfArc a) {
    if (!_finitePt(a.center) ||
        !a.radius.isFinite ||
        !a.startDeg.isFinite ||
        !a.endDeg.isFinite) {
      return;
    }
    if (full) {
      truncated = true;
    } else {
      arcs.add(a);
      count++;
    }
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
    _parseEntities(
        pairs, ent.start, ent.end, _Xform.identity, blocks, 0, acc, const {});
  } else {
    // Some exporters omit the section wrapper — parse the whole stream as a
    // best-effort fallback (block defs are still skipped via the depth/zero
    // base handling below).
    _parseEntities(
        pairs, 0, pairs.length, _Xform.identity, blocks, 0, acc, const {});
  }

  if (acc.polylines.isEmpty && acc.circles.isEmpty && acc.arcs.isEmpty) {
    return null;
  }
  return DxfDrawing(
    polylines: acc.polylines,
    circles: acc.circles,
    arcs: acc.arcs,
    bounds: DxfBounds(acc.minX, acc.minY, acc.maxX, acc.maxY),
    truncated: acc.truncated,
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
/// [ancestors] is the active block-expansion stack (cycle guard).
void _parseEntities(
  List<_Pair> pairs,
  int start,
  int end,
  _Xform xform,
  Map<String, _Block> blocks,
  int depth,
  _Acc acc,
  Set<String> ancestors,
) {
  var i = start;
  while (i < end) {
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

    // Paper space (67 = 1) lives in ENTITIES beside model space in R2000+ —
    // the layout's frame / title block, not the plan. Only checked at the top
    // level: block contents inherit the space of the INSERT that places them.
    final paper = depth == 0 && _first(body, 67) == 1;

    switch (type) {
      case 'LINE':
        if (!paper) _emitLine(body, xform, acc);
        break;
      case 'LWPOLYLINE':
        if (!paper) _emitLwPolyline(body, xform.compose(_ocs(body)), acc);
        break;
      case 'POLYLINE':
        // Old-style polyline: vertices follow as VERTEX entities until SEQEND.
        // Its extrusion sits on the POLYLINE header and applies to the run.
        // Round 24 — a POLYFACE (70 bit 64) or polygon MESH (bit 16) is a 3D
        // surface whose face records sit at (0,0,0): skipped like every other
        // 3D entity (its vertices are still consumed).
        final closed = _flagBit(body, 70, 1);
        final mesh = _flagBit(body, 70, 64) || _flagBit(body, 70, 16);
        final vEnd = _emitOldPolyline(
            pairs, j, end, xform.compose(_ocs(body)), closed, acc,
            emit: !paper && !mesh);
        j = vEnd; // resume after SEQEND
        break;
      case 'CIRCLE':
        if (!paper) _emitCircle(body, xform.compose(_ocs(body)), acc);
        break;
      case 'ARC':
        if (!paper) _emitArc(body, xform.compose(_ocs(body)), acc);
        break;
      case 'INSERT':
        if (!paper) {
          _emitInsert(body, xform.compose(_ocs(body)), blocks, depth, acc,
              ancestors);
        }
        break;
      default:
        break; // TEXT, DIMENSION, HATCH, SPLINE, 3D… skipped
    }
    i = j;
  }
}

double? _first(List<_Pair> body, int code) {
  for (final p in body) {
    // Round 24 — a non-finite value reads as ABSENT (the entity is skipped).
    if (p.code == code) return p.df;
  }
  return null;
}

String? _firstStr(List<_Pair> body, int code) {
  for (final p in body) {
    if (p.code == code) return p.value.trim();
  }
  return null;
}

/// The entity's OCS → WCS map in the plane: an extrusion of (0,0,−1) (group
/// 230 < 0 with 210/220 absent or ~0) is an X flip; the default (0,0,1) or any
/// other (truly 3D) normal is treated as identity — the previous behaviour.
_Xform _ocs(List<_Pair> body) {
  final nz = _first(body, 230);
  if (nz == null || nz >= 0) return _Xform.identity;
  final nx = _first(body, 210) ?? 0.0;
  final ny = _first(body, 220) ?? 0.0;
  if (nx.abs() > 1e-9 || ny.abs() > 1e-9) return _Xform.identity;
  return _Xform.flipX;
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
      px = p.df; // Round 24 — a non-finite vertex is skipped
    } else if (p.code == 20 && px != null) {
      final py = p.df;
      if (py != null) pts.add(x.apply(px, py));
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
  _Acc acc, {
  bool emit = true,
}) {
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
      var flags = 0;
      var badCoord = false;
      while (j < end && pairs[j].code != 0) {
        final c = pairs[j].code;
        if (c == 10 || c == 20) {
          final v = pairs[j].df;
          if (v == null) badCoord = true;
          if (c == 10) vx = v;
          if (c == 20) vy = v;
        }
        if (c == 70) flags = pairs[j].d.toInt();
        j++;
      }
      // Round 24 — a polyface FACE record (70 bit 128 without bit 64) carries
      // vertex indices, not a point (its 10/20 are 0,0): never a plan point.
      final faceRecord = (flags & 128) != 0 && (flags & 64) == 0;
      if (!faceRecord && !badCoord && vx != null && vy != null) {
        pts.add(x.apply(vx, vy));
      }
      i = j;
    } else {
      break; // unexpected — stop the vertex run
    }
  }
  if (emit && pts.isNotEmpty) {
    acc.addPolyline(DxfPolyline(pts, closed: closed));
  }
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
  if (x.isConformal) {
    // Rotation + uniform scale: the angles just shift (exact, the old path).
    final rot = x.rotationDeg;
    acc.addArc(DxfArc(x.apply(cx, cy), r * x.scale, a0 + rot, a1 + rot));
    return;
  }
  // Mirror / non-uniform scale: map the arc's ENDPOINTS and read the angles
  // back, so a mirrored door swing lands in the mirrored quadrant. A mirroring
  // transform (det < 0) reverses the sweep, so swap start/end to keep the
  // stored arc CCW (DxfArc's convention).
  final c = x.apply(cx, cy);
  double angleOf(double deg) {
    final rad = deg * math.pi / 180.0;
    final p = x.apply(cx + r * math.cos(rad), cy + r * math.sin(rad));
    return math.atan2(p.y - c.y, p.x - c.x) * 180.0 / math.pi;
  }

  var s = angleOf(a0);
  var e = angleOf(a1);
  if (x.det < 0) {
    final t = s;
    s = e;
    e = t;
  }
  s = ((s % 360) + 360) % 360;
  var sweep = (((e - s) % 360) + 360) % 360;
  // A full-circle arc (start ≡ end, distinct values) stays a full sweep.
  if (sweep < 1e-9 && (a1 - a0).abs() > 1e-9) sweep = 360;
  acc.addArc(DxfArc(c, r * x.scale, s, s + sweep));
}

/// Largest column × row ARRAY expanded from one INSERT (the rest is dropped —
/// the instances also count against the [_Acc.maxInserts] budget).
const int _maxArrayInstances = 10000;

void _emitInsert(
  List<_Pair> body,
  _Xform x,
  Map<String, _Block> blocks,
  int depth,
  _Acc acc,
  Set<String> ancestors,
) {
  final name = _firstStr(body, 2);
  if (name == null) return;
  // A block already on the active expansion stack would recurse into itself
  // (AutoCAD refuses to save one; only a corrupt / hand-made file has it).
  if (ancestors.contains(name)) return;
  final block = blocks[name];
  if (block == null) return;
  // Round 24 (r2) — a real INSERT refused by the depth or insert budget drops
  // geometry: flag it (and only then — a file with exactly [_Acc.maxInserts]
  // INSERTs, none refused, is complete).
  if (depth >= _maxInsertDepth || acc.insertsSpent) {
    acc.truncated = true;
    return;
  }

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

  // Array form (DWG MINSERT): 70/71 column/row counts, 44/45 spacing. The
  // spacing runs along the INSERT's ROTATED axes in drawing units (not scaled
  // by 41/42 — AutoCAD's MINSERT semantics). A plain INSERT is 1 × 1.
  final cols = math.max(1, (_first(body, 70) ?? 1).toInt());
  final rows = math.max(1, (_first(body, 71) ?? 1).toInt());
  final colDx = _first(body, 44) ?? 0.0;
  final rowDy = _first(body, 45) ?? 0.0;
  final nested = {...ancestors, name};

  var instances = 0;
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      if (instances >= _maxArrayInstances || acc.insertsSpent) {
        acc.truncated = true;
        return;
      }
      instances++;
      acc.inserts++;
      final ox = c * colDx, oy = r * rowDy;
      final insert = _Xform(ax, bx, cx, dy, ex + cos * ox - sin * oy,
          fy + sin * ox + cos * oy);
      final child = x.compose(insert);
      _parseEntities(block.pairs, 0, block.pairs.length, child, blocks,
          depth + 1, acc, nested);
    }
  }
}
