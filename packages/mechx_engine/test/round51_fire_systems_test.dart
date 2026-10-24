// Round 51 — fire systems split at storage tanks, and the series pump chain
// read from topology (not floors). Seeded properties.
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:test/test.dart';

NetNode _n(String id,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's',
        x: 0,
        y: 0,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        [ServiceType s = ServiceType.fireHydrant]) =>
    NetEdge(id: id, fromId: a, toId: b, service: s);

void main() {
  test(
      'property: every fire edge in exactly one system; systems share only '
      'tank nodes (seeded)', () {
    final rng = math.Random(5101);
    for (var trial = 0; trial < 200; trial++) {
      final nNodes = 4 + rng.nextInt(12);
      final nodes = <NetNode>[
        for (var i = 0; i < nNodes; i++)
          _n('n$i',
              role: rng.nextInt(5) == 0 ? NodeRole.plant : NodeRole.main,
              c: switch (rng.nextInt(8)) {
                0 => NodeComponent.groundTank,
                1 => NodeComponent.roofTank,
                2 => NodeComponent.pump,
                _ => null,
              }),
      ];
      final edges = <NetEdge>[
        for (var k = 0; k < nNodes + rng.nextInt(6); k++)
          _e(
              'e$k',
              'n${rng.nextInt(nNodes)}',
              'n${rng.nextInt(nNodes)}',
              rng.nextBool()
                  ? ServiceType.fireHydrant
                  : ServiceType.fireSprinkler),
      ];
      final net = Network(nodes: nodes, edges: edges);
      final sys = fireSystems(net);
      final seen = <String>{};
      for (final s in sys) {
        for (final e in s.edges) {
          expect(seen.add(e.id), isTrue, reason: 'edge ${e.id} twice');
          expect(s.nodeIds.contains(e.fromId), isTrue);
          expect(s.nodeIds.contains(e.toId), isTrue);
        }
      }
      expect(seen.length, edges.length);
      for (var i = 0; i < sys.length; i++) {
        for (var j = i + 1; j < sys.length; j++) {
          for (final id in sys[i].nodeIds.intersection(sys[j].nodeIds)) {
            expect(isFireSystemBoundary(net.nodeById(id)), isTrue,
                reason: 'shared non-tank node $id');
          }
        }
      }
      // Two pipes sharing a NON-tank node are always in one system.
      final sysOf = <String, int>{};
      for (var i = 0; i < sys.length; i++) {
        for (final e in sys[i].edges) {
          sysOf[e.id] = i;
        }
      }
      for (final a in edges) {
        for (final b in edges) {
          final shared = {a.fromId, a.toId}.intersection({b.fromId, b.toId});
          if (shared.any((id) => !isFireSystemBoundary(net.nodeById(id)))) {
            expect(sysOf[a.id], sysOf[b.id]);
          }
        }
      }
    }
  });

  test('a network with no tank keeps the plain connected components', () {
    final net = Network(nodes: [
      for (final id in ['a', 'b', 'c', 'd']) _n(id),
    ], edges: [
      _e('ab', 'a', 'b'),
      _e('cd', 'c', 'd', ServiceType.fireSprinkler),
      _e('bc', 'b', 'c'),
    ]);
    expect(fireSystems(net), hasLength(1));
  });

  test(
      'property: a series chain GT -> P1 -> ... -> Pn is staged in flow '
      'order whatever floor each pump sits on (seeded)', () {
    final rng = math.Random(5102);
    for (var trial = 0; trial < 100; trial++) {
      final n = 2 + rng.nextInt(4);
      final nodes = <NetNode>[
        _n('GT', role: NodeRole.plant, c: NodeComponent.groundTank),
        for (var i = 1; i <= n; i++) ...[
          _n('P$i',
              floor: rng.nextInt(3),
              role: NodeRole.plant,
              c: NodeComponent.pump),
          _n('D$i'),
          _n('Z$i'),
          _n('HB$i', role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        ],
      ];
      final edges = <NetEdge>[
        _e('g', 'GT', 'P1'),
        for (var i = 1; i <= n; i++) ...[
          _e('p$i', 'P$i', 'D$i'),
          _e('z$i', 'D$i', 'Z$i'),
          _e('hb$i', 'Z$i', 'HB$i'),
          if (i < n) _e('s$i', 'D$i', 'P${i + 1}'),
        ],
      ];
      // Shuffle the drawing order: topology, not order, decides.
      edges.shuffle(rng);
      final net = Network(nodes: nodes, edges: edges);
      final sys = fireSystems(net).single;
      final ids = [for (var i = 1; i <= n; i++) 'P$i'];
      final sets = fireParallelPumpSets(net, sys, ids);
      final st = fireSeriesPumpStages(net, sys, sets);
      expect(st, isNotNull);
      expect(st!.map((s) => s.pumpIds.single), ids);
      for (var k = 0; k < n; k++) {
        expect(st[k].upstream, k == 0 ? null : k - 1);
        expect(st[k].discharge.nodeIds, contains('HB${k + 1}'));
        for (var j = 1; j <= n; j++) {
          if (j != k + 1) {
            expect(st[k].discharge.nodeIds.contains('HB$j'), isFalse);
          }
        }
      }
    }
  });

  test('a bypass (both sides reached) is unreadable: null', () {
    // GT -> A -P1-> B -P2-> C is a readable two-stage chain; P3 drawn A -> C
    // bypasses P2, so by the time P2 is judged BOTH its sides (B from P1, C
    // from P3) were reached in an earlier round: the `ra && rb` branch.
    // A, B and C are real junctions (a hydrant box each), so every pump's
    // leg ends stop there — never walk through to another pump (the
    // back-to-back guard, a different null).
    Network chain({required bool bypass}) => Network(nodes: [
          _n('GT', role: NodeRole.plant, c: NodeComponent.groundTank),
          _n('A'),
          _n('B'),
          _n('C'),
          for (final j in ['A', 'B', 'C'])
            _n('HB$j', role: NodeRole.fixture, c: NodeComponent.hydrantBox),
          _n('P1', role: NodeRole.plant, c: NodeComponent.pump),
          _n('P2', role: NodeRole.plant, c: NodeComponent.pump),
          if (bypass) _n('P3', role: NodeRole.plant, c: NodeComponent.pump),
        ], edges: [
          _e('ga', 'GT', 'A'),
          for (final j in ['A', 'B', 'C']) _e('hb$j', j, 'HB$j'),
          _e('a1', 'A', 'P1'),
          _e('1b', 'P1', 'B'),
          _e('b2', 'B', 'P2'),
          _e('2c', 'P2', 'C'),
          if (bypass) ...[
            _e('a3', 'A', 'P3'),
            _e('3c', 'P3', 'C'),
          ],
        ]);

    final plain = chain(bypass: false);
    final ps = fireSystems(plain).single;
    for (final id in ['P1', 'P2']) {
      final ends = fireDrawnPumpLegEnds(plain, ps, id);
      expect({ends.$1, ends.$2}.intersection({'P1', 'P2', 'P3'}), isEmpty);
    }
    final readable = fireSeriesPumpStages(
        plain, ps, fireParallelPumpSets(plain, ps, ['P1', 'P2']));
    expect(readable, isNotNull);
    expect(readable!.map((s) => s.pumpIds.single), ['P1', 'P2']);

    final net = chain(bypass: true);
    final sys = fireSystems(net).single;
    for (final id in ['P1', 'P2', 'P3']) {
      final ends = fireDrawnPumpLegEnds(net, sys, id);
      expect({ends.$1, ends.$2}.intersection({'P1', 'P2', 'P3'}), isEmpty);
    }
    final sets = fireParallelPumpSets(net, sys, ['P1', 'P2', 'P3']);
    // Three distinct (suction, discharge) pairs — no parallel merge hides it.
    expect(sets, hasLength(3));
    expect(fireSeriesPumpStages(net, sys, sets), isNull);
  });
}
