/// Drawing review R1 (2026-11-13) — enlarged DETAIL sheets for dense plan
/// areas: the pure geometry rules both plan exporters share (golden rule 5).
///
/// When a plan sheet, after the normal legal-slot placement and the key-tag
/// fallback, would still stamp "N label bertumpuk", the issued set does what a
/// drafting office does: the dense area is boxed on the plan with a dashed
/// DETAIL boundary + bubble ("DETAIL A - LIHAT M-5nn"), its labels are left to
/// the detail, and a DETAIL sheet draws it again at an enlarged standard scale
/// (1:10 / 1:20 / 1:25 / 1:50) with every label placed by the same rule.
///
/// This library holds the rules only — cluster detection
/// ([planDetailClusterRects]), the scale pick + sheet packing
/// ([planDetailPack]), the detail letters and the
/// format-neutral mark list ([PlanMarks]); the sheets themselves are built in
/// `plan_detail_sheet.dart`. Pure (Flutter-free) and deterministic.
library;

import 'dart:math' as math;

import 'drawing_chrome.dart' show LabelBox, kPlanScaleLadder;

/// The enlarged standard scales a detail may plot at, LARGEST drawing first
/// (the pick takes the first that fits).
const List<int> kDetailScaleLadder = [10, 20, 25, 50];

/// One detail callout on a plan: its [letter] (`A`, `B`…), the boxed area in
/// SHEET PIXELS (y-down) and the drawing number of the detail sheet that
/// draws it ([sheetRef], e.g. `M-504`).
class PlanDetailCallout {
  final String letter;
  final LabelBox rectPx;
  final String sheetRef;

  /// Drawing review S1 — the cuts this detail shares with the detail(s) it
  /// was split from (a cluster too dense for one sheet): each is drawn on
  /// the detail as a dashed MATCH LINE naming the neighbour.
  final List<PlanDetailMatch> matches;
  const PlanDetailCallout(
      {required this.letter,
      required this.rectPx,
      required this.sheetRef,
      this.matches = const []});

  bool containsPx(double x, double y) =>
      x >= rectPx.minX &&
      x <= rectPx.maxX &&
      y >= rectPx.minY &&
      y <= rectPx.maxY;

  /// The bubble caption printed beside the boundary (ASCII; PDF == DXF).
  String get caption => 'DETAIL $letter - LIHAT $sheetRef';
}

/// Drawing review S1 — a shared cut between two pieces of a split detail:
/// the segment ([x1], [y1])-([x2], [y2]) in SHEET PIXELS and the neighbour
/// it continues on ([letter] on drawing [sheetRef]).
class PlanDetailMatch {
  final double x1, y1, x2, y2;
  final String letter;
  final String sheetRef;
  const PlanDetailMatch(this.x1, this.y1, this.x2, this.y2,
      {required this.letter, required this.sheetRef});

  /// The match-line caption printed under the detail (ASCII; PDF == DXF).
  String get caption => 'MATCH LINE - LIHAT DETAIL $letter ($sheetRef)';
}

/// Drawing review S1 — split a detail box that is still too dense for its own
/// sheet in two along its LONGER side. The cut falls in the gap between the
/// two middle [anchors] (sorted along that side) inside [r], so no anchor
/// sits on it (each element stays labelled on exactly one piece); with fewer
/// than two distinct anchor coordinates it falls at the middle. Pure.
(LabelBox, LabelBox) planDetailSplitRect(
    LabelBox r, List<({double x, double y})> anchors) {
  final horiz = (r.maxX - r.minX) >= (r.maxY - r.minY);
  final lo = horiz ? r.minX : r.minY, hi = horiz ? r.maxX : r.maxY;
  final vs = <double>{
    for (final a in anchors)
      if (a.x >= r.minX && a.x <= r.maxX && a.y >= r.minY && a.y <= r.maxY)
        horiz ? a.x : a.y
  }.toList()
    ..sort();
  var cut = (lo + hi) / 2;
  if (vs.length >= 2) {
    // The gap between distinct coordinates nearest the middle.
    var best = double.infinity;
    for (var i = 0; i + 1 < vs.length; i++) {
      final c = (vs[i] + vs[i + 1]) / 2;
      final d = (c - (lo + hi) / 2).abs();
      if (d < best) {
        best = d;
        cut = c;
      }
    }
  }
  return horiz
      ? (
          (minX: r.minX, minY: r.minY, maxX: cut, maxY: r.maxY),
          (minX: cut, minY: r.minY, maxX: r.maxX, maxY: r.maxY),
        )
      : (
          (minX: r.minX, minY: r.minY, maxX: r.maxX, maxY: cut),
          (minX: r.minX, minY: cut, maxX: r.maxX, maxY: r.maxY),
        );
}

