// Round 37 (2026-10-18) — mech-sim-5-force-main-into-stp-unroots-building-
// drain.
//
// A tank is an ejector PIT only on a drawn ejector's SUCTION side
// (`ejectorPitOf`). An STP the force main DISCHARGES into stays the sink root
// of the drainage tree, so the building drain from a 12-storey stack carries
// the whole stack (12 x the per-floor fixture DFU) out of K1 — never a
// phantom leaf load flowing up from the STP.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.drainage, kind: k);

/// L1..L12 soil stack K12 -> ... -> K1 -> 'out' -> STP (ground tank, L1), a
/// 20-DFU fixture on every floor. Basement (floor 0): two WCs into PIT, then
/// [ejectors] ejector(s) EJ_i -> check valve CE_i -> header EH, riser EH ->
/// EH1 (L1), and the force main lands on the STP ([intoStp]) or on K1.
Network _building({int ejectors = 1, bool intoStp = true}) {
  final nodes = <NetNode>[
    _n('STP', 0, 0, floor: 1, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('PIT', 300, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('w1', 340, 0, role: NodeRole.fixture),
    _n('w2', 340, 40, role: NodeRole.fixture),
    _n('EH', 200, 0),
    _n('EH1', 200, 0, floor: 1),
  ];
  final edges = <NetEdge>[
    _e('pw1', 'w1', 'PIT'),
    _e('pw2', 'w2', 'PIT'),
    _e('ehr', 'EH', 'EH1', k: EdgeKind.riser),
    _e('fm', 'EH1', intoStp ? 'STP' : 'K1'),
    _e('out', 'K1', 'STP'),
  ];
  for (var i = 1; i <= ejectors; i++) {
    nodes
      ..add(_n('EJ$i', 260, 40.0 * i, role: NodeRole.plant, c: NodeComponent.pump))
      ..add(_n('CE$i', 230, 40.0 * i, c: NodeComponent.checkValve));
    edges
      ..add(_e('s$i', 'PIT', 'EJ$i'))
      ..add(_e('d$i', 'EJ$i', 'CE$i'))
      ..add(_e('c$i', 'CE$i', 'EH'));
  }
  for (var f = 1; f <= 12; f++) {
    nodes
      ..add(_n('K$f', 100, 0, floor: f))
      ..add(_n('fx$f', 140, 0, floor: f, role: NodeRole.fixture));
    edges.add(_e('b$f', 'fx$f', 'K$f'));
    if (f > 1) edges.add(_e('k$f', 'K$f', 'K${f - 1}', k: EdgeKind.riser));
  }
  return Network(nodes: nodes, edges: edges);
}

void main() {
  for (final ejectors in [1, 2]) {
    test('$ejectors ejector(s), force main into the STP: the building drain '
        'carries the whole 12-floor stack out of K1', () {
      final fu = <String, double>{};
      final s = autoSizeNetwork(
        _building(ejectors: ejectors),
        const SizingContext(),
        leafDemand: {ServiceType.drainage: const FlowRate(0)},
        leafFixtureUnits: {ServiceType.drainage: 20},
        fixtureUnitsOut: fu,
      );
      // Each floor's fixture branch carries its own DFU (the engine's
      // per-fixture figure); the stack is 12 of them.
      final per = fu['b1']!;
      expect(per, greaterThan(0));
      expect(s['out']!.flowFromId, 'K1');
      expect(fu['out'], closeTo(12 * per, 1e-9));
      // The stack flows DOWN: k2 (K2 -> K1) carries 11 floors.
      expect(s['k2']!.flowFromId, 'K2');
      expect(fu['k2'], closeTo(11 * per, 1e-9));
      // No reducer in the direction of flow.
      expect(s['out']!.diameter.inMillimeters,
          greaterThanOrEqualTo(s['k2']!.diameter.inMillimeters));
      // The same drawing with the force main tied into K1 sizes the building
      // drain on the stack plus the pumped pit (the ejector's own load).
      final fuK1 = <String, double>{};
      final sK1 = autoSizeNetwork(
        _building(ejectors: ejectors, intoStp: false),
        const SizingContext(),
        leafDemand: {ServiceType.drainage: const FlowRate(0)},
        leafFixtureUnits: {ServiceType.drainage: 20},
        fixtureUnitsOut: fuK1,
      );
      expect(sK1['out']!.flowFromId, 'K1');
      expect(fuK1['out']!, greaterThanOrEqualTo(12 * per));
      // The STP drawing's building drain is never smaller than the stack it
      // drains (the K1 drawing's k2 is the same stack).
      expect(s['out']!.diameter.inMillimeters,
          greaterThanOrEqualTo(sK1['k2']!.diameter.inMillimeters));
    });
  }
}
