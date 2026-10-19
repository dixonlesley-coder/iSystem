/// Round 30 (mech-sim-4-vent-stack-without-vtr-stub-undersized) — a vent
/// stack whose TOP node is the top-floor tie (no separate VTR stub) is the
/// SAME stack as one with a VTR stub drawn above it: `gravityRiserEndElevation`
/// already reads that bare top-storey vent junction as the roof penetration,
/// so the sizer must vent the stack's whole load through it. The no-stub
/// drawing used to root the vent tree elsewhere and size every riser on 72
/// instead of 90 DFU (DN75 where UPC 703.2 needs DN100: DN75 <= 84 DFU).
library;

import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart' as drain;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main}) =>
    NetNode(id: id, sheetId: 's1', x: x, y: y, floorIndex: floor, role: role);

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

/// [floors] storeys, one soil stack S0..S(n-1) off an outfall, each floor a
/// fixture of [load] DFU on S_f and a vent tie t_f (S_f -> V_f, or the reverse
/// when [tieUp] is false) into a vent stack V0..V(n-1). [stub]: a VTR riser
/// above the top vent node.
({Network net, Map<String, double> dfu}) _tower(
    {int floors = 10, double load = 9, bool stub = false, bool tieUp = true}) {
  final nodes = <NetNode>[_n('out', 0, 0)];
  final edges = <NetEdge>[_e('sewer', 'out', 'S0', ServiceType.drainage)];
  final dfu = <String, double>{};
  for (var f = 0; f < floors; f++) {
    nodes
      ..add(_n('S$f', 100, 0, floor: f))
      ..add(_n('fx$f', 160, 0, floor: f, role: NodeRole.fixture))
      ..add(_n('V$f', 120, 0, floor: f));
    dfu['fx$f'] = load;
    edges
      ..add(_e('fb$f', 'S$f', 'fx$f', ServiceType.drainage))
      ..add(tieUp
          ? _e('t$f', 'S$f', 'V$f', ServiceType.vent)
          : _e('t$f', 'V$f', 'S$f', ServiceType.vent));
    if (f > 0) {
      edges
        ..add(_e('s$f', 'S${f - 1}', 'S$f', ServiceType.drainage,
            kind: EdgeKind.riser))
        ..add(_e('v$f', 'V${f - 1}', 'V$f', ServiceType.vent,
            kind: EdgeKind.riser));
    }
  }
  if (stub) {
    nodes.add(_n('VTR', 120, 30, floor: floors));
    edges.add(_e('vtr', 'V${floors - 1}', 'VTR', ServiceType.vent,
        kind: EdgeKind.riser));
  }
  return (net: Network(nodes: nodes, edges: edges), dfu: dfu);
}

({Map<String, EdgeSizing> s, Map<String, double> fu}) _size(
    ({Network net, Map<String, double> dfu}) p) {
  final fu = <String, double>{};
  final s = autoSizeNetwork(p.net, const SizingContext(),
      leafDemand: const {}, nodeDrainageUnits: p.dfu, fixtureUnitsOut: fu);
  return (s: s, fu: fu);
}

