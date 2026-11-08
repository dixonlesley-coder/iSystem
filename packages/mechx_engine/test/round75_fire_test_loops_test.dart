// Round 75 — TWO (or more) test loops in one fire system, and the index-
// path friction never short-cutting through a zero-flow test line.
//
// fire-convergence-26-two-test-loops-unrecognised-pump-bypass: each test-
// line candidate used to be verified with ONLY its own chain stripped, so a
// second loop still connected the pump's suction and discharge and NO loop
// was recognised (a duplex room with a flow-meter loop DH -> TB -> GT beside
// a bypass DH -> TA -> SH: the loops carried 31.545 L/s round the pumps, g
// fell DN125 -> DN100 — 1.5 x 0.031545 / (pi 0.1^2 / 4) = 6.02 m/s, above
// the NFPA 20 4.57 m/s suction cap — and m / x1 fell below the Table
// 4.28(a) DN125 for 500 gpm). In a series room a stage-1 own loop beside a
// stage-2 loop to the first suction header made the real trunk chains read
// as "test lines" and collapsed the solve.
//
// First principles: one Class I stack per zone, standpipeFlow(1) = 500 gpm
// = 500 x 3.785411784 / 60 = 31.545 L/s. A test line carries the pump's
// TEST flow, never fire-event demand: every pipe sizes, flows and points
// exactly as with no loop, and each loop carries 0 L/s from its discharge
// end.
//
// fire-convergence-26-index-friction-shortcut-through-zero-flow-test-line:
// the Hazen-Williams index friction from P1 is a walk over the pipes that
// carry water; a recognised loop carries 0 L/s, so it can never be a free
// path from a lower suction header to an upper discharge header — the
// friction (and so the stage heads) is identical with and without loops.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _hy = ServiceType.fireHydrant;
const _q = 31.545;
final _building =
    BuildingLevels([for (var i = 0; i < 11; i++) Floor('L$i', const Length(4))]);
const _cal = {'s1': ScaleCalibration(0.01)};

