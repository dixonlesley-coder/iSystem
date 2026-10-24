// Round 55 (2026-10-18) — engine pins:
//
//   regression-fire-fragment-rooted-past-inline-terminal-starves-pump-train —
//     a sprinkler branch drawn straight off a hose-reel / hydrant-box tee is
//     fed THROUGH that terminal: the fragment roots at the join
//     (`fireServiceJoinNodes`), so the pump train carries the 12 L/s
//     remote-area demand, not the 5 L/s reel flow.
//   regression-hydrant-cross-tie-adds-phantom-standpipe-stack — a sprinkler
//     riser is a standpipe stack only when a hydrant branch off it reaches a
//     hose outlet of its own; a cross-tie to another stack is not one.
//   regression-mccb-refusal-keeps-mcb-that-also-fails-ads — the MCCB class
//     refusal keeps the MCB only when that MCB passes ADS; a way failing as
//     both keeps its adequate-kA MCCB and one `ads-disconnection` error.
//
// First principles: the sprinkler remote area here is capped at 12 L/s; the
// pump train d / ab / br carries max(hydrant 5 L/s, sprinkler 12 L/s) = 12
// L/s. DN65 (ID 65 mm, A = pi 0.065^2 / 4 = 3.318e-3 m2) runs
// v = 0.012 / 3.318e-3 = 3.6 m/s (inside the 6 m/s fire cap); DN40 would run
// 0.012 / 1.257e-3 = 9.5 m/s.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/hydraulics.dart'
    show headFromPressure, pressureFromHead;
import 'package:mechx_engine/network/hot_water_pressure.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x,
        {int floor = 0,
        double y = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.fireHydrant, EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

BuildingLevels _floors(int n) => BuildingLevels(
    [for (var i = 0; i < n; i++) Floor('L$i', const Length(3.5))]);

Map<String, EdgeSizing> _size(Network net, BuildingLevels b,
        {FlowRate? sprinkler = const FlowRate(0.012), FlowRate? hydrant}) =>
    autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {
        ServiceType.fireHydrant: FlowRate(0.005),
        ServiceType.fireSprinkler: FlowRate(0.001),
      },
      sprinklerDemandCap: sprinkler,
      hydrantDesignFlow: hydrant ?? standpipeFlow(1),
      building: b,
    );

/// GT -> FP -> A -> B (hydrant), then B -> R0 as SPRINKLER and a sprinkler
/// riser R0..R5 with 3 heads per floor. [inlineReel]: B is the hose reel
/// itself (the branch teed straight off the reel); else B is a bare tee with
/// the reel on a stub B -> HR. [flip] draws `br` from R0.
Network _reelTee({required bool inlineReel, required bool flip}) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 10, role: NodeRole.plant, c: NodeComponent.pump),
    _n('A', 20),
    inlineReel
        ? _n('B', 30, role: NodeRole.fixture, c: NodeComponent.hoseReel)
        : _n('B', 30),
    if (!inlineReel)
      _n('HR', 32, role: NodeRole.fixture, c: NodeComponent.hoseReel),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'FP'),
    _e('d', 'FP', 'A'),
    _e('ab', 'A', 'B'),
    if (!inlineReel) _e('hr', 'B', 'HR'),
    flip
        ? _e('br', 'R0', 'B', s: ServiceType.fireSprinkler)
        : _e('br', 'B', 'R0', s: ServiceType.fireSprinkler),
  ];
  for (var k = 0; k < 6; k++) {
    nodes.add(_n('R$k', 40, floor: k));
    if (k > 0) {
      edges.add(_e('r$k', 'R${k - 1}', 'R$k',
          s: ServiceType.fireSprinkler, k: EdgeKind.riser));
    }
    for (var j = 0; j < 3; j++) {
      nodes.add(_n('H${k}_$j', 50.0 + j * 5,
          floor: k, role: NodeRole.fixture, c: NodeComponent.sprinklerHead));
      edges
          .add(_e('h${k}_$j', 'R$k', 'H${k}_$j', s: ServiceType.fireSprinkler));
    }
  }
  return Network(nodes: nodes, edges: edges);
}

