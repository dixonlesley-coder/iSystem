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

import 'dart:math' as math;
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
///     ('LANJUT (lembar lain): <first>..<last>'). Round 45 — the band is cut
///     into UNITS (a board fed from another band + its same-band
///     descendants, so a band of PARENT boards splits too), each page draws
///     only its chunk + the chunk's own ancestor path (never the whole band
///     above it), and an empty storey band is skipped. The
///     `belowMinLabelPt` flag stays only as the backstop for a single board
///     that cannot reach the floor by itself.
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
          Map<String, String> lengths = const {},
          Map<int, String> notes = const {}}) =>
      buildElectricalRiser(
          project: project,
          result: result,
          building: building,
          sourceChain: sourceChain,
          floorRange: r,
          hidePanelIds: hide,
          typicalNames: names,
          typicalFeederLengths: lengths,
          bandNotes: notes);
  final levels = electricalRiserBandCount(project, result, building);
  List<SldSheet> floorPages(int a, int b,
          {Set<String> hide = const {},
          Map<String, String> names = const {},
          Map<String, String> lengths = const {}}) =>
      paginatedRiserSheets(
        build: (r) => build(
            r == null
                ? (a == 0 && b == levels - 1 ? null : (lo: a, hi: b))
                : (lo: a + r.lo, hi: a + r.hi),
            hide: hide,
            names: names,
            lengths: lengths),
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
  final lengths = <String, String>{};
  for (final g in electricalRiserTypicalGroups(project, result, building)
      .values) {
    if (!bandIllegible(floorOf[g.first] ?? 0)) continue;
    hide.addAll(g.skip(1));
    names[g.first] =
        electricalTypicalName([for (final id in g) nameOf[id] ?? id]);
    // Round 45 — the typical node's feeder prints its members' length range.
    final len = electricalRiserTypicalFeederLength(project, result, g);
    if (len != null) lengths[g.first] = len;
  }
  final collapsed = hide.isEmpty
      ? plain
      : floorPages(0, levels - 1, hide: hide, names: names, lengths: lengths);
  if (collapsed.every((p) => p.belowMinLabelPt == null)) return collapsed;

  // 2. Column pages for each band still too wide BY ITSELF.
  //
  // Round 45 (elec-props-11-riser-parent-band-never-paginates,
  // electrical-sim-10-riser-column-pages-keep-full-band-width) — a band is
  // split into UNITS: each board whose feeding parent is on ANOTHER band,
  // together with its same-band descendants (parents included — a band of
  // sub-mains is split like any other). A page draws its chunk of units plus
  // ONLY the chunk's own ancestor path (cropped off the page, a LANJUT stub at
  // the edge); every other board — the rest of the band, the other bands,
  // the chunk's off-band children — is hidden, so the riser channel, the
  // branch annotations and the stubs come from the drawn boards only and the
  // page is as narrow as its chunk. A unit that is still too wide alone is
  // refined into its same-band children's units (its root rides each).
  final allIds = [
    for (final id in result.order)
      if (result.panels.containsKey(id) && !hide.contains(id)) id,
  ];
  final orderIndex = {for (var i = 0; i < allIds.length; i++) allIds[i]: i};
  final parentOfId = <String, String>{
    for (final p in project.panels)
      for (final c in p.circuits)
        if (c.feedsPanelId != null) c.feedsPanelId!: p.id,
  };
  final childrenOf = <String, List<String>>{};
  for (final id in allIds) {
    final par = parentOfId[id];
    if (par != null) (childrenOf[par] ??= []).add(id);
  }
  String label(String id) => names[id] ?? nameOf[id] ?? id;
  Set<String> ancestorsOf(Iterable<String> ids) {
    final out = <String>{};
    for (final id in ids) {
      for (var p = parentOfId[id]; p != null && out.add(p);
          p = parentOfId[p]) {}
    }
    return out;
  }

  // Everything a page drawing [members] hides.
  Set<String> pageHide(Set<String> members) {
    final keep = {...members, ...ancestorsOf(members)};
    return {
      ...hide,
      for (final id in allIds)
        if (!keep.contains(id)) id,
    };
  }

  // A unit rooted at [root] on band [f]: the root + its same-band descendants.
  List<String> unitOf(String root, int f) {
    final out = <String>[root];
    for (var i = 0; i < out.length; i++) {
      for (final k in childrenOf[out[i]] ?? const <String>[]) {
        if (floorOf[k] == f) out.add(k);
      }
    }
    out.sort((a, b) => orderIndex[a]!.compareTo(orderIndex[b]!));
    return out;
  }

  SldSheet pageFor(int f, Set<String> members,
          {Map<int, String> notes = const {}}) =>
      build((lo: f, hi: f),
          hide: pageHide(members),
          names: names,
          lengths: lengths,
          notes: notes);
  final legibleUnit = <String, bool>{};
  bool unitLegible(int f, List<String> u) =>
      legibleUnit['$f|${u.join(',')}'] ??= legible(pageFor(f, u.toSet()));

  // Per wide band: its (refined) units, then greedy chunks of whole units.
  final chunksOf = <int, List<List<String>>>{};
  for (var f = 0; f < levels; f++) {
    final onBand = [
      for (final id in allIds)
        if (floorOf[id] == f) id,
    ];
    if (onBand.isEmpty) continue; // an empty storey band: nothing to split
    if (legible(pageFor(f, onBand.toSet()))) continue;
    // Units, grouped by parent (siblings contiguous), riser order within.
    final roots = [
      for (final id in onBand)
        if (parentOfId[id] == null || floorOf[parentOfId[id]] != f) id,
    ]..sort((a, b) {
        final pa = orderIndex[parentOfId[a]] ?? -1;
        final pb = orderIndex[parentOfId[b]] ?? -1;
        return pa != pb
            ? pa.compareTo(pb)
            : orderIndex[a]!.compareTo(orderIndex[b]!);
      });
    var units = [for (final r in roots) unitOf(r, f)];
    // Refine a unit too wide alone into its root's same-band children's units.
    for (var guard = 0; guard < onBand.length; guard++) {
      var changed = false;
      final next = <List<String>>[];
      for (final u in units) {
        final sameBandKids = [
          for (final k in childrenOf[u.first] ?? const <String>[])
            if (floorOf[k] == f) k,
        ];
        if (u.length > 1 && sameBandKids.isNotEmpty && !unitLegible(f, u)) {
          next.addAll([for (final k in sameBandKids) unitOf(k, f)]);
          changed = true;
        } else {
          next.add(u);
        }
      }
      units = next;
      if (!changed) break;
    }
    if (units.length < 2) continue;
    bool fits(int i, int k) =>
        legible(pageFor(f, {for (final u in units.sublist(i, i + k)) ...u}));
    final chunks = <List<String>>[];
    var prevK = 1;
    var i = 0;
    while (i < units.length) {
      final remaining = units.length - i;
      var k = 1;
      final guess = math.min(prevK, remaining);
      if (guess > 1 &&
          fits(i, guess) &&
          (guess == remaining || !fits(i, guess + 1))) {
        k = guess;
      } else {
        var lo = 1, hi = remaining;
        while (lo <= hi) {
          final mid = (lo + hi) ~/ 2;
          if (mid == 1 || fits(i, mid)) {
            k = mid;
            lo = mid + 1;
          } else {
            hi = mid - 1;
          }
        }
      }
      chunks.add([for (final u in units.sublist(i, i + k)) ...u]);
      prevK = k;
      i += k;
    }
    chunksOf[f] = chunks;
  }
  if (chunksOf.isEmpty) return collapsed;

  // Everything beyond each wide band's FIRST chunk is drawn only on its own
  // column page; the pages that still show the parent board name them.
  final beyondFirst = <String>{
    for (final c in chunksOf.values)
      for (final chunk in c.skip(1)) ...chunk,
  };
  final firstChunkOf = <String>{
    for (final c in chunksOf.values) ...c.first,
  };
  Map<int, String> parentNotes(Set<String> elsewhere) {
    final byBand = <int, List<String>>{};
    for (final id in allIds) {
      if (!elsewhere.contains(id)) continue;
      final par = parentOfId[id];
      if (par == null || floorOf[par] == floorOf[id]) continue;
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
    final chunks = chunksOf[f]!;
    final out = <SldSheet>[];
    for (final chunk in chunks) {
      final mine = chunk.toSet();
      // The gutter note names, PER PARENT of this chunk, its sibling boards
      // drawn on the other sheets (never a range spanning other parents).
      final parts = <String>[];
      final parents = <String?>{
        for (final id in chunk)
          if (parentOfId[id] == null || floorOf[parentOfId[id]] != f)
            parentOfId[id],
      };
      for (final par in parents) {
        final others = [
          for (final c in chunks)
            for (final id in c)
              if (!mine.contains(id) &&
                  parentOfId[id] == par &&
                  (par == null || floorOf[par] != f))
                id,
        ];
        if (others.isEmpty) continue;
        parts.add(others.length == 1
            ? label(others.first)
            : '${label(others.first)}..${label(others.last)}');
      }
      out.add(flagged(pageFor(f, mine,
          notes: parts.isEmpty ? const {} : {f: parts.join(', ')})));
    }
    return out;
  }

  final restNotes = parentNotes(beyondFirst);
  // The rest pages keep each wide band's FIRST chunk (off the page, it only
  // carries its parents' LANJUT stubs) and hide the other chunks.
  final restHide = <String>{
    ...hide,
    for (final c in chunksOf.entries)
      for (final chunk in c.value.skip(1)) ...chunk,
    for (final id in allIds)
      if (chunksOf.containsKey(floorOf[id]) && !firstChunkOf.contains(id)) id,
  };
  List<SldSheet> restPages(int a, int b) => paginatedRiserSheets(
        build: (r) => build(
            r == null ? (lo: a, hi: b) : (lo: a + r.lo, hi: a + r.hi),
            hide: restHide,
            names: names,
            lengths: lengths,
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
    if (chunksOf.containsKey(f)) {
      pages.addAll(columnPages(f));
      f--;
      continue;
    }
    var a = f;
    while (a - 1 >= 0 && !chunksOf.containsKey(a - 1)) {
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
