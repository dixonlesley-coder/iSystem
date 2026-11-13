// Reference building 3 (office) — app regressions for the pass-2 fixes.
//
// O2 — on UPFEED the zone table hangs from the solved upfeed field, never
//      the legacy 255 kPa budget walk.
// O4 — the auto-wired MEP feeder carrying a fire pump is specified FRC by
//      the sync (no `life-safety-feeder-cable` against its own feeder),
//      reverted when the life-safety way goes, never over a hand-set type.
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/electrical/model.dart';
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

  group('O4 — the MEP feeder cable follows the life-safety way', () {
    Future<ProviderContainer> office() async {
      final b = buildOffice();
      final c = _load(
          floors: b.building.floors,
          sheets: kOfficeSheets,
          net: b.network,
          occupancy: b.occupancy);
      c.read(electricalProjectProvider.notifier).setProject(b.electrical);
      await Future<void>.delayed(Duration.zero);
      return c;
    }

    ElectricalCircuitView feeder(ProviderContainer c) {
      final w = c
          .read(electricalProjectProvider)
          .panels
          .firstWhere((p) => p.id == kOfficeMainPanelId)
          .circuits
          .firstWhere((x) => x.id == kMepEquipmentFeederId);
      return (cableType: w.cableType);
    }

    test('a fire pump on the MEP board makes its auto-wired feeder FRC; no '
        'life-safety-feeder-cable warning', () async {
      final c = await office();
      addTearDown(c.dispose);
      expect(feeder(c).cableType, 'FRC');
      final kinds = [for (final i in c.read(designIssuesProvider)) i.kind];
      expect(kinds.where((k) => k.contains('life-safety-feeder-cable')),
          isEmpty);
      // Sized on the FRC (XLPE 90 °C) table: 110 A x 1.25 = 137.5 <= 144 A
      // at 35 mm² (the PVC table would need 70 mm², Iz 171). Backlog B-1:
      // the auto-sized cable then grows for the 1.6 x 125 = 200 A
      // selectivity floor, still on the FRC table: 50 mm² 175 ✗, 70 mm² 222
      // ✓ (the PVC table would need 95 mm², Iz 207).
      final r = c
          .read(electricalResultProvider)
          .panels[kOfficeMainPanelId]!
          .circuits
          .firstWhere((x) => x.circuitId == kMepEquipmentFeederId);
      expect(r.cable.csaMm2, 70);
      expect(r.cable.deratedIz.amperes, 222);
    });

    test('the FRC the sync set is cleared when the fire pump goes; a '
        'hand-set type is never touched', () async {
      final c = await office();
      addTearDown(c.dispose);
      final b = buildOffice();
      Network withoutFire() => Network(
            nodes: [
              for (final n in b.network.nodes)
                if (n.id != 'FP') n,
            ],
            edges: [
              for (final e in b.network.edges)
                if (e.fromId != 'FP' && e.toId != 'FP') e,
            ],
          );
      c.read(networkControllerProvider.notifier).loadNetwork(withoutFire());
      await Future<void>.delayed(Duration.zero);
      expect(feeder(c).cableType, isNull);
      // Back again: FRC again.
      c.read(networkControllerProvider.notifier).loadNetwork(b.network);
      await Future<void>.delayed(Duration.zero);
      expect(feeder(c).cableType, 'FRC');
      // The engineer specifies NYY by hand: the sync leaves it (and the
      // judge then flags it, as for any hand-specified non-FRC feeder).
      c.read(electricalProjectProvider.notifier).setCircuit(
          kOfficeMainPanelId, kMepEquipmentFeederId,
          cableType: 'NYY');
      c.read(networkControllerProvider.notifier).loadNetwork(withoutFire());
      await Future<void>.delayed(Duration.zero);
      c.read(networkControllerProvider.notifier).loadNetwork(b.network);
      await Future<void>.delayed(Duration.zero);
      expect(feeder(c).cableType, 'NYY');
    });

    test('backlog E-2: the auto-FRC record is persisted — after a reload the '
        'sync still reverts its own FRC when the fire pump goes', () async {
      final c = await office();
      addTearDown(c.dispose);
      final b = buildOffice();
      // Save: the feeder carries the sync's FRC + the persisted record.
      final saved = ElectricalProject.fromJson(jsonDecode(
              jsonEncode(c.read(electricalProjectProvider).toJson()))
          as Map<String, dynamic>);
      final w = saved.panels
          .firstWhere((p) => p.id == kOfficeMainPanelId)
          .circuits
          .firstWhere((x) => x.id == kMepEquipmentFeederId);
      expect((w.cableType, w.cableTypeAuto), ('FRC', true));
      // Reopen in a fresh app (no in-memory record), then remove the fire
      // pump: the FRC the sync set is cleared.
      final r = _load(
          floors: b.building.floors,
          sheets: kOfficeSheets,
          net: b.network,
          occupancy: b.occupancy);
      addTearDown(r.dispose);
      r.read(electricalProjectProvider.notifier).setProject(saved);
      await Future<void>.delayed(Duration.zero);
      expect(feeder(r).cableType, 'FRC');
      r.read(networkControllerProvider.notifier).loadNetwork(Network(
            nodes: [
              for (final n in b.network.nodes)
                if (n.id != 'FP') n,
            ],
            edges: [
              for (final e in b.network.edges)
                if (e.fromId != 'FP' && e.toId != 'FP') e,
            ],
          ));
      await Future<void>.delayed(Duration.zero);
      expect(feeder(r).cableType, isNull);
      // A hand-set FRC (no record) survives a reload and the removal.
      final hand = _handFrc(saved);
      final h = _load(
          floors: b.building.floors,
          sheets: kOfficeSheets,
          net: b.network,
          occupancy: b.occupancy);
      addTearDown(h.dispose);
      h.read(electricalProjectProvider.notifier).setProject(hand);
      await Future<void>.delayed(Duration.zero);
      h.read(networkControllerProvider.notifier).loadNetwork(Network(
            nodes: [
              for (final n in b.network.nodes)
                if (n.id != 'FP') n,
            ],
            edges: [
              for (final e in b.network.edges)
                if (e.fromId != 'FP' && e.toId != 'FP') e,
            ],
          ));
      await Future<void>.delayed(Duration.zero);
      expect(feeder(h).cableType, 'FRC');
    });
  });
}

/// The saved project with the MEP feeder's FRC re-marked as HAND-set (no
/// `cableTypeAuto` record), through JSON as an older file would carry it.
ElectricalProject _handFrc(ElectricalProject p) {
  final j = jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
  for (final panel in j['panels'] as List) {
    for (final c in (panel as Map<String, dynamic>)['circuits'] as List) {
      (c as Map<String, dynamic>).remove('cableTypeAuto');
    }
  }
  return ElectricalProject.fromJson(j);
}

typedef ElectricalCircuitView = ({String? cableType});