/// 6 floors, GT -> FP -> A; A -> H0..H5 a hydrant stack (a box per floor);
/// A -> S0..S5 a sprinkler riser (3 heads per floor, no hose outlet). [tie]
/// adds one hydrant edge H5 -> S5 at the top floor.
Network _stackPlusSprinklerRiser({required bool tie}) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 10, role: NodeRole.plant, c: NodeComponent.pump),
    _n('A', 20),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'FP'),
    _e('d', 'FP', 'A'),
    _e('ah', 'A', 'H0'),
    _e('as', 'A', 'S0', s: ServiceType.fireSprinkler),
    if (tie) _e('tie', 'H5', 'S5'),
  ];
  for (var k = 0; k < 6; k++) {
    nodes.add(_n('H$k', 30, floor: k));
    nodes.add(_n('S$k', 60, floor: k));
    nodes.add(_n('B$k', 35,
        floor: k, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges.add(_e('b$k', 'H$k', 'B$k'));
    if (k > 0) {
      edges.add(_e('hr$k', 'H${k - 1}', 'H$k', k: EdgeKind.riser));
      edges.add(_e('sr$k', 'S${k - 1}', 'S$k',
          s: ServiceType.fireSprinkler, k: EdgeKind.riser));
    }
    for (var j = 0; j < 3; j++) {
      nodes.add(_n('Q${k}_$j', 65.0 + j * 5,
          floor: k, role: NodeRole.fixture, c: NodeComponent.sprinklerHead));
      edges
          .add(_e('q${k}_$j', 'S$k', 'Q${k}_$j', s: ServiceType.fireSprinkler));
    }
  }
  return Network(nodes: nodes, edges: edges);
}

/// GT -> S, S -> P1 -> D and S -> P2 -> D (duty + standby) drawn on [room];
/// D -> R0..R5 a riser drawn on [riser] with a hydrant box and 4 heads per
/// floor. [flip] draws every room / riser pipe backwards.
Network _pumpRoom(ServiceType room, ServiceType riser,
    {bool two = true, bool flip = false}) {
  NetEdge e(String id, String a, String b, ServiceType s,
          [EdgeKind k = EdgeKind.run]) =>
      flip ? _e(id, b, a, s: s, k: k) : _e(id, a, b, s: s, k: k);
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('S', 5),
    _n('P1', 10, role: NodeRole.plant, c: NodeComponent.pump),
    if (two) _n('P2', 10, y: 10, role: NodeRole.plant, c: NodeComponent.pump),
    _n('D', 15),
  ];
  final edges = <NetEdge>[
    e('g', 'GT', 'S', room),
    e('s1', 'S', 'P1', room),
    e('d1', 'P1', 'D', room),
    if (two) e('s2', 'S', 'P2', room),
    if (two) e('d2', 'P2', 'D', room),
    e('dr', 'D', 'R0', riser),
  ];
  for (var k = 0; k < 6; k++) {
    nodes.add(_n('R$k', 30, floor: k));
    if (k > 0) edges.add(e('r$k', 'R${k - 1}', 'R$k', riser, EdgeKind.riser));
    nodes.add(_n('B$k', 35,
        floor: k, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges.add(_e('b$k', 'R$k', 'B$k'));
    for (var j = 0; j < 4; j++) {
      nodes.add(_n('H${k}_$j', 50.0 + j * 5,
          floor: k, role: NodeRole.fixture, c: NodeComponent.sprinklerHead));
      edges
          .add(_e('h${k}_$j', 'R$k', 'H${k}_$j', s: ServiceType.fireSprinkler));
    }
  }
  return Network(nodes: nodes, edges: edges);
}

void main() {
  group('sprinkler branch teed straight off a hose reel', () {
    final b = _floors(6);
    for (final flip in [false, true]) {
      test(
          'the pump train carries the 12 L/s remote area at DN65 and the '
          'branch flows reel -> riser (flip=$flip)', () {
        final r = _size(_reelTee(inlineReel: true, flip: flip), b);
        for (final id in ['g', 'd', 'ab', 'br']) {
          expect(r[id]!.flow.inLitersPerSecond, closeTo(12.0, 1e-9),
              reason: id);
          expect(r[id]!.diameter.inMillimeters, 65, reason: id);
          const v = 0.012 / (math.pi * 0.065 * 0.065 / 4);
          expect(v, closeTo(3.62, 0.01));
        }
        expect(r['br']!.flowFromId, 'B');
      });
    }

    test('the bare-tee control (reel on a stub) sizes the same train', () {
      for (final flip in [false, true]) {
        final reel = _size(_reelTee(inlineReel: true, flip: flip), b);
        final tee = _size(_reelTee(inlineReel: false, flip: flip), b);
        for (final id in ['g', 'd', 'ab', 'br', 'r1', 'r5']) {
          expect(reel[id]!.flow.cubicMetersPerSecond,
              closeTo(tee[id]!.flow.cubicMetersPerSecond, 1e-12),
              reason: id);
          expect(
              reel[id]!.diameter.inMillimeters, tee[id]!.diameter.inMillimeters,
              reason: id);
          expect(reel[id]!.flowFromId, tee[id]!.flowFromId, reason: id);
        }
        // The reel's own 5 L/s hose flow on its stub.
        expect(tee['hr']!.flow.inLitersPerSecond, closeTo(5.0, 1e-9));
      }
    });
  });

  group('top-floor hydrant cross-tie to a sprinkler riser', () {
    final b = _floors(6);
    test(
        'counts ONE standpipe stack (500 gpm, DN100 discharge) with or '
        'without the tie; no pipe is sized for the phantom 750 gpm', () {
      for (final tie in [false, true]) {
        final net = _stackPlusSprinklerRiser(tie: tie);
        final n = drawnStandpipeRiserCount(net);
        expect(n, 1, reason: 'tie=$tie');
        final r = _size(net, b, hydrant: standpipeFlow(n));
        // 500 gpm = 500 x 3.785411784 / 60 = 31.545 L/s.
        expect(r['d']!.flow.inLitersPerSecond, closeTo(31.545, 1e-3),
            reason: 'tie=$tie');
        expect(r['d']!.diameter.inMillimeters, 100, reason: 'tie=$tie');
        // Without the tie the sprinkler riser carries its own 12 L/s remote
        // area (DN65, 3.6 m/s). With it, the tie closes a ring through the
        // sprinkler riser — the top hose outlet can be fed round that arm —
        // so the Round-48/54 ring rule sizes it for the ONE-stack standpipe
        // flow (DN100, 4.0 m/s), never the phantom two-stack 750 gpm DN125.
        expect(r['sr1']!.flow.inLitersPerSecond,
            closeTo(tie ? 31.545 : 12.0, 1e-3),
            reason: 'tie=$tie');
        expect(r['sr1']!.diameter.inMillimeters, tie ? 100 : 65,
            reason: 'tie=$tie');
        for (final e in r.values) {
          expect(e.flow.inLitersPerSecond, lessThan(31.546),
              reason: 'tie=$tie ${e.edgeId}');
        }
      }
    });

    test('a box teed off the sprinkler riser still makes it a stack', () {
      final base = _stackPlusSprinklerRiser(tie: false);
      final net = Network(nodes: [
        ...base.nodes,
        _n('X', 70,
            floor: 3, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ], edges: [
        ...base.edges,
        _e('x', 'S3', 'X'),
      ]);
      expect(drawnStandpipeRiserCount(net), 2);
    });
  });

  test(
      'seeded property: 200 random mixed hydrant / sprinkler fire networks '
      'with INLINE terminals (branches teed off a reel / box / head) and '
      '1-2 same-floor chords (rings) — flipping any fire pipe and shuffling '
      'the drawing order never changes any size, flow or direction', () {
    final b = _floors(6);
    var ringSeeds = 0;
    for (var seed = 0; seed < 200; seed++) {
      final rnd = math.Random(5500 + seed);
      final nodes = <NetNode>[
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('FP', 5, role: NodeRole.plant, c: NodeComponent.pump),
      ];
      final edges = <NetEdge>[_e('g', 'GT', 'FP')];
      final open = <NetNode>[nodes[1]];
      final count = 6 + rnd.nextInt(20);
      for (var i = 0; i < count; i++) {
        final parent = open[rnd.nextInt(open.length)];
        final svc = rnd.nextBool()
            ? ServiceType.fireHydrant
            : ServiceType.fireSprinkler;
        final up = rnd.nextInt(4) == 0 && parent.floorIndex < 5;
        final floor = up ? parent.floorIndex + 1 : parent.floorIndex;
        final terminal = rnd.nextInt(3) == 0;
        final id = 'N$i';
        final node = terminal
            ? _n(id, parent.x + 5,
                y: i.toDouble(),
                floor: floor,
                role: NodeRole.fixture,
                c: svc == ServiceType.fireHydrant
                    ? (rnd.nextBool()
                        ? NodeComponent.hydrantBox
                        : NodeComponent.hoseReel)
                    : NodeComponent.sprinklerHead)
            : _n(id, parent.x + 5, y: i.toDouble(), floor: floor);
        nodes.add(node);
        // A terminal sometimes carries a branch on (an inline reel / head).
        if (!terminal || rnd.nextInt(3) == 0) open.add(node);
        edges.add(_e('e$i', parent.id, id,
            s: svc, k: up ? EdgeKind.riser : EdgeKind.run));
      }
      // 1-2 same-floor chords between non-terminal nodes of one service.
      final chords = 1 + rnd.nextInt(2);
      for (var c = 0; c < chords; c++) {
        final mains = [
          for (final n in nodes.skip(2))
            if (n.role == NodeRole.main) n
        ];
        if (mains.length < 2) break;
        final a = mains[rnd.nextInt(mains.length)];
        final peers = [
          for (final n in mains)
            if (n.id != a.id &&
                n.floorIndex == a.floorIndex &&
                !edges.any((e) =>
                    (e.fromId == a.id && e.toId == n.id) ||
                    (e.fromId == n.id && e.toId == a.id)))
              n
        ];
        if (peers.isEmpty) continue;
        final p = peers[rnd.nextInt(peers.length)];
        if (c == 0) ringSeeds++;
        edges.add(_e('c$c', a.id, p.id,
            s: rnd.nextBool()
                ? ServiceType.fireHydrant
                : ServiceType.fireSprinkler));
      }
      final base = _size(Network(nodes: nodes, edges: edges), b);
      final flipped = [
        for (final e in edges)
          rnd.nextBool()
              ? NetEdge(
                  id: e.id,
                  fromId: e.toId,
                  toId: e.fromId,
                  service: e.service,
                  kind: e.kind)
              : e,
      ]..shuffle(rnd);
      final other =
          _size(Network(nodes: [...nodes]..shuffle(rnd), edges: flipped), b);
      for (final e in edges) {
        final x = base[e.id], y = other[e.id];
        expect(x == null, y == null, reason: 'seed $seed ${e.id}');
        if (x == null || y == null) continue;
        expect(y.flow.cubicMetersPerSecond,
            closeTo(x.flow.cubicMetersPerSecond, 1e-9),
            reason: 'seed $seed ${e.id} flow');
        expect(y.diameter.inMillimeters, x.diameter.inMillimeters,
            reason: 'seed $seed ${e.id} size');
        if (x.flow.cubicMetersPerSecond > 1e-9) {
          expect(y.flowFromId, x.flowFromId, reason: 'seed $seed ${e.id} from');
        }
      }
    }
    // Non-vacuous: most seeds carry at least one ring.
    expect(ringSeeds, greaterThan(100));
  });

  group('duty + standby pump room on one fire service, riser on the other', () {
    final b = _floors(6);
    const hyd = ServiceType.fireHydrant, spr = ServiceType.fireSprinkler;
    Map<String, EdgeSizing> run(Network net, [Set<String>? legs]) =>
        autoSizeNetwork(
          net,
          const SizingContext(),
          leafDemand: const {
            ServiceType.fireHydrant: FlowRate(0.005),
            ServiceType.fireSprinkler: FlowRate(0.001),
          },
          sprinklerDemandCap: const FlowRate(0.012),
          hydrantDesignFlow: const FlowRate(0.0315),
          parallelLegEdgeIdsOut: legs,
          building: b,
        );
    for (final (room, riser) in [(hyd, spr), (spr, hyd)]) {
      for (final flip in [false, true]) {
        test(
            'room ${room.name} / riser ${riser.name} (flip=$flip): every room '
            'pipe carries the 31.5 L/s Class I flow at DN100, the standby '
            'leg mirrored and recorded', () {
          final legs = <String>{};
          final r = run(_pumpRoom(room, riser, flip: flip), legs);
          // DN100: v = 0.0315 / (pi 0.1^2 / 4) = 4.01 m/s (inside 6 m/s).
          expect(0.0315 / (math.pi * 0.01 / 4), closeTo(4.01, 0.01));
          for (final id in ['g', 's1', 'd1', 's2', 'd2', 'dr', 'r1']) {
            expect(r[id], isNotNull, reason: id);
            expect(r[id]!.flow.inLitersPerSecond, closeTo(31.5, 1e-9),
                reason: id);
            expect(r[id]!.diameter.inMillimeters, 100, reason: id);
          }
          // Oriented tank -> pumps -> header, whatever the drawing.
          expect(r['g']!.flowFromId, 'GT');
          expect(r['s1']!.flowFromId, 'S');
          expect(r['d1']!.flowFromId, 'P1');
          expect(r['s2']!.flowFromId, 'S');
          expect(r['d2']!.flowFromId, 'P2');
          // P2 (the higher id) is the standby: its leg is the mirrored one.
          expect(legs, {'s2', 'd2'});
        });
      }
    }

    test('the single-pump variant is unchanged (no standby leg)', () {
      for (final (room, riser) in [(hyd, spr), (spr, hyd)]) {
        final legs = <String>{};
        final r = run(_pumpRoom(room, riser, two: false), legs);
        for (final id in ['g', 's1', 'd1', 'dr']) {
          expect(r[id]!.flow.inLitersPerSecond, closeTo(31.5, 1e-9));
          expect(r[id]!.diameter.inMillimeters, 100);
        }
        expect(legs, isEmpty);
      }
    });
  });

  group('FDC teed into a hydrant ring main', () {
    final b = _floors(1);
    Network main({required bool ring, required bool fdcInward}) {
      final nodes = <NetNode>[
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('P', 10, role: NodeRole.plant, c: NodeComponent.pump),
        for (var k = 0; k < 4; k++) ...[
          _n('J$k', 20.0 + 10 * k),
          _n('B$k', 20.0 + 10 * k,
              y: 10, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        ],
        _n('F', 40, y: -10, c: NodeComponent.fireDeptConnection),
      ];
      final edges = <NetEdge>[
        _e('g', 'GT', 'P'),
        _e('p', 'P', 'J0'),
        for (var k = 0; k < 3; k++) _e('m$k', 'J$k', 'J${k + 1}'),
        if (ring) _e('m3', 'J3', 'J0'),
        for (var k = 0; k < 4; k++) _e('b$k', 'J$k', 'B$k'),
        fdcInward ? _e('fdc', 'F', 'J2') : _e('fdc', 'J2', 'F'),
      ];
      return Network(nodes: nodes, edges: edges);
    }

    test(
        'the FDC line is sized on the largest flow at its junction, at least '
        'DN100, on a ring exactly as on a tree, in both drawing directions',
        () {
      for (final inward in [false, true]) {
        final tree = _size(main(ring: false, fdcInward: inward), b);
        final ring = _size(main(ring: true, fdcInward: inward), b);
        for (final r in [tree, ring]) {
          final f = r['fdc'];
          expect(f, isNotNull, reason: 'inward=$inward');
          // 500 gpm = 31.545 L/s at the junction -> DN100 (4.0 m/s).
          expect(f!.flow.inLitersPerSecond, closeTo(31.545, 1e-3));
          expect(f.diameter.inMillimeters, 100);
          expect(f.flowFromId, 'F');
        }
      }
    });
  });

  group('duty + standby + jockey room with the jockey on hand-picked DN25', () {
    final b = _floors(6);
    Network room(String jockeyId) {
      final nodes = <NetNode>[
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('S', 5),
        _n('P1', 10, role: NodeRole.plant, c: NodeComponent.pump),
        _n('P2', 10, y: 10, role: NodeRole.plant, c: NodeComponent.pump),
        _n(jockeyId, 10, y: 20, role: NodeRole.plant, c: NodeComponent.pump),
        _n('D', 15),
      ];
      const dn25 = Diameter(0.025);
      final edges = <NetEdge>[
        _e('g', 'GT', 'S'),
        _e('s1', 'S', 'P1'),
        _e('d1', 'P1', 'D'),
        _e('s2', 'S', 'P2'),
        _e('d2', 'P2', 'D'),
        NetEdge(
            id: 'sj',
            fromId: 'S',
            toId: jockeyId,
            service: ServiceType.fireHydrant,
            sizeOverride: dn25),
        NetEdge(
            id: 'dj',
            fromId: jockeyId,
            toId: 'D',
            service: ServiceType.fireHydrant,
            sizeOverride: dn25),
        _e('dr', 'D', 'R0'),
      ];
      for (var k = 0; k < 6; k++) {
        nodes.add(_n('R$k', 30, floor: k));
        if (k > 0) edges.add(_e('r$k', 'R${k - 1}', 'R$k', k: EdgeKind.riser));
        nodes.add(_n('B$k', 35,
            floor: k, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
        edges.add(_e('b$k', 'R$k', 'B$k'));
      }
      return Network(nodes: nodes, edges: edges);
    }

    Map<String, EdgeSizing> run(Network net,
            {Map<String, FlowRate> jockey = const {}, Set<String>? legs}) =>
        autoSizeNetwork(
          net,
          const SizingContext(),
          leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
          hydrantDesignFlow: standpipeFlow(1),
          sizeOverrides: {
            for (final e in net.edges)
              if (e.sizeOverride != null) e.id: e.sizeOverride!,
          },
          jockeyLegFlows: jockey,
          parallelLegEdgeIdsOut: legs,
          building: b,
        );

    test(
        'the first solve never takes the small hand-picked leg as the duty '
        '(tree) leg, whatever the jockey id', () {
      for (final id in ['JP', 'PZ']) {
        final legs = <String>{};
        final r = run(room(id), legs: legs);
        // P1's leg is the tree leg; P2 and the jockey are mirrored.
        expect(legs, {'s2', 'd2', 'sj', 'dj'}, reason: id);
        expect(r['s2']!.diameter.inMillimeters, r['s1']!.diameter.inMillimeters,
            reason: id);
      }
    });

    test(
        'a hand-picked jockey leg keeps DN25 but carries the jockey duty flow '
        '(1 % of 500 gpm = 0.315 L/s, v = 0.64 m/s), never the set flow', () {
      final q = FlowRate(standpipeFlow(1).cubicMetersPerSecond * 0.01);
      for (final id in ['JP', 'PZ']) {
        final r = run(room(id), jockey: {id: q});
        for (final leg in ['sj', 'dj']) {
          expect(r[leg]!.diameter.inMillimeters, 25, reason: '$id $leg');
          expect(r[leg]!.flow.cubicMetersPerSecond,
              closeTo(q.cubicMetersPerSecond, 1e-12),
              reason: '$id $leg');
          final v = q.cubicMetersPerSecond / (math.pi * 0.025 * 0.025 / 4);
          expect(v, closeTo(0.64, 0.01));
          expect(r[leg]!.velocity.metersPerSecond, closeTo(v, 1e-9),
              reason: '$id $leg');
        }
      }
    });
  });

  group('MCCB refusal only when the MCB would pass ADS', () {
    const profile = PuilProfile();
    ElectricalProject hotel(double lengthM,
            {double loadW = 300, int phases = 1}) =>
        ElectricalProject(
          id: 'h',
          name: 'Hotel',
          earthingSystem: EarthingSystem.tnS,
          transformerKva: const ApparentPower(1600e3),
          panels: [
            const ElectricalPanel(
              id: 'LV',
              name: 'LVMDP',
              voltage: Voltage(400),
              circuits: [
                ElectricalCircuit(
                    id: 'f',
                    name: 'SDP-E feeder',
                    loadKind: LoadKind.feeder,
                    length: Length(15),
                    cableOverrideMm2: 300,
                    feedsPanelId: 'SDP'),
              ],
            ),
            ElectricalPanel(
              id: 'SDP',
              name: 'SDP-E',
              voltage: const Voltage(400),
              circuits: [
                ElectricalCircuit(
                    id: 'el',
                    name: 'Emergency lighting',
                    loadKind: LoadKind.lighting,
                    loadW: loadW,
                    phases: phases,
                    lifeSafety: true,
                    length: Length(lengthM)),
              ],
            ),
          ],
        );

    for (final len in [350.0, 450.0, 600.0]) {
      test(
          '300 W, ${len.toStringAsFixed(0)} m life-safety lighting way: Zs '
          'above the B6 MCB limit 0.95 x 230 / (5 x 6) = 7.283 ohm, so it keeps '
          'the MCCB and carries exactly one defect (ads-disconnection)', () {
        final pr = hotel(len);
        final fault = estimatedServiceFaultLevelA(pr)!;
        final sys = computeSystem(profile, pr, originFaultLevel: fault);
        final way = sys.panels['SDP']!.circuits.single;
        final f = faultStudy(sys, pr, profile, originFaultLevel: fault);
        final c = f.circuits['el']!;
        expect(c.adsOk, isFalse);
        // The B6 MCB limit: 0.95 x U0 / (5 x In).
        const mcbLimit = 0.95 * 230 / (5 * 6);
        expect(mcbLimit, closeTo(7.283, 1e-3));
        expect(c.zsOhm!, greaterThan(mcbLimit));
        expect(way.breaker.deviceClass, BreakerClass.mccb);
        final codes = [
          for (final w in [...sys.warnings, ...f.warnings])
            if (w.circuitId == 'el') w.code,
        ];
        expect(codes.where((x) => x == 'ads-disconnection'), hasLength(1));
        expect(codes, isNot(contains('mcb-backup-protection-required')));
        expect(codes, isNot(contains('cascade-combination-unverified')));
        expect(codes, isNot(contains('breaking-capacity-inadequate')));
      });
    }

    test('the Round-54 60 m / 16 A way still keeps its passing MCB', () {
      final pr = hotel(60, loadW: 6000, phases: 3);
      final fault = estimatedServiceFaultLevelA(pr)!;
      final sys = computeSystem(profile, pr, originFaultLevel: fault);
      final f = faultStudy(sys, pr, profile, originFaultLevel: fault);
      expect(sys.panels['SDP']!.circuits.single.breaker.deviceClass,
          BreakerClass.mcb);
      expect(f.circuits['el']!.adsOk, isTrue);
    });

    test(
        'seeded property: 200 random final ways — a kept (refused) MCB on a '
        'high-fault bus always passes ADS', () {
      final rnd = math.Random(55);
      for (var i = 0; i < 200; i++) {
        final pr = hotel(10 + rnd.nextDouble() * 700,
            loadW: 100 + rnd.nextDouble() * 6000);
        final fault = estimatedServiceFaultLevelA(pr)!;
        final sys = computeSystem(profile, pr, originFaultLevel: fault);
        final f = faultStudy(sys, pr, profile, originFaultLevel: fault);
        final codes = {
          for (final w in sys.warnings)
            if (w.circuitId == 'el') w.code,
        };
        if (codes.contains('mcb-backup-protection-required') &&
            sys.panels['SDP']!.circuits.single.breaker.deviceClass ==
                BreakerClass.mcb) {
          // Kept because of the class / frame refusal or the cable: never
          // an MCB that also fails the loop while an MCCB was available.
          final c = f.circuits['el']!;
          if (c.adsOk == false) {
            fail('trial $i: refused MCCB but the MCB fails ADS too');
          }
        }
      }
    });
  });

  group('TT feeder RCD >= 3 x the largest RCD directly below it', () {
    const profile = PuilProfile();
    ElectricalProject clinic({bool vfd = true}) {
      ElectricalCircuit pump(String id) => ElectricalCircuit(
            id: id,
            name: id,
            loadKind: vfd ? LoadKind.pump : LoadKind.lighting,
            motorKw: vfd ? 5.5 : null,
            loadW: vfd ? 0 : 900,
            phases: vfd ? 3 : 1,
            cosPhi: 0.85,
            length: const Length(20),
            starterType: vfd ? StarterType.vfd : null,
          );
      return ElectricalProject(
        id: 'c',
        name: 'Clinic',
        earthingSystem: EarthingSystem.tt,
        panels: [
          const ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'fP',
                  name: 'SDB-Pump feeder',
                  loadKind: LoadKind.feeder,
                  length: Length(25),
                  feedsPanelId: 'SDB'),
            ],
          ),
          ElectricalPanel(
            id: 'SDB',
            name: 'SDB-Pump',
            voltage: const Voltage(400),
            circuits: [pump('p1'), pump('p2')],
          ),
        ],
      );
    }

    test(
        'a feeder over two 300 mA Type B VFD pump RCDs takes 1000 mA S Type '
        'B (the first rung >= 3 x 300 = 900 mA), and claims no false '
        'selectivity', () {
      final sys = computeSystem(profile, clinic());
      final f = sys.panels['MDP']!.circuits.single.rcd;
      final finals = sys.panels['SDB']!.circuits;
      for (final w in finals) {
        expect(w.rcd.ratingMa, 300);
        expect(w.rcd.type, RcdType.b);
      }
      expect(ttFeederRcdMaAbove(300), 1000);
      expect(f.ratingMa, 1000);
      expect(f.ratingMa, greaterThanOrEqualTo(3 * 300));
      expect(f.type, RcdType.b);
      expect(f.timeDelayed, isTrue);
      expect(f.reason, contains('300 mA RCD below'));
      expect(
          sys.warnings.where((w) => w.code == 'tt-rcd-not-selective'), isEmpty);
    });

    test('a feeder over 30 mA finals stays at 300 mA (byte-identical rung)',
        () {
      final sys = computeSystem(profile, clinic(vfd: false));
      expect(sys.panels['SDB']!.circuits.first.rcd.ratingMa, 30);
      final f = sys.panels['MDP']!.circuits.single.rcd;
      expect(f.ratingMa, 300);
      expect(f.reason, contains('selective above the downstream final RCDs'));
    });

    test('the level ladder is unchanged when nothing below exceeds 100 mA', () {
      // 100 -> 300, 300 -> 1000, 1000 -> 3000, 3000 -> 10000, then clamped.
      expect([100, 300, 1000, 3000, 10000].map(ttFeederRcdMaAbove).toList(),
          [300, 1000, 3000, 10000, 10000]);
      expect(ttFeederRcdSelectiveAbove(10000, 10000), isFalse);
      expect(ttFeederRcdSelectiveAbove(1000, 300), isTrue);
      expect(ttFeederRcdSelectiveAbove(300, 300), isFalse);
    });
  });

  group('genset floored at the largest backed machine', () {
    const profile = PuilProfile();
    ElectricalCircuit motor(String id, double kw,
            {StarterType? starter, bool life = false}) =>
        ElectricalCircuit(
          id: id,
          name: id,
          loadKind: LoadKind.pump,
          motorKw: kw,
          phases: 3,
          cosPhi: 0.85,
          length: const Length(20),
          starterType: starter,
          lifeSafety: life,
          cableType: life ? 'FRC' : null,
        );
    ElectricalProject apartment(
            {double diversity = 0.6,
            GeneratorSource gen = const GeneratorSource(backupFraction: 0)}) =>
        ElectricalProject(
          id: 'a',
          name: 'Apartment',
          earthingSystem: EarthingSystem.tnS,
          transformerKva: const ApparentPower(1000e3),
          dualTransformer: true,
          sources: ElectricalSources(generator: gen),
          panels: [
            const ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              voltage: Voltage(400),
              circuits: [
                ElectricalCircuit(
                    id: 'fE',
                    name: 'ESDB feeder',
                    loadKind: LoadKind.feeder,
                    length: Length(20),
                    feedsPanelId: 'ESDB'),
              ],
            ),
            ElectricalPanel(
              id: 'ESDB',
              name: 'ESDB',
              voltage: const Voltage(400),
              essential: true,
              diversityFactor: diversity,
              circuits: [
                motor('lift1', 15, starter: StarterType.vfd),
                motor('lift2', 15, starter: StarterType.vfd),
                motor('fp', 75, starter: StarterType.starDelta, life: true),
                motor('jp', 3, life: true),
              ],
            ),
          ],
        );

    test(
        'a 75 kW fire pump (85.2 kW input, 144.7 A, 100.3 kVA) on an ESDB '
        'diversified to ~87 kVA: the set is sized >= max(100.3 kVA, '
        '85.2 / 0.8 = 106.5 kVA) -> the 125 kVA rung, never 100 kVA', () {
      final pr = apartment();
      final sys = computeSystem(profile, pr);
      final esdb = sys.panels['ESDB']!;
      // P = 75 / 0.88 = 85.23 kW; Ib = P / (sqrt3 x 400 x 0.85) = 144.7 A.
      const pIn = 75000 / 0.88;
      final ib = pIn / (math.sqrt(3) * 400 * 0.85);
      expect(ib, closeTo(144.7, 0.05));
      expect(esdb.largestDownstreamRunA, closeTo(ib, 0.1));
      // The diversified board is below the machine.
      expect(esdb.demandVa, lessThan(math.sqrt(3) * 400 * ib));
      final va = gensetBackupDemandVa(pr, sys).voltAmperes;
      final w = gensetBackupDemandW(pr, sys).watts;
      expect(va, greaterThanOrEqualTo(math.sqrt(3) * 400 * ib - 50));
      expect(w, greaterThanOrEqualTo(pIn - 1));
      final g = sizeGenerator(gensetBackupDemandVa(pr, sys),
          backupPower: gensetBackupDemandW(pr, sys));
      expect(g.ratingKva.inKilovoltAmperes, 125);
    });

    test('a forced 100 kVA nameplate below the machine floor warns', () {
      final pr = apartment(
          gen: const GeneratorSource(
              backupFraction: 0, kva: ApparentPower(100e3)));
      final sys = computeSystem(profile, pr);
      final codes = {for (final w in gensetBackupWarnings(pr, sys)) w.code};
      expect(codes, contains('genset-below-essential-power'));
    });

    test(
        'an essential board whose diversified demand already exceeds its '
        'largest machine is unchanged', () {
      final pr = ElectricalProject(
        id: 'b',
        name: 'B',
        earthingSystem: EarthingSystem.tnS,
        sources: const ElectricalSources(
            generator: GeneratorSource(backupFraction: 0)),
        panels: [
          ElectricalPanel(
            id: 'E',
            name: 'ESDB',
            voltage: const Voltage(400),
            essential: true,
            circuits: [
              for (var i = 0; i < 4; i++) motor('m$i', 5.5),
            ],
          ),
        ],
      );
      final sys = computeSystem(profile, pr);
      expect(gensetBackupDemandVa(pr, sys).voltAmperes,
          closeTo(essentialDemandVa(pr, sys), 1e-6));
      expect(gensetBackupDemandW(pr, sys).watts,
          closeTo(essentialDemandW(pr, sys), 1e-6));
    });
  });

  group('hot-water pressure through the heater', () {
    final b = _floors(4);
    // Cold C -> heater H (plant on both services); hot H -> T (riser) -> S1
    // and S2 showers. Zero flow everywhere: the field is pure static, so a
    // hot fixture's residual is the heater-inlet residual less rho g dz.
    NetNode at(String id, double z, {NodeRole role = NodeRole.main}) => NetNode(
        id: id,
        sheetId: 's1',
        x: 0,
        y: 0,
        floorIndex: 0,
        role: role,
        elevation: Length(z));
    final net = Network(nodes: [
      at('C', 0),
      at('H', 0, role: NodeRole.plant),
      at('T', 9),
      at('S1', 10, role: NodeRole.fixture),
      at('S2', 4, role: NodeRole.fixture),
    ], edges: const [
      NetEdge(id: 'c', fromId: 'C', toId: 'H', service: ServiceType.coldWater),
      NetEdge(id: 'h', fromId: 'H', toId: 'T', service: ServiceType.hotWater),
      NetEdge(id: 's1', fromId: 'T', toId: 'S1', service: ServiceType.hotWater),
      NetEdge(id: 's2', fromId: 'T', toId: 'S2', service: ServiceType.hotWater),
    ]);
    EdgeSizing z(String id, String from) => EdgeSizing(
        edgeId: id,
        service: ServiceType.hotWater,
        flow: const FlowRate(0),
        diameter: const Diameter(0.025),
        velocity: const Velocity(0),
        flowFromId: from);
    final sizing = {
      'h': z('h', 'H'),
      's1': z('s1', 'T'),
      's2': z('s2', 'T'),
    };
    const target = Pressure(225000);
    HotWaterField solve(double inletKpa) => solveHotWaterFromHeaters(
          net: net,
          coldResidual: {'H': Pressure(inletKpa * 1000)},
          coldNoFlow: {'H': Pressure(inletKpa * 1000)},
          sizing: sizing,
          calibrationBySheet: const {},
          building: b,
          targetResidual: target,
        );

    test('the heater is the plant on both services', () {
      expect(hotWaterHeaters(net).keys, ['H']);
    });

    test(
        'residual = inlet - rho g dz (no flow): S1 at +10 m, S2 at +4 m; '
        'the shortfall is what the top shower needs beyond the inlet', () {
      final f = solve(400);
      final p10 = pressureFromHead(const Head(10)).pascals;
      final p4 = pressureFromHead(const Head(4)).pascals;
      expect(f.residual['S1']!.pascals, closeTo(400000 - p10, 1e-6));
      expect(f.residual['S2']!.pascals, closeTo(400000 - p4, 1e-6));
      expect(f.noFlowStatic['S2']!.pascals, closeTo(400000 - p4, 1e-6));
      expect(f.deliveryNodeIds, {'S1', 'S2'});
      expect(f.criticalNodeId, 'S1');
      // 400 kPa - 98 kPa = 302 kPa >= 225 kPa: no shortfall.
      expect(f.shortfall.meters, 0);
      // 200 kPa inlet: S1 needs head(225 kPa) + 10 m at the heater.
      final g = solve(200);
      final need = headFromPressure(target).meters + 10;
      expect(
          g.shortfall.meters,
          closeTo(
              need - headFromPressure(const Pressure(200000)).meters, 1e-9));
    });

    test('a cold-only network has no hot field (byte-identical)', () {
      final cold = Network(nodes: net.nodes, edges: [net.edges.first]);
      expect(
          solveHotWaterFromHeaters(
            net: cold,
            coldResidual: const {'H': Pressure(400000)},
            coldNoFlow: const {},
            sizing: const {},
            calibrationBySheet: const {},
            building: b,
            targetResidual: target,
          ).isEmpty,
          isTrue);
    });

    test(
        'merge: a hot fixture below target clears held-by-design and is the '
        'critical node', () {
      const cold = PressureSolution(
        residualPressure: {'C': Pressure(300000), 'H': Pressure(250000)},
        requiredPumpHead: Head(30),
        criticalNodeId: 'H',
        targetHeldByDesign: true,
        deliveryNodeIds: {'H'},
      );
      final merged =
          mergeHotWaterField(cold, solve(250), targetResidual: target);
      expect(merged.residualPressure.keys, containsAll(['C', 'H', 'S1', 'S2']));
      expect(merged.targetHeldByDesign, isFalse);
      expect(merged.criticalNodeId, 'S1');
      expect(merged.deliveryNodeIds, {'H', 'S1', 'S2'});
    });
  });
}
