/// R6 — ONE annotation layout for the plan exporters (golden rule 5).
///
/// The plan PDF (points) and the plan DXF (model millimetres) used to each run
/// their own copy of the label pipeline with their own marks: the PDF printed
/// 9 pt text beside 14 pt glyphs while the DXF printed 2.5 mm text beside
/// world-sized glyphs, so the shared placer saw a different text-to-geometry
/// ratio in each format and made different choices — the same run tag was
/// two lines in the PDF and one in the DXF.
///
/// [layoutPlanAnnotations] is now the single source: every annotation size is
/// a PAPER dimension (millimetres on the plotted sheet, below), each exporter
/// passes its own sheet-pixel → output map plus its output units per paper
/// millimetre, and the layout places the setting-out grid marks, the UP/DN
/// riser marks, the riser tie dimensions and every run / riser / equipment
/// tag in that output space. At the same plotted scale the two maps differ by
/// a pure similarity, and the placer reads only geometry-to-text ratios, so
/// the PDF and the DXF make the SAME line split and the SAME slot choice.
///
/// Pure (Flutter-free) and deterministic given the network's emission order.
library;

import 'dart:math' as math;

import '../network/network.dart';
import '../sizing/drainage_advisory.dart' show laidGravitySlope;
import '../sizing/network_sizing.dart' show EdgeSizing;
import '../units.dart' show Length;
import 'drawing_chrome.dart' show LabelBox, kMinPlotTextMm;
import 'plan_symbols.dart';

/// Paper millimetres per PDF point.
const double kPlanPaperMmPerPt = 25.4 / 72;

/// Plotted height of a plan run / riser / equipment tag and of the UP/DN
/// marks: 9 pt (3.175 mm) — above the ISO 3098 2.5 mm minimum.
const double kPlanLabelTextMm = 9 * kPlanPaperMmPerPt;

/// Plotted height of a riser tie-dimension figure: the ISO 3098 minimum.
const double kPlanTieTextMm = kMinPlotTextMm;

/// Plotted box of an equipment / fixture glyph (14 pt).
const double kPlanGlyphSizeMm = 14 * kPlanPaperMmPerPt;

/// Half-size of the area a glyph node keeps clear of tags (7 pt).
const double kPlanGlyphClearMm = 7 * kPlanPaperMmPerPt;

/// Half-size of the area a plain junction keeps clear of tags (2.5 pt).
const double kPlanJunctionClearMm = 2.5 * kPlanPaperMmPerPt;

/// Plotted radius of a riser marker circle (5 pt).
const double kPlanRiserMarkerMm = 5 * kPlanPaperMmPerPt;

/// Gap from a riser marker to its UP/DN mark and to its tag (8 pt).
const double kPlanRiserTagGapMm = 8 * kPlanPaperMmPerPt;

/// Gap from an equipment glyph's centre to its tag (10 pt).
const double kPlanEquipmentTagGapMm = 10 * kPlanPaperMmPerPt;

/// Plotted radius of a setting-out grid bubble (9 pt), and its gap beyond the
/// drawn extent (2 pt).
const double kPlanGridBubbleMm = 9 * kPlanPaperMmPerPt;
const double kPlanGridBubbleGapMm = 2 * kPlanPaperMmPerPt;

/// drafting-4: a tie dimension's perpendicular offset from the axis-to-riser
/// ordinate (10 pt), and the half-length of its 45° oblique tick (2 pt).
const double kPlanTieOffsetMm = 10 * kPlanPaperMmPerPt;
const double kPlanTieTickMm = 2 * kPlanPaperMmPerPt;

/// How the plan PDF plots a sheet (R6): its standard plotted-scale
/// denominator (`1 : N`) and the sheet area OUTSIDE its drawing frame + title
/// block, as axis-aligned boxes in SHEET PIXELS (y-down). The plan DXF takes
/// it so its annotations size to the same paper dimensions and dodge the same
/// sheet limits as the PDF's.
class PlanSheetPlot {
  final int scaleDenominator;
  final List<LabelBox> occupiedPx;
  const PlanSheetPlot(
      {required this.scaleDenominator, this.occupiedPx = const []});
}

