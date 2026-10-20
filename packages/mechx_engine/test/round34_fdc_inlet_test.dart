// Round 34 (fire-hvac-drawings-fdc-drawn-and-sized-as-outlet) — the fire
// department connection is a SUPPLY INLET: no demand, never a hydrant outlet,
// never a delivery node, its branch oriented INTO the system.
import 'dart:math';

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x,
        {NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id, sheetId: 's', floorIndex: 0, x: x, y: 0, role: role, component: c);

NetEdge _e(String id, String a, String b) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.fireHydrant);

/// tank -> pump -> header -> one hydrant box, optionally an FDC teed onto the
/// header (through [fdcBends] bare bend nodes).
Network _net({bool fdc = false, int fdcBends = 0}) => Network(nodes: [
      _n('T', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('P', 100, role: NodeRole.plant, c: NodeComponent.pump),
      _n('H', 200),
      _n('B', 300, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      if (fdc) ...[
        for (var i = 0; i < fdcBends; i++) _n('k$i', 200 + 10.0 * (i + 1)),
        _n('F', 250, c: NodeComponent.fireDeptConnection),
      ],
    ], edges: [
      _e('tp', 'T', 'P'),
      _e('ph', 'P', 'H'),
      _e('hb', 'H', 'B'),
      if (fdc) ...[
        for (var i = 0; i <= fdcBends; i++)
          _e('f$i', i == 0 ? 'H' : 'k${i - 1}', i == fdcBends ? 'F' : 'k$i'),
      ],
    ]);

const _box = FlowRate(0.0063); // 6.3 L/s per hydrant box
const _standpipe = FlowRate(0.0315); // 31.5 L/s (500 gpm)

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.fireHydrant: _box},
      hydrantDesignFlow: _standpipe,
    );

void main() {
  test('one box + an FDC keeps the per-box flow on the trunk', () {
    final without = _size(_net());
    final withFdc = _size(_net(fdc: true));
    // One hydrant outlet ⇒ per-box flow (6.3 L/s) on the pump trunk and the
    // suction; adding the inlet must not count it as a 2nd outlet (which lifted
    // the trunk to the 31.5 L/s standpipe figure, DN65 -> DN100).
    for (final id in ['tp', 'ph', 'hb']) {
      expect(withFdc[id]!.flow.inLitersPerSecond,
          closeTo(without[id]!.flow.inLitersPerSecond, 1e-9),
          reason: id);
      expect(withFdc[id]!.diameter.inMillimeters,
          without[id]!.diameter.inMillimeters,
          reason: id);
    }
    expect(withFdc['ph']!.flow.inLitersPerSecond, closeTo(6.3, 1e-9));
    // The FDC branch carries no design draw-off and points INTO the header.
    expect(withFdc['f0']!.flow.cubicMetersPerSecond, 0);
    expect(withFdc['f0']!.flowFromId, 'F');
  });

  // Seeded property: however many bare bends the FDC branch is drawn with and
  // whatever its leaf demand, the trunk flow never moves and every edge of the
  // inlet chain points from the FDC inward.
  test('property: the inlet chain never loads the trunk (seeded)', () {
    final rnd = Random(34);
    final base = _size(_net())['ph']!.flow.inLitersPerSecond;
    for (var t = 0; t < 20; t++) {
      final bends = rnd.nextInt(4);
      final sized = _size(_net(fdc: true, fdcBends: bends));
      expect(sized['ph']!.flow.inLitersPerSecond, closeTo(base, 1e-9));
      for (var i = 0; i <= bends; i++) {
        final e = sized['f$i']!;
        expect(e.flow.cubicMetersPerSecond, 0);
        // Edge f_i joins (H | k_{i-1}) to (k_i | F): its far end is upstream.
        expect(e.flowFromId, i == bends ? 'F' : 'k$i', reason: 'f$i');
      }
    }
  });

  test('the FDC is never a delivery node', () {
    expect(isSupplyInletComponent(NodeComponent.fireDeptConnection), isTrue);
    expect(isSupplyInletComponent(NodeComponent.hydrantBox), isFalse);
  });
}
