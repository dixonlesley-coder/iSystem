/// Round 21 (riser-drafting-2-2) — legibility-driven PAGINATION of the
/// mechanical riser single-line.
///
/// The riser PDF used to fit the whole building onto ONE A3 sheet: a
/// 12-storey riser (12 × 150-unit bands) printed its tags at ~3 pt, below the
/// [kMinPlotLabelPt] floor the electrical detail SLD already enforces
/// (`electricalSldDetailToPdf`). This module picks the fewest pages whose
/// labels print as large as the sheet geometry allows: one page when it
/// already prints at [kMinPlotLabelPt], else the LARGEST floors-per-page
/// whose every page prints at `min(kMinPlotLabelPt, 0.95 × best)` — `best` being
/// the single-floor pages' size (the sheet's WIDTH caps how large a label
/// can ever get, so 7 pt is not always reachable and a one-floor-per-page
/// set would gain nothing past that cap).
///
/// The builder supplies each page (`buildMechanicalRiserSld(floorRange:)`),
/// which draws a 'LANJUT KE <floor>' match stub where a riser leaves the
/// page; the extras (plant detail, callouts, notes) ride the page carrying
/// the lowest floor. Pages are returned TOP floors first. Pure.
library;

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
  final whole = build(null);
  if (levelCount <= 1 || minPt(whole) >= kMinPlotLabelPt - 1e-9) {
    return [whole];
  }
  ({List<SldSheet> sheets, double min}) pagesAt(int k) {
    final sheets = [for (final r in riserFloorChunks(levelCount, k)) build(r)];
    var m = double.infinity;
    for (final s in sheets) {
      final v = minPt(s);
      if (v < m) m = v;
    }
    return (sheets: sheets, min: m);
  }

  final single = pagesAt(1);
  // Within 5 % of the best achievable size counts as legible-as-possible, so
  // float noise never forces one more page.
  final cap = single.min * 0.95;
  final target = (cap < kMinPlotLabelPt ? cap : kMinPlotLabelPt) - 1e-9;
  // The width-capped case: one sheet already prints as large as any split.
  if (minPt(whole) >= target) return [whole];
  var best = single.sheets;
  for (var k = 2; k < levelCount; k++) {
    final pages = pagesAt(k);
    if (pages.min < target) break;
    best = pages.sheets;
  }
  return best;
}