void main() {
  test(
      '10 storeys x 9 DFU: the no-stub stack vents 90 DFU => DN100, '
      'exactly as the stubbed stack', () {
    // Hand check: 10 x 9 = 90 DFU; UPC 703.2 DN75 <= 84 < 90 <= 256 => DN100.
    expect(drain.ventDiameterForDfu(90).inMillimeters, 100);
    for (final tieUp in [true, false]) {
      final ref = _size(_tower(stub: true, tieUp: tieUp));
      final t = _size(_tower(tieUp: tieUp));
      for (var f = 1; f < 10; f++) {
        final id = 'v$f';
        expect(t.fu[id], closeTo(ref.fu[id]!, 1e-9), reason: '$id up=$tieUp');
        expect(
            t.s[id]!.diameter.inMillimeters, ref.s[id]!.diameter.inMillimeters,
            reason: '$id up=$tieUp');
        expect(t.s[id]!.diameter.inMillimeters, 100, reason: id);
      }
    }
  });

  test(
      'property: a stub-less stack sizes every riser exactly as the same '
      'stack with a VTR stub (seeded floors / loads / tie direction)', () {
    final rnd = math.Random(30);
    for (var i = 0; i < 40; i++) {
      final floors = 2 + rnd.nextInt(12);
      final load = (1 + rnd.nextInt(20)).toDouble();
      final up = rnd.nextBool();
      final ref =
          _size(_tower(floors: floors, load: load, stub: true, tieUp: up));
      final t = _size(_tower(floors: floors, load: load, tieUp: up));
      for (var f = 1; f < floors; f++) {
        final id = 'v$f';
        expect(t.fu[id], closeTo(ref.fu[id]!, 1e-9),
            reason: '$id floors=$floors load=$load up=$up');
        expect(
            t.s[id]!.diameter.inMillimeters, ref.s[id]!.diameter.inMillimeters,
            reason: '$id floors=$floors load=$load up=$up');
      }
    }
  });

  test(
      'r2: a branch vent riser tied by a run into a stub-less stack top '
      'keeps its OWN load (the stack, not the branch riser, roots)', () {
    // 4 storeys x 20 DFU; floor 2's fixture is vented by its own riser
    // A2 -> A3 tied by a run into V3 (the stack top). Rooting at A3 (the
    // id-first top-storey riser top) used to carry the whole stack through
    // the tie: 60 DFU / DN75 where the tie serves 20 DFU / DN50.
    ({Network net, Map<String, double> dfu}) build(bool stub) {
      final nodes = <NetNode>[_n('out', 0, 0)];
      final edges = <NetEdge>[_e('sewer', 'out', 'S0', ServiceType.drainage)];
      final dfu = <String, double>{};
      for (var f = 0; f < 4; f++) {
        nodes
          ..add(_n('S$f', 100, 0, floor: f))
          ..add(_n('fx$f', 160, 0, floor: f, role: NodeRole.fixture))
          ..add(_n('V$f', 120, 0, floor: f));
        dfu['fx$f'] = 20;
        edges.add(_e('fb$f', 'S$f', 'fx$f', ServiceType.drainage));
        if (f != 2) edges.add(_e('t$f', 'S$f', 'V$f', ServiceType.vent));
        if (f > 0) {
          edges
            ..add(_e('s$f', 'S${f - 1}', 'S$f', ServiceType.drainage,
                kind: EdgeKind.riser))
            ..add(_e('v$f', 'V${f - 1}', 'V$f', ServiceType.vent,
                kind: EdgeKind.riser));
        }
      }
      nodes
        ..add(_n('A2', 170, 0, floor: 2))
        ..add(_n('A3', 170, 0, floor: 3));
      edges
        ..add(_e('a2', 'fx2', 'A2', ServiceType.vent))
        ..add(_e('ar', 'A2', 'A3', ServiceType.vent, kind: EdgeKind.riser))
        ..add(_e('tie', 'A3', 'V3', ServiceType.vent));
      if (stub) {
        nodes.add(_n('VTR', 120, 30, floor: 4));
        edges.add(
            _e('vtr', 'V3', 'VTR', ServiceType.vent, kind: EdgeKind.riser));
      }
      return (net: Network(nodes: nodes, edges: edges), dfu: dfu);
    }

    final ref = _size(build(true));
    final t = _size(build(false));
    // The tie carries fx2's 20 DFU only (UPC 703.2: DN50 <= 24).
    expect(t.fu['tie'], 20);
    expect(t.s['tie']!.diameter.inMillimeters, 50);
    // The stack below the header junction keeps its own soil stack's load
    // (t0 + t1 + t3 = 60 DFU => DN75), exactly as the stubbed drawing.
    for (final id in ['v1', 'v2', 'v3', 'tie', 'ar', 'a2', 't3']) {
      expect(t.fu[id], closeTo(ref.fu[id]!, 1e-9), reason: id);
      expect(t.s[id]!.diameter.inMillimeters, ref.s[id]!.diameter.inMillimeters,
          reason: id);
    }
    expect(t.fu['v3'], 60);
  });
}
