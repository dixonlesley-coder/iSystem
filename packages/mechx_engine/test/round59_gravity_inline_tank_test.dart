// Round 59 (plumbing-hvac-convergence-9-inline-interceptor-roots-building-
// drain) — an INLINE ground tank on a gravity service (a kitchen grease
// interceptor, a rainwater-harvesting tank with an overflow) is a node the
// flow passes THROUGH when the component also ends at a demand-free
// outfall: the building drain is never rooted at the interceptor, and the
// result never depends on the node ids.
//
// First principles: the 10-storey WC stack carries 10 x 6 = 60 DFU, the
// kitchen branch 2 x 2 = 4 DFU. Both join at J, so the sewer connection
// J -> OUT carries 60 + 4 = 64 DFU, more than 2 WCs on a run => DN100
// (`minDrainMmForWcCount`); the interceptor's outlet GI -> J carries only
// the kitchen's 4 DFU => DN50 (the IPC 710.1(2) DN50 row, 6 DFU), flowing
// GI -> J.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

BuildingLevels _floors(int n) => BuildingLevels(
    [for (var i = 0; i < n; i++) Floor('L$i', const Length(3.5))]);

/// [outfall]: 'leaf' (a bare outfall OUT) or 'stp' (a degree-1 STP ground
/// tank OUT). [gi] is the interceptor's node id.
(Network, Map<String, double>, Set<String>) _drain(String outfall, String gi) {
  const s = ServiceType.drainage;
  final nodes = <NetNode>[
    _n('K1', 0, role: NodeRole.fixture),
    _n('K2', 10, role: NodeRole.fixture),
    _n('KJ', 20),
    _n(gi, 40, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('J', 60),
    outfall == 'stp'
        ? _n('OUT', 100, role: NodeRole.plant, c: NodeComponent.groundTank)
        : _n('OUT', 100),
  ];
  final edges = <NetEdge>[
    _e('k1', 'K1', 'KJ', s),
    _e('k2', 'K2', 'KJ', s),
    _e('kg', 'KJ', gi, s),
    _e('gj', gi, 'J', s),
    _e('jo', 'J', 'OUT', s),
    _e('sj', 'S0', 'J', s),
  ];
  final dfu = <String, double>{'K1': 2, 'K2': 2};
  final wcs = <String>{};
  for (var f = 0; f < 10; f++) {
    nodes.add(_n('S$f', 80, floor: f));
    nodes.add(_n('W$f', 85, floor: f, role: NodeRole.fixture));
    edges.add(_e('w$f', 'W$f', 'S$f', s));
    dfu['W$f'] = 6;
    wcs.add('W$f');
    if (f > 0) edges.add(_e('s$f', 'S$f', 'S${f - 1}', s, k: EdgeKind.riser));
  }
  return (Network(nodes: nodes, edges: edges), dfu, wcs);
}

Network _flipShuffle(Network net, math.Random rnd) {
  final edges = [
    for (final e in net.edges)
      rnd.nextBool()
          ? NetEdge(
              id: e.id,
              fromId: e.toId,
              toId: e.fromId,
              service: e.service,
              kind: e.kind)
          : e,
  ]..shuffle(rnd);
  final nodes = [...net.nodes]..shuffle(rnd);
  return Network(nodes: nodes, edges: edges);
}

(Map<String, EdgeSizing>, Map<String, double>) _size(
    Network net, Map<String, double> dfu, Set<String> wcs) {
  final fu = <String, double>{};
  final r = autoSizeNetwork(
    net,
    const SizingContext(),
    leafDemand: const {},
    nodeDrainageUnits: dfu,
    waterClosetNodeIds: wcs,
    building: _floors(10),
    fixtureUnitsOut: fu,
  );
  return (r, fu);
}

void main() {
  for (final outfall in ['leaf', 'stp']) {
    for (final gi in ['GI', 'ZGI', 'A0']) {
      test(
          'inline interceptor $gi upstream of a $outfall outfall: the '
          'sewer connection carries 64 DFU DN100, the interceptor outlet '
          '4 DFU DN50', () {
        final (net, dfu, wcs) = _drain(outfall, gi);
        final (r, fu) = _size(net, dfu, wcs);
        expect(fu['jo'], closeTo(64, 1e-9));
        expect(r['jo']!.diameter.inMillimeters, closeTo(100, 1e-9));
        expect(r['jo']!.flowFromId, 'J');
        expect(fu['gj'], closeTo(4, 1e-9));
        expect(r['gj']!.diameter.inMillimeters, closeTo(50, 1e-9));
        expect(r['gj']!.flowFromId, gi);
      });
    }
  }

  test(
      'seeded property: ids renamed / edges flipped / shuffled never move '
      'a size, DFU or flow direction', () {
    final rnd = math.Random(5902);
    for (final outfall in ['leaf', 'stp']) {
      final (net0, dfu, wcs) = _drain(outfall, 'GI');
      final (base, baseFu) = _size(net0, dfu, wcs);
      for (var t = 0; t < 30; t++) {
        // A random interceptor id (sorting before / after every other id).
        final gi =
            rnd.nextBool() ? 'A${rnd.nextInt(99)}' : 'Z${rnd.nextInt(99)}';
        final (net, _, _) = _drain(outfall, gi);
        final (r, fu) = _size(_flipShuffle(net, rnd), dfu, wcs);
        for (final id in base.keys) {
          expect(
              r[id]!.diameter.inMillimeters, base[id]!.diameter.inMillimeters,
              reason: '$outfall $id trial $t');
          expect(fu[id], closeTo(baseFu[id]!, 1e-9),
              reason: '$outfall $id trial $t');
          final f = base[id]!.flowFromId;
          expect(r[id]!.flowFromId, f == 'GI' ? gi : f,
              reason: '$outfall $id trial $t');
        }
      }
    }
  });

  test(
      'rainwater: an inline harvesting tank upstream of a storm-sewer '
      'outfall passes the whole roof flow onward', () {
    const s = ServiceType.rainwater;
    final net = Network(nodes: [
      _n('RD1', 0,
          floor: 1, role: NodeRole.fixture, c: NodeComponent.roofDrain),
      _n('RD2', 20,
          floor: 1, role: NodeRole.fixture, c: NodeComponent.roofDrain),
      _n('T1', 0),
      _n('T2', 20),
      _n('H', 40),
      _n('A1', 60, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('OUT', 100),
    ], edges: [
      _e('d1', 'RD1', 'T1', s, k: EdgeKind.riser),
      _e('d2', 'RD2', 'T2', s, k: EdgeKind.riser),
      _e('t1', 'T1', 'H', s),
      _e('t2', 'T2', 'H', s),
      _e('ht', 'H', 'A1', s),
      _e('to', 'A1', 'OUT', s),
    ]);
    final r = autoSizeNetwork(net, const SizingContext(),
        leafDemand: const {ServiceType.rainwater: FlowRate(0.002)},
        building: _floors(2));
    // Each roof drain 2 L/s => the harvesting tank's overflow carries 4 L/s
    // toward the sewer, never the phantom leaf default flowing backwards.
    expect(r['to']!.flow.inLitersPerSecond, closeTo(4, 1e-9));
    expect(r['to']!.flowFromId, 'A1');
    expect(r['ht']!.flow.inLitersPerSecond, closeTo(4, 1e-9));
    expect(r['ht']!.flowFromId, 'H');
  });
}
