// Backlog K-2 (2026-11-20, office backlog (d)) — the delivered field at a
// water meter feeding a ground tank is on MAINS pressure in every reference
// building with a meter feed (office, apartment, shophouse x 3, tower).
//
// Every meter sits at its floor + 0.5 m and feeds a ground tank on the
// Lantai 1 slab (0.0 m) over a 3.0 m run + its 0.5 m drop = 3.5 m (backlog
// D-3); the available mains head is the default 10 m (`mainsHeadProvider`).
// The meter itself reads that head (no rise, no friction to itself):
// 10 x 9.81 = 98.1 kPa, flowing and no-flow. The tank inlet keeps
// 10 − (0.0 − 0.5) − hf, Hazen–Williams C150 on the sized feed:
//   building   fill Q (L/s)              DN   hf (m)     inlet (m)
//   office     10 000 / 4 h = 0.694444   25   0.312966   10.187034
//   apartment  20 000 / 4 h = 1.388889   32   0.339507   10.160493
//   shophouse  500 / 4 h    = 0.034722   15   0.014672   10.485328
//   tower      150 000 / 4 h = 10.416667 100  0.055125   10.444875
// with hf = 10.67 x 3.5 x Q^1.852 / (150^1.852 x D^4.8704).
//
// Before K-2 the meters read the solve's back-calculation: office −13.979
// (upfeed, from GT at 0 kPa), apartment 376.860, shophouse 110.180, tower
// 1128.601 kPa (downfeed, the roof tank's gravity walked back down the
// transfer riser). The ground tanks: office 0.000 kPa (the pump side);
// since fix round 6 (C7) an open downfeed ground tank reads 0 kPa too (it
// read the roof tank's gravity walked back: apartment 394.042, shophouse
// 115.345, tower 1139.324 kPa).
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/store/tank_fill_store.dart';

import '../packages/mechx_engine/test/reference/apartment.dart';
import '../packages/mechx_engine/test/reference/office.dart';
import '../packages/mechx_engine/test/reference/shophouse.dart';
import '../packages/mechx_engine/test/reference/tower.dart';

ProviderContainer _load(ReferenceBuilding b, FeedStrategy feed) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(sheetsControllerProvider.notifier).loadSheets(
    [
      for (final s in b.sheets)
        Sheet(id: s.id, name: s.name, sizePx: const Size(2384, 1684)),
    ],
    sheetFloors: {for (final s in b.sheets) s.id: s.floorIndex},
  );
  final project = c.read(projectControllerProvider.notifier)
    ..setFloors(b.building.floors);
  for (final MapEntry(:key, :value) in b.calibrations.entries) {
    project.setCalibration(key, value);
  }
  c.read(feedStrategyProvider.notifier).set(feed);
  c.read(occupancyProvider.notifier).set(b.occupancy);
  c.read(populationProvider.notifier).set(b.population);
  c.read(demandUseProvider.notifier).pick(b.demandUse);
  c.read(networkControllerProvider.notifier).loadNetwork(b.network);
  return c;
}

typedef _Case = ({
  String name,
  ReferenceBuilding Function() build,
  FeedStrategy feed,
  Map<String, String> meters, // meter -> tank
  double hf,
  double tankKpa,
});

final List<_Case> _cases = [
  (
    name: 'office',
    build: buildOffice,
    feed: FeedStrategy.upfeed,
    meters: {'WM': 'GT'},
    hf: 0.312966,
    tankKpa: 0.0,
  ),
  (
    name: 'apartment',
    build: buildApartment,
    feed: FeedStrategy.downfeed,
    meters: {'WM': 'GT'},
    hf: 0.339507,
    tankKpa: 0.0,
  ),
  (
    name: 'shophouse',
    build: buildShophouse,
    feed: FeedStrategy.downfeed,
    meters: {'WM_A': 'GT_A', 'WM_B': 'GT_B', 'WM_C': 'GT_C'},
    hf: 0.014672,
    tankKpa: 0.0,
  ),
  (
    name: 'tower',
    build: buildTower,
    feed: FeedStrategy.downfeed,
    meters: {'WM': 'GT'},
    hf: 0.055125,
    tankKpa: 0.0,
  ),
];

void main() {
  for (final k in _cases) {
    test('${k.name}: each meter reads the mains head, the tank inlet the '
        'remaining head, the tank its pump-side figure', () {
      final c = _load(k.build(), k.feed);
      final field = c.read(residualByNodeProvider);
      final noFlow = (c.read(upfeedDeliveredProvider)?.noFlowStaticPressure ??
          c.read(downfeedDeliveredProvider)!.noFlowStaticPressure);
      final checks = {
        for (final m in c.read(mainsPressureChecksProvider)) m.meterId: m,
      };
      expect(checks.keys.toSet(), k.meters.keys.toSet());
      for (final MapEntry(key: wm, value: gt) in k.meters.entries) {
        // 10 m x 9.81 kPa/m.
        expect(field[wm]!.inKiloPascals, closeTo(98.1, 1e-9), reason: wm);
        expect(noFlow[wm]!.inKiloPascals, closeTo(98.1, 1e-9), reason: wm);
        final m = checks[wm]!;
        expect(m.tankId, gt);
        expect(m.liftM, closeTo(-0.5, 1e-9));
        expect(m.frictionM, closeTo(k.hf, 5e-6));
        // 10 − (−0.5) − hf.
        expect(m.inletHead.meters, closeTo(10.5 - k.hf, 5e-6));
        expect(field[gt]!.inKiloPascals, closeTo(k.tankKpa, 5e-4), reason: gt);
      }
    });
  }

  test('only the meter-feed nodes follow the mains input; every other node '
      'is byte-identical', () {
    for (final k in _cases) {
      final c = _load(k.build(), k.feed);
      final before = Map.of(c.read(residualByNodeProvider));
      c.read(mainsHeadProvider.notifier).set(20.0);
      final after = c.read(residualByNodeProvider);
      expect(after.keys.toSet(), before.keys.toSet(), reason: k.name);
      for (final id in before.keys) {
        if (k.meters.containsKey(id)) {
          // 20 m x 9.81 = 196.2 kPa.
          expect(after[id]!.inKiloPascals, closeTo(196.2, 1e-9),
              reason: '${k.name} $id');
        } else {
          expect(after[id]!.pascals, before[id]!.pascals,
              reason: '${k.name} $id');
        }
      }
    }
  });
}
