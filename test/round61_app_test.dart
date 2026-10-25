// Round 61 (2026-10-18) — app-side fixes.
//
//   fire-convergence-13-assumed-jockey-picks-by-lexical-id-not-draw-order —
//     three identical fire pumps: the duty is the FIRST drawn and the
//     assumed jockey the LAST drawn, by draw order (tag number, then the
//     natural id order n9 < n10), never a String compare.
//   fire-convergence-13-dry-fdc-standpipe-phantom-55kw-pump — an FDC-only
//     (dry, brigade-fed) standpipe carries no phantom fire pump: no
//     firePumpDuty / jockey / FP-01, a 'brigade-fed' info stating the inlet
//     requirement instead of the unsatisfiable no-source warning.
//   plumbing-hvac-convergence-11-shared-return-peer-unit-fan-static-dropped
//     — two CRAH / AHUs with their own supplies on ONE shared return: each
//     fan's duty is its supply index + max(intake, the shared return's
//     static) + its 250 Pa internal static (identical units, identical
//     duties), never the return static on one unit only.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/room_air.dart'
    show AirEquipmentKind, defaultInternalStatic;
import 'package:mechx_engine/units.dart';

void _seed(ProviderContainer c, {int floors = 1, double h = 3.5}) {
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < floors; i++) Floor('L$i', Length(h))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
}

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c,
        int? tagNo}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c,
        tagNo: tagNo);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.fireHydrant, kind: k);

/// GT -> S -> three identical pumps (S -> P -> CV -> H), H -> a riser.
Network _room(List<String> pumpIds, {List<int?>? tags}) => Network(nodes: [
      _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('S', 100, 0),
      for (var i = 0; i < 3; i++) ...[
        _n(pumpIds[i], 200, i * 50.0,
            role: NodeRole.plant,
            c: NodeComponent.pump,
            tagNo: tags?[i]),
        _n('CV$i', 250, i * 50.0, c: NodeComponent.checkValve),
      ],
      _n('H', 300, 0),
      _n('R1', 300, 0, floor: 1),
    ], edges: [
      _e('g', 'GT', 'S'),
      for (var i = 0; i < 3; i++) ...[
        _e('s$i', 'S', pumpIds[i]),
        _e('p$i', pumpIds[i], 'CV$i'),
        _e('c$i', 'CV$i', 'H'),
      ],
      _e('r', 'H', 'R1', k: EdgeKind.riser),
    ]);

