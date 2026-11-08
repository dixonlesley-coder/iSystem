// Round 74 (plumbing-hvac-convergence-23) — a gravity outfall reached from a
// downpipe / stack foot through a yard TEE (or off a foot that also carries a
// collector) is an OUTFALL, never a phantom inlet.
//
// First principles (rainwater, flows add): RD1 = 10 L/s down the F1
// downpipe, RD2 = RD3 = 6 L/s down F2 / F3 which meet at the yard tee J and
// run on to O2. Each drain discharges at its NEAREST outfall (in hops): RD1
// -> O1 (1 hop vs 5), RD2 -> O2 (2 hops vs 3), RD3 -> O2 (2 vs 5). So
//   o1 = 10 L/s (the lone-downpipe value), o2 = 6 + 6 = 12 L/s flowing
//   AWAY from J, the collector F1 - C - F2 is the flagged closing edge, and
//   o1 + o2 = 22 L/s = the drains' sum (no phantom 1 L/s inlet).
// Drainage is the same topology with DFU (10 / 6 / 6) in place of L/s.
library;

import 'dart:math' as math;

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

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

NodeComponent _drain(ServiceType s) => s == ServiceType.rainwater
    ? NodeComponent.roofDrain
    : NodeComponent.floorDrain;

/// [tee]: F2 / F3 meet at the yard tee J -> O2. Otherwise the simpler
/// drawing: one outfall stub off each foot (F2 degree 3) and no RD3.
/// [only]: keep only these drains (the lone reference sub-networks).
Network _net(ServiceType s, {required bool tee, Set<String>? only}) {
  bool keep(String d) => only == null || only.contains(d);
  final withA = keep('RD1');
  final withB = keep('RD2') || (tee && keep('RD3'));
  final collector = withA && withB;
  return Network(nodes: [
    if (withA) ...[
      _n('RD1', 0, 0, floor: 5, role: NodeRole.fixture, c: _drain(s)),
      _n('F1', 0, 0),
      _n('O1', -50, 0),
    ],
    if (collector) _n('C', 150, 0),
    if (keep('RD2')) ...[
      _n('RD2', 300, 0, floor: 5, role: NodeRole.fixture, c: _drain(s)),
      _n('F2', 300, 0),
    ],
    if (tee && keep('RD3')) ...[
      _n('RD3', 400, 0, floor: 5, role: NodeRole.fixture, c: _drain(s)),
      _n('F3', 400, 0),
    ],
    if (tee && withB) _n('J', 350, 0),
    if (withB) _n('O2', 350, 60),
  ], edges: [
    if (withA) ...[
      _e('d1', 'RD1', 'F1', s, k: EdgeKind.riser),
      _e('o1', 'F1', 'O1', s),
    ],
    if (collector) ...[_e('c1', 'F1', 'C', s), _e('c2', 'C', 'F2', s)],
    if (keep('RD2')) _e('d2', 'RD2', 'F2', s, k: EdgeKind.riser),
    if (tee) ...[
      if (keep('RD3')) ...[
        _e('d3', 'RD3', 'F3', s, k: EdgeKind.riser),
        _e('j3', 'F3', 'J', s),
      ],
      if (keep('RD2')) _e('j2', 'F2', 'J', s),
      if (withB) _e('o2', 'J', 'O2', s),
    ] else if (withB)
      _e('o2', 'F2', 'O2', s),
  ]);
}

Network _shuffled(Network net, math.Random rnd) => Network(
    nodes: [...net.nodes]..shuffle(rnd),
    edges: [
      for (final e in net.edges)
        rnd.nextBool()
            ? NetEdge(
                id: e.id,
                fromId: e.toId,
                toId: e.fromId,
                service: e.service,
                kind: e.kind)
            : e,
    ]..shuffle(rnd));

const _load = {'RD1': 10.0, 'RD2': 6.0, 'RD3': 6.0};

Map<String, EdgeSizing> _size(ServiceType s, Network net,
    [Map<String, double>? fu]) {
  final ids = {for (final n in net.nodes) n.id};
  return autoSizeNetwork(net, const SizingContext(),
      // A bare leaf's default load (the phantom-inlet amount).
      leafDemand: const {
        ServiceType.rainwater: FlowRate(0.001),
        ServiceType.drainage: FlowRate(0.001),
      },
      leafFixtureUnits: const {ServiceType.drainage: 2},
      nodeFlowDemand: s == ServiceType.rainwater
          ? {
              for (final e in _load.entries)
                if (ids.contains(e.key)) e.key: FlowRate(e.value / 1000)
            }
          : const {},
      nodeDrainageUnits: s == ServiceType.drainage
          ? {
              for (final e in _load.entries)
                if (ids.contains(e.key)) e.key: e.value
            }
          : const {},
      fixtureUnitsOut: fu);
}

void main() {
  for (final s in [ServiceType.rainwater, ServiceType.drainage]) {
    for (final tee in [true, false]) {
      test('${s.name} ${tee ? 'yard tee' : 'two-stub'}: O2 is an outfall '
          '(seeded shuffles / flips)', () {
        final refA = _size(s, _net(s, tee: tee, only: {'RD1'}));
        final refB = _size(
            s, _net(s, tee: tee, only: tee ? {'RD2', 'RD3'} : {'RD2'}));
        final bLoad = tee ? 12.0 : 6.0;
        final rnd = math.Random(74 + (tee ? 1 : 0) + s.index * 7);
        for (var t = 0; t < 40; t++) {
          final fu = <String, double>{};
          final got = _size(s, _shuffled(_net(s, tee: tee), rnd), fu);
          // o1 == the lone RD1 downpipe; o2 == the lone RD2 (+RD3) part.
          for (final (id, ref) in [('o1', refA), ('d1', refA), ('o2', refB)]) {
            expect(got[id]!.flow.cubicMetersPerSecond,
                closeTo(ref[id]!.flow.cubicMetersPerSecond, 1e-12),
                reason: '$id trial $t');
            expect(got[id]!.diameter.inMillimeters,
                ref[id]!.diameter.inMillimeters,
                reason: '$id trial $t');
          }
          expect(got['o1']!.flowFromId, 'F1', reason: 'trial $t');
          expect(got['o2']!.flowFromId, tee ? 'J' : 'F2', reason: 'trial $t');
          if (tee) {
            expect(got['j2']!.flowFromId, 'F2', reason: 'trial $t');
          }
          // The collector's divide edge is the flagged closing edge.
          expect(
              got['c1']!.loopUnbalanced || got['c2']!.loopUnbalanced, isTrue,
              reason: 'trial $t');
          if (s == ServiceType.rainwater) {
            expect(got['o2']!.flow.inLitersPerSecond, closeTo(bLoad, 1e-9));
            // No phantom inlet: total discharged = the drains' sum.
            expect(
                got['o1']!.flow.inLitersPerSecond +
                    got['o2']!.flow.inLitersPerSecond,
                closeTo(10 + bLoad, 1e-9));
          } else {
            expect(fu['o1'], closeTo(10, 1e-9), reason: 'trial $t');
            expect(fu['o2'], closeTo(bLoad, 1e-9), reason: 'trial $t');
          }
        }
      });
    }
  }
}
