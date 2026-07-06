/// Pure-Dart raster snap-to-ink for a PDF plan **underlay** (B12).
///
/// A PDF sheet is a raster page (pdfrx) with no vector geometry, so there is
/// nothing for a drafter to latch a run onto. This gives it a snap surface the
/// cheap way: render the page once to a grayscale **luminance** map, then let a
/// query find the nearest sufficiently-dark linework ridge under the cursor and
/// refine to the line's centreline.
///
/// Two entry points:
///  * [luminanceFromRgba] — collapse an RGBA buffer to one luminance byte per
///    pixel (the cached per-sheet map an integrator builds once, async/LRU).
///  * [findInkSnap] — the lowest-precedence underlay candidate: the nearest
///    dark ridge point within the pick radius, centred across the line width.
///
/// This file is PURE and INTEGRATION-FREE: only `dart:typed_data` +
/// `dart:math`, no Flutter, no providers, no rendering. Everything is in
/// **sheet-px** coordinates (pixel `(ix, iy)` sampled at integer `(ix, iy)`).
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// How far below the sampled background median a pixel must be to count as ink
/// (0–255 luminance). Keeps a faint grey wash from reading as a snappable line.
const double _kDarkMargin = 40.0;

/// Radius (px) of the local window used to refine a hit to the line centreline.
/// Wide enough to span a few-px-thick stroke, tight enough to stay on one line.
const double _kRefineRadius = 3.5;

/// A snapped ink point in sheet-px: the centreline [x]/[y] and its Euclidean
/// [distance] from the query cursor.
class InkSnapPoint {
  final double x;
  final double y;
  final double distance;
  const InkSnapPoint(this.x, this.y, this.distance);

  @override
  String toString() => 'InkSnapPoint(($x, $y), d=$distance)';
}

/// Collapse a tightly-packed [rgba] buffer (`4·w·h` bytes, R,G,B,A order) to a
/// `w·h` luminance map using Rec.601 weights (`0.299R + 0.587G + 0.114B`).
/// Alpha is ignored (a rendered page is opaque). Returns an all-zero map if the
/// buffer is too short (defensive — never throws).
Uint8List luminanceFromRgba(Uint8List rgba, int w, int h) {
  final out = Uint8List(w <= 0 || h <= 0 ? 0 : w * h);
  if (out.isEmpty) return out;
  final n = out.length;
  if (rgba.length < n * 4) return out;
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    final r = rgba[o], g = rgba[o + 1], b = rgba[o + 2];
    // +0.5 → round-to-nearest.
    out[i] = (0.299 * r + 0.587 * g + 0.114 * b + 0.5).toInt();
  }
  return out;
}

/// The nearest sufficiently-dark ridge point to (`cx`,`cy`) within [radiusPx],
/// refined to the stroke centreline, or null if no ink is in range.
///
/// [lum] is a `w·h` luminance map (see [luminanceFromRgba]). A pixel is "dark"
/// when its luminance is below [threshold]; when [threshold] is omitted it is
/// derived adaptively as `(window background median) − margin`, so the test is
/// relative to the page's own paper tone. The hit is then nudged 1–2 px across
/// the stroke to its centroid perpendicular to the local dominant axis, so a
/// thick line snaps to its centre rather than the first edge pixel touched.
InkSnapPoint? findInkSnap(
  Uint8List lum,
  int w,
  int h,
  double cx,
  double cy,
  double radiusPx, {
  double? threshold,
}) {
  if (w <= 0 || h <= 0 || lum.length < w * h) return null;
  if (radiusPx <= 0) return null;

  final x0 = math.max(0, (cx - radiusPx).floor());
  final x1 = math.min(w - 1, (cx + radiusPx).ceil());
  final y0 = math.max(0, (cy - radiusPx).floor());
  final y1 = math.min(h - 1, (cy + radiusPx).ceil());
  if (x0 > x1 || y0 > y1) return null;

  final thr = threshold ?? _adaptiveThreshold(lum, w, x0, y0, x1, y1);

  // Nearest dark pixel within the radius.
  final r2 = radiusPx * radiusPx;
  var bestD2 = double.infinity;
  var bestX = 0, bestY = 0;
  var found = false;
  for (var y = y0; y <= y1; y++) {
    final row = y * w;
    for (var x = x0; x <= x1; x++) {
      if (lum[row + x] >= thr) continue;
      final ddx = x - cx, ddy = y - cy;
      final d2 = ddx * ddx + ddy * ddy;
      if (d2 > r2) continue;
      if (d2 < bestD2) {
        bestD2 = d2;
        bestX = x;
        bestY = y;
        found = true;
      }
    }
  }
  if (!found) return null;

  final refined = _refineToCentreline(lum, w, h, bestX, bestY, thr);
  final sx = refined[0], sy = refined[1];
  final dx = sx - cx, dy = sy - cy;
  return InkSnapPoint(sx, sy, math.sqrt(dx * dx + dy * dy));
}

