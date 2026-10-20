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
///
/// Round 44 (regression-riser-width-bound-band-still-illegible) — a band
/// too WIDE for the sheet (many boards side by side on one storey) cannot be
/// fixed by any floor split, so two further steps run, only when the floor
/// pagination leaves a page below the floor:
///  1. TYPICAL collapse — on each illegible band, identical sibling leaf
///     boards ([electricalRiserTypicalGroups]) are drawn as ONE node
///     'PHB UNIT 101..116 (TIPIKAL x16)' (its feeder + fan-out drawn once);
///  2. COLUMN pages — a band still illegible is split into board chunks of
///     the largest size k that prints at [kMinPlotLabelPt] (binary search),
///     each its own page whose gutter names the boards on the other sheets
///     ('LANJUT (lembar lain): <first>..<last>'); a parent board on the same
///     band rides every chunk. The `belowMinLabelPt` flag stays only as the
///     backstop for a single board that cannot reach the floor by itself.
List<SldSheet> paginatedElectricalRiserSheets({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  BuildingLevels? building,
  bool sourceChain = true,
  DrawingChrome? chrome,
  String projectName = 'Untitled project',
  String diagramTitle = 'ELECTRICAL SINGLE-LINE DIAGRAM',
}) {
  double minPt(SldSheet s) => sldSinglePageMinLabelPt(s,
      chrome: chrome, projectName: projectName, diagramTitle: diagramTitle);
  bool legible(SldSheet s) => minPt(s) >= kMinPlotLabelPt - 1e-9;
  SldSheet build(({int lo, int hi})? r,
          {Set<String> hide = const {},
          Map<String, String> names = const {},
          Map<int, String> notes = const {}}) =>
      buildElectricalRiser(
          project: project,
          result: result,
          building: building,
          sourceChain: sourceChain,
          floorRange: r,
          hidePanelIds: hide,
          typicalNames: names,
          bandNotes: notes);
  final levels = electricalRiserBandCount(project, result, building);
  List<SldSheet> floorPages(int a, int b,
          {Set<String> hide = const {},
          Map<String, String> names = const {}}) =>
      paginatedRiserSheets(
        build: (r) => build(
            r == null
                ? (a == 0 && b == levels - 1 ? null : (lo: a, hi: b))
                : (lo: a + r.lo, hi: a + r.hi),
            hide: hide,
            names: names),
        levelCount: b - a + 1,
        chrome: chrome,
        projectName: projectName,
        diagramTitle: diagramTitle,
      );

  final plain = floorPages(0, levels - 1);
  if (plain.every((p) => p.belowMinLabelPt == null)) return plain;

  // 1. Typical collapse on the bands that are illegible on their own page.
  final floorOf = electricalRiserFloorOf(project, result, building);
  final nameOf = {for (final p in project.panels) p.id: p.name};
  final illegibleBand = <int, bool>{};
  bool bandIllegible(int f) =>
      illegibleBand[f] ??= !legible(build((lo: f, hi: f)));
  final hide = <String>{};
  final names = <String, String>{};
  for (final g in electricalRiserTypicalGroups(project, result, building)
      .values) {
    if (!bandIllegible(floorOf[g.first] ?? 0)) continue;
    hide.addAll(g.skip(1));
    names[g.first] =
        electricalTypicalName([for (final id in g) nameOf[id] ?? id]);
  }
  final collapsed = hide.isEmpty
      ? plain
      : floorPages(0, levels - 1, hide: hide, names: names);
  if (collapsed.every((p) => p.belowMinLabelPt == null)) return collapsed;

  // 2. Column pages for each band still too wide BY ITSELF (judged with
  // every other band's boards hidden, so a parent band is never blamed for
  // its children's width).
  final allIds = [
    for (final id in result.order)
      if (result.panels.containsKey(id) && !hide.contains(id)) id,
  ];
  final parentIds = <String>{
    for (final p in project.panels)
      for (final c in p.circuits)
        if (c.feedsPanelId != null) p.id,
  };
  final parentOfId = <String, String>{
    for (final p in project.panels)
      for (final c in p.circuits)
        if (c.feedsPanelId != null) c.feedsPanelId!: p.id,
  };
  String label(String id) => names[id] ?? nameOf[id] ?? id;
  // Boards off band [f], except the ancestors of the band's boards (a
  // feeder's parent stays: its legs + annotations are part of the width).
  Set<String> notOn(int f) {
    final keep = <String>{};
    for (final id in allIds) {
      if (floorOf[id] != f) continue;
      for (var p = parentOfId[id]; p != null && keep.add(p);
          p = parentOfId[p]) {}
    }
    return {
      for (final id in allIds)
        if (floorOf[id] != f && !keep.contains(id)) id,
    };
  }
  // Per wide band: the boards that can be split (non-parents) and the chunk
  // size k — the largest whose first chunk prints at the floor in isolation.
  final chunkOf = <int, ({List<String> chunkable, int k})>{};
  for (var f = 0; f < levels; f++) {
    final others = notOn(f);
    if (legible(
        build((lo: f, hi: f), hide: {...hide, ...others}, names: names))) {
      continue;
    }
    final chunkable = [
      for (final id in allIds)
        if (floorOf[id] == f && !parentIds.contains(id)) id,
    ];
    if (chunkable.length < 2) continue;
    bool fits(int k) => legible(build((lo: f, hi: f),
        hide: {...hide, ...others, ...chunkable.skip(k)}, names: names));
    var lo = 1, hi = chunkable.length - 1, k = 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (fits(mid)) {
        k = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    chunkOf[f] = (chunkable: chunkable, k: k);
  }
  if (chunkOf.isEmpty) return collapsed;

  // Everything beyond each wide band's FIRST chunk is drawn only on its own
  // column page; the pages that still show the parent board name them.
  final beyondFirst = <String>{
    for (final c in chunkOf.values) ...c.chunkable.skip(c.k),
  };
  Map<int, String> parentNotes(Set<String> elsewhere) {
    final byBand = <int, List<String>>{};
    for (final id in allIds) {
      if (!elsewhere.contains(id)) continue;
      final par = parentOfId[id];
      if (par == null) continue;
      (byBand[floorOf[par] ?? 0] ??= []).add(id);
    }
    return {
      for (final e in byBand.entries)
        e.key: '${label(e.value.first)}..${label(e.value.last)}',
    };
  }

  SldSheet flagged(SldSheet p) {
    final pt = minPt(p);
    return pt < kMinPlotLabelPt - 1e-9 ? p.withBelowMinLabelPt(pt) : p;
  }

  List<SldSheet> columnPages(int f) {
    final c = chunkOf[f]!;
    final out = <SldSheet>[];
    for (var s = 0; s < c.chunkable.length; s += c.k) {
      final e = s + c.k < c.chunkable.length ? s + c.k : c.chunkable.length;
      final chunk = c.chunkable.sublist(s, e).toSet();
      final onBand = [
        for (final id in c.chunkable)
          if (!chunk.contains(id)) id,
      ];
      final elsewhere = <String>{
        ...beyondFirst.where((id) => floorOf[id] != f),
        ...onBand,
      };
      out.add(flagged(build((lo: f, hi: f),
          hide: {...hide, ...elsewhere},
          names: names,
          notes: onBand.isEmpty
              ? const {}
              : {f: '${label(onBand.first)}..${label(onBand.last)}'})));
    }
    return out;
  }

  final restNotes = parentNotes(beyondFirst);
  List<SldSheet> restPages(int a, int b) => paginatedRiserSheets(
        build: (r) => build(
            r == null ? (lo: a, hi: b) : (lo: a + r.lo, hi: a + r.hi),
            hide: {...hide, ...beyondFirst},
            names: names,
            notes: restNotes),
        levelCount: b - a + 1,
        chrome: chrome,
        projectName: projectName,
        diagramTitle: diagramTitle,
      );

  // Floors TOP first: each wide band contributes its column pages; the
  // contiguous runs of other floors paginate by floor range as before.
  final pages = <SldSheet>[];
  var f = levels - 1;
  while (f >= 0) {
    if (chunkOf.containsKey(f)) {
      pages.addAll(columnPages(f));
      f--;
      continue;
    }
    var a = f;
    while (a - 1 >= 0 && !chunkOf.containsKey(a - 1)) {
      a--;
    }
    pages.addAll(restPages(a, f));
    f = a - 1;
  }
  return pages;
}

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