/// What a placed tag annotates.
enum PlanLabelKind { run, riser, equipment }

/// One placed tag: what it labels ([kind] + [id] — the edge id for a run or
/// riser, the node id for equipment), its placement (lines, rotation, leader)
/// and its text height in output units.
class PlanPlacedLabel {
  final PlanLabelKind kind;
  final String id;
  final LeaderedLabelPlacement placement;
  final double textSize;
  const PlanPlacedLabel(this.kind, this.id, this.placement, this.textSize);
}

/// A riser UP/DN mark: [text] with its baseline START at ([x], [y]).
class PlanUpDownMark {
  final String text;
  final double x;
  final double y;
  final double textSize;
  const PlanUpDownMark(this.text, this.x, this.y, this.textSize);
}

/// A riser tie dimension: the axis-side and riser-side extension lines, the
/// offset dimension line, the two oblique ticks, and the figure [text] with
/// its baseline START at ([textX], [textY]).
class PlanTieDimension {
  final LabelSegment axisExtension;
  final LabelSegment riserExtension;
  final LabelSegment dimension;
  final List<LabelSegment> ticks;
  final String text;
  final double textX;
  final double textY;
  final double textSize;
  const PlanTieDimension({
    required this.axisExtension,
    required this.riserExtension,
    required this.dimension,
    required this.ticks,
    required this.text,
    required this.textX,
    required this.textY,
    required this.textSize,
  });
}

/// One setting-out axis as drawn: its chain [line] across the extent and its
/// bubble centre + radius beyond it.
class PlanGridMark {
  final String label;
  final bool isColumn;
  final LabelSegment line;
  final double bubbleX;
  final double bubbleY;
  final double bubbleR;
  const PlanGridMark(this.label, this.isColumn, this.line, this.bubbleX,
      this.bubbleY, this.bubbleR);
}

/// The whole annotation layout of one plan sheet, in the caller's output
/// space (y-up).
class PlanAnnotations {
  final List<PlanGridMark> grid;
  final List<PlanUpDownMark> upDown;
  final List<PlanTieDimension> ties;
  final List<PlanPlacedLabel> labels;

  /// Round 24 — annotations that could only be placed OVERPRINTING something
  /// (the density limit of the sheet: no clear slot existed). The exporters
  /// print [planOverlapWarning] on the sheet when this is non-zero, so an
  /// illegible sheet is never issued as if it were clean.
  final int overlapCount;
  const PlanAnnotations(
      {this.grid = const [],
      this.upDown = const [],
      this.ties = const [],
      this.labels = const [],
      this.overlapCount = 0});
}

/// Round 24 — the minimum PAPER width (mm) at which a sized duct is drawn
/// true-width double-line; narrower it keeps the single band-stroke centre
/// line (two lines closer than ~1 mm on paper fuse into one heavy stroke).
const double kPlanDuctDoubleLineMinMm = 1.0;

/// Round 24 — the true PLAN width of a sized AIR run in metres (a rectangular
/// duct's W, a round duct's Ø); null for a pipe or an unsized edge. Pure; the
/// ONE source both plan exporters draw the double-line duct from.
double? planDuctWidthM(EdgeSizing? s) {
  if (s == null || !s.service.isAir) return null;
  final w = s.isRectangular ? s.width!.meters : s.diameter.meters;
  return w > 0 && w.isFinite ? w : null;
}

/// Round 24 — the two outline lines of a true-width run (a→b) offset ±[half]
/// perpendicular to it, in the caller's output space. Pure.
List<LabelSegment> planDoubleLineOutline(
    double ax, double ay, double bx, double by, double half) {
  final dx = bx - ax, dy = by - ay;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len <= 0 || !(half > 0)) return const [];
  final nx = -dy / len * half, ny = dx / len * half;
  return [
    (x1: ax + nx, y1: ay + ny, x2: bx + nx, y2: by + ny),
    (x1: ax - nx, y1: ay - ny, x2: bx - nx, y2: by - ny),
  ];
}

