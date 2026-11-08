// Round 55 (2026-10-18) — app-side pins:
//
//   fire-convergence-7-jockey-role-depends-on-node-id-order — the duty /
//     standby / jockey roles of a fire pump room (and so the MDP ways) are
//     invariant to renaming the pumps: a jockey on hand-picked DN25 legs is
//     the jockey whether its id sorts before or after the main pumps.
//   fire-convergence-7-hand-picked-jockey-leg-carries-duty-flow — those
//     DN25 legs carry the jockey's own flow, so Review raises no velocity
//     warning on them.
//   plumbing-hvac-convergence-5-hot-water-never-pressure-solved — the hot
//     network is pressure-solved through its heater: the hot index shower
//     sizes the pump (it sits at exactly the target residual) and the lower
//     hot showers are over-pressure judged.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c,
        PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: c?.role ?? role,
        component: c,
        fixture: fixture);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.coldWater,
        EdgeKind k = EdgeKind.run,
        Diameter? size}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: s, kind: k, sizeOverride: size);

void _seed(ProviderContainer c, int floors) {
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < floors; i++) Floor('L$i', Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
}

/// GT -> S -> {P1, P2, the jockey} -> D -> a 4-storey hydrant riser with a box
/// per floor; the jockey's two legs hand-picked at DN25.
Network _pumpRoom(String jockeyId) {
  const dn25 = Diameter(0.025);
  return Network(nodes: [
    _n('GT', 0, 0, c: NodeComponent.groundTank),
    _n('S', 100, 0),
    _n('P1', 200, 0, c: NodeComponent.pump),
    _n('P2', 200, 100, c: NodeComponent.pump),
    _n(jockeyId, 200, 200, c: NodeComponent.pump),
    _n('D', 300, 0),
    for (var f = 0; f < 4; f++) ...[
      _n('R$f', 400, 0, floor: f),
      _n('B$f', 450, 0, floor: f, c: NodeComponent.hydrantBox),
    ],
  ], edges: [
    _e('g', 'GT', 'S', s: ServiceType.fireHydrant),
    _e('s1', 'S', 'P1', s: ServiceType.fireHydrant),
    _e('d1', 'P1', 'D', s: ServiceType.fireHydrant),
    _e('s2', 'S', 'P2', s: ServiceType.fireHydrant),
    _e('d2', 'P2', 'D', s: ServiceType.fireHydrant),
    _e('sj', 'S', jockeyId, s: ServiceType.fireHydrant, size: dn25),
    _e('dj', jockeyId, 'D', s: ServiceType.fireHydrant, size: dn25),
    _e('dr', 'D', 'R0', s: ServiceType.fireHydrant),
    for (var f = 1; f < 4; f++)
      _e('r$f', 'R${f - 1}', 'R$f',
          s: ServiceType.fireHydrant, k: EdgeKind.riser),
    for (var f = 0; f < 4; f++)
      _e('b$f', 'R$f', 'B$f', s: ServiceType.fireHydrant),
  ]);
}

/// Upfeed from a ground tank: a cold riser with a lavatory per floor and a
/// heater WH on L0 whose hot riser (drawn 10 m further out than the cold
/// riser) feeds a shower per floor.
Network _hotel(int floors) => Network(nodes: [
      _n('GT', 0, 0, c: NodeComponent.groundTank),
      _n('WH', 100, 300, role: NodeRole.plant),
      for (var f = 0; f < floors; f++) ...[
        _n('C$f', 100, 0, floor: f),
        _n('LV$f', 200, 0,
            floor: f,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.lavatory),
        _n('H$f', 1100, 300, floor: f),
        _n('SH$f', 1200, 300,
            floor: f, role: NodeRole.fixture, fixture: PlumbingFixture.shower),
      ],
    ], edges: [
      _e('g', 'GT', 'C0'),
      _e('wf', 'C0', 'WH'),
      _e('hm', 'WH', 'H0', s: ServiceType.hotWater),
      for (var f = 0; f < floors; f++) ...[
        if (f > 0) _e('c$f', 'C${f - 1}', 'C$f', k: EdgeKind.riser),
        if (f > 0)
          _e('h$f', 'H${f - 1}', 'H$f', s: ServiceType.hotWater, k: EdgeKind.riser),
        _e('lv$f', 'C$f', 'LV$f'),
        _e('sh$f', 'H$f', 'SH$f', s: ServiceType.hotWater),
      ],
    ]);