/// Background-relative dark threshold: the median luminance of the window minus
/// [_kDarkMargin]. Median (not mean) resists a few dark ink pixels dragging it.
double _adaptiveThreshold(Uint8List lum, int w, int x0, int y0, int x1, int y1) {
  final vals = <int>[];
  for (var y = y0; y <= y1; y++) {
    final row = y * w;
    for (var x = x0; x <= x1; x++) {
      vals.add(lum[row + x]);
    }
  }
  vals.sort();
  final median = vals[vals.length ~/ 2].toDouble();
  return median - _kDarkMargin;
}

/// Move the hit (`hx`,`hy`) onto the local stroke centreline: gather the dark
/// pixels within [_kRefineRadius], find their dominant axis (PCA of the cluster)
/// and project the hit onto the centroid line along that axis — i.e. across the
/// stroke width to its centre. Falls back to the hit for a 1-px / degenerate
/// cluster. Returns `[x, y]`.
List<double> _refineToCentreline(
    Uint8List lum, int w, int h, int hx, int hy, double thr) {
  final rr = _kRefineRadius;
  final rr2 = rr * rr;
  final x0 = math.max(0, (hx - rr).floor());
  final x1 = math.min(w - 1, (hx + rr).ceil());
  final y0 = math.max(0, (hy - rr).floor());
  final y1 = math.min(h - 1, (hy + rr).ceil());

  var count = 0;
  var sumX = 0.0, sumY = 0.0;
  for (var y = y0; y <= y1; y++) {
    final row = y * w;
    for (var x = x0; x <= x1; x++) {
      if (lum[row + x] >= thr) continue;
      final ddx = x - hx, ddy = y - hy;
      if (ddx * ddx + ddy * ddy > rr2) continue;
      count++;
      sumX += x;
      sumY += y;
    }
  }
  if (count < 2) return [hx.toDouble(), hy.toDouble()];

  final mx = sumX / count, my = sumY / count;

  // Covariance of the cluster.
  var sxx = 0.0, sxy = 0.0, syy = 0.0;
  for (var y = y0; y <= y1; y++) {
    final row = y * w;
    for (var x = x0; x <= x1; x++) {
      if (lum[row + x] >= thr) continue;
      final ddx = x - hx, ddy = y - hy;
      if (ddx * ddx + ddy * ddy > rr2) continue;
      final ex = x - mx, ey = y - my;
      sxx += ex * ex;
      sxy += ex * ey;
      syy += ey * ey;
    }
  }

  // Dominant (larger-eigenvalue) eigenvector of [[sxx,sxy],[sxy,syy]].
  double dxAxis, dyAxis;
  if (sxy.abs() < 1e-9) {
    if (sxx >= syy) {
      dxAxis = 1;
      dyAxis = 0;
    } else {
      dxAxis = 0;
      dyAxis = 1;
    }
  } else {
    final tr = sxx + syy;
    final det = sxx * syy - sxy * sxy;
    final disc = math.max(0.0, (tr * tr) / 4 - det);
    final lambda = tr / 2 + math.sqrt(disc);
    dxAxis = lambda - syy;
    dyAxis = sxy;
  }
  final len = math.sqrt(dxAxis * dxAxis + dyAxis * dyAxis);
  if (len < 1e-9) return [hx.toDouble(), hy.toDouble()];
  dxAxis /= len;
  dyAxis /= len;

  // Project the hit onto the centreline (through the centroid along the axis):
  // keeps its position ALONG the line, recentres it ACROSS the width.
  final t = (hx - mx) * dxAxis + (hy - my) * dyAxis;
  return [mx + t * dxAxis, my + t * dyAxis];
}