/// Round 24 — the on-sheet warning a plan exporter prints when [overlapCount]
/// annotations could not be placed clear (null when there are none). One
/// text for the PDF and the DXF (bilingual — the issued set is Indonesian).
String? planOverlapWarning(int overlapCount) => overlapCount <= 0
    ? null
    : 'PERHATIAN: $overlapCount label bertumpuk / labels overlap - '
        'cetak skala lebih besar, kertas lebih besar, atau pecah lembar';

/// A label to place for an edge: the one-line [text] + the optional two-line
/// [split] form (both from the shared composers).
typedef PlanEdgeLabelText = ({String text, List<String>? split});

/// Round 10 (mech-drawing-props-1) — the ONE label-composition rule both plan
/// exporters call, so the PDF and the DXF of one issued sheet tag exactly the
/// same edges with exactly the same text. Every edge (run or riser, sized or
/// NOT) is composed through [composePlanEdgeLabel] /
/// [composePlanEdgeLabelLines]: an unsized run still carries its tag + its
/// take-off length (the DXF used to skip it, so one missing label shifted
/// every later greedy slot choice and the two formats disagreed). An edge with
/// nothing to say (no tag, size, length or CL) gets no label.
///
/// [sizeText] gives an edge's printed size (null = unsized); [lengthOf] its
/// real length (null = unknown — never fabricated); [gravitySlope] the laid
/// fall a gravity RUN prints (`1:100`, G5).
Map<String, PlanEdgeLabelText> composePlanEdgeLabels({
  required Network net,
  required String? Function(NetEdge e) sizeText,
  required Length? Function(NetEdge e) lengthOf,
  Map<String, String>? edgeTags,
  Map<String, String>? edgeElevationLabels,
  double? gravitySlope,
  double? Function(NetEdge e)? diameterMmOf,
}) {
  final out = <String, PlanEdgeLabelText>{};
  for (final e in net.edges) {
    final size = sizeText(e);
    final len = lengthOf(e);
    final lenText =
        (len != null && len.meters > 0) ? planLengthLabel(len) : null;
    final elev = edgeElevationLabels?[e.id];
    final slope = (e.kind == EdgeKind.run &&
            e.service.regime == FlowRegime.gravity &&
            gravitySlope != null)
        // Round 33 — the fall the run is LAID at (a ≤ DN65 drainage branch
        // never prints flatter than its 1:50 minimum).
        ? gravitySlopeLabel(
            laidGravitySlope(e, gravitySlope, diameterMmOf?.call(e)))
        : null;
    final text = composePlanEdgeLabel(
      tag: edgeTags?[e.id],
      size: size,
      length: lenText,
      elevation: elev,
      slope: slope,
    );
    if (text == null) continue;
    out[e.id] = (
      text: text,
      split: composePlanEdgeLabelLines(
        tag: edgeTags?[e.id],
        size: size,
        length: lenText,
        elevation: elev,
        slope: slope,
      ),
    );
  }
  return out;
}