void main() {
  group('fire pump roles follow DRAW order', () {
    test('naturalIdCompare: n9 < n10, pA < pB', () {
      expect(naturalIdCompare('n9', 'n10'), lessThan(0));
      expect(naturalIdCompare('n10', 'n8'), greaterThan(0));
      expect(naturalIdCompare('pA', 'pC'), lessThan(0));
      expect(naturalIdCompare('n1', 'n1'), 0);
    });

    for (final ids in [
      ['n8', 'n9', 'n10'],
      ['pA', 'pB', 'pC'],
      ['n98', 'n99', 'n100'],
    ]) {
      test('$ids: duty ${ids.first}, standby ${ids[1]}, jockey ${ids.last}',
          () {
        final roles = parallelFirePumpRoles(_room(ids), ids.toSet(),
            bore: (_) => 100.0);
        expect(roles.jockey, {ids.last});
        expect(roles.assumedJockey, {ids.last});
        expect(roles.standby, {ids[1]});
      });
    }

    test('the persisted tag number outranks the id', () {
      // Ids sort the other way; the tag numbers say P-01 = z, P-03 = a.
      final roles = parallelFirePumpRoles(
          _room(['z', 'm', 'a'], tags: [1, 2, 3]), {'z', 'm', 'a'},
          bore: (_) => 100.0);
      expect(roles.jockey, {'a'});
      expect(roles.standby, {'m'});
    });
  });

  group('a dry (FDC-only) standpipe has no phantom fire pump', () {
    // FDC -> CV -> R0, a 6-storey hydrant riser R0..R5, a box on each floor.
    Network dry() => Network(nodes: [
          _n('FDC', 0, 0,
              role: NodeRole.fixture, c: NodeComponent.fireDeptConnection),
          _n('CV', 100, 0, c: NodeComponent.checkValve),
          for (var f = 0; f < 6; f++) ...[
            _n('R$f', 300, 0, floor: f),
            _n('HB$f', 400, 0,
                floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
          ],
        ], edges: [
          _e('f1', 'FDC', 'CV'),
          _e('f2', 'CV', 'R0'),
          for (var f = 1; f < 6; f++)
            _e('r$f', 'R${f - 1}', 'R$f', k: EdgeKind.riser),
          for (var f = 0; f < 6; f++) _e('hb$f', 'R$f', 'HB$f'),
        ]);

    test('no duty, no jockey, a dry basis and a brigade-fed info', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seed(c, floors: 6);
      c.read(networkControllerProvider.notifier).loadNetwork(dry());
      final bases = c.read(fireSystemBasesProvider);
      expect(bases, hasLength(1));
      final b = bases.single;
      expect(b.dry, isTrue);
      expect(b.duty, isNull);
      expect(b.jockey, isNull);
      expect(b.dryInletId, 'FDC');
      expect(c.read(firePumpDutyProvider), isNull);
      expect(c.read(fireJockeyDutyProvider), isNull);
      expect(c.read(governingFireBasisProvider), isNull);
      expect(c.read(fireAllGravityFedProvider), isTrue);
      // Inlet head: lift FDC (L0 surface) -> top outlet (5 x 3.5 + 1.2 m),
      // + the Class I 690 kPa residual (690000 / (1000 x 9.81) = 70.34 m),
      // + at least the 15 m friction allowance.
      const lower = 5 * 3.5 + 1.2 + 690000 / 9810 + 15;
      expect(b.dryRequiredInletHeadM, greaterThanOrEqualTo(lower - 1e-6));
      final issues = c.read(designIssuesProvider);
      expect(issues.map((i) => i.kind), contains('brigade-fed:FDC'));
      expect(issues.where((i) => i.kind.startsWith('no-source:')), isEmpty);
      // No drawn pump, so no fire-pump way on the panel feed either.
      expect(c.read(mepDutyBindingProvider).firePumpNodeIds, isEmpty);
    });
  });

  group('two AHUs on one shared return get equal duties', () {
    NetEdge air(String id, String a, String b, ServiceType s) =>
        NetEdge(id: id, fromId: a, toId: b, service: s, kind: EdgeKind.run);
    NetNode term(String id, double x, double y, NodeComponent c, double q) =>
        NetNode(
            id: id,
            sheetId: 's1',
            x: x,
            y: y,
            floorIndex: 0,
            role: NodeRole.fixture,
            component: c,
            airflow: FlowRate(q));
    Network net() => Network(nodes: [
          _n('ahuA', 0, 0, role: NodeRole.plant, c: NodeComponent.ahu),
          _n('ahuB', 0, 1000, role: NodeRole.plant, c: NodeComponent.ahu),
          term('sa1', 800, 0, NodeComponent.supplyDiffuser, 1.0),
          term('sb1', 800, 1000, NodeComponent.supplyDiffuser, 1.0),
          _n('rj', 400, 500),
          term('rg1', 900, 400, NodeComponent.returnGrille, 0.9),
          term('rg2', 900, 600, NodeComponent.returnGrille, 0.9),
        ], edges: [
          air('a1', 'ahuA', 'sa1', ServiceType.duct),
          air('b1', 'ahuB', 'sb1', ServiceType.duct),
          air('g1', 'rg1', 'rj', ServiceType.returnAir),
          air('g2', 'rg2', 'rj', ServiceType.returnAir),
          air('ra', 'rj', 'ahuA', ServiceType.returnAir),
          air('rb', 'rj', 'ahuB', ServiceType.returnAir),
        ]);

    test('duty = supply index + max(intake, return) + internal, both units',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seed(c);
      c.read(networkControllerProvider.notifier).loadNetwork(net());
      final duties = c.read(supplyFanDutiesByRootProvider);
      final sup = {
        for (final s in c.read(airSystemsProvider(ServiceType.duct)))
          s.fanNodeId: s,
      };
      final ret = c.read(airSystemsProvider(ServiceType.returnAir));
      expect(ret, hasLength(1), reason: 'one shared return system');
      final internal = defaultInternalStatic(AirEquipmentKind.ahu).pascals;
      for (final id in ['ahuA', 'ahuB']) {
        final s = sup[id]!;
        final expected = s.stat.pascals -
            s.intake.pascals +
            (s.intake.pascals > ret.single.stat.pascals
                ? s.intake.pascals
                : ret.single.stat.pascals) +
            internal;
        expect(duties[id]!.totalStaticPressure.pascals,
            closeTo(expected, 1e-6),
            reason: id);
        expect(ret.single.stat.pascals, greaterThan(0));
      }
      expect(duties['ahuA']!.totalStaticPressure.pascals,
          closeTo(duties['ahuB']!.totalStaticPressure.pascals, 1e-6));
    });
  });

  // Round 61 (fire-convergence-13-yard-hydrants-rated-as-building-
  // standpipe) — a yard-only system (pillar hydrants on a site main, no
  // building stack) is rated on the yard basis: 38 L/s (SNI 03-1735) at the
  // 350 kPa outlet residual (350000 / 9810 = 35.68 m) + the larger of the
  // sized friction to the hydrants and the 15 m allowance — never the
  // 31.5 L/s / 690 kPa Class I standpipe.
  group('yard (pillar) hydrants are rated on the yard basis', () {
    Network yard() => Network(nodes: [
          _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
          _n('PD', 100, 0, role: NodeRole.plant, c: NodeComponent.pump),
          for (var k = 0; k < 6; k++) ...[
            _n('Y$k', 200.0 + 4000 * k, 0),
            _n('PH$k', 200.0 + 4000 * k, 100,
                role: NodeRole.fixture, c: NodeComponent.pillarHydrant),
          ],
        ], edges: [
          _e('g', 'GT', 'PD'),
          _e('y0', 'PD', 'Y0'),
          for (var k = 1; k < 6; k++) _e('y$k', 'Y${k - 1}', 'Y$k'),
          for (var k = 0; k < 6; k++) _e('l$k', 'Y$k', 'PH$k'),
        ]);

    test('flow 38 L/s, head >= 35.68 + 15 m, no standpipe printed', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seed(c);
      c.read(networkControllerProvider.notifier).loadNetwork(yard());
      final b = c.read(fireSystemBasesProvider).single;
      expect(b.flow.inLitersPerSecond, closeTo(38.0, 1e-9));
      expect(b.standpipe, isNull);
      expect(b.head.meters,
          greaterThanOrEqualTo(350000 / 9810 + 15 - 1e-6));
      // The governing pump and the report's standpipe follow the yard basis.
      expect(c.read(firePumpDutyProvider)!.flow.inLitersPerSecond,
          closeTo(38.0, 1e-9));
      expect(c.read(reportStandpipeDesignProvider), isNull);
    });
  });
}
