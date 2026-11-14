// Fix round 6 (2026-11-14) — the issued riser must not creep back to a
// multi-minute export. Operation counts, not wall-clock bounds:
//  * the riser label placer examines a small fraction of the obstacle boxes
//    a full scan would (the spatial index), and
//  * the paginator builds each distinct page variant once.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_symbols.dart' show equipmentNodeTags;
import 'package:mechx_engine/report/riser_pagination.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:test/test.dart';

import 'reference/shophouse.dart' as shop;

void main() {
  final b = shop.buildShophouse();
  final net = b.network;
  final sizing = autoSizeNetwork(net, const SizingContext(),
      leafDemand: const {},
      calibrationBySheet: b.calibrations,
      building: b.building);
  final lengths = {
    for (final e in net.edges)
      e.id: edgeLength(e, net,
          calibrationBySheet: b.calibrations, building: b.building),
  };
  SldSheet riser(({int lo, int hi})? r,
          {MechRiserPlant plant = MechRiserPlant.auto, int? part}) =>
      buildMechanicalRiserSld(
        network: net,
        sizing: sizing,
        building: b.building,
        edgeLengths: lengths,
        detailCallouts: true,
        nodeTags: equipmentNodeTags(net),
        notes: const ['Catatan 1'],
        floorRange: r,
        plant: plant,
        columnPart: part,
      );

  test('the riser placer examines under 10 % of the boxes a full scan would',
      () {
    final t0 = mechRiserObstacleTests, s0 = mechRiserObstacleScan;
    // The whole shophouse riser: its key circles still overprint, so the
    // pitch / band escalation re-draws it at every step (19 layouts).
    final s = riser(null);
    expect(s.prims, isNotEmpty);
    final tests = mechRiserObstacleTests - t0;
    final scan = mechRiserObstacleScan - s0;
    // Before the index every query visited every box: tests == scan
    // (~935 M box visits for this one build, ~1 s per layout). The index
    // visits ~2.4 % of them.
    expect(scan, greaterThan(0));
    expect(tests * 10, lessThan(scan),
        reason: 'the obstacle tests are a full scan again ($tests / $scan)');
  });

  test('the paginator builds each distinct page variant once', () {
    final calls = <String, int>{};
    SldSheet count(String k, SldSheet Function() f) {
      calls[k] = (calls[k] ?? 0) + 1;
      return f();
    }

    final pages = paginatedRiserSheets(
      build: (r) => count('b$r', () => riser(r)),
      buildWithoutExtras: (r) => count('w$r',
          () => riser(r)), // same sheet: only the call count matters here
      buildExtrasOnly: () => count('x', () => riser((lo: 0, hi: 0))),
      buildColumnPart: (r, k, bare) =>
          count('c$r$k$bare', () => riser(r, part: k)),
      buildPlantRow: (r, bare) =>
          count('r$r$bare', () => riser(r, plant: MechRiserPlant.row)),
      buildPlantPart: (r, k, bare) => count('p$r$k$bare',
          () => riser(r, plant: MechRiserPlant.split, part: k)),
      levelCount: b.building.levelCount,
    );
    expect(pages, isNotEmpty);
    expect(calls.values, everyElement(1), reason: '$calls');
  });
}
