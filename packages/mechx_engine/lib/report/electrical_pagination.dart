/// Round 23 (elec-drafting-2-1) — legibility-driven PAGINATION of the
/// electrical building RISER and the zoomed-out building single-line
/// (OVERVIEW), the electrical companions of the mechanical riser's
/// `riser_pagination.dart` and the detail SLD's `electricalSldDetailToPdf`.
///
/// Both used to be fitted onto ONE A3 sheet whatever the building: a
/// 12-storey / 19-board tower riser printed its labels at ~1.5 pt, its
/// overview at ~3.2 pt, and even a 5-storey office riser fell below the
/// [kMinPlotLabelPt] floor. Now:
///
/// * the RISER splits into floor-range pages through the SAME chunker the
///   mechanical riser uses ([paginatedRiserSheets]); each page cuts the
///   feeders that leave it with a `LANJUT KE <floor>` match stub, and the
///   source spine rides the page carrying its root band;
/// * the OVERVIEW splits by SUB-TREE: the top page draws the source spine,
///   the root(s) and their direct sub-boards (each cut board noted
///   `LANJUT KE DIAGRAM <board>`), and every cut board's sub-tree is its own
///   page (`DARI <parent>` above its root) — recursively, while a page still
///   prints below the floor and has a deeper level to cut.
///
/// One page whenever the whole sheet already prints at [kMinPlotLabelPt].
/// The DXF of either drawing stays ONE sheet (CAD zooms). Pure.
library;

import 'dart:typed_data';

import '../electrical/model.dart';
import '../electrical/panel_results.dart' show ElectricalSystemResult;
import '../geometry/building.dart';
import 'drawing_chrome.dart' show DrawingChrome, kMinPlotLabelPt;
import 'electrical_pdf_export.dart'
    show electricalSldSheetsToPdf, sldSinglePageMinLabelPt;
import 'electrical_sld_drawing.dart';
import 'riser_pagination.dart' show paginatedRiserSheets;

/// The electrical riser as issuable PAGES, TOP floors first (see the library
/// doc). `[whole]` when it already prints at [kMinPlotLabelPt].
List<SldSheet> paginatedElectricalRiserSheets({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  BuildingLevels? building,
  bool sourceChain = true,
  DrawingChrome? chrome,
  String projectName = 'Untitled project',
  String diagramTitle = 'ELECTRICAL SINGLE-LINE DIAGRAM',
}) =>
    paginatedRiserSheets(
      build: (r) => buildElectricalRiser(
          project: project,
          result: result,
          building: building,
          sourceChain: sourceChain,
          floorRange: r),
      levelCount: electricalRiserBandCount(project, result, building),
      chrome: chrome,
      projectName: projectName,
      diagramTitle: diagramTitle,
    );

