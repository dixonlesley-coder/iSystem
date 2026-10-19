/// Round 27 — vent-stack residuals carried from Round 26 r4 (UPC 703.2 /
/// IPC 916.1: a vent stack is sized uniformly on the DFU of the soil stack it
/// serves, never reverse-tapered; only a shared header / stub carries the
/// combined load):
///
/// * residuals-1 — a roof header VB3 -> M -> VA3 through a BARE mid node with
///   the VTR drawn as a RUN off M: the larger stack kept its below-tie partial
///   load (DN50 at 22 DFU instead of DN65 at 32).
/// * residuals-2 — the same header with a RISER VTR off M: both header halves
///   passed as stack offsets and merged both stacks (the small one two DN up).
/// * residuals-3 — a stack offset drawn as two runs through a bare bend node
///   left the lower stack reverse-tapered (DN50 below a DN65 stack).
/// * residuals-5 — a run VTR on a component that also has a riser VTR took a
///   phantom 2 DFU (the small stack one DN up).
///
/// The reference for every stack is the SAME stack with its own VTR (no
/// header): the engine's own sizing of that soil stack.
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

enum _Top { own, midRun, midRiser, mixedVtr }

/// Two soil stacks off one outfall (A at [a] DFU per floor, B at [b]), four
/// floors, each vent stack tied every floor. [top]:
///  * own — each stack has its own riser VTR (the reference);
///  * midRun — header VB3 -> M -> VA3 through a bare node M, VTR as a RUN
///    M -> VTR on floor 3;
///  * midRiser — the same header, VTR as a RISER M (3) -> VTR (4);
///  * mixedVtr — A a riser VTR, B a run VTR (VB3 -> VTRB, floor 3), header
///    VB3 -> VA3.
({Network net, Map<String, double> dfu}) _two(_Top top,
    {double a = 10, double b = 1}) {
  final nodes = <NetNode>[_n('out', 0, 0)];
  final edges = <NetEdge>[];
  final dfu = <String, double>{};
  for (final (tag, x, load) in [('A', 100.0, a), ('B', 400.0, b)]) {
    edges.add(_e('sewer$tag', 'out', 'DS${tag}0', ServiceType.drainage));
    for (var f = 0; f < 4; f++) {
      nodes
        ..add(_n('DS$tag$f', x, 0, floor: f))
        ..add(_n('fx$tag$f', x + 50, 0, floor: f, role: NodeRole.fixture))
        ..add(_n('V$tag$f', x + 20, 0, floor: f));
      dfu['fx$tag$f'] = load;
      edges
        ..add(_e('fb$tag$f', 'DS$tag$f', 'fx$tag$f', ServiceType.drainage))
        ..add(_e('t$tag$f', 'V$tag$f', 'DS$tag$f', ServiceType.vent));
      if (f > 0) {
        edges
          ..add(_e(
              'ds$tag$f', 'DS$tag${f - 1}', 'DS$tag$f', ServiceType.drainage,
              kind: EdgeKind.riser))
          ..add(_e('v$tag$f', 'V$tag${f - 1}', 'V$tag$f', ServiceType.vent,
              kind: EdgeKind.riser));
      }
    }
  }
  switch (top) {
    case _Top.own:
      nodes
        ..add(_n('VTRA', 120, 30, floor: 4))
        ..add(_n('VTRB', 420, 30, floor: 4));
      edges
        ..add(_e('vtrA', 'VA3', 'VTRA', ServiceType.vent, kind: EdgeKind.riser))
        ..add(
            _e('vtrB', 'VB3', 'VTRB', ServiceType.vent, kind: EdgeKind.riser));
    case _Top.midRun:
    case _Top.midRiser:
      final riser = top == _Top.midRiser;
      nodes
        ..add(_n('M', 250, 0, floor: 3))
        ..add(_n('VTR', 250, 30, floor: riser ? 4 : 3));
      edges
        ..add(_e('hB', 'VB3', 'M', ServiceType.vent))
        ..add(_e('hA', 'M', 'VA3', ServiceType.vent))
        ..add(_e('vtr', 'M', 'VTR', ServiceType.vent,
            kind: riser ? EdgeKind.riser : EdgeKind.run));
    case _Top.mixedVtr:
      nodes
        ..add(_n('VTRA', 120, 30, floor: 4))
        ..add(_n('VTRB', 420, 30, floor: 3));
      edges
        ..add(_e('vtrA', 'VA3', 'VTRA', ServiceType.vent, kind: EdgeKind.riser))
        ..add(_e('vtrB', 'VB3', 'VTRB', ServiceType.vent))
        ..add(_e('hdr', 'VB3', 'VA3', ServiceType.vent));
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
  test('first principles: the own-VTR reference basis', () {
    // Stack A at 10 DFU/floor: the soil stack carries 40 DFU, the vent basis
    // 32 (the Round-25 base rule: the foot's own seed is not vented through
    // the stack) => UPC 703.2 24 < 32 <= 48 => DN65. Stack B at 1 DFU/floor:
    // 4 DFU => 1 < 4 <= 8 => DN40.
    final own = _size(_two(_Top.own));
    for (final id in ['vA1', 'vA2', 'vA3']) {
      expect(own.fu[id], closeTo(32, 1e-9), reason: id);
      expect(own.s[id]!.diameter.inMillimeters, 65, reason: id);
    }
    for (final id in ['vB1', 'vB2', 'vB3']) {
      expect(own.fu[id], closeTo(4, 1e-9), reason: id);
      expect(own.s[id]!.diameter.inMillimeters, 40, reason: id);
    }
    expect(drain.ventDiameterForDfu(32).inMillimeters, 65);
    expect(drain.ventDiameterForDfu(22).inMillimeters, 50);
  });

  void expectOwnStacks(_Top top, double a, double b) {
    final own = _size(_two(_Top.own, a: a, b: b));
    final t = _size(_two(top, a: a, b: b));
    for (final tag in ['A', 'B']) {
      for (final f in [1, 2, 3]) {
        final id = 'v$tag$f';
        expect(t.fu[id], closeTo(own.fu[id]!, 1e-9),
            reason: '$top a=$a b=$b $id');
        expect(t.s[id]!.diameter.inMillimeters,
            own.s[id]!.diameter.inMillimeters,
            reason: '$top a=$a b=$b $id');
      }
    }
  }

  test(
      'residuals-1: header through a bare mid node, RUN VTR — each stack '
      'keeps its own size (A DN65 at 32, B DN40 at 4)', () {
    expectOwnStacks(_Top.midRun, 10, 1);
    final t = _size(_two(_Top.midRun));
    expect(t.s['vA1']!.diameter.inMillimeters, 65);
    // The header halves carry each stack's own load; the VTR both.
    expect(t.fu['hA'], closeTo(32, 1e-9));
    expect(t.fu['hB'], closeTo(4, 1e-9));
    expect(t.fu['vtr'], closeTo(36, 1e-9));
    expectOwnStacks(_Top.midRun, 19, 2);
  });

  test(
      'residuals-2: header through a bare mid node, RISER VTR — the stacks '
      'are not merged (B DN40, not DN65)', () {
    expectOwnStacks(_Top.midRiser, 10, 1);
    expectOwnStacks(_Top.midRiser, 10, 9);
    expectOwnStacks(_Top.midRiser, 6, 6);
    final t = _size(_two(_Top.midRiser));
    expect(t.s['vB1']!.diameter.inMillimeters, 40);
    // The shared stub above the junction carries both stacks: 32 + 4.
    expect(t.fu['vtr'], closeTo(36, 1e-9));
  });

  test(
      'residuals-5: a run VTR beside another stack\'s riser VTR is an open '
      'terminal, no phantom 2 DFU', () {
    expectOwnStacks(_Top.mixedVtr, 6, 6);
    expectOwnStacks(_Top.mixedVtr, 19, 2);
    // a = 19, b = 2: A's riser VTR carries A's own vent load plus B's (the
    // header drains B into A), never a phantom 2 DFU more; B's run VTR is
    // its roof termination, sized on B's own stack (the r4 run-VTR rule).
    final own = _size(_two(_Top.own, a: 19, b: 2));
    final t = _size(_two(_Top.mixedVtr, a: 19, b: 2));
    expect(t.fu['vtrA'], closeTo(own.fu['vtrA']! + own.fu['vtrB']!, 1e-9));
    expect(t.fu['hdr'], closeTo(own.fu['vtrB']!, 1e-9));
    expect(t.fu['vtrB'], closeTo(own.fu['vtrB']!, 1e-9));
  });

  /// One soil stack, 4 floors x [load] DFU. Vent risers V0..V2 tied at
  /// floors 0..2, an offset at floor 2 to W2, W2 -> W3 tied at floor 3, VTR
  /// riser W3 -> VTR (floor 4). [bend] draws the offset as two runs through a
  /// bare node K (V2 -> K -> W2) instead of one run (V2 -> W2).
  ({Network net, Map<String, double> dfu}) offsetStack(
      {required bool bend, double load = 10}) {
    final nodes = <NetNode>[_n('out', 0, 0)];
    final edges = <NetEdge>[
      _e('sewer', 'out', 'DS0', ServiceType.drainage),
    ];
    final dfu = <String, double>{};
    for (var f = 0; f < 4; f++) {
      nodes
        ..add(_n('DS$f', 100, 0, floor: f))
        ..add(_n('fx$f', 150, 0, floor: f, role: NodeRole.fixture));
      dfu['fx$f'] = load;
      edges.add(_e('fb$f', 'DS$f', 'fx$f', ServiceType.drainage));
      if (f > 0) {
        edges.add(_e('ds$f', 'DS${f - 1}', 'DS$f', ServiceType.drainage,
            kind: EdgeKind.riser));
      }
    }
    for (var f = 0; f <= 2; f++) {
      nodes.add(_n('V$f', 120, 0, floor: f));
      edges.add(_e('t$f', 'V$f', 'DS$f', ServiceType.vent));
      if (f > 0) {
        edges.add(_e('v$f', 'V${f - 1}', 'V$f', ServiceType.vent,
            kind: EdgeKind.riser));
      }
    }
    nodes
      ..add(_n('W2', 200, 0, floor: 2))
      ..add(_n('W3', 200, 0, floor: 3))
      ..add(_n('VTR', 200, 0, floor: 4));
    edges
      ..add(_e('w3', 'W2', 'W3', ServiceType.vent, kind: EdgeKind.riser))
      ..add(_e('t3', 'W3', 'DS3', ServiceType.vent))
      ..add(_e('vtr', 'W3', 'VTR', ServiceType.vent, kind: EdgeKind.riser));
    if (bend) {
      nodes.add(_n('K', 160, 40, floor: 2));
      edges
        ..add(_e('o1', 'V2', 'K', ServiceType.vent))
        ..add(_e('o2', 'K', 'W2', ServiceType.vent));
    } else {
      edges.add(_e('o1', 'V2', 'W2', ServiceType.vent));
    }
    return (net: Network(nodes: nodes, edges: edges), dfu: dfu);
  }

  test(
      'residuals-3: an offset drawn through a bare bend node keeps the stack '
      'uniform (never reverse-tapered)', () {
    for (final load in [10.0, 20.0]) {
      final one = _size(offsetStack(bend: false, load: load));
      final two = _size(offsetStack(bend: true, load: load));
      // Single-run offset: the whole developed length on one load.
      final stack = one.fu['vtr']!;
      for (final id in ['v1', 'v2', 'o1', 'w3', 'vtr']) {
        expect(one.fu[id], closeTo(stack, 1e-9), reason: 'one $load $id');
      }
      for (final id in ['v1', 'v2', 'o1', 'o2', 'w3', 'vtr']) {
        expect(two.fu[id], closeTo(stack, 1e-9), reason: 'bend $load $id');
        expect(two.s[id]!.diameter.inMillimeters,
            drain.ventDiameterForDfu(stack).inMillimeters,
            reason: 'bend $load $id');
      }
    }
  });

  test(
      'property: any edge order + per-floor loads, every stack keeps its own '
      'vent basis under each roof-header idiom (seeded)', () {
    final rnd = math.Random(2027);
    for (var trial = 0; trial < 30; trial++) {
      final a = 1.0 + rnd.nextInt(20);
      final b = 1.0 + rnd.nextInt(20);
      final top = [_Top.midRun, _Top.midRiser, _Top.mixedVtr][trial % 3];
      final own = _size(_two(_Top.own, a: a, b: b));
      final p = _two(top, a: a, b: b);
      final t = _size((
        net: Network(
            nodes: p.net.nodes,
            edges: [...p.net.edges]..shuffle(math.Random(trial))),
        dfu: p.dfu,
      ));
      for (final tag in ['A', 'B']) {
        for (final f in [1, 2, 3]) {
          final id = 'v$tag$f';
          expect(t.fu[id], closeTo(own.fu[id]!, 1e-9),
              reason: 'trial $trial $top a=$a b=$b $id');
        }
      }
    }
  });
}
