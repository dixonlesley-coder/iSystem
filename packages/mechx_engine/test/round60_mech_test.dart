// Round 60 (2026-10-18) — mechanical sizing pins.
//
//   plumbing-hvac-convergence-10-rainwater-run-outfall-phantom-inlet — a
//     second rainwater outfall reached from its downpipe foot by a short RUN
//     is an outfall, never a phantom inlet: each downpipe carries its own
//     nearest drains, exactly as when the outfall sits at the stack foot.
//   plumbing-hvac-convergence-10-inline-fcu-airflow-double-counted — an
//     inline FCU's rated airflow is the air its diffusers deliver, never
//     extra demand on top of them.
//
// First principles (rain): 4 roof drains x 2 L/s on the collector A - C1 -
// C2 - B, downpipes at A and B; each drain drains to its NEAREST outfall, so
// RD0 + RD1 -> the A downpipe (4 L/s) and RD2 + RD3 -> the B downpipe
// (4 L/s); total 8 L/s, no phantom outfall load.
// First principles (air): two FCUs each feeding two 0.25 m3/s diffusers
// (0.5 m3/s per FCU, 1.0 m3/s in all) — the trunk carries 1.0 m3/s whether or
// not each FCU's own rated 0.5 m3/s is entered.
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? component,
        FlowRate? airflow}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: floor,
      role: role,
      component: component,
      airflow: airflow,
    );

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

const _rw = ServiceType.rainwater;

/// The audit_r15 two-downpipe roof, with each downpipe ending at a foot node
/// F1 / F2 on L0 and (when [runA] / [runB]) a short RUN on to the outfall
/// O1 / O2 (else the foot IS the outfall).
Network _roof({required bool runA, required bool runB}) => Network(nodes: [
      for (var i = 0; i < 4; i++)
        _n('RD$i', i * 100.0, -40,
            floor: 3,
            role: NodeRole.fixture,
            component: NodeComponent.roofDrain),
      _n('A', 0, 0, floor: 3),
      _n('C1', 100, 0, floor: 3),
      _n('C2', 200, 0, floor: 3),
      _n('B', 300, 0, floor: 3),
      _n('F1', 0, 0),
      _n('F2', 300, 0),
      if (runA) _n('O1', -50, 0),
      if (runB) _n('O2', 350, 0),
    ], edges: [
      _e('r0', 'RD0', 'A', _rw),
      _e('r1', 'RD1', 'C1', _rw),
      _e('r2', 'RD2', 'C2', _rw),
      _e('r3', 'RD3', 'B', _rw),
      _e('ac', 'A', 'C1', _rw),
      _e('cc', 'C1', 'C2', _rw),
      _e('bc', 'C2', 'B', _rw),
      _e('d1', 'A', 'F1', _rw, kind: EdgeKind.riser),
      _e('d2', 'B', 'F2', _rw, kind: EdgeKind.riser),
      if (runA) _e('o1', 'F1', 'O1', _rw),
      if (runB) _e('o2', 'F2', 'O2', _rw),
    ]);

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