/// Drawing review S1 — the shared cuts of a set of detail boxes: for each box
/// the segments (sheet px) where it TOUCHES another along a positive length,
/// with that neighbour's index. Boxes that overlap or only meet at a corner
/// share no cut. Pure.
List<List<({double x1, double y1, double x2, double y2, int other})>>
    planDetailSharedCuts(List<LabelBox> rects) {
  const eps = 1e-6;
  final out = [
    for (final _ in rects)
      <({double x1, double y1, double x2, double y2, int other})>[]
  ];
  for (var i = 0; i < rects.length; i++) {
    for (var j = 0; j < rects.length; j++) {
      if (i == j) continue;
      final a = rects[i], b = rects[j];
      // Vertical shared edge (a's right / left on b's left / right).
      for (final x in [a.maxX, a.minX]) {
        if ((x == a.maxX && (b.minX - x).abs() < eps) ||
            (x == a.minX && (b.maxX - x).abs() < eps)) {
          final y0 = math.max(a.minY, b.minY), y1 = math.min(a.maxY, b.maxY);
          if (y1 - y0 > eps) out[i].add((x1: x, y1: y0, x2: x, y2: y1, other: j));
        }
      }
      for (final y in [a.maxY, a.minY]) {
        if ((y == a.maxY && (b.minY - y).abs() < eps) ||
            (y == a.minY && (b.maxY - y).abs() < eps)) {
          final x0 = math.max(a.minX, b.minX), x1 = math.min(a.maxX, b.maxX);
          if (x1 - x0 > eps) out[i].add((x1: x0, y1: y, x2: x1, y2: y, other: j));
        }
      }
    }
  }
  return out;
}

/// A format-neutral mark list. As an INPUT to the annotation layout the
/// positions are sheet pixels and the sizes ([PlanMarkCircle.r],
/// [PlanMarkText.size]) paper millimetres; as an OUTPUT (`PlanAnnotations.
/// marks`) everything is in the exporter's output units.
class PlanMarks {
  final List<PlanMarkLine> lines;
  final List<PlanMarkCircle> circles;
  final List<PlanMarkText> texts;
  const PlanMarks(
      {this.lines = const [], this.circles = const [], this.texts = const []});
  static const empty = PlanMarks();
  bool get isEmpty => lines.isEmpty && circles.isEmpty && texts.isEmpty;
}

class PlanMarkLine {
  final double x1, y1, x2, y2;
  final bool dashed;
  final bool heavy;
  const PlanMarkLine(this.x1, this.y1, this.x2, this.y2,
      {this.dashed = false, this.heavy = false});
}

class PlanMarkCircle {
  final double cx, cy, r;
  final bool filled;
  const PlanMarkCircle(this.cx, this.cy, this.r, {this.filled = false});
}

/// A text with its baseline START at ([x], [y]).
class PlanMarkText {
  final double x, y, size;
  final String text;
  const PlanMarkText(this.x, this.y, this.size, this.text);
}

/// The detail letter of the [i]-th (0-based) callout of a sheet: A..Z, AA…
String planDetailLetter(int i) {
  const a = 65;
  if (i < 26) return String.fromCharCode(a + i);
  return planDetailLetter(i ~/ 26 - 1) + String.fromCharCode(a + i % 26);
}

