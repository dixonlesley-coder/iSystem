// Reference building 3 (office) — app regressions for the pass-2 fixes.
//
// O2 — on UPFEED the zone table hangs from the solved upfeed field, never
//      the legacy 255 kPa budget walk.
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import '../packages/mechx_engine/test/reference/office.dart';

ProviderContainer _load(
    {required List<Floor> floors,
    required List<String> sheets,
    required Network net,
    Occupancy occupancy = Occupancy.public}) {
  final c = ProviderContainer();
  c.read(sheetsControllerProvider.notifier).loadSheets(
    [
      for (final s in sheets)
        Sheet(id: s, name: s, sizePx: const Size(2384, 1684)),
    ],
    sheetFloors: {for (var i = 0; i < sheets.length; i++) sheets[i]: i},
  );
  final p = c.read(projectControllerProvider.notifier)..setFloors(floors);
  for (final s in sheets) {
    p.setCalibration(s, const ScaleCalibration(0.02));
  }
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
  c.read(occupancyProvider.notifier).set(occupancy);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

/// A tall upfeed tower: GT → P → riser R0..R(n-1), one flush-valve WC per
/// floor 1.0 m off the riser, 4.0 m storeys.
Network _tower(int n) {
  NetNode node(String id, double x, int f,
          {NodeComponent? c, PlumbingFixture? fx}) =>
      NetNode(
        id: id,
        sheetId: 's$f',
        x: x,
        y: 500,
        floorIndex: f,
        role: c?.role ?? (fx != null ? NodeRole.fixture : NodeRole.main),
        component: c,
        fixture: fx,
      );
  final nodes = <NetNode>[
    node('GT', 100, 0, c: NodeComponent.groundTank),
    node('P', 150, 0, c: NodeComponent.pump),
    for (var f = 0; f < n; f++) ...[
      node('R$f', 250, f),
      node('WC$f', 300, f, fx: PlumbingFixture.waterClosetFlushValve),
    ],
  ];
  final edges = <NetEdge>[
    const NetEdge(
        id: 'g', fromId: 'GT', toId: 'P', service: ServiceType.coldWater),
    const NetEdge(
        id: 'p', fromId: 'P', toId: 'R0', service: ServiceType.coldWater),
    for (var f = 1; f < n; f++)
      NetEdge(
          id: 'r$f',
          fromId: 'R${f - 1}',
          toId: 'R$f',
          service: ServiceType.coldWater,
          kind: EdgeKind.riser),
    for (var f = 0; f < n; f++)
      NetEdge(
          id: 'b$f',
          fromId: 'R$f',
          toId: 'WC$f',
          service: ServiceType.coldWater),
  ];
  return Network(nodes: nodes, edges: edges);
}

void main() {
  group('O2 — the upfeed zone table reads the solved field', () {
    test('the office is ONE zone, no PRV: the highest solved fixture static '
        '(38.539 − 1.1) × 9.81 = 367.275 kPa < 392.266', () {
      final b = buildOffice();
      final c = _load(
          floors: b.building.floors,
          sheets: kOfficeSheets,
          net: b.network,
          occupancy: b.occupancy);
      addTearDown(c.dispose);
      // Datum = GT (0.0) + the pump's no-flow head 38.539 m.
      expect(c.read(upfeedZoneDatumProvider)!.meters, closeTo(38.539, 5e-4));
      final zones = c.read(zonesProvider);
      expect([for (final z in zones) (z.bottomFloorIndex, z.topFloorIndex)],
          [(0, 3)]);
      final st = c.read(zoneStaticsProvider).single;
      expect(st.viaPrv, isFalse);
      expect(st.withinLimit, isTrue);
      expect(st.bottomStatic.inKiloPascals, closeTo(367.275, 2e-3));
      // The same field the upfeed over-pressure judge reads: nothing over.
      expect(c.read(upfeedOverPressureProvider), isEmpty);
    });

    test('a 16-storey upfeed tower still splits where the solved static '
        'exceeds 392.266 kPa', () {
      const n = 16;
      final c = _load(
        floors: [for (var i = 0; i < n; i++) Floor('L$i', const Length(4.0))],
        sheets: [for (var i = 0; i < n; i++) 's$i'],
        net: _tower(n),
      );
      addTearDown(c.dispose);
      final datum = c.read(upfeedZoneDatumProvider)!.meters;
      // The pump lifts to the top WC (60 + 1.1 m) plus friction + 225 kPa.
      expect(datum, greaterThan(60 + 1.1 + 225 / 9.81));
      final zones = c.read(zonesProvider);
      expect(zones.length, greaterThan(1));
      // The top zone is fed by the pump head; the zones below take PRVs.
      final statics = c.read(zoneStaticsProvider);
      expect(statics.where((z) => !z.viaPrv).length, 1);
      for (final z in statics) {
        expect(z.withinLimit, isTrue);
      }
    });
  });
}
