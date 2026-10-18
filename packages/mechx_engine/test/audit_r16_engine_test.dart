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
import 'package:mechx_engine/network/network.dart';
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
          NetEdge(id: 'j1', fromId: 'j', toId: 'd1', service: ServiceType.duct),
          NetEdge(id: 'j2', fromId: 'j', toId: 'd2', service: ServiceType.duct),
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
}