/// Room kept around a detail's boxed area inside its frame, paper mm (the
/// labels of the outermost elements sit there).
const double kPlanDetailFramePadMm = 18;

bool _overlap(LabelBox p, LabelBox q) =>
    p.minX < q.maxX - 1e-9 &&
    q.minX < p.maxX - 1e-9 &&
    p.minY < q.maxY - 1e-9 &&
    q.minY < p.maxY - 1e-9;

/// The dense clusters of a plan sheet as boxed areas in sheet pixels.
///
/// [seeds] are the anchors of the annotations that could only be placed
/// overprinting something; [elements] every annotated element anchor on the
/// floor. Seeds closer than 2 × [linkPx] form one cluster (single linkage);
/// each cluster's box spans its seeds plus every element within [linkPx] of
/// one of them (ONE hop, so a long chain of evenly spaced heads is never
/// swallowed whole), grown by [marginPx]. [existing] boxes (an earlier pass)
/// join, and boxes that overlap merge until stable (boxes that only touch —
/// the tiles of [planDetailTiles] — stay apart). Returned sorted top-to-bottom, left-to-right. Pure.
List<LabelBox> planDetailClusterRects({
  required List<({double x, double y})> seeds,
  required List<({double x, double y})> elements,
  required double linkPx,
  required double marginPx,
  List<LabelBox> existing = const [],
}) {
  final n = seeds.length;
  final parent = List<int>.generate(n, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  final l2 = 2 * linkPx;
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      final dx = seeds[i].x - seeds[j].x, dy = seeds[i].y - seeds[j].y;
      if (dx * dx + dy * dy <= l2 * l2) parent[find(i)] = find(j);
    }
  }
  final groups = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    (groups[find(i)] ??= <int>[]).add(i);
  }
  final rects = <LabelBox>[...existing];
  for (final g in groups.values) {
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity;
    void inc(double x, double y) {
      x0 = math.min(x0, x);
      y0 = math.min(y0, y);
      x1 = math.max(x1, x);
      y1 = math.max(y1, y);
    }

    for (final i in g) {
      inc(seeds[i].x, seeds[i].y);
    }
    for (final e in elements) {
      for (final i in g) {
        final dx = e.x - seeds[i].x, dy = e.y - seeds[i].y;
        if (dx * dx + dy * dy <= linkPx * linkPx) {
          inc(e.x, e.y);
          break;
        }
      }
    }
    rects.add((
      minX: x0 - marginPx,
      minY: y0 - marginPx,
      maxX: x1 + marginPx,
      maxY: y1 + marginPx
    ));
  }
  // Merge overlapping / near boxes to a fixed point.
  var merged = true;
  while (merged) {
    merged = false;
    outer:
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        if (_overlap(rects[i], rects[j])) {
          final p = rects[i], q = rects[j];
          rects[i] = (
            minX: math.min(p.minX, q.minX),
            minY: math.min(p.minY, q.minY),
            maxX: math.max(p.maxX, q.maxX),
            maxY: math.max(p.maxY, q.maxY),
          );
          rects.removeAt(j);
          merged = true;
          break outer;
        }
      }
    }
  }
  rects.sort((p, q) {
    final d = p.minY.compareTo(q.minY);
    return d != 0 ? d : p.minX.compareTo(q.minX);
  });
  return rects;
}

