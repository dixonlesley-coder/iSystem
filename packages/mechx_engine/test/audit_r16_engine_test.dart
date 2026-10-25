// Round 16 — engine-side regressions (2026-10-18).
//
//   riser-function-transfer-scheme  the FUNCTION suffix reads the solved flow
//                                   path: GT -> transfer pump -> roof tank is
//                                   TRANSFER up to (and into) the tank, and
//                                   every pipe the roof tank feeds — the
//                                   down-risers included — is GRAVITASI.
//   ahu-intake-leaf-phantom         an AHU's bare fresh-air leaf is an
//                                   intake: no phantom 50 L/s supply load,
//                                   sized on the unit's delivered airflow,
//                                   flowing INTO the unit.
//   downfeed-prv                    a drawn PRV holds its setpoint below it
//                                   in the gravity solve, and the downfeed
//                                   delivery nodes are judged for fixture
//                                   over-pressure.
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, int f,
        {NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's',
        x: x,
        y: 0,
        floorIndex: f,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {EdgeKind k = EdgeKind.run, bool rev = false}) =>
    NetEdge(
        id: id,
        fromId: rev ? b : a,
        toId: rev ? a : b,
        service: ServiceType.coldWater,
        kind: k);

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
    net, const SizingContext(),
    leafDemand: const {ServiceType.coldWater: FlowRate(0)},
    leafFixtureUnits: const {ServiceType.coldWater: 2.0});

