// Round 37 (2026-10-18) — mech-sim-5-fdc-line-sized-at-zero-flow.
//
// The fire-department connection is an INLET (no demand, flow inward), but
// the brigade pumps the SYSTEM design flow in through it: its pipe is sized on
// the header trunk flow it joins, on the fire velocity cap, never below DN100.
// A two-stack standpipe carries the multi-riser total at the header (the
// largest flow there), so the FDC pipe carries that figure.
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's',
        floorIndex: floor,
        x: x,
        y: y,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id,
        fromId: a,
        toId: b,
        service: ServiceType.fireHydrant,
        kind: k);

Network _net({bool fdc = true}) {
  final nodes = <NetNode>[
    _n('T', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('P', 50, 0, role: NodeRole.plant, c: NodeComponent.pump),
    _n('FH', 100, 0),
    if (fdc) _n('F', 100, 60, c: NodeComponent.fireDeptConnection),
  ];
  final edges = <NetEdge>[
    _e('tp', 'T', 'P'),
    _e('pf', 'P', 'FH'),
    if (fdc) _e('fdc', 'F', 'FH'),
  ];
  for (final s in ['A', 'B']) {
    final x = s == 'A' ? 200.0 : 300.0;
    for (var f = 0; f < 4; f++) {
      nodes
        ..add(_n('$s$f', x, 0, floor: f))
        ..add(_n('b$s$f', x + 20, 0,
            floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
      edges.add(_e('l$s$f', '$s$f', 'b$s$f'));
      edges.add(f == 0
          ? _e('h$s', 'FH', '${s}0')
          : _e('r$s$f', '$s${f - 1}', '$s$f', k: EdgeKind.riser));
    }
  }
  return Network(nodes: nodes, edges: edges);
}

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.fireHydrant: FlowRate(0.0063)},
      hydrantDesignFlow: FlowRate.litersPerSecond(47.32),
    );

void main() {
  test('the FDC pipe carries the header flow at >= DN100 within the fire '
      'velocity cap; the system is otherwise unchanged', () {
    final withFdc = _size(_net());
    final without = _size(_net(fdc: false));
    final headerQ = [
      for (final id in ['pf', 'hA', 'hB'])
        withFdc[id]!.flow.inLitersPerSecond,
    ].reduce(math.max);
    final f = withFdc['fdc']!;
    expect(f.flow.inLitersPerSecond, closeTo(headerQ, 1e-9));
    expect(f.flow.inLitersPerSecond, greaterThan(0));
    expect(f.diameter.inMillimeters, greaterThanOrEqualTo(kFdcMinBoreMm));
    expect(f.velocity.metersPerSecond,
        lessThanOrEqualTo(kMaxFireVelocityMps + 1e-9));
    // v = 4Q / (pi D^2) — the printed velocity is the flow through the bore.
    final d = f.diameter.inMillimeters / 1000;
    expect(f.velocity.metersPerSecond,
        closeTo(4 * headerQ / 1000 / (math.pi * d * d), 0.05));
    expect(f.flowFromId, 'F');
    for (final id in without.keys) {
      expect(withFdc[id]!.flow.inLitersPerSecond,
          closeTo(without[id]!.flow.inLitersPerSecond, 1e-9),
          reason: id);
      expect(withFdc[id]!.diameter.inMillimeters,
          without[id]!.diameter.inMillimeters,
          reason: id);
    }
  });

  test('a hand-picked FDC size stays the engineer\'s', () {
    final s = autoSizeNetwork(
      _net(),
      const SizingContext(),
      leafDemand: const {ServiceType.fireHydrant: FlowRate(0.0063)},
      hydrantDesignFlow: FlowRate.litersPerSecond(47.32),
      sizeOverrides: {'fdc': Diameter.mm(150)},
    );
    expect(s['fdc']!.diameter.inMillimeters, 150);
  });
}