/// Lay out every annotation of the plan sheet ([sheetId], [floorIndex]) —
/// see the library note. [map] takes a sheet-pixel point to the output space
/// (y-up, axis-aligned, uniform scale); [unitsPerMm] is the output units per
/// PAPER millimetre at the sheet's plotted scale (PDF: 72/25.4; DXF: the
/// plotted-scale denominator N, model mm per paper mm). [edgeLabels] maps an
/// edge id to its composed label (runs and risers; absent ⇒ unlabelled);
/// [nodeTags] the equipment tags. With [grid] + [gridExtentPx] (the sheet-px
/// extent the axes span) the setting-out grid is laid out, and with a real
/// [metersPerPixel] too the per-riser tie dimensions. [occupied] seeds hard
/// no-go boxes in output units (a PDF's frame strips + title block).
/// [runHalfWidths] (edge id → half the drawn width in output units) registers
/// a true-width duct's double-line outline as linework (Round 24).
///
/// Order (greedy, deterministic): hard marks first (runs, glyphs, grid, riser
/// markers), then the UP/DN marks (each tries the four quadrants about its
/// marker and takes the first clear of runs, marks and grid lines — R6), the
/// tie dimensions, then the run tags, equipment tags and riser tags. Two risers
/// that print the IDENTICAL tag (or mark) at the same marker print it ONCE.
PlanAnnotations layoutPlanAnnotations({
  required Network net,
  required String sheetId,
  required int floorIndex,
  required ({double x, double y}) Function(double xPx, double yPx) map,
  required double unitsPerMm,
  required Map<String, PlanEdgeLabelText> edgeLabels,
  Map<String, String>? nodeTags,
  ReferenceGrid? grid,
  ({double minX, double minY, double maxX, double maxY})? gridExtentPx,
  double? metersPerPixel,
  List<LabelBox> occupied = const [],
  Map<String, double> runHalfWidths = const {},
}) {
  bool onFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;
  final u = unitsPerMm;
  final ts = kPlanLabelTextMm * u;
  final layout = PlanLabelLayout(boxes: [...occupied]);

  // ── Hard marks: runs, node glyphs, grid, riser markers ────────────────────
  for (final e in net.edges) {
    if (e.kind != EdgeKind.run) continue;
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null || !onFloor(a) || !onFloor(c)) continue;
    final pa = map(a.x, a.y), pc = map(c.x, c.y);
    layout.addRun(e.id, pa.x, pa.y, pc.x, pc.y);
    // Round 24 — a true-width (double-line) duct's two outline lines are
    // linework other tags must clear (its own tag may sit between them).
    final hw = runHalfWidths[e.id];
    if (hw != null && hw > 0) {
      for (final o in planDoubleLineOutline(pa.x, pa.y, pc.x, pc.y, hw)) {
        layout.addRun(e.id, o.x1, o.y1, o.x2, o.y2);
      }
    }
  }
  for (final n in net.nodes) {
    if (!onFloor(n)) continue;
    final p = map(n.x, n.y);
    final r = (n.component != null || n.role == NodeRole.fixture
            ? kPlanGlyphClearMm
            : kPlanJunctionClearMm) *
        u;
    layout.addBox((minX: p.x - r, minY: p.y - r, maxX: p.x + r, maxY: p.y + r));
  }
  final gridMarks = <PlanGridMark>[];
  final ext = gridExtentPx;
  if (grid != null && !grid.isEmpty && ext != null) {
    final r = kPlanGridBubbleMm * u;
    final off = r + kPlanGridBubbleGapMm * u;
    for (final axis in grid.columns) {
      final p1 = map(axis.position, ext.minY),
          p2 = map(axis.position, ext.maxY);
      final top = math.max(p1.y, p2.y) + off;
      gridMarks.add(PlanGridMark(axis.label, true,
          (x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y), p1.x, top, r));
      layout.addGridLine(p1.x, p1.y, p2.x, p2.y);
      layout.addBox(
          (minX: p1.x - r, minY: top - r, maxX: p1.x + r, maxY: top + r));
    }
    for (final axis in grid.rows) {
      final p1 = map(ext.minX, axis.position),
          p2 = map(ext.maxX, axis.position);
      final left = math.min(p1.x, p2.x) - off;
      gridMarks.add(PlanGridMark(axis.label, false,
          (x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y), left, p1.y, r));
      layout.addGridLine(p1.x, p1.y, p2.x, p2.y);
      layout.addBox(
          (minX: left - r, minY: p1.y - r, maxX: left + r, maxY: p1.y + r));
    }
  }
  // Every on-floor riser endpoint, in emission order, with its UP/DN senses.
  final riserNodes = <String, List<String>>{};
  for (final e in net.edges) {
    if (e.kind == EdgeKind.run) continue;
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null) continue;
    for (final n in [a, c]) {
      if (!onFloor(n)) continue;
      final senses = riserNodes.putIfAbsent(n.id, () => <String>[]);
      final other = n.id == a.id ? c : a;
      final sense =
          riserUpDown(hereFloor: n.floorIndex, otherFloor: other.floorIndex);
      // R6: two coincident risers rising the same way print ONE mark.
      if (sense != null && !senses.contains(sense)) senses.add(sense);
    }
  }
  final mr = kPlanRiserMarkerMm * u;
  for (final id in riserNodes.keys) {
    final n = net.nodeById(id)!;
    final p = map(n.x, n.y);
    layout.addBox(
        (minX: p.x - mr, minY: p.y - mr, maxX: p.x + mr, maxY: p.y + mr));
  }

  // ── UP/DN marks: the first clear quadrant about the marker (R6) ───────────
  final upDown = <PlanUpDownMark>[];
  final gap = kPlanRiserTagGapMm * u;
  for (final entry in riserNodes.entries) {
    final n = net.nodeById(entry.key)!;
    final p = map(n.x, n.y);
    for (final sense in entry.value) {
      final w = sense.length * ts * 0.55;
      // (x, baseline) of the four quadrants: lower-right (the long-standing
      // slot), upper-right, lower-left, upper-left — each box clear of the
      // marker circle and disjoint from its vertical twin.
      final quads = <(double, double)>[
        (p.x + gap, p.y - gap),
        (p.x + gap, p.y + 0.3 * ts),
        (p.x - gap - w, p.y - gap),
        (p.x - gap - w, p.y + 0.3 * ts),
      ];
      LabelBox boxAt(double x, double y) =>
          (minX: x, minY: y, maxX: x + w, maxY: y + ts);
      // Passes, best first: well clear of every run (so the mark never
      // crowds the slot beside a run leaving the marker, where that run's
      // tag belongs) and of the grid; just clear of the runs and the grid;
      // just clear of the runs.
      bool clearAt(double x, double y, double runClear, bool avoidGrid) {
        final b = boxAt(x, y);
        if (layout.hitsBox(b)) return false;
        if (layout.hitsRun(b, clearance: runClear)) return false;
        return !avoidGrid || !layout.hitsGrid(b);
      }

      (double, double)? pick;
      for (final (runClear, avoidGrid) in [
        (0.7 * ts, true),
        (0.1 * ts, true),
        (0.1 * ts, false),
      ]) {
        for (final (x, y) in quads) {
          if (clearAt(x, y, runClear, avoidGrid)) {
            pick = (x, y);
            break;
          }
        }
        if (pick != null) break;
      }
      // Nothing clear: stack below the first quadrant (never dropped).
      if (pick == null) {
        var (x, y) = quads.first;
        for (var step = 0; step < 4; step++) {
          if (!layout.hitsBox(boxAt(x, y))) break;
          y -= 1.3 * ts;
        }
        // Round 24 — still colliding after the stack: counted, not silent.
        if (layout.hitsBox(boxAt(x, y))) layout.markUnresolved();
        pick = (x, y);
      }
      final (x, y) = pick;
      upDown.add(PlanUpDownMark(sense, x, y, ts));
      layout.addBox(boxAt(x, y));
    }
  }

  // ── N4 riser tie dimensions (only with a real scale) ──────────────────────
  final ties = <PlanTieDimension>[];
  if (grid != null && !grid.isEmpty && ext != null && metersPerPixel != null) {
    final off = kPlanTieOffsetMm * u;
    final pt = u * kPlanPaperMmPerPt; // one plotted point in output units
    final fs = kPlanTieTextMm * u;
    void tieDim(double fromXpx, double fromYpx, double toXpx, double toYpx,
        String label) {
      final la = map(fromXpx, fromYpx); // axis end
      final lb = map(toXpx, toYpx); // riser end (at the marker)
      final dxp = lb.x - la.x, dyp = lb.y - la.y;
      final len = math.sqrt(dxp * dxp + dyp * dyp);
      final ux = len > 1e-9 * u ? dxp / len : 1.0;
      final uy = len > 1e-9 * u ? dyp / len : 0.0;
      // The direction rotated by -90° (both output spaces are y-up), so the
      // dimension lands on the SAME side in every format.
      final px = uy, py = -ux;
      final dax = la.x + px * off, day = la.y + py * off;
      final dbx = lb.x + px * off, dby = lb.y + py * off;
      final over = off + 2 * pt;
      final tkx = (ux + px) * kPlanTieTickMm * u / math.sqrt2;
      final tky = (uy + py) * kPlanTieTickMm * u / math.sqrt2;
      // The dimension + extension lines are linework later tags must not
      // overprint (nor a leader run along).
      final axisExt = (
        x1: la.x + px * 2 * pt,
        y1: la.y + py * 2 * pt,
        x2: la.x + px * over,
        y2: la.y + py * over,
      );
      final riserExt = (
        x1: lb.x + px * 6 * pt,
        y1: lb.y + py * 6 * pt,
        x2: lb.x + px * over,
        y2: lb.y + py * over,
      );
      for (final l in [
        axisExt,
        riserExt,
        (x1: dax, y1: day, x2: dbx, y2: dby)
      ]) {
        layout.addRun(null, l.x1, l.y1, l.x2, l.y2);
      }
      // Stagger the figure AWAY from the marker (back off along the line
      // toward the axis), then step perpendicular until the box clears
      // everything already placed (marker / UP-DN / other ties).
      final w = label.length * fs * 0.55;
      final h = fs;
      final along = math.min(22 * pt, len * 0.5);
      LabelBox boxAt(double bcx, double bcy) => (
            minX: bcx - w / 2,
            minY: bcy - h / 2,
            maxX: bcx + w / 2,
            maxY: bcy + h / 2,
          );
      // Round 10 (mech-drawing-props-3) — the figure must clear RUNS too (a
      // parallel HW main 0.5–0.9 m from a CW riser used to strike straight
      // through the setting-out figure). Candidates, in order: the historic
      // slot stepping outward on the figure's side; the opposite side of the
      // dimension line; then the same two ladders at other stations ALONG the
      // dimension (stepping perpendicular alone can never escape a run that
      // parallels the perpendicular). Nothing clear ⇒ the historic outermost
      // slot, as before.
      bool blocked(double bcx, double bcy) =>
          layout.hitsBox(boxAt(bcx, bcy)) ||
          layout.hitsRun(boxAt(bcx, bcy), clearance: 0.1 * fs);
      final stations = <double>[
        along,
        for (final f in const [0.3, 0.5, 0.7, 0.85])
          if (len * f > w / 2 + pt && len * f < len - w / 2 - pt) len * f,
      ];
      double? fx, fy; // the historic fallback (outermost +p slot)
      double? cx, cy;
      search:
      for (var si = 0; si < stations.length; si++) {
        final cx0 = lb.x - ux * stations[si] + px * off;
        final cy0 = lb.y - uy * stations[si] + py * off;
        for (final side in const [1.0, -1.0]) {
          for (var step = 0; step <= 6; step++) {
            final o = 7 * pt + step * (h + 4 * pt);
            final x = cx0 + side * px * o, y = cy0 + side * py * o;
            if (si == 0 && side > 0) {
              fx = x;
              fy = y;
            }
            if (!blocked(x, y)) {
              cx = x;
              cy = y;
              break search;
            }
          }
        }
      }
      if (cx == null) {
        // Round 24 — the historic slot is kept, but it overlaps: counted.
        if (blocked(fx!, fy!)) layout.markUnresolved();
      }
      cx ??= fx!;
      cy ??= fy!;
      layout.addBox(boxAt(cx, cy));
      ties.add(PlanTieDimension(
        axisExtension: axisExt,
        riserExtension: riserExt,
        dimension: (x1: dax, y1: day, x2: dbx, y2: dby),
        ticks: [
          for (final (ex, ey) in [(dax, day), (dbx, dby)])
            (x1: ex - tkx, y1: ey - tky, x2: ex + tkx, y2: ey + tky),
        ],
        text: label,
        textX: cx - w / 2,
        textY: cy - h / 2,
        textSize: fs,
      ));
    }

    for (final id in riserNodes.keys) {
      final n = net.nodeById(id)!;
      final col = nearestAxis(grid.columns, n.x);
      if (col != null) {
        final t = formatTieOffsetMm((n.x - col.position).abs(), metersPerPixel);
        if (t != null) tieDim(col.position, n.y, n.x, n.y, t);
      }
      final row = nearestAxis(grid.rows, n.y);
      if (row != null) {
        final t = formatTieOffsetMm((n.y - row.position).abs(), metersPerPixel);
        if (t != null) tieDim(n.x, row.position, n.x, n.y, t);
      }
    }
  }

  // ── Tags: runs, then equipment, then risers ────────────────────────────────
  final labels = <PlanPlacedLabel>[];
  for (final e in net.edges) {
    if (e.kind != EdgeKind.run) continue;
    final l = edgeLabels[e.id];
    if (l == null) continue;
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null || !onFloor(a) || !onFloor(c)) continue;
    final pa = map(a.x, a.y), pc = map(c.x, c.y);
    labels.add(PlanPlacedLabel(
        PlanLabelKind.run,
        e.id,
        placePlanLabel(
            ax: pa.x,
            ay: pa.y,
            bx: pc.x,
            by: pc.y,
            text: l.text,
            splitLines: l.split,
            textSize: ts,
            layout: layout,
            ownRunId: e.id,
            // Round 29 (drawings-3-3) — clear the duct's own outline.
            ownHalfWidth: runHalfWidths[e.id] ?? 0),
        ts));
  }
  // A point feature's tag: a short pseudo-run just right of the feature,
  // anchored on it (so an escaped tag leaders back to the feature itself).
  LeaderedLabelPlacement pointTag(
      double px, double py, double gapMm, String text, List<String>? split) {
    final w = text.length * ts * 0.55;
    final x0 = px + gapMm * u;
    return placePlanLabel(
        ax: x0,
        ay: py,
        bx: x0 + w,
        by: py,
        text: text,
        splitLines: split,
        textSize: ts,
        layout: layout,
        anchorPoint: (x: px, y: py));
  }

  // Round 33 (engineer-walkthrough-plan-fixtures-anonymous) — every plumbing
  // fixture on the floor also carries its plan code (WC / LAV / SH / FD…)
  // through the SAME placer as the equipment tags, so PDF == DXF.
  final allNodeTags = <String, String>{
    ...fixturePlanTags(net,
        sheetId: sheetId, floorIndex: floorIndex, nodeTags: nodeTags),
    // Round 34 — air terminals carry their airflow + face size.
    ...airTerminalPlanTags(net,
        sheetId: sheetId, floorIndex: floorIndex, nodeTags: nodeTags),
    ...?nodeTags,
  };
  if (allNodeTags.isNotEmpty) {
    for (final n in net.nodes) {
      if (!onFloor(n)) continue;
      final tag = allNodeTags[n.id];
      if (tag == null || tag.isEmpty) continue;
      final p = map(n.x, n.y);
      labels.add(PlanPlacedLabel(PlanLabelKind.equipment, n.id,
          pointTag(p.x, p.y, kPlanEquipmentTagGapMm, tag, null), ts));
    }
  }
  final printed = <String>{};
  for (final e in net.edges) {
    if (e.kind == EdgeKind.run) continue;
    final l = edgeLabels[e.id];
    if (l == null) continue;
    final a = net.nodeById(e.fromId);
    final c = net.nodeById(e.toId);
    if (a == null || c == null) continue;
    final marker = onFloor(a) ? a : (onFloor(c) ? c : null);
    if (marker == null) continue;
    // R6: two coincident risers (the stack below + above one floor) carrying
    // the IDENTICAL tag at the same marker print it ONCE.
    final key = '${marker.x.toStringAsFixed(3)},'
        '${marker.y.toStringAsFixed(3)}|${l.text}';
    if (!printed.add(key)) continue;
    final p = map(marker.x, marker.y);
    labels.add(PlanPlacedLabel(PlanLabelKind.riser, e.id,
        pointTag(p.x, p.y, kPlanRiserTagGapMm, l.text, l.split), ts));
  }

  return PlanAnnotations(
      grid: gridMarks,
      upDown: upDown,
      ties: ties,
      labels: labels,
      overlapCount: layout.unresolvedCount);
}