/// The building single-line OVERVIEW as issuable PAGES (see the library
/// doc): `[whole]` when it prints at [kMinPlotLabelPt], else the top page +
/// one page per cut sub-tree (depth-first, in board order).
List<SldSheet> paginatedElectricalOverviewSheets({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  bool sourceChain = true,
  DrawingChrome? chrome,
  String projectName = 'Untitled project',
  String diagramTitle = 'ELECTRICAL SINGLE-LINE DIAGRAM',
}) {
  double minPt(SldSheet s) => sldSinglePageMinLabelPt(s,
      chrome: chrome, projectName: projectName, diagramTitle: diagramTitle);
  final children = <String, List<String>>{};
  final hasParent = <String>{};
  for (final p in project.panels) {
    for (final c in p.circuits) {
      final k = c.feedsPanelId;
      if (k != null && result.panels.containsKey(k)) {
        (children[p.id] ??= []).add(k);
        hasParent.add(k);
      }
    }
  }
  final orderIndex = {
    for (var i = 0; i < result.order.length; i++) result.order[i]: i,
  };
  List<String> kidsOf(String id) => [...(children[id] ?? const <String>[])]
    ..sort((a, b) => (orderIndex[a] ?? 0).compareTo(orderIndex[b] ?? 0));
  bool hasGrandchildren(String id) =>
      kidsOf(id).any((k) => kidsOf(k).isNotEmpty);

  // One sub-tree as pages ([root] null ⇒ the whole building).
  List<SldSheet> pagesFor(String? root) {
    final whole = buildElectricalOverview(
        project: project,
        result: result,
        sourceChain: sourceChain,
        subtreeRootId: root);
    final roots = root != null
        ? [root]
        : [
            for (final id in result.order)
              if (!hasParent.contains(id)) id,
          ];
    if (minPt(whole) >= kMinPlotLabelPt - 1e-9) return [whole];
    final splittable = roots.any(hasGrandchildren);
    final directCount =
        roots.fold<int>(0, (n, r) => n + kidsOf(r).length);
    if (!splittable && directCount < 2) return [whole];
    final top = splittable
        ? buildElectricalOverview(
            project: project,
            result: result,
            sourceChain: sourceChain,
            subtreeRootId: root,
            maxDepth: 1)
        : whole;
    // Round 34 (electrical-drawings-4-overview-pagination-leaves-top-page-
    // below-floor) — a wide FLAT tier is width-bound: cutting sub-trees left
    // the depth-1 top page itself below the floor. Re-check it, and when it
    // is still too small split the roots' direct sub-boards into the fewest
    // equal chunks whose every page prints at the floor (the source spine
    // rides the first chunk; a single-board chunk is the last resort).
    var tops = [top];
    if (minPt(top) < kMinPlotLabelPt - 1e-9) {
      final direct = [
        for (final r in roots) ...kidsOf(r),
      ];
      for (var g = 2; g <= direct.length; g++) {
        final size = (direct.length / g).ceil();
        final chunks = [
          for (var i = 0; i < direct.length; i += size)
            direct.sublist(i, (i + size).clamp(0, direct.length)).toSet(),
        ];
        final pages = [
          for (var i = 0; i < chunks.length; i++)
            buildElectricalOverview(
                project: project,
                result: result,
                sourceChain: sourceChain && i == 0,
                subtreeRootId: root,
                maxDepth: splittable ? 1 : null,
                rootChildIds: chunks[i]),
        ];
        tops = pages;
        if (pages.every((p) => minPt(p) >= kMinPlotLabelPt - 1e-9)) break;
      }
    }
    return [
      ...tops,
      if (splittable)
        for (final r in roots)
          for (final k in kidsOf(r))
            if (kidsOf(k).isNotEmpty) ...pagesFor(k),
    ];
  }

  return pagesFor(null);
}

/// The paginated electrical RISER as one multi-page vector PDF (`Sheet i of
/// N` on every page's title block).
Uint8List electricalRiserToPdf({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  BuildingLevels? building,
  bool sourceChain = true,
  DrawingChrome? chrome,
  String title = 'iSystem electrical building riser',
  String diagramTitle = 'ELECTRICAL SINGLE-LINE DIAGRAM',
  String projectName = 'Untitled project',
}) =>
    electricalSldSheetsToPdf(
      sheets: paginatedElectricalRiserSheets(
          project: project,
          result: result,
          building: building,
          sourceChain: sourceChain,
          chrome: chrome,
          projectName: projectName,
          diagramTitle: diagramTitle),
      title: title,
      diagramTitle: diagramTitle,
      chrome: chrome,
      projectName: projectName,
    );

/// The paginated building single-line OVERVIEW as one multi-page vector PDF.
Uint8List electricalOverviewToPdf({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  bool sourceChain = true,
  DrawingChrome? chrome,
  String title = 'iSystem electrical single-line (overview)',
  String diagramTitle = 'ELECTRICAL SINGLE-LINE DIAGRAM',
  String projectName = 'Untitled project',
}) =>
    electricalSldSheetsToPdf(
      sheets: paginatedElectricalOverviewSheets(
          project: project,
          result: result,
          sourceChain: sourceChain,
          chrome: chrome,
          projectName: projectName,
          diagramTitle: diagramTitle),
      title: title,
      diagramTitle: diagramTitle,
      chrome: chrome,
      projectName: projectName,
    );
