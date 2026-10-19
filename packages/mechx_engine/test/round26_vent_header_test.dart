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
    NetNode(
        id: id, sheetId: 's1', x: x, y: y, floorIndex: floor, role: role);

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

/// Two soil stacks off one outfall — A at [dfuA] per floor, B at [dfuB] per
/// floor, 4 floors — each with its own vent stack tied every floor. With
/// [header], B's top VB3 runs to A's top VA3 and only A has a VTR; without
/// it each stack has its own VTR.
({Network net, Map<String, double> dfu}) _twoStacks(
    {required bool header, double dfuA = 10, double dfuB = 1}) {
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
          ..add(_e('ds$tag$f', 'DS$tag${f - 1}', 'DS$tag$f',
              ServiceType.drainage,
              kind: EdgeKind.riser))
          ..add(_e('v$tag$f', 'V$tag${f - 1}', 'V$tag$f', ServiceType.vent,
              kind: EdgeKind.riser));
      }
    }
  }
  nodes.add(_n('VTRA', 120, 0, floor: 4));
  edges.add(_e('vtrA', 'VA3', 'VTRA', ServiceType.vent, kind: EdgeKind.riser));
  if (header) {
    edges.add(_e('hdr', 'VB3', 'VA3', ServiceType.vent));
  } else {
    nodes.add(_n('VTRB', 420, 0, floor: 4));
    edges.add(
        _e('vtrB', 'VB3', 'VTRB', ServiceType.vent, kind: EdgeKind.riser));
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

  test('property: a header never changes the other stack (seeded)', () {
    final rnd = math.Random(26);
    for (var trial = 0; trial < 25; trial++) {
      final a = 1.0 + rnd.nextInt(20);
      final b = 1.0 + rnd.nextInt(20);
      final alone = _twoStacks(header: false, dfuA: a, dfuB: b);
      final tied = _twoStacks(header: true, dfuA: a, dfuB: b);
      final sAlone = autoSizeNetwork(alone.net, const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: alone.dfu);
      final sTied = autoSizeNetwork(tied.net, const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: tied.dfu);
      for (final id in ['vB1', 'vB2', 'vB3']) {
        expect(sTied[id]!.diameter.inMillimeters,
            sAlone[id]!.diameter.inMillimeters,
            reason: 'trial $trial a=$a b=$b $id');
      }
    }
  });
}
