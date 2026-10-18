/// The PLOT fit of a single-line [SldSheet]: how big the sheet is drawn on the
/// page, and how big its labels are printed (drafting-6). Pure, no Flutter.
///
/// The vector exporters auto-fit a sheet into the A3 drawing area by scaling
/// the whole drawing down. Before this pass the labels scaled down with it, so a
/// dense riser printed its cable tags at 5 pt (about 1.3 mm capitals), well
/// under the ISO 3098 minimum. [fitSldSheetForPlot] keeps the geometry scale and
/// GROWS each label that would print below [kMinPlotLabelPt], in drawing units,
/// so it prints at the minimum after the fit.
///
/// Growth never creates an overlap. Each label is grown in place (its anchor
/// never moves, so a schedule cell stays in its row and a tag stays by its run),
/// and only as far as clear space allows: it may not cover another label (at
/// that label's current size) or any line, box or circle it did not already sit
/// on. Labels grow together in rounds, so neighbours share the space between
/// them rather than the first-drawn one taking it all. A label that is boxed in
/// stays at the largest size that fits, never smaller than the size it was
/// drawn at. So the original collision-free layout, which the builders' own
/// label placers produced, is still collision-free after growth. On a very
/// dense sheet (a tall riser fitted to A3 at about 1:3) the stacked fan-out
/// rows can't all reach the minimum; they stay at the largest legible size
/// that does not overlap.
///
/// The fitted sheet's bounds also cover every label's real text extent (the
/// Helvetica width, ascent and descent), not just its baseline anchor, so the
/// top label of a sheet (for example the `PLN MV STATION` supply head) can no
/// longer print across the top frame line (drafting-9).
///
/// The PDF renderer (`electrical_pdf_export.dart`) and the DXF renderer
/// (`electrical_dxf_export.dart`) both draw the fitted sheet, so the two
/// formats print the same label sizes (golden rule 5: one geometry, every
/// render). The live Flutter canvas zooms freely, so it keeps the unfitted
/// sheet.
library;

import 'dart:math' as math;

import 'drawing_chrome.dart' show helveticaTextWidth, kMinPlotLabelPt;
import 'sld_sheet.dart';

/// Ascent of a label's box above its baseline, as a multiple of its size.
/// Helvetica capitals and ascenders reach about 0.72 em; a little is added so
/// two labels never touch.
const double kSldLabelAscent = 0.75;

/// Descent of a label's box below its baseline, as a multiple of its size
/// (Helvetica descenders reach about 0.21 em).
const double kSldLabelDescent = 0.22;

/// The A3-landscape drawing area (points) that an SLD sheet is fitted into when
/// no page chrome is known (the DXF export, which is plotted to fit A3). It is
/// the A3 page less the 40 pt frame margins, a 12 pt inset inside the frame on
/// every side, and the 96 pt strip the legacy title block reserves.
const double kSldA3PlotAvailW = 1190.55 - 2 * 40 - 2 * 12;

/// See [kSldA3PlotAvailW].
const double kSldA3PlotAvailH = 841.89 - 2 * 40 - 2 * 12 - 96;

/// The outcome of [fitSldSheetForPlot]: the sheet to draw (labels grown, bounds
/// covering every label's text) and the geometry scale (page points per
/// drawing unit, at most 1) to draw it at.
class SldPlotFit {
  final SldSheet sheet;
  final double scale;
  const SldPlotFit(this.sheet, this.scale);
}

/// An axis-aligned box in y-down drawing space.
class _Box {
  final double l, t, r, b;
  const _Box(this.l, this.t, this.r, this.b);

  bool overlaps(_Box o, double tol) =>
      l < o.r - tol && o.l < r - tol && t < o.b - tol && o.t < b - tol;
}

/// The text box of [l] printed at [size] drawing units.
_Box _labelBox(SldLabel l, double size) => _Box(
      l.x,
      l.y - kSldLabelAscent * size,
      l.x + helveticaTextWidth(l.text, size),
      l.y + kSldLabelDescent * size,
    );

/// A non-label obstacle, reduced to segments (lines, rectangle edges) or a box
/// (a circle's bounding square).
class _Obstacle {
  final double x1, y1, x2, y2;
  final bool isBox;
  const _Obstacle.segment(this.x1, this.y1, this.x2, this.y2) : isBox = false;
  const _Obstacle.box(this.x1, this.y1, this.x2, this.y2) : isBox = true;