/// The detail sheet's packing: every detail of [sizesM] (real metres) plotted
/// at ONE scale — the largest drawing (first rung of [kDetailScaleLadder],
/// then the coarser plan rungs) at which all their frames (the extent + [pad]
/// all round) pack into [area] (paper mm, y-down) in rows, each frame with
/// [captionMm] below it for the caption + scale bar and [gapMm] between.
/// Rows run top-down, frames left-to-right, each row centred. Pure.
({int n, List<LabelBox> frames}) planDetailPack({
  required List<({double w, double h})> sizesM,
  required LabelBox area,
  double pad = kPlanDetailFramePadMm,
  double gapMm = 8,
  double captionMm = 16,
}) {
  final rungs = [
    ...kDetailScaleLadder,
    for (final n in kPlanScaleLadder)
      if (n > kDetailScaleLadder.last) n,
  ];
  final aw = area.maxX - area.minX, ah = area.maxY - area.minY;
  List<LabelBox>? pack(int n) {
    final frames = <LabelBox>[];
    final rows = <List<int>>[[]];
    var x = 0.0, y = 0.0, rowH = 0.0;
    final sz = [
      for (final s in sizesM) (w: s.w * 1000 / n + 2 * pad, h: s.h * 1000 / n + 2 * pad)
    ];
    final pos = <(double, double)>[];
    for (var i = 0; i < sz.length; i++) {
      final s = sz[i];
      if (s.w > aw || s.h + captionMm > ah) return null;
      if (x > 0 && x + s.w > aw) {
        y += rowH + captionMm + gapMm;
        x = 0;
        rowH = 0;
        rows.add([]);
      }
      pos.add((x, y));
      rows.last.add(i);
      x += s.w + gapMm;
      rowH = math.max(rowH, s.h);
    }
    if (y + rowH + captionMm > ah) return null;
    for (final row in rows) {
      if (row.isEmpty) continue;
      final last = row.last;
      final rowW = pos[last].$1 + sz[last].w;
      final off = (aw - rowW) / 2;
      for (final i in row) {
        final (px, py) = pos[i];
        frames.add((
          minX: area.minX + off + px,
          minY: area.minY + py,
          maxX: area.minX + off + px + sz[i].w,
          maxY: area.minY + py + sz[i].h,
        ));
      }
    }
    return frames;
  }

  for (final n in rungs) {
    final f = pack(n);
    if (f != null) return (n: n, frames: f);
  }
  final n = rungs.last;
  return (n: n, frames: pack(n) ?? [for (final _ in sizesM) area]);
}

/// The divided scale bar of a detail at `1 : [n]`: a round real length whose
/// bar spans 30..80 paper mm, as a [PlanMarks] whose positions are paper mm
/// (y-down) from ([x0], baseline [y0]) and whose text is [textMm] high.
PlanMarks planDetailScaleBar(
    {required int n, required double x0, required double y0,
    required double textMm}) {
  const options = [0.1, 0.2, 0.25, 0.5, 1.0, 2.0, 2.5, 5.0, 10.0];
  var m = options.last;
  for (final o in options) {
    if (o * 1000 / n >= 30) {
      m = o;
      break;
    }
  }
  final len = m * 1000 / n; // paper mm
  const h = 1.5;
  final lines = <PlanMarkLine>[
    PlanMarkLine(x0, y0, x0 + len, y0),
    PlanMarkLine(x0, y0 - h, x0 + len, y0 - h),
    for (var i = 0; i <= 4; i++)
      PlanMarkLine(x0 + len * i / 4, y0, x0 + len * i / 4, y0 - h),
  ];
  String fig(double v) => v >= 1
      ? '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} m'
      : '${(v * 1000).round()} mm';
  final ty = y0 + textMm * 1.4;
  return PlanMarks(lines: lines, texts: [
    PlanMarkText(x0, ty, textMm, '0'),
    PlanMarkText(x0 + len - fig(m).length * textMm * 0.55, ty, textMm, fig(m)),
  ]);
}

/// Drawing review R1 — a plan sheet plotted at a FIXED paper map instead of
/// the auto-fit: one sheet pixel is one paper millimetre measured from the
/// page's top-left corner (y-down), the SCALE row reads [scaleRow]
/// (`AS SHOWN` on a detail sheet, whose details each carry their own scale)
/// and no sheet-wide scale bar is drawn.
class PlanFixedFit {
  final String scaleRow;
  const PlanFixedFit({this.scaleRow = kPlanDetailScaleRow});
}

/// The SCALE row of a detail sheet (each detail states its own scale).
const String kPlanDetailScaleRow = 'AS SHOWN';
