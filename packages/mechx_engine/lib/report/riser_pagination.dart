/// Round 21 (riser-drafting-2-2) — legibility-driven PAGINATION of the
/// mechanical riser single-line.
///
/// The riser PDF used to fit the whole building onto ONE A3 sheet: a
/// 12-storey riser (12 × 150-unit bands) printed its tags at ~3 pt, below the
/// [kMinPlotLabelPt] floor the electrical detail SLD already enforces
/// (`electricalSldDetailToPdf`). This module picks the fewest pages whose
/// labels print as large as the sheet geometry allows: one page when it
/// already prints at [kMinPlotLabelPt], else floor runs cut GREEDILY from
/// floor 0 upward, each page as tall as it can be while it prints at the
/// largest `min(kMinPlotLabelPt, 0.95 × its single-floor size)` of its floors
/// (Round 40 — the sheet's WIDTH caps how large a label can ever get, so a
/// width-limited band shrinks only its own page, never the whole set).
///
/// The builder supplies each page (`buildMechanicalRiserSld(floorRange:)`),
/// which draws a 'LANJUT KE <floor>' match stub where a riser leaves the
/// page; the extras (plant detail, callouts, notes) ride the page carrying
/// the lowest floor. Pages are returned TOP floors first. Pure.
library;

import 'dart:math' as math;

import 'drawing_chrome.dart' show DrawingChrome, kMinPlotLabelPt;
import 'electrical_pdf_export.dart' show sldSinglePageMinLabelPt;
import 'sld_sheet.dart';

/// The floor ranges a riser of [levelCount] storeys splits into at
/// [floorsPerPage] floors each, TOP page first. Chunks are cut from floor 0
/// upward, so the TOP page (listed first) is the one that may hold fewer
/// floors — 12 floors at 5 per page ⇒ (10..11), (5..9), (0..4). Pure.
List<({int lo, int hi})> riserFloorChunks(int levelCount, int floorsPerPage) {
  final k = floorsPerPage < 1 ? 1 : floorsPerPage;
  final out = <({int lo, int hi})>[];
  for (var lo = 0; lo < levelCount; lo += k) {
    final hi = (lo + k - 1) < levelCount ? lo + k - 1 : levelCount - 1;
    out.add((lo: lo, hi: hi));
  }
  return out.reversed.toList();
}

/// The riser sheet as issuable PAGES (see the library doc): `[build(null)]`
/// when the whole riser prints at [kMinPlotLabelPt] or there is at most one
/// storey, else one sheet per floor range. [build] returns the sheet for a
/// floor range (null ⇒ the whole building).
List<SldSheet> paginatedRiserSheets({
  required SldSheet Function(({int lo, int hi})? range) build,
  required int levelCount,
  DrawingChrome? chrome,
  String projectName = 'Untitled project',
  String diagramTitle = 'SINGLE-LINE DIAGRAM',
}) {
  double minPt(SldSheet s) => sldSinglePageMinLabelPt(s,
      chrome: chrome, projectName: projectName, diagramTitle: diagramTitle);
  // Round 43 (electrical-sim-8-riser-floor-band-illegible) — a page whose
  // floors are WIDTH-bound (17 boards side by side on one storey) cannot
  // reach the plotted floor by any floor split: it is flagged with the size
  // it really prints at, so the issued sheet says so instead of silently
  // printing ~1.7 pt tags.
  SldSheet flagged(SldSheet p) {
    final pt = minPt(p);
    return pt < kMinPlotLabelPt - 1e-9 ? p.withBelowMinLabelPt(pt) : p;
  }

  final whole = build(null);
  if (levelCount <= 1 || minPt(whole) >= kMinPlotLabelPt - 1e-9) {
    return [flagged(whole)];
  }
  // Round 40 (elec-drawings-5-riser-pagination-global-cap-shrinks-all-
  // pages) — paginate GREEDILY per chunk from floor 0 upward. Each floor's
  // own best size is `min(kMinPlotLabelPt, 0.95 × its single-floor page)`;
  // a page may hold a run of floors only while it prints at the LARGEST of
  // those targets among its floors, so a width-limited band (a ground band
  // with the source spine + several boards) shrinks ITS OWN page only —
  // never every page of the set (one global floors-per-page used to print
  // the upper pages at ~6 pt where 5-floor chunks print at 7 pt).
  final singleMin = [
    for (var f = 0; f < levelCount; f++) minPt(build((lo: f, hi: f))),
  ];
  // Round 45 — a floor whose own page REACHES the floor targets the floor
  // itself: the plot fit caps labels at [kMinPlotLabelPt], so a legible
  // floor reads exactly 7.0 and the 0.95 relaxation (meant only for a floor
  // that cannot reach it alone) let a multi-floor page print at 6.65 pt.
  double floorTarget(int f) {
    if (singleMin[f] >= kMinPlotLabelPt - 1e-9) return kMinPlotLabelPt - 1e-9;
    final cap = singleMin[f] * 0.95;
    return (cap < kMinPlotLabelPt ? cap : kMinPlotLabelPt) - 1e-9;
  }

  final pages = <SldSheet>[];
  var lo = 0;
  while (lo < levelCount) {
    var hi = lo;
    var sheet = build((lo: lo, hi: lo));
    var target = floorTarget(lo);
    while (hi + 1 < levelCount) {
      final t = math.max(target, floorTarget(hi + 1));
      final next = build((lo: lo, hi: hi + 1));
      if (minPt(next) < t) break;
      hi++;
      sheet = next;
      target = t;
    }
    pages.add(sheet);
    lo = hi + 1;
  }
  // One chunk spanning every floor IS the whole sheet.
  if (pages.length == 1) return [flagged(whole)];
  return [for (final p in pages.reversed) flagged(p)];
}