  bool hits(_Box b, double tol) {
    final l = b.l + tol, t = b.t + tol, r = b.r - tol, bo = b.b - tol;
    if (r <= l || bo <= t) return false;
    if (isBox) return x1 < r && l < x2 && y1 < bo && t < y2;
    // Bounding-box reject.
    if (math.max(x1, x2) < l ||
        math.min(x1, x2) > r ||
        math.max(y1, y2) < t ||
        math.min(y1, y2) > bo) {
      return false;
    }
    bool inside(double x, double y) => x > l && x < r && y > t && y < bo;
    if (inside(x1, y1) || inside(x2, y2)) return true;
    // Liang-Barsky clip of the segment against the box.
    final dx = x2 - x1, dy = y2 - y1;
    var u0 = 0.0, u1 = 1.0;
    bool clip(double p, double q) {
      if (p == 0) return q >= 0;
      final u = q / p;
      if (p < 0) {
        if (u > u1) return false;
        if (u > u0) u0 = u;
      } else {
        if (u < u0) return false;
        if (u < u1) u1 = u;
      }
      return true;
    }

    return clip(-dx, x1 - l) &&
        clip(dx, r - x1) &&
        clip(-dy, y1 - t) &&
        clip(dy, bo - y1) &&
        u0 < u1;
  }
}

List<_Obstacle> _obstaclesOf(SldPrim p) => switch (p) {
      SldLine() => [_Obstacle.segment(p.x1, p.y1, p.x2, p.y2)],
      SldRect() => [
          _Obstacle.segment(p.x, p.y, p.x + p.w, p.y),
          _Obstacle.segment(p.x + p.w, p.y, p.x + p.w, p.y + p.h),
          _Obstacle.segment(p.x, p.y + p.h, p.x + p.w, p.y + p.h),
          _Obstacle.segment(p.x, p.y, p.x, p.y + p.h),
        ],
      SldCircle() => [
          _Obstacle.box(p.cx - p.r, p.cy - p.r, p.cx + p.r, p.cy + p.r)
        ],
      SldLabel() => const [],
    };

/// Clear space a GROWN label keeps ahead of its text end, as a multiple of its
/// size — a full word space (Round 23, elec-drafting-2-7: a thin space let a
/// grown riser fan-out stub run up to the NEIGHBOUR board's stub line, which
/// then printed as one string, `...125A 3ph— Lift penumpang`), so growth stops
/// short of a neighbouring label or line instead of reading into it. Only the right side is padded: the left anchor never
/// moves (a leader may legitimately end there), and the box's ascent/descent
/// already carry a small margin over the real glyphs.
const double kSldLabelClearance = 0.3;

/// [sheet] with every label smaller than [floorSize] drawing units grown toward
/// [floorSize] in place, as far as clear space allows (see the library doc),
/// and the bounds widened to cover every label's text extent. A sheet with no
/// label below [floorSize] only has its bounds widened.
SldSheet floorSldLabels(SldSheet sheet, double floorSize) {
  final prims = sheet.prims;
  final labelIdx = <int>[
    for (var i = 0; i < prims.length; i++)
      if (prims[i] is SldLabel) i
  ];
  final obstacles = <_Obstacle>[
    for (final p in prims) ..._obstaclesOf(p),
  ];
  // The current box of every label (its original size until it is grown).
  final boxes = <int, _Box>{
    for (final i in labelIdx)
      i: _labelBox(prims[i] as SldLabel, (prims[i] as SldLabel).size),
  };
  final out = List<SldPrim>.of(prims);
  // Labels that need to grow, each with the obstacles that can block it: the
  // lines / boxes the label ALREADY sits on (a tag written over its own run, a
  // caption inside its panel box) don't block its growth.
  final growing = <int>[];
  final blockersOf = <int, List<_Obstacle>>{};
  final sizeOf = <int, double>{};
  for (final i in labelIdx) {
    final l = prims[i] as SldLabel;
    if (l.size >= floorSize - 1e-9 || l.text.trim().isEmpty) continue;
    growing.add(i);
    sizeOf[i] = l.size;
    final orig = boxes[i]!;
    blockersOf[i] = [
      for (final o in obstacles)
        if (!o.hits(orig, 0)) o
    ];
  }

  bool clear(int i, double size) {
    final l = prims[i] as SldLabel;
    final t = _labelBox(l, size);
    final pad = kSldLabelClearance * size;
    final b = _Box(t.l, t.t, t.r + pad, t.b);
    for (final j in labelIdx) {
      if (j != i && boxes[j]!.overlaps(b, 0)) return false;
    }
    for (final o in blockersOf[i]!) {
      if (o.hits(b, 0)) return false;
    }
    return true;
  }

  // Grow FAIRLY, in rounds: each round every label takes the next step toward
  // the minimum, so neighbours competing for the same clear space share it
  // (no label crowds another out just by being drawn first). A label that
  // meets an obstacle takes the largest size that fits and stops.
  const rounds = 6;
  final stuck = <int>{};
  for (var k = 1; k <= rounds; k++) {
    for (final i in growing) {
      if (stuck.contains(i)) continue;
      final l = prims[i] as SldLabel;
      final cur = sizeOf[i]!;
      final target = l.size + (floorSize - l.size) * k / rounds;
      if (target <= cur + 1e-9) continue;
      var size = target;
      if (!clear(i, target)) {
        var lo = cur, hi = target;
        for (var it = 0; it < 12; it++) {
          final mid = (lo + hi) / 2;
          if (clear(i, mid)) {
            lo = mid;
          } else {
            hi = mid;
          }
        }
        size = lo;
        stuck.add(i);
      }
      if (size > cur + 1e-9) {
        sizeOf[i] = size;
        boxes[i] = _labelBox(l, size);
      }
    }
  }
  for (final i in growing) {
    final l = prims[i] as SldLabel;
    final size = sizeOf[i]!;
    if (size > l.size + 1e-9) {
      out[i] = SldLabel(l.x, l.y, l.text, size: size, bold: l.bold, role: l.role);
    }
  }
  return _withTextBounds(sheet, out);
}