void main() {
  group('rain outfall reached by a run', () {
    const perDrain = 0.002; // 2 L/s
    final ref = autoSizeNetwork(
        _roof(runA: false, runB: false), const SizingContext(),
        leafDemand: const {_rw: FlowRate(perDrain)});

    test('reference: the stack-foot outfalls split the roof 4 / 4 L/s', () {
      expect(ref['d1']!.flow.cubicMetersPerSecond, closeTo(4e-3, 1e-12));
      expect(ref['d2']!.flow.cubicMetersPerSecond, closeTo(4e-3, 1e-12));
      expect(ref['cc']!.loopUnbalanced, isTrue);
    });

    test(
        'seeded property: a run to either / both outfalls never changes a '
        'downpipe or collector size, flow or direction; no phantom inlet', () {
      final rnd = math.Random(6009);
      for (var t = 0; t < 60; t++) {
        final runA = rnd.nextBool(), runB = t.isEven || rnd.nextBool();
        final s = autoSizeNetwork(_shuffled(_roof(runA: runA, runB: runB), rnd),
            const SizingContext(),
            leafDemand: const {_rw: FlowRate(perDrain)});
        for (final id in ['r0', 'r1', 'r2', 'r3', 'ac', 'bc', 'd1', 'd2']) {
          expect(s[id]!.flow.cubicMetersPerSecond,
              closeTo(ref[id]!.flow.cubicMetersPerSecond, 1e-12),
              reason: '$id trial $t A=$runA B=$runB');
          expect(s[id]!.diameter.inMillimeters, ref[id]!.diameter.inMillimeters,
              reason: '$id trial $t');
          expect(s[id]!.flowFromId, ref[id]!.flowFromId, reason: '$id t$t');
        }
        expect(s['cc']!.loopUnbalanced, isTrue, reason: 'trial $t');
        // The outfall runs carry their downpipe's flow AWAY from the foot.
        if (runA) {
          expect(s['o1']!.flowFromId, 'F1', reason: 'trial $t');
          expect(s['o1']!.flow.cubicMetersPerSecond, closeTo(4e-3, 1e-12));
        }
        if (runB) {
          expect(s['o2']!.flowFromId, 'F2', reason: 'trial $t');
          expect(s['o2']!.flow.cubicMetersPerSecond, closeTo(4e-3, 1e-12));
        }
        // Total discharged = 4 x 2 L/s: no phantom outfall load.
        expect(
            s['d1']!.flow.cubicMetersPerSecond +
                s['d2']!.flow.cubicMetersPerSecond,
            closeTo(4 * perDrain, 1e-12));
      }
    });
  });

  group('inline FCU airflow', () {
    const sa = ServiceType.duct;
    Network ducts({FlowRate? fcuAirflow}) => Network(nodes: [
          _n('AHU', 0, 0, role: NodeRole.plant, component: NodeComponent.ahu),
          _n('J', 100, 0),
          for (final k in ['A', 'B']) ...[
            _n('F$k', 200, k == 'A' ? -100 : 100,
                role: NodeRole.plant,
                component: NodeComponent.fcu,
                airflow: fcuAirflow),
            for (var d = 0; d < 2; d++)
              _n('D$k$d', 300.0 + 50 * d, k == 'A' ? -100 : 100,
                  role: NodeRole.fixture,
                  component: NodeComponent.supplyDiffuser,
                  airflow: const FlowRate(0.25)),
          ],
        ], edges: [
          _e('t', 'AHU', 'J', sa),
          _e('a', 'J', 'FA', sa),
          _e('b', 'J', 'FB', sa),
          _e('a0', 'FA', 'DA0', sa),
          _e('a1', 'DA0', 'DA1', sa),
          _e('b0', 'FB', 'DB0', sa),
          _e('b1', 'DB0', 'DB1', sa),
        ]);

    test(
        'the trunk carries the diffusers\' 1.0 m3/s with or without the '
        'FCU rated airflow; a LEAF FCU still bears its own', () {
      // The app passes every node's airflow as its explicit demand.
      Map<String, EdgeSizing> size(Network net) =>
          autoSizeNetwork(net, const SizingContext(),
              leafDemand: const {},
              nodeFlowDemand: {
                for (final n in net.nodes)
                  if (n.airflow != null) n.id: n.airflow!,
              });
      final bare = size(ducts());
      final rated = size(ducts(fcuAirflow: const FlowRate(0.5)));
      expect(bare['t']!.flow.cubicMetersPerSecond, closeTo(1.0, 1e-12));
      for (final id in ['t', 'a', 'b', 'a0', 'b0']) {
        expect(rated[id]!.flow.cubicMetersPerSecond,
            closeTo(bare[id]!.flow.cubicMetersPerSecond, 1e-12),
            reason: id);
        expect(
            rated[id]!.diameter.inMillimeters, bare[id]!.diameter.inMillimeters,
            reason: id);
      }
      expect(rated['a']!.flow.cubicMetersPerSecond, closeTo(0.5, 1e-12));
      // An FCU rated ABOVE its diffusers passes its own airflow on (a floor).
      final over = size(ducts(fcuAirflow: const FlowRate(0.7)));
      expect(over['a']!.flow.cubicMetersPerSecond, closeTo(0.7, 1e-12));
      expect(over['t']!.flow.cubicMetersPerSecond, closeTo(1.4, 1e-12));
      // A leaf FCU (no diffuser drawn) bears its whole airflow.
      final leaf = Network(nodes: [
        _n('AHU', 0, 0, role: NodeRole.plant, component: NodeComponent.ahu),
        _n('FA', 200, 0,
            role: NodeRole.plant,
            component: NodeComponent.fcu,
            airflow: const FlowRate(0.5)),
      ], edges: [
        _e('a', 'AHU', 'FA', sa),
      ]);
      expect(size(leaf)['a']!.flow.cubicMetersPerSecond, closeTo(0.5, 1e-12));
    });
  });
}
