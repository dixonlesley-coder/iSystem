/// Round 26 (regression-vent-header-unions-separate-stacks) — a roof vent
/// HEADER tying the tops of two independent vent stacks into one VTR does not
/// merge the stacks: each vent stack keeps the size of its own soil stack's
/// DFU (UPC 703.2 / IPC 916.1, uniform over the stack), and only a genuine
/// horizontal OFFSET (one group's TOP joined to a different group's BOTTOM on
/// the same storey) is part of a stack.
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

/// Two soil stacks off one outfall — A at [dfuA] per floor, B at [dfuB] per
/// floor, 4 floors — each with its own vent stack tied every floor. With
/// [header], B's top VB3 runs to A's top VA3 and only A has a VTR; without
/// it each stack has its own VTR. [mirror] draws the header the other way:
/// A's top VA3 runs to B's top VB3 and only B (the SMALL stack) has a VTR.
/// Round 26 r3 — [headerFloor] moves the header to a MID storey (VA_f <->
/// VB_f; each stack continues above it, tied every floor, so a stack with no
/// VTR keeps a dead STUB above the header) and [vtrA] / [vtrB] override
/// which stacks carry a VTR.
({Network net, Map<String, double> dfu}) _twoStacks(
    {required bool header,
    bool mirror = false,
    int headerFloor = 3,
    bool? vtrA,
    bool? vtrB,
    double dfuA = 10,
    double dfuB = 1}) {
  final nodes = <NetNode>[_n('out', 0, 0)];
  final edges = <NetEdge>[];
  final dfu = <String, double>{};
  for (final (tag, x, load) in [('A', 100.0, dfuA), ('B', 400.0, dfuB)]) {
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
  final vtrOnA = vtrA ?? (!header || !mirror);
  final vtrOnB = vtrB ?? (!header || mirror);
  if (vtrOnA) {
    nodes.add(_n('VTRA', 120, 0, floor: 4));
    edges
        .add(_e('vtrA', 'VA3', 'VTRA', ServiceType.vent, kind: EdgeKind.riser));
  }
  if (vtrOnB) {
    nodes.add(_n('VTRB', 420, 0, floor: 4));
    edges
        .add(_e('vtrB', 'VB3', 'VTRB', ServiceType.vent, kind: EdgeKind.riser));
  }
  if (header) {
    final f = headerFloor;
    edges.add(mirror
        ? _e('hdr', 'VA$f', 'VB$f', ServiceType.vent)
        : _e('hdr', 'VB$f', 'VA$f', ServiceType.vent));
  }
  return (net: Network(nodes: nodes, edges: edges), dfu: dfu);
}

void main() {
  test('a header between two stack tops leaves the small stack its own size',
      () {
    final alone = _twoStacks(header: false);
    final tied = _twoStacks(header: true);
    final fuAlone = <String, double>{};
    final fuTied = <String, double>{};
    final sAlone = autoSizeNetwork(alone.net, const SizingContext(),
        leafDemand: const {},
        nodeDrainageUnits: alone.dfu,
        fixtureUnitsOut: fuAlone);
    final sTied = autoSizeNetwork(tied.net, const SizingContext(),
        leafDemand: const {},
        nodeDrainageUnits: tied.dfu,
        fixtureUnitsOut: fuTied);
    // Stack B: 4 floors x 1 DFU = 4 DFU; UPC 703.2 1 < 4 <= 8 ⇒ DN40.
    expect(drain.ventDiameterForDfu(4).inMillimeters, 40);
    for (final id in ['vB1', 'vB2', 'vB3']) {
      expect(sAlone[id]!.diameter.inMillimeters, 40, reason: '$id alone');
      expect(sTied[id]!.diameter.inMillimeters, 40, reason: '$id tied');
      expect(fuTied[id], fuAlone[id], reason: '$id basis');
    }
    // The header itself carries B's own load, not the merged 36 DFU.
    expect(fuTied['hdr'], lessThan(36));
    expect(sTied['hdr']!.diameter.inMillimeters, 40);
    // Stack A carries its vent basis (32 DFU: the soil stack's 40 less the
    // foot's own seed, the Round-25 base rule) ⇒ DN65 (24 < 32 <= 48); with
    // the header its VTR also takes B's 4 ⇒ 36 DFU, still DN65.
    expect(fuTied['vtrA'], fuAlone['vtrA']! + fuTied['hdr']!);
    for (final id in ['vA1', 'vA2', 'vA3', 'vtrA']) {
      expect(sTied[id]!.diameter.inMillimeters, 65, reason: id);
    }
  });

  test('mirrored header (VTR on the SMALL stack) leaves it its own size', () {
    // Round 26 r2 — A's top VA3 headered into B's top VB3, VTR only on B.
    // The stub VB3 -> VTRB carries A + B (36 DFU, DN65) but B's own stack
    // stays on its own 4 DFU (DN40); A keeps its own 32 DFU (DN65).
    final alone = _twoStacks(header: false);
    final tied = _twoStacks(header: true, mirror: true);
    final fuTied = <String, double>{};
    final sAlone = autoSizeNetwork(alone.net, const SizingContext(),
        leafDemand: const {}, nodeDrainageUnits: alone.dfu);
    final sTied = autoSizeNetwork(tied.net, const SizingContext(),
        leafDemand: const {},
        nodeDrainageUnits: tied.dfu,
        fixtureUnitsOut: fuTied);
    for (final id in ['vB1', 'vB2', 'vB3']) {
      expect(sTied[id]!.diameter.inMillimeters, 40, reason: id);
    }
    for (final id in ['vA1', 'vA2', 'vA3']) {
      expect(
          sTied[id]!.diameter.inMillimeters, sAlone[id]!.diameter.inMillimeters,
          reason: id);
    }
    // The shared stub to the one VTR carries the combined load.
    expect(sTied['vtrB']!.diameter.inMillimeters, 65);
    expect(sTied['hdr']!.diameter.inMillimeters,
        drain.ventDiameterForDfu(fuTied['hdr']!).inMillimeters);
  });

  test(
      'property: a header never changes either stack, both orientations '
      '(seeded)', () {
    final rnd = math.Random(26);
    for (var trial = 0; trial < 40; trial++) {
      final a = 1.0 + rnd.nextInt(20);
      final b = 1.0 + rnd.nextInt(20);
      final mirror = trial.isOdd;
      final alone = _twoStacks(header: false, dfuA: a, dfuB: b);
      final tied = _twoStacks(header: true, mirror: mirror, dfuA: a, dfuB: b);
      final sAlone = autoSizeNetwork(alone.net, const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: alone.dfu);
      final sTied = autoSizeNetwork(tied.net, const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: tied.dfu);
      for (final id in ['vA1', 'vA2', 'vA3', 'vB1', 'vB2', 'vB3']) {
        expect(sTied[id]!.diameter.inMillimeters,
            sAlone[id]!.diameter.inMillimeters,
            reason: 'trial $trial mirror=$mirror a=$a b=$b $id');
      }
    }
  });

  test(
      'a MID-storey header off a stack with NO VTR (dead stub above) bounds '
      'that stack by its whole load', () {
    // Round 26 r3 — A (10 DFU/floor x 4) headered A -> B at floor 2, VTR
    // only on B, A's vent riser continuing to floor 3 as a dead stub (tied to
    // its soil stack at floor 3, no VTR). A's vent air leaves ONLY through
    // the header, so the header carries A's whole vent load and A's stack is
    // sized on it (IPC 916.1 / UPC 703.2 uniform): DN65 over vA1..vA3, the
    // size A takes alone with its own VTR (32 DFU basis, 24 < 32 <= 48).
    // Before, the stub above the junction made A read as the RECEIVING stack
    // and A was sized on its member max (vA2 = 20 DFU ⇒ DN50).
    final alone = _twoStacks(header: false);
    final tied = _twoStacks(
        header: true, mirror: true, headerFloor: 2, vtrA: false, vtrB: true);
    final fuTied = <String, double>{};
    final sAlone = autoSizeNetwork(alone.net, const SizingContext(),
        leafDemand: const {}, nodeDrainageUnits: alone.dfu);
    final sTied = autoSizeNetwork(tied.net, const SizingContext(),
        leafDemand: const {},
        nodeDrainageUnits: tied.dfu,
        fixtureUnitsOut: fuTied);
    for (final id in ['vA1', 'vA2', 'vA3']) {
      expect(sAlone[id]!.diameter.inMillimeters, 65, reason: '$id alone');
      expect(sTied[id]!.diameter.inMillimeters, 65, reason: id);
    }
    // The header carries A's whole load; it is sized on its own basis.
    expect(sTied['hdr']!.diameter.inMillimeters,
        drain.ventDiameterForDfu(fuTied['hdr']!).inMillimeters);
    // B below the junction keeps its own 4 DFU (DN40); the shared section
    // above it to B's VTR carries A + B (DN65).
    for (final id in ['vB1', 'vB2']) {
      expect(sTied[id]!.diameter.inMillimeters, 40, reason: id);
    }
    for (final id in ['vB3', 'vtrB']) {
      expect(sTied[id]!.diameter.inMillimeters, 65, reason: id);
    }
  });

  test('a second VTR on one vent component is an open terminal (no load)', () {
    // Round 26 r3 — VTRs on BOTH stacks, header at floor 2. Only one VTR is
    // the vent tree root; the other used to take the 2-DFU leaf default, so
    // the header read B's 8 DFU (4 floors x 2) + 2 = 10 ⇒ DN50 where B alone
    // is DN40 (1 < 6 <= 8, UPC 703.2). An open VTR bears no vent load: the
    // header carries exactly what B's own VTR carries alone.
    final alone = _twoStacks(header: false, dfuA: 19, dfuB: 2);
    final tied = _twoStacks(
        header: true,
        headerFloor: 2,
        vtrA: true,
        vtrB: true,
        dfuA: 19,
        dfuB: 2);
    final fuAlone = <String, double>{};
    final fuTied = <String, double>{};
    final sAlone = autoSizeNetwork(alone.net, const SizingContext(),
        leafDemand: const {},
        nodeDrainageUnits: alone.dfu,
        fixtureUnitsOut: fuAlone);
    final sTied = autoSizeNetwork(tied.net, const SizingContext(),
        leafDemand: const {},
        nodeDrainageUnits: tied.dfu,
        fixtureUnitsOut: fuTied);
    expect(fuAlone['vtrB'], 8);
    expect(fuTied['hdr'], fuAlone['vtrB']);
    expect(fuTied['vtrA'], fuAlone['vtrA']! + fuAlone['vtrB']!);
    for (final id in ['vB1', 'vB2', 'vA1', 'vA2']) {
      expect(
          sTied[id]!.diameter.inMillimeters, sAlone[id]!.diameter.inMillimeters,
          reason: id);
    }
  });

  test(
      'property: header storey x direction x VTR placement — a VTR-less stack '
      'keeps its own size everywhere, a vented stack below the junction '
      '(seeded)', () {
    final rnd = math.Random(2603);
    for (var trial = 0; trial < 60; trial++) {
      final a = 1.0 + rnd.nextInt(20);
      final b = 1.0 + rnd.nextInt(20);
      final hf = 1 + rnd.nextInt(3);
      final mirror = rnd.nextBool();
      // A non-empty VTR set: A only, B only, or both.
      final pick = rnd.nextInt(3);
      final vtrA = pick != 1;
      final vtrB = pick != 0;
      final alone = _twoStacks(header: false, dfuA: a, dfuB: b);
      final tied = _twoStacks(
          header: true,
          mirror: mirror,
          headerFloor: hf,
          vtrA: vtrA,
          vtrB: vtrB,
          dfuA: a,
          dfuB: b);
      final sAlone = autoSizeNetwork(alone.net, const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: alone.dfu);
      final sTied = autoSizeNetwork(tied.net, const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: tied.dfu);
      final why = 'trial $trial hf=$hf mirror=$mirror vtrA=$vtrA vtrB=$vtrB '
          'a=$a b=$b';
      for (final (tag, vented) in [('A', vtrA), ('B', vtrB)]) {
        for (var f = 1; f <= 3; f++) {
          final id = 'v$tag$f';
          final own = sAlone[id]!.diameter.inMillimeters;
          final got = sTied[id]!.diameter.inMillimeters;
          if (!vented || f <= hf) {
            // A drained stack (no VTR) is sized on its whole load all the
            // way up; a vented stack below / at the junction riser keeps
            // its own soil stack's size.
            expect(got, own, reason: '$why $id');
          } else {
            // The shared section above the junction carries both stacks.
            expect(got, greaterThanOrEqualTo(own), reason: '$why $id');
          }
        }
      }
    }
  });
}