NetNode _n(String id, double x,
        {int f = 0,
        double y = 0,
        NodeRole r = NodeRole.main,
        NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: f,
        role: r,
        component: c);

NetEdge Function(String, String, String, {EdgeKind k}) _mk(Set<String> flip) =>
    (String id, String a, String b, {EdgeKind k = EdgeKind.run}) => NetEdge(
        id: id,
        fromId: flip.contains(id) ? b : a,
        toId: flip.contains(id) ? a : b,
        service: _hy,
        kind: k);

/// Duplex room: GT -g- SH, P1 / P2 SH -> DH, DH -m- X0, riser X0..X5,
/// boxes L1..L5. [toHeader] adds DH -ta1- TA -ta2- SH, [toTank] adds
/// DH -tb1- TB -tb2- GT.
Network _duplex(
    {bool toHeader = false, bool toTank = false, Set<String> flip = const {}}) {
  final e = _mk(flip);
  return Network(nodes: [
    _n('GT', 0, r: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 50),
    _n('P1', 100, r: NodeRole.plant, c: NodeComponent.pump),
    _n('P2', 100, y: 40, r: NodeRole.plant, c: NodeComponent.pump),
    _n('DH', 160),
    if (toHeader) _n('TA', 100, y: -60, c: NodeComponent.gateValve),
    if (toTank) _n('TB', 80, y: -120, c: NodeComponent.gateValve),
    for (var f = 0; f <= 5; f++) _n('X$f', 200, f: f),
    for (var f = 1; f <= 5; f++)
      _n('B$f', 300, f: f, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
  ], edges: [
    e('g', 'GT', 'SH'),
    e('s1', 'SH', 'P1'),
    e('d1', 'P1', 'DH'),
    e('s2', 'SH', 'P2'),
    e('d2', 'P2', 'DH'),
    e('m', 'DH', 'X0'),
    for (var f = 1; f <= 5; f++)
      e('x$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
    for (var f = 1; f <= 5; f++) e('b$f', 'X$f', 'B$f'),
    if (toHeader) ...[e('ta1', 'DH', 'TA'), e('ta2', 'TA', 'SH')],
    if (toTank) ...[e('tb1', 'DH', 'TB'), e('tb2', 'TB', 'GT')],
  ]);
}

/// The Round-74 series room (P1 on L0, P2 on L5) with any set of loops:
/// 'own1' DH1 -> T1 -> SH, 'own2' DH2 -> T2 -> SH2, 'first' DH2 -> T3 -> SH,
/// 'tank' DH2 -> T4 -> GT.
const _loopEnds = {
  'own1': ('DH1', 'SH'),
  'own2': ('DH2', 'SH2'),
  'first': ('DH2', 'SH'),
  'tank': ('DH2', 'GT'),
};

Network _series({Set<String> loops = const {}, Set<String> flip = const {}}) {
  final e = _mk(flip);
  var i = 0;
  final loopNodes = <NetNode>[];
  final loopEdges = <NetEdge>[];
  for (final l in _loopEnds.keys) {
    if (!loops.contains(l)) continue;
    i++;
    final (a, b) = _loopEnds[l]!;
    final f = a == 'DH1' ? 0 : 5;
    loopNodes.add(_n('T$l', 120.0 + 10 * i,
        f: f, y: -60.0 * i, c: NodeComponent.gateValve));
    loopEdges
      ..add(e('${l}_1', a, 'T$l'))
      ..add(e('${l}_2', 'T$l', b));
  }
  return Network(nodes: [
    _n('GT', 0, r: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 50),
    _n('P1', 100, r: NodeRole.plant, c: NodeComponent.pump),
    _n('DH1', 160),
    for (var f = 0; f <= 5; f++) _n('X$f', 200, f: f),
    for (var f = 1; f <= 4; f++)
      _n('B$f', 300, f: f, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
    _n('SH2', 250, f: 5),
    _n('P2', 300, f: 5, r: NodeRole.plant, c: NodeComponent.pump),
    _n('DH2', 350, f: 5),
    for (var f = 5; f <= 10; f++) _n('Y$f', 400, f: f),
    for (var f = 6; f <= 10; f++)
      _n('C$f', 500, f: f, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
    ...loopNodes,
  ], edges: [
    e('g', 'GT', 'SH'),
    e('s', 'SH', 'P1'),
    e('d', 'P1', 'DH1'),
    e('m', 'DH1', 'X0'),
    for (var f = 1; f <= 5; f++)
      e('x$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
    for (var f = 1; f <= 4; f++) e('b$f', 'X$f', 'B$f'),
    e('h', 'X5', 'SH2'),
    e('s2', 'SH2', 'P2'),
    e('d2', 'P2', 'DH2'),
    e('m2', 'DH2', 'Y5'),
    for (var f = 6; f <= 10; f++)
      e('y$f', 'Y${f - 1}', 'Y$f', k: EdgeKind.riser),
    for (var f = 6; f <= 10; f++) e('c$f', 'Y$f', 'C$f'),
    ...loopEdges,
  ]);
}

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
    net, const SizingContext(),
    leafDemand: const {_hy: FlowRate(0.005)},
    hydrantDesignFlow: standpipeFlow(1),
    building: _building,
    calibrationBySheet: _cal);

void _expectSame(Map<String, EdgeSizing> r, Map<String, EdgeSizing> base,
    Iterable<String> ids, String why) {
  for (final id in ids) {
    expect(r[id]?.diameter.inMillimeters, base[id]?.diameter.inMillimeters,
        reason: '$why $id DN');
    expect(r[id]?.flow.inLitersPerSecond,
        closeTo(base[id]!.flow.inLitersPerSecond, 1e-6),
        reason: '$why $id flow');
    expect(r[id]?.flowFromId, base[id]?.flowFromId, reason: '$why $id from');
  }
}

void _expectLoopsZero(
    Network net, Map<String, EdgeSizing> r, Set<String> loopIds, String why) {
  for (final id in loopIds) {
    expect(r[id]?.flow.cubicMetersPerSecond ?? 0, 0, reason: '$why $id flow');
  }
}

double? _friction(Network net, Map<String, EdgeSizing> sizing, String pump) {
  final sys = fireSystems(net).firstWhere((s) => s.nodeIds.contains(pump));
  return fireIndexPathFrictionM(
    net: net,
    system: sys,
    pumpId: pump,
    sizing: sizing,
    lengthOf: (e) => edgeLength(e, net,
            calibrationBySheet: _cal, building: _building)
        .meters,
  );
}

/// A THREE-stage direct series room (P1 L0, P2 L3, P3 L6, boxes L1..L10):
/// GT -g- SH1 -s1- P1 -d1- DH1 -m1- riser, the riser top of each zone -h<k>-
/// SH<k> -s<k>- P<k> -d<k>- DH<k> -m<k>- the next riser. [loops] pick from
/// 'own<k>' (DH<k> -> SH<k>), 'first<k>' (DH<k> -> SH1) and 'tank' (DH3 ->
/// GT).
Network _three({Set<String> loops = const {}, Set<String> flip = const {}}) {
  final e = _mk(flip);
  const base = [0, 3, 6];
  const top = [3, 6, 10];
  final nodes = <NetNode>[
    _n('GT', 0, r: NodeRole.plant, c: NodeComponent.groundTank),
  ];
  final edges = <NetEdge>[e('g', 'GT', 'SH1')];
  for (var k = 1; k <= 3; k++) {
    final f0 = base[k - 1];
    final x = 200.0 * k;
    nodes.addAll([
      _n('SH$k', x - 150, f: f0),
      _n('P$k', x - 100, f: f0, r: NodeRole.plant, c: NodeComponent.pump),
      _n('DH$k', x - 40, f: f0),
      for (var f = f0; f <= top[k - 1]; f++) _n('R${k}_$f', x, f: f),
      for (var f = f0 + 1; f <= top[k - 1]; f++)
        if (k == 3 || f < top[k - 1])
          _n('B${k}_$f', x + 60, f: f,
              r: NodeRole.fixture, c: NodeComponent.hydrantBox),
    ]);
    edges.addAll([
      if (k > 1) e('h$k', 'R${k - 1}_$f0', 'SH$k'),
      e('s$k', 'SH$k', 'P$k'),
      e('d$k', 'P$k', 'DH$k'),
      e('m$k', 'DH$k', 'R${k}_$f0'),
      for (var f = f0 + 1; f <= top[k - 1]; f++)
        e('r${k}_$f', 'R${k}_${f - 1}', 'R${k}_$f', k: EdgeKind.riser),
      for (var f = f0 + 1; f <= top[k - 1]; f++)
        if (k == 3 || f < top[k - 1]) e('b${k}_$f', 'R${k}_$f', 'B${k}_$f'),
    ]);
  }
  var i = 0;
  for (final l in loops) {
    i++;
    final k = l == 'tank' ? 3 : int.parse(l.substring(l.length - 1));
    final (String a, String b) = l == 'tank'
        ? ('DH3', 'GT')
        : l.startsWith('own')
            ? ('DH$k', 'SH$k')
            : ('DH$k', 'SH1');
    final from = l == 'tank' ? 3 : k;
    nodes.add(_n('T$l', 150.0 + 7 * i,
        f: base[from - 1], y: -50.0 * i, c: NodeComponent.gateValve));
    edges
      ..add(e('${l}_1', a, 'T$l'))
      ..add(e('${l}_2', 'T$l', b));
  }
  return Network(nodes: nodes, edges: edges);
}

void main() {
  test('first principles: 500 gpm = 31.545 L/s; DN100 breaches the suction '
      'cap at 150 %', () {
    expect(standpipeFlow(1).inLitersPerSecond, closeTo(_q, 0.001));
    double v(double mm) =>
        1.5 * _q / 1000 / (math.pi * math.pow(mm / 1000, 2) / 4);
    expect(v(100), greaterThan(4.57));
    expect(v(125), lessThan(4.57));
  });

  group('duplex room with TWO loops (bypass + flow meter to the tank)', () {
    final base = _size(_duplex());
    final ids = [for (final e in _duplex().edges) e.id];

    test('no loop: g / m / x1 are DN125 at 31.545 L/s', () {
      for (final id in ['g', 'm', 'x1']) {
        expect(base[id]!.diameter.inMillimeters, 125, reason: id);
        expect(base[id]!.flow.inLitersPerSecond, closeTo(_q, 0.01));
      }
    });

    test('both loops are test lines; every pipe == no loop', () {
      final net = _duplex(toHeader: true, toTank: true);
      final lines = fireTestLineChains(net);
      expect(lines, hasLength(2));
      expect({for (final l in lines) l.joinId}, {'DH'});
      expect({for (final l in lines) ...l.edgeIds},
          {'ta1', 'ta2', 'tb1', 'tb2'});
      final r = _size(net);
      _expectSame(r, base, ids, 'two loops');
      _expectLoopsZero(net, r, {'ta1', 'ta2', 'tb1', 'tb2'}, 'two loops');
      expect(r['ta1']!.flowFromId, 'DH');
      expect(r['tb1']!.flowFromId, 'DH');
    });

    test('seeded: drawn-direction flips of every loop + pump-room pipe', () {
      final rnd = math.Random(7501);
      const flippable = [
        'g', 's1', 'd1', 's2', 'd2', 'm', //
        'ta1', 'ta2', 'tb1', 'tb2',
      ];
      for (var t = 0; t < 16; t++) {
        final flip = {
          for (final id in flippable)
            if (rnd.nextBool()) id,
        };
        final noLoop = _size(_duplex(flip: flip));
        final net = _duplex(toHeader: true, toTank: true, flip: flip);
        final r = _size(net);
        _expectSame(r, noLoop, ids, 't$t $flip');
        _expectLoopsZero(net, r, {'ta1', 'ta2', 'tb1', 'tb2'}, 't$t');
        // The index friction from the duty pump never short-cuts a loop.
        expect(_friction(net, r, 'P1'),
            closeTo(_friction(_duplex(flip: flip), noLoop, 'P1')!, 1e-9),
            reason: 't$t');
      }
    });
  });

  group('series room with several loops', () {
    final baseNet = _series();
    final base = _size(baseNet);
    final ids = [for (final e in baseNet.edges) e.id];
    final f1 = _friction(baseNet, base, 'P1')!;
    final f2 = _friction(baseNet, base, 'P2')!;

    test('no loop: the P1 index runs past P2 (friction P1 > P2 > 0)', () {
      expect(f2, greaterThan(0));
      expect(f1, greaterThan(f2));
    });

    final combos = <Set<String>>[
      {'own1'},
      {'first'},
      {'tank'},
      {'own1', 'first'},
      {'own1', 'own2'},
      {'own2', 'tank'},
      {'own1', 'tank'},
      {'own1', 'own2', 'tank'},
      {'own1', 'first', 'tank'},
    ];
    for (final loops in combos) {
      test('loops $loops: test lines only, sizes / friction == no loop', () {
        final net = _series(loops: loops);
        final loopIds = {
          for (final l in loops) ...['${l}_1', '${l}_2'],
        };
        final lines = fireTestLineChains(net);
        // Never a trunk chain: every returned pipe is a drawn loop pipe.
        expect({for (final l in lines) ...l.edgeIds}, loopIds);
        expect(lines, hasLength(loops.length));
        final r = _size(net);
        _expectSame(r, base, ids, '$loops');
        _expectLoopsZero(net, r, loopIds, '$loops');
        // fire-convergence-26 index friction: identical with the loops.
        expect(_friction(net, r, 'P1'), closeTo(f1, 1e-9), reason: 'P1');
        expect(_friction(net, r, 'P2'), closeTo(f2, 1e-9), reason: 'P2');
      });
    }

    test('seeded: loop combos x drawn-direction flips == no loop', () {
      final rnd = math.Random(7502);
      const pumpRoom = ['g', 's', 'd', 'm', 'h', 's2', 'd2', 'm2'];
      for (var t = 0; t < 18; t++) {
        final loops = combos[rnd.nextInt(combos.length)];
        final loopIds = {
          for (final l in loops) ...['${l}_1', '${l}_2'],
        };
        final flip = {
          for (final id in [...pumpRoom, ...loopIds])
            if (rnd.nextBool()) id,
        };
        final noLoopNet = _series(flip: flip);
        final noLoop = _size(noLoopNet);
        final net = _series(loops: loops, flip: flip);
        final r = _size(net);
        _expectSame(r, noLoop, ids, 't$t $loops $flip');
        _expectLoopsZero(net, r, loopIds, 't$t');
        expect(
            {for (final l in fireTestLineChains(net)) ...l.edgeIds}, loopIds,
            reason: 't$t $loops');
        for (final p in ['P1', 'P2']) {
          expect(_friction(net, r, p),
              closeTo(_friction(noLoopNet, noLoop, p)!, 1e-9),
              reason: 't$t $loops $p');
        }
      }
    });
  });


  group('three-stage series room with several loops', () {
    final baseNet = _three();
    final base = _size(baseNet);
    final ids = [for (final e in baseNet.edges) e.id];
    final fr = {
      for (final p in ['P1', 'P2', 'P3']) p: _friction(baseNet, base, p)!,
    };
    test('no loop: every zone is fed (x riser > 0 L/s)', () {
      expect(base['m1']!.flow.inLitersPerSecond, greaterThan(0));
      expect(base['m3']!.flow.inLitersPerSecond, greaterThan(0));
      expect(fr['P1']!, greaterThan(fr['P3']!));
    });
    final combos = <Set<String>>[
      {'own1', 'first3'},
      {'own1', 'own2', 'first3'},
      {'first2', 'first3'},
      {'own1', 'own2', 'own3'},
      {'own2', 'tank'},
      {'own1', 'first2', 'tank'},
    ];
    test('seeded: loop combos x drawn-direction flips == no loop', () {
      final rnd = math.Random(7503);
      for (var t = 0; t < 18; t++) {
        final loops = combos[t % combos.length];
        final loopIds = {
          for (final l in loops) ...['${l}_1', '${l}_2'],
        };
        final flip = {
          for (final id in [
            'g', 's1', 'd1', 'm1', 'h2', 's2', 'd2', 'm2', 'h3', 's3', //
            'd3', 'm3', ...loopIds,
          ])
            if (rnd.nextBool()) id,
        };
        final noLoopNet = _three(flip: flip);
        final noLoop = _size(noLoopNet);
        final net = _three(loops: loops, flip: flip);
        final lines = fireTestLineChains(net);
        expect({for (final l in lines) ...l.edgeIds}, loopIds,
            reason: 't$t $loops');
        final r = _size(net);
        _expectSame(r, noLoop, ids, 't$t $loops $flip');
        _expectLoopsZero(net, r, loopIds, 't$t');
        for (final p in ['P1', 'P2', 'P3']) {
          expect(_friction(net, r, p),
              closeTo(_friction(noLoopNet, noLoop, p)!, 1e-9),
              reason: 't$t $loops $p');
        }
      }
    });
  });

  test('a zero-flow pipe is never a free path: a pipe left at 0 L/s between '
      'two flowing branches adds no shortcut', () {
    // P -a- J -b- K -c- H (box), and a zero-flow tie P..K would otherwise
    // skip a and b. Hand sizing: a / b / c carry 5 L/s DN65 over 10 m each,
    // the tie 0 L/s.
    final net = Network(nodes: [
      _n('P', 0, r: NodeRole.plant, c: NodeComponent.pump),
      _n('J', 1000),
      _n('K', 2000),
      _n('H', 3000, r: NodeRole.fixture, c: NodeComponent.hydrantBox),
    ], edges: const [
      NetEdge(id: 'a', fromId: 'P', toId: 'J', service: _hy),
      NetEdge(id: 'b', fromId: 'J', toId: 'K', service: _hy),
      NetEdge(id: 'c', fromId: 'K', toId: 'H', service: _hy),
      NetEdge(id: 'tie', fromId: 'P', toId: 'K', service: _hy),
    ]);
    EdgeSizing es(String id, double lps) => EdgeSizing(
          edgeId: id,
          service: _hy,
          flow: FlowRate.litersPerSecond(lps),
          diameter: Diameter.mm(65),
          velocity: const Velocity(0),
        );
    final sizing = {
      'a': es('a', 5),
      'b': es('b', 5),
      'c': es('c', 5),
      'tie': es('tie', 0),
    };
    final f = fireIndexPathFrictionM(
      net: net,
      system: fireSystems(net).single,
      pumpId: 'P',
      sizing: sizing,
      lengthOf: (e) => 10,
    )!;
    // hf = 10.67 L Q^1.852 / (C^1.852 D^4.87), C 120, three 10 m pipes.
    double hw(double lps, double mm, double l) =>
        10.67 *
        l *
        math.pow(lps / 1000, 1.852) /
        (math.pow(120, 1.852) * math.pow(mm / 1000, 4.8704));
    expect(f, closeTo(3 * hw(5, 65, 10), 1e-3));
  });
}
