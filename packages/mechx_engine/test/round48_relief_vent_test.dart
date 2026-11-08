// Round 48 — a relief / yoke vent between a soil stack and its vent stack is
// floored at the smaller of the two stacks
// (mech-convergence-3-relief-vent-below-vent-stack).
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart' as drain;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, int f, {NodeRole role = NodeRole.main}) =>
    NetNode(id: id, sheetId: 's1', x: x, y: 0, floorIndex: f, role: role);

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

/// 20-storey soil stack S0..S19 (9 DFU per storey ⇒ 180 DFU) with a
/// parallel vent stack V0..V19 + VTR, tied at the base and by relief vents
/// at [reliefAt].
({Network net, Map<String, double> dfu}) _tower(List<int> reliefAt) {
  final nodes = <NetNode>[_n('out', 0, 0)];
  final edges = <NetEdge>[_e('sewer', 'out', 'S0', ServiceType.drainage)];
  final dfu = <String, double>{};
  for (var f = 0; f < 20; f++) {
    nodes
      ..add(_n('S$f', 100, f))
      ..add(_n('V$f', 120, f))
      ..add(_n('fx$f', 200, f, role: NodeRole.fixture));
    dfu['fx$f'] = 9;
    edges.add(_e('fb$f', 'S$f', 'fx$f', ServiceType.drainage));
    if (f > 0) {
      edges
        ..add(_e('s$f', 'S${f - 1}', 'S$f', ServiceType.drainage,
            k: EdgeKind.riser))
        ..add(
            _e('v$f', 'V${f - 1}', 'V$f', ServiceType.vent, k: EdgeKind.riser));
    }
  }
  nodes.add(_n('VTR', 120, 20));
  edges
    ..add(_e('vtr', 'V19', 'VTR', ServiceType.vent, k: EdgeKind.riser))
    ..add(_e('base', 'V0', 'S0', ServiceType.vent))
    ..addAll([
      for (final f in reliefAt) _e('rv$f', 'S$f', 'V$f', ServiceType.vent),
    ]);
  return (net: Network(nodes: nodes, edges: edges), dfu: dfu);
}

void main() {
  test('relief vents every 5 storeys take min(soil, vent stack) = DN100', () {
    final t = _tower([5, 10, 15]);
    final fu = <String, double>{};
    final s = autoSizeNetwork(t.net, const SizingContext(),
        leafDemand: const {}, nodeDrainageUnits: t.dfu, fixtureUnitsOut: fu);
    // Each relief vent's DFU share is 5 storeys x 9 = 45 DFU (UPC 703.2
    // 24 < 45 <= 48 ⇒ DN65) — one size below the stacks it ties.
    expect(drain.ventDiameterForDfu(45).inMillimeters, 65);
    for (final f in [5, 10, 15]) {
      final soil = s['s$f']!.diameter.inMillimeters;
      final vent = s['v$f']!.diameter.inMillimeters;
      final want = soil < vent ? soil : vent;
      expect(want, 100, reason: 'both stacks DN100 at storey $f');
      expect(s['rv$f']!.diameter.inMillimeters, want, reason: 'rv$f');
    }
  });

  test('a hand pick below the relief floor is belowCodeMinimum', () {
    final t = _tower([5, 10, 15]);
    final s = autoSizeNetwork(t.net, const SizingContext(),
        leafDemand: const {},
        nodeDrainageUnits: t.dfu,
        sizeOverrides: {'rv10': Diameter.mm(65)});
    expect(s['rv10']!.diameter.inMillimeters, 65);
    expect(s['rv10']!.belowCodeMinimum, isTrue);
  });

  test('per-storey ties keep their own DFU (branch-vent connections)', () {
    // Ties at EVERY storey relieve one storey each — the storey's branch-vent
    // connection, sized on its own 9 DFU (Round 12), never floored.
    final t = _tower([for (var f = 1; f < 20; f++) f]);
    final s = autoSizeNetwork(t.net, const SizingContext(),
        leafDemand: const {}, nodeDrainageUnits: t.dfu);
    for (final f in [5, 10, 15]) {
      expect(s['rv$f']!.diameter.inMillimeters,
          drain.ventDiameterForDfu(9).inMillimeters,
          reason: 'rv$f');
    }
  });
}