void main() {
  group('fire pump roles invariant to the pump ids', () {
    for (final id in ['JP', 'PZ']) {
      test('jockey "$id" on DN25: standby P2, jockey $id, no assumption, '
          'main-pump legs alike, no velocity warning on the jockey legs', () {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        _seed(c, 4);
        c.read(networkControllerProvider.notifier).loadNetwork(_pumpRoom(id));
        final bind = c.read(mepDutyBindingProvider);
        expect(bind.fireStandbyPumpNodeIds, {'P2'});
        expect(bind.fireJockeyPumpNodeIds, {id});
        expect(bind.fireAssumedJockeyPumpNodeIds, isEmpty);
        final sz = c.read(sizingProvider);
        expect(sz['s2']!.diameter.inMillimeters,
            sz['s1']!.diameter.inMillimeters);
        expect(sz['d2']!.diameter.inMillimeters,
            sz['d1']!.diameter.inMillimeters);
        expect(sz['sj']!.diameter.inMillimeters, 25);
        // The jockey legs carry the jockey's own (1 %) flow.
        expect(sz['sj']!.flow.cubicMetersPerSecond,
            lessThan(0.02 * sz['s1']!.flow.cubicMetersPerSecond));
        final kinds = {for (final i in c.read(designIssuesProvider)) i.kind};
        expect(kinds, isNot(contains('water-velocity:sj')));
        expect(kinds, isNot(contains('water-velocity:dj')));
        expect(kinds.where((k) => k.startsWith('fire-jockey-assumed')),
            isEmpty);
      });
    }
  });

  group('hot water pressure-solved through the heater', () {
    final target = SupplyDesignCriteria.recommended()
        .targetFixtureResidualPressure;

    ProviderContainer hotel(int floors, {bool hot = true}) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seed(c, floors);
      c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
      var net = _hotel(floors);
      if (!hot) {
        net = Network(
            nodes: net.nodes,
            edges: [
              for (final e in net.edges)
                if (e.service == ServiceType.coldWater) e,
            ]);
      }
      c.read(networkControllerProvider.notifier).loadNetwork(net);
      return c;
    }

    test(
        'the hot index shower governs: it sits at exactly the target '
        'residual, the pump head is raised to hold it, and the pump duty '
        'reads that head', () {
      final c = hotel(6);
      final sol = c.read(solveProvider)!;
      final top = sol.residualPressure['SH5'];
      expect(top, isNotNull);
      expect(sol.deliveryNodeIds, contains('SH5'));
      expect(sol.criticalNodeId, 'SH5');
      expect(top!.pascals, closeTo(target.pascals, 1));
      // Every hot and cold delivery node at or above the target.
      for (final id in sol.deliveryNodeIds) {
        expect(sol.residualPressure[id]!.pascals,
            greaterThanOrEqualTo(target.pascals - 1),
            reason: id);
      }
      final cold = hotel(6, hot: false).read(solveProvider)!;
      expect(sol.requiredPumpHead.meters,
          greaterThan(cold.requiredPumpHead.meters));
      expect(c.read(pumpDutyProvider)!.head.meters,
          closeTo(sol.requiredPumpHead.meters, 1e-9));
    });

    test('a cold-only project is unchanged (no hot node in the field)', () {
      final c = hotel(6, hot: false);
      final sol = c.read(solveProvider)!;
      expect(sol.residualPressure.keys.any((k) => k.startsWith('SH')),
          isFalse);
    });

    test('the lower hot showers of a 16-storey upfeed are over-pressure '
        'judged (392 kPa fixture maximum)', () {
      final c = hotel(16);
      final over = {
        for (final o in c.read(upfeedOverPressureProvider)) o.nodeId,
      };
      expect(over, contains('SH0'));
      expect(c.read(residualByNodeProvider)['SH0']!.inKiloPascals,
          greaterThan(392));
    });
  });
}