/// A copy of [sheet] with [prims] and its bounds widened to cover every label's
/// text extent (never narrowed).
SldSheet _withTextBounds(SldSheet sheet, List<SldPrim> prims) {
  var minX = sheet.minX, minY = sheet.minY;
  var maxX = sheet.maxX, maxY = sheet.maxY;
  for (final p in prims) {
    if (p is! SldLabel || p.text.trim().isEmpty) continue;
    final b = _labelBox(p, p.size);
    minX = math.min(minX, b.l);
    minY = math.min(minY, b.t);
    maxX = math.max(maxX, b.r);
    maxY = math.max(maxY, b.b);
  }
  return SldSheet(
    prims: prims,
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
    legend: sheet.legend,
    supplyNote: sheet.supplyNote,
  );
}

/// The geometry scale (page points per drawing unit) that fits [sheet]'s bounds
/// into [availW] × [availH] points, never above 1 (a small drawing is not blown
/// up past 1:1).
double sldAutoFitScale(SldSheet sheet,
    {required double availW, required double availH}) {
  final spanX = math.max(1e-6, sheet.maxX - sheet.minX);
  final spanY = math.max(1e-6, sheet.maxY - sheet.minY);
  var scale = math.min(availW / spanX, availH / spanY);
  if (!scale.isFinite || scale <= 0) scale = 1.0;
  return math.min(scale, 1.0);
}

/// Fit [sheet] into [availW] × [availH] points so that every label prints at
/// [minPlotPt] or more wherever there is clear space for it (see the library
/// doc). Growing labels can widen the bounds and so lower the scale, so the fit
/// is repeated (from the ORIGINAL sheet each time, a handful of rounds) until
/// the scale settles.
SldPlotFit fitSldSheetForPlot(
  SldSheet sheet, {
  required double availW,
  required double availH,
  double minPlotPt = kMinPlotLabelPt,
}) {
  var cur = _withTextBounds(sheet, sheet.prims);
  var scale = sldAutoFitScale(cur, availW: availW, availH: availH);
  final smallest = sheet.prims
      .whereType<SldLabel>()
      .where((l) => l.text.trim().isNotEmpty)
      .fold(double.infinity, (m, l) => math.min(m, l.size));
  for (var round = 0; round < 6; round++) {
    final floorSize = minPlotPt / scale;
    if (smallest >= floorSize - 1e-9) break;
    final next = floorSldLabels(sheet, floorSize);
    final nextScale = sldAutoFitScale(next, availW: availW, availH: availH);
    cur = next;
    final settled = (nextScale - scale).abs() <= 1e-4 * scale;
    scale = nextScale;
    if (settled) break;
  }
  return SldPlotFit(cur, scale);
}
