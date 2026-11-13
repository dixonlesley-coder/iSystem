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
  SldSheet Function(({int lo, int hi}) range)? buildWithoutExtras,
  SldSheet Function()? buildExtrasOnly,
  SldSheet Function(({int lo, int hi}) range, int part, bool withoutExtras)?
      buildColumnPart,
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
    if (levelCount == 1 &&
        buildWithoutExtras != null &&
        buildExtrasOnly != null &&
        minPt(whole) < kMinPlotLabelPt - 1e-9) {
      final bare = buildWithoutExtras((lo: 0, hi: 0));
      if (minPt(bare) > minPt(whole)) {
        return [flagged(bare), flagged(buildExtrasOnly())];
      }
    }
    return [flagged(whole)];
  }
  // Drawing review R2 — the 7 pt floor is EXACT: when the page carrying the
  // building's lowest floor cannot reach it WITH the extras (plant detail,
  // callouts, notes) but prints larger without them, every page holding
  // floor 0 is built without them and the extras follow on a continuation
  // sheet of their own. Only a page that cannot reach 7 pt even then is
  // flagged with the size it really prints at.
  var shed = false;
  if (buildWithoutExtras != null && buildExtrasOnly != null) {
    final withX = minPt(build((lo: 0, hi: 0)));
    shed = withX < kMinPlotLabelPt - 1e-9 &&
        minPt(buildWithoutExtras((lo: 0, hi: 0))) > withX;
  }
  SldSheet page(({int lo, int hi}) r) =>
      shed && r.lo == 0 ? buildWithoutExtras!(r) : build(r);

  // Round 40 (elec-drawings-5-riser-pagination-global-cap-shrinks-all-
  // pages) — paginate GREEDILY per chunk from floor 0 upward. Each floor's
  // own best size is `min(kMinPlotLabelPt, its single-floor page)`;
  // a page may hold a run of floors only while it prints at the LARGEST of
  // those targets among its floors, so a width-limited band (a ground band
  // with the source spine + several boards) shrinks ITS OWN page only —
  // never every page of the set (one global floors-per-page used to print
  // the upper pages at ~6 pt where 5-floor chunks print at 7 pt).
  final singleMin = [
    for (var f = 0; f < levelCount; f++) minPt(page((lo: f, hi: f))),
  ];
  // Round 45 — a floor whose own page REACHES the floor targets the floor
  // itself: the plot fit caps labels at [kMinPlotLabelPt], so a legible
  // floor reads exactly 7.0 and the 0.95 relaxation (meant only for a floor
  // that cannot reach it alone) let a multi-floor page print at 6.65 pt.
  // Drawing review R2 — EXACT, no relaxation: a floor that cannot reach the
  // floor alone targets its own single-floor size (the 0.95 slack let a
  // multi-floor page print at 6.78 pt where the floor alone printed larger).
  double floorTarget(int f) =>
      (singleMin[f] < kMinPlotLabelPt ? singleMin[f] : kMinPlotLabelPt) - 1e-9;

  final pages = <SldSheet>[];
  final ranges = <({int lo, int hi})>[];
  var lo = 0;
  while (lo < levelCount) {
    var hi = lo;
    var sheet = page((lo: lo, hi: lo));
    var target = floorTarget(lo);
    while (hi + 1 < levelCount) {
      final t = math.max(target, floorTarget(hi + 1));
      final next = page((lo: lo, hi: hi + 1));
      if (minPt(next) < t) break;
      hi++;
      sheet = next;
      target = t;
    }
    pages.add(sheet);
    ranges.add((lo: lo, hi: hi));
    lo = hi + 1;
  }
  // Drawing review S2 — a page whose key circles still overprint (the
  // placer's unresolved count) gives each of its floors a page of its own
  // when that clears more: the re-spacing then has the sheet's full width
  // and the band its full height. Never fewer floors than legible (a
  // single-floor page prints at least at its own target).
  for (var i = pages.length - 1; i >= 0; i--) {
    final r = ranges[i];
    if (pages[i].overlapCount == 0 || r.hi == r.lo) continue;
    final singles = [for (var f = r.lo; f <= r.hi; f++) page((lo: f, hi: f))];
    final left = singles.fold<int>(0, (a, p) => a + p.overlapCount);
    if (left < pages[i].overlapCount) {
      pages.replaceRange(i, i + 1, singles);
      ranges.replaceRange(
          i, i + 1, [for (var f = r.lo; f <= r.hi; f++) (lo: f, hi: f)]);
    }
  }
  // Drawing review S4 — a ONE-floor page still overprinting after the pitch
  // escalation is width-bound: its fixture columns split over two pages
  // ('BAGIAN 1/2', 'BAGIAN 2/2'; [buildColumnPart] part 1 keeps the risers
  // and plant), kept only when the two parts overprint strictly less and
  // neither prints smaller than the page it replaces.
  if (buildColumnPart != null) {
    for (var i = pages.length - 1; i >= 0; i--) {
      final r = ranges[i];
      if (pages[i].overlapCount == 0 || r.hi != r.lo) continue;
      final bare = shed && r.lo == 0;
      final parts = [
        for (final k in [1, 2]) buildColumnPart(r, k, bare)
      ];
      final left = parts.fold<int>(0, (a, p) => a + p.overlapCount);
      final floorPt = math.min(minPt(pages[i]), kMinPlotLabelPt) - 1e-9;
      if (left < pages[i].overlapCount &&
          parts.every((p) => minPt(p) >= floorPt)) {
        // Pages run bottom-up here (reversed below): part 2 then part 1
        // lists part 1 first on the issued set.
        pages.replaceRange(i, i + 1, parts.reversed);
        ranges.replaceRange(i, i + 1, [r, r]);
      }
    }
  }
  // One chunk spanning every floor IS the whole sheet.
  final out = pages.length == 1 && !shed ? [whole] : pages.reversed.toList();
  return [
    for (final p in out) flagged(p),
    if (shed) flagged(buildExtrasOnly!()),
  ];
}