void main() {
  group('riser-function-transfer-scheme', () {
    // GT -> P (transfer pump) -> J0 -(riser)- J3 -> RT (roof tank, L3)
    // -> K3 -(risers)- K2 - K1, fixtures off K2 and K1.
    Network build({bool flipAll = false, int seed = 0}) {
      bool rev(int i) => flipAll && ((seed >> i) & 1) == 1;
      return Network(nodes: [
        _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('P', 20, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n('J0', 40, 0),
        _n('J3', 40, 3),
        _n('RT', 60, 3, role: NodeRole.plant, c: NodeComponent.roofTank),
        _n('K3', 80, 3),
        _n('K2', 80, 2),
        _n('K1', 80, 1),
        _n('f1', 100, 1, role: NodeRole.fixture),
        _n('f2', 100, 2, role: NodeRole.fixture),
      ], edges: [
        _e('suc', 'GT', 'P', rev: rev(0)),
        _e('dis', 'P', 'J0', rev: rev(1)),
        _e('tr', 'J0', 'J3', k: EdgeKind.riser, rev: rev(2)),
        _e('in', 'J3', 'RT', rev: rev(3)),
        _e('out', 'RT', 'K3', rev: rev(4)),
        _e('r32', 'K3', 'K2', k: EdgeKind.riser, rev: rev(5)),
        _e('r21', 'K2', 'K1', k: EdgeKind.riser, rev: rev(6)),
        _e('b1', 'K1', 'f1', rev: rev(7)),
        _e('b2', 'K2', 'f2', rev: rev(8)),
      ]);
    }

    const expected = <String, RiserFunction?>{
      'suc': null, // suction: fed from the ground tank, not boosted
      'dis': RiserFunction.transfer,
      'tr': RiserFunction.transfer,
      'in': RiserFunction.transfer, // the tank INLET is the lift, never gravity
      'out': RiserFunction.gravitasi,
      'r32': RiserFunction.gravitasi,
      'r21': RiserFunction.gravitasi,
      'b1': RiserFunction.gravitasi,
      'b2': RiserFunction.gravitasi,
    };

    test('every pipe reads its flow-path function, under any drawing', () {
      for (var seed = 0; seed < 64; seed++) {
        final net = build(flipAll: seed > 0, seed: seed * 37);
        final flow = flowFromBySizing(_size(net));
        for (final e in net.edges) {
          expect(
              riserFunctionFor(net, e, downfeed: true, flowFrom: flow),
              expected[e.id],
              reason: 'seed $seed ${e.id}');
        }
      }
    });

    test('a booster set hung off the roof tank is BOOSTER, upstream GRAVITASI',
        () {
      final net = Network(nodes: [
        _n('RT', 0, 3, role: NodeRole.plant, c: NodeComponent.roofTank),
        _n('T', 20, 3),
        _n('B', 40, 3, role: NodeRole.plant, c: NodeComponent.boosterSet),
        _n('f', 60, 3, role: NodeRole.fixture),
        _n('g', 20, 2, role: NodeRole.fixture),
      ], edges: [
        _e('rt', 'RT', 'T'),
        _e('tb', 'T', 'B'),
        _e('bf', 'B', 'f'),
        _e('tg', 'T', 'g', k: EdgeKind.riser),
      ]);
      final flow = flowFromBySizing(_size(net));
      RiserFunction? fn(String id) => riserFunctionFor(
          net, net.edgeById(id)!, downfeed: true, flowFrom: flow);
      expect(fn('rt'), RiserFunction.gravitasi);
      expect(fn('tb'), RiserFunction.gravitasi);
      expect(fn('tg'), RiserFunction.gravitasi);
      expect(fn('bf'), RiserFunction.booster);
    });

    test('upfeed GT -> pump -> riser -> fixtures is BOOSTER past the pump', () {
      final net = Network(nodes: [
        _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('P', 20, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n('J0', 40, 0),
        _n('J2', 40, 2),
        _n('f', 60, 2, role: NodeRole.fixture),
      ], edges: [
        _e('suc', 'GT', 'P'),
        _e('dis', 'P', 'J0'),
        _e('r', 'J0', 'J2', k: EdgeKind.riser),
        _e('b', 'J2', 'f'),
      ]);
      final flow = flowFromBySizing(_size(net));
      RiserFunction? fn(String id) => riserFunctionFor(
          net, net.edgeById(id)!, downfeed: false, flowFrom: flow);
      expect(fn('suc'), isNull);
      expect(fn('dis'), RiserFunction.booster);
      expect(fn('r'), RiserFunction.booster);
      expect(fn('b'), RiserFunction.booster);
    });
  });

  group('ahu-intake-leaf-phantom', () {
    NetNode an(String id, double x, double y,
            {NodeRole role = NodeRole.main, NodeComponent? c, FlowRate? q}) =>
        NetNode(
            id: id,
            sheetId: 's',
            x: x,
            y: y,
            floorIndex: 0,
            role: role,
            component: c,
            airflow: q);
    const q = FlowRate(0.3);
    Network build(String oaId, String ahuId) => Network(nodes: [
          an(oaId, 0, 0),
          an(ahuId, 40, 0, role: NodeRole.plant, c: NodeComponent.ahu),
          an('j', 80, 0),
          an('d1', 120, -20,
              role: NodeRole.fixture, c: NodeComponent.supplyDiffuser, q: q),
          an('d2', 120, 20,
              role: NodeRole.fixture, c: NodeComponent.supplyDiffuser, q: q),
        ], edges: [
          NetEdge(id: 'oa1', fromId: oaId, toId: ahuId, service: ServiceType.duct),
          NetEdge(id: 'aj', fromId: ahuId, toId: 'j', service: ServiceType.duct),
          const NetEdge(id: 'j1', fromId: 'j', toId: 'd1', service: ServiceType.duct),
          const NetEdge(id: 'j2', fromId: 'j', toId: 'd2', service: ServiceType.duct),
        ]);

    test('intake carries the delivered 0.3 + 0.3 = 0.6 m³/s INTO the AHU', () {
      for (final ids in const [('oa', 'ahu'), ('zz', 'a0'), ('a', 'z')]) {
        final net = build(ids.$1, ids.$2);
        final s = autoSizeNetwork(net, const SizingContext(),
            leafDemand: const {ServiceType.duct: FlowRate(0.05)},
            nodeFlowDemand: const {'d1': q, 'd2': q});
        // The supply trunk carries exactly the drawn 0.6 (no phantom 0.05).
        expect(s['aj']!.flow.cubicMetersPerSecond, closeTo(0.6, 1e-12));
        expect(s['aj']!.flowFromId, ids.$2);
        // The intake: the same 0.6 m³/s, flowing from the open leaf in.
        expect(s['oa1']!.flow.cubicMetersPerSecond, closeTo(0.6, 1e-12));
        expect(s['oa1']!.flowFromId, ids.$1);
        // Same duct as the trunk (equal airflow, equal sizing basis).
        expect(s['oa1']!.diameter.inMillimeters,
            s['aj']!.diameter.inMillimeters);
        // What LEAVES the AHU is 0.6, not 0.65.
        final leaving = [
          for (final id in ['oa1', 'aj'])
            if (s[id]!.flowFromId == ids.$2) s[id]!.flow.cubicMetersPerSecond,
        ].fold<double>(0, (a, b) => a + b);
        expect(leaving, closeTo(0.6, 1e-12));
      }
    });
  });

  group('downfeed-prv', () {
    // 20 floors × 3.5 m; roof tank at the roof (70 m). A gravity riser of
    // ceiling mains m_i (3.5·i + 3.2 m) with one fixture f_i per floor at
    // 3.5·i + 1.1 m. FRICTIONLESS (no sizing) so every figure is exact:
    // head(f_i) = 70 − (3.5·i + 1.1).
    final building = BuildingLevels(
        [for (var i = 0; i < 20; i++) Floor('L$i', const Length(3.5))]);
    const target = Pressure(225000);
    final targetHead = headFromPressure(target).meters;

    Network build(Set<int> prvFloors) {
      final nodes = <NetNode>[
        const NetNode(
            id: 'RT',
            sheetId: 's',
            x: 0,
            y: 0,
            floorIndex: 19,
            role: NodeRole.plant,
            component: NodeComponent.roofTank),
      ];
      final edges = <NetEdge>[];
      var above = 'RT';
      for (var i = 19; i >= 0; i--) {
        if (prvFloors.contains(i)) {
          nodes.add(NetNode(
              id: 'P$i',
              sheetId: 's',
              x: 0,
              y: 0,
              floorIndex: i,
              component: NodeComponent.prv));
          edges.add(NetEdge(
              id: 'rp$i',
              fromId: above,
              toId: 'P$i',
              service: ServiceType.coldWater,
              kind: EdgeKind.riser));
          above = 'P$i';
          nodes.add(NetNode(id: 'm$i', sheetId: 's', x: 0, y: 0, floorIndex: i));
          edges.add(NetEdge(
              id: 'pm$i',
              fromId: above,
              toId: 'm$i',
              service: ServiceType.coldWater));
        } else {
          nodes.add(NetNode(id: 'm$i', sheetId: 's', x: 0, y: 0, floorIndex: i));
          edges.add(NetEdge(
              id: 'r$i',
              fromId: above,
              toId: 'm$i',
              service: ServiceType.coldWater,
              kind: EdgeKind.riser));
        }
        nodes.add(NetNode(
            id: 'f$i',
            sheetId: 's',
            x: 40,
            y: 0,
            floorIndex: i,
            role: NodeRole.fixture));
        edges.add(NetEdge(
            id: 'b$i',
            fromId: 'm$i',
            toId: 'f$i',
            service: ServiceType.coldWater));
        above = 'm$i';
      }
      return Network(nodes: nodes, edges: edges);
    }

    DownfeedSolution solve(Set<int> prvs) => solveDownfeed(
          net: build(prvs),
          service: ServiceType.coldWater,
          tankId: 'RT',
          edgeFlows: const {},
          sizing: const {},
          calibrationBySheet: const {'s': ScaleCalibration(0.01)},
          building: building,
          targetResidual: target,
        );

    double kpa(double head) => pressureFromHead(Head(head)).inKiloPascals;

    test('no PRV: the ground fixture reads 70 − 1.1 = 68.9 m, over relief', () {
      final s = solve(const {});
      expect(s.residualPressure['f0']!.inKiloPascals, closeTo(kpa(68.9), 1e-6));
      final over = downfeedOverPressure(s);
      // Over the 392.3 kPa (40 m) fixture max: 70 − 3.5·i − 1.1 > 40.0 ⇒
      // i ≤ 8 (i = 8 gives 40.9 m).
      expect({for (final o in over) o.nodeId},
          {for (var i = 0; i <= 8; i++) 'f$i'});
      final f0 = over.firstWhere((o) => o.nodeId == 'f0');
      expect(f0.overRelief, isTrue); // 675.7 kPa ≥ 490.3 kPa
    });

    test('one PRV on L9 holds the setpoint: head below = H_set + drop', () {
      final s = solve(const {9});
      // P9 sits at the L9 ceiling (34.7 m) and arrives with 70 − 34.7 =
      // 35.3 m > H_set, so it outputs H_set.
      expect(s.residualPressure['P9']!.inKiloPascals,
          closeTo(kpa(targetHead), 1e-6));
      // f0: H_set + (34.7 − 1.1) = H_set + 33.6 m.
      expect(s.residualPressure['f0']!.inKiloPascals,
          closeTo(kpa(targetHead + 33.6), 1e-6));
      expect(s.noFlowStaticPressure['f0']!.inKiloPascals,
          closeTo(kpa(targetHead + 33.6), 1e-6));
      // Above the PRV, unchanged: f12 = 70 − 43.1 = 26.9 m.
      expect(s.residualPressure['f12']!.inKiloPascals,
          closeTo(kpa(26.9), 1e-6));
    });

    test('PRVs on L14 / L9 / L4 zone the riser: no fixture over the limit',
        () {
      final s = solve(const {14, 9, 4});
      // P14 arrives with only 70 − 52.2 = 17.8 m < H_set: it passes the flow
      // through, so f10 reads plain gravity 70 − 36.1 = 33.9 m. P9 (35.3 m
      // in) and P4 (H_set + 17.5 m in) reduce, so each of their zone bottoms
      // reads H_set + (3.5·k + 3.2 − (3.5·(k−4) + 1.1)) = H_set + 16.1 m.
      expect(s.residualPressure['f10']!.inKiloPascals,
          closeTo(kpa(33.9), 1e-6));
      for (final f in ['f5', 'f0']) {
        expect(s.residualPressure[f]!.inKiloPascals,
            closeTo(kpa(targetHead + 16.1), 1e-6),
            reason: f);
      }
      expect(kpa(targetHead + 16.1), lessThan(392.3));
      expect(downfeedOverPressure(s), isEmpty);
    });

    test('a PRV arriving BELOW its setpoint passes the flow through', () {
      // A PRV on L18 arrives with 70 − (63 + 3.2) = 3.8 m < H_set: no change.
      final a = solve(const {18});
      final b = solve(const {});
      expect(a.residualPressure['f0']!.pascals,
          closeTo(b.residualPressure['f0']!.pascals, 1e-6));
    });
  });
}
