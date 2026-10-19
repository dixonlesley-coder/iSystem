/// Round 27 — check-valve classification on the hotel recirculation:
///
/// * regression-mixed-discharge-and-return-cv — a DISCHARGE valve on the
///   heater outlet (H -> CVd -> M) beside the common RETURN valve (RJ -> CV
///   -> H). Cutting both isolated the root, the return valve read as a second
///   parallel discharge, and Hardy–Cross pushed half the peak forward through
///   the return valve (heater feed DN15 instead of DN25).
/// * residuals-0 — the return valve drawn heater-outward (H -> CV -> RJ) was
///   read verbatim as a supply valve.
/// * residuals-4 — a hotel return teed at the inline top fixture left the
///   supply-riser / return-riser ring in Hardy–Cross; the far riser base sized
///   one DN small.
///
/// The reference for every case is the engine's own open network (no return
/// drawn): a return check valve carries no draw-off (the Round-12 principle).
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.hotWater, kind: k);

/// Heater H -> M -> [risers] supply risers of 4 floors with a 2-UBAP fixture
/// on each floor. [ret]: each riser top runs down a return riser to RJ, then
/// RJ -> CV -> H ([reversedReturn] draws the valve legs H -> CV -> RJ).
/// [discharge] replaces the plain H -> M pipe by H -> CVd -> M (ids hm1 /
/// hm2). [fixtureTee] tees each return top from the top fixture instead of
/// the riser top. [cvdId] / [cvId] rename the valves (id-order metamorphic).
Network _hotel({
  int risers = 2,
  bool ret = true,
  bool discharge = false,
  bool reversedReturn = false,
  bool fixtureTee = false,
  String cvdId = 'CVd',
  String cvId = 'CV',
}) {
  final nodes = <NetNode>[
    _n('H', 0, 0, role: NodeRole.plant),
    _n('M', 50, 0),
  ];
  final edges = <NetEdge>[];
  if (discharge) {
    nodes.add(_n(cvdId, 25, 0, c: NodeComponent.checkValve));
    edges
      ..add(_e('hm1', 'H', cvdId))
      ..add(_e('hm2', cvdId, 'M'));
  } else {
    edges.add(_e('hm', 'H', 'M'));
  }
  for (var r = 0; r < risers; r++) {
    final x = 100.0 + 200 * r;
    for (var f = 0; f < 4; f++) {
      nodes
        ..add(_n('S${r}_$f', x, 0, floor: f))
        ..add(_n('fx${r}_$f', x + 40, 0, floor: f, role: NodeRole.fixture));
      edges
        ..add(_e('b${r}_$f', 'S${r}_$f', 'fx${r}_$f'))
        ..add(f == 0
            ? _e('m$r', 'M', 'S${r}_0')
            : _e('s${r}_$f', 'S${r}_${f - 1}', 'S${r}_$f',
                k: EdgeKind.riser));
    }
    if (ret) {
      for (var f = 0; f < 4; f++) {
        nodes.add(_n('R${r}_$f', x + 20, 0, floor: f));
      }
      edges.add(_e('top$r', fixtureTee ? 'fx${r}_3' : 'S${r}_3', 'R${r}_3'));
      for (var f = 3; f >= 1; f--) {
        edges.add(
            _e('r${r}_$f', 'R${r}_$f', 'R${r}_${f - 1}', k: EdgeKind.riser));
      }
      edges.add(_e('rj$r', 'R${r}_0', 'RJ'));
    }
  }
  if (ret) {
    nodes
      ..add(_n('RJ', 30, 0))
      ..add(_n(cvId, 10, 0, c: NodeComponent.checkValve));
    edges.addAll(reversedReturn
        ? [_e('ch', 'H', cvId), _e('jc', cvId, 'RJ')]
        : [_e('jc', 'RJ', cvId), _e('ch', cvId, 'H')]);
  }
  return Network(nodes: nodes, edges: edges);
}

Map<String, EdgeSizing> _size(Network net, {bool cal = false}) =>
    autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.hotWater: FlowRate(0)},
      leafFixtureUnits: const {ServiceType.hotWater: 2.0},
      building: cal
          ? const BuildingLevels([
              Floor('L1', Length(3.0)),
              Floor('L2', Length(3.0)),
              Floor('L3', Length(3.0)),
              Floor('L4', Length(3.0)),
            ])
          : null,
      calibrationBySheet:
          cal ? const {'s1': ScaleCalibration(0.05)} : const {},
    );

const _sni = SniProfile();
double _curve(double ubap) =>
    _sni.probableFlowForFixtureUnits(ubap).inLitersPerSecond;

void main() {
  test('first principles: the reference flows', () {
    // Flush-tank Gambar 1: 10..20 UBAP and 0..10 UBAP segments. A riser base
    // carries 4 floors x 2 UBAP = 8 UBAP -> 8/10 x 0.5 = 0.400 L/s; the
    // heater feed 2 x 8 = 16 UBAP. DN15 at 0.4 L/s is v = 4Q/(pi D^2) =
    // 2.26 m/s, over the 2.0 m/s cap, so a riser base must be DN20.
    expect(_curve(8), closeTo(0.400, 1e-12));
    expect(4 * 0.400e-3 / (math.pi * 0.015 * 0.015), greaterThan(2.0));
    final open = _size(_hotel(ret: false));
    expect(open['hm']!.flow.inLitersPerSecond, closeTo(_curve(16), 1e-9));
    expect(open['m0']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9));
    expect(open['hm']!.diameter.inMillimeters, 25);
    expect(open['m0']!.diameter.inMillimeters, 20);
  });

  test(
      'regression: a discharge CV on the heater outlet + the return CV — the '
      'feed is curve(16) DN25, riser bases curve(8) DN20, the return 0', () {
    for (final cal in [false, true]) {
      final open = _size(_hotel(ret: false, discharge: true), cal: cal);
      for (final ids in [('CVd', 'CV'), ('CV', 'CVd'), ('A', 'Z'), ('Z', 'A')]) {
        final s = _size(
            _hotel(discharge: true, cvdId: ids.$1, cvId: ids.$2),
            cal: cal);
        final why = 'cal=$cal ids=$ids';
        for (final id in ['hm1', 'hm2']) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(_curve(16), 1e-9),
              reason: '$why $id');
          expect(s[id]!.diameter.inMillimeters, 25, reason: '$why $id');
        }
        for (final id in ['m0', 'm1']) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9),
              reason: '$why $id');
          expect(s[id]!.diameter.inMillimeters, 20, reason: '$why $id');
        }
        // The whole supply sizes exactly as with no return drawn.
        for (final id in open.keys) {
          expect(s[id]!.flow.inLitersPerSecond,
              closeTo(open[id]!.flow.inLitersPerSecond, 1e-9),
              reason: '$why $id');
        }
        for (final id in ['ch', 'jc', 'rj0', 'rj1', 'top0', 'top1', 'r0_1']) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(0, 1e-12),
              reason: '$why $id');
        }
        // The return valve is oriented RJ -> CV -> H (its pass direction).
        expect(s['jc']!.flowFromId, 'RJ', reason: why);
        expect(s['ch']!.flowFromId, ids.$2, reason: why);
      }
    }
  });

  test(
      'residuals-0: a return CV drawn heater-outward (H -> CV -> RJ) is still '
      'a return — the trunk carries curve(16) DN25', () {
    for (final cal in [false, true]) {
      for (final discharge in [false, true]) {
        final s = _size(_hotel(reversedReturn: true, discharge: discharge),
            cal: cal);
        final why = 'cal=$cal discharge=$discharge';
        final trunk = discharge ? ['hm1', 'hm2'] : ['hm'];
        for (final id in trunk) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(_curve(16), 1e-9),
              reason: '$why $id');
          expect(s[id]!.diameter.inMillimeters, 25, reason: '$why $id');
        }
        for (final id in ['m0', 'm1']) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9),
              reason: '$why $id');
        }
        expect(s['ch']!.flow.inLitersPerSecond, closeTo(0, 1e-12));
        expect(s['jc']!.flow.inLitersPerSecond, closeTo(0, 1e-12));
        expect(s['jc']!.flowFromId, 'RJ', reason: why);
        expect(s['ch']!.flowFromId, 'CV', reason: why);
      }
    }
  });

  test(
      'residuals-4: a common return teed at the inline top fixture — every '
      'riser base carries curve(8) DN20, the returns carry no draw-off', () {
    for (final risers in [2, 3]) {
      for (final cal in [false, true]) {
        final s = _size(_hotel(risers: risers, fixtureTee: true), cal: cal);
        final open = _size(_hotel(risers: risers, ret: false), cal: cal);
        final why = 'risers=$risers cal=$cal';
        expect(s['hm']!.flow.inLitersPerSecond,
            closeTo(_curve(8.0 * risers), 1e-9),
            reason: why);
        for (var r = 0; r < risers; r++) {
          expect(s['m$r']!.flow.inLitersPerSecond, closeTo(_curve(8), 1e-9),
              reason: '$why m$r');
          expect(s['m$r']!.diameter.inMillimeters, 20, reason: '$why m$r');
          for (final id in ['top$r', 'r${r}_3', 'r${r}_1', 'rj$r']) {
            expect(s[id]!.flow.inLitersPerSecond, closeTo(0, 1e-12),
                reason: '$why $id');
          }
        }
        for (final id in open.keys) {
          expect(s[id]!.flow.inLitersPerSecond,
              closeTo(open[id]!.flow.inLitersPerSecond, 1e-9),
              reason: '$why $id');
        }
      }
    }
  });

  test(
      'property: drawing direction, valve ids, edge order, riser count and '
      'tee placement never move the supply off the open network (seeded)', () {
    final rnd = math.Random(27);
    for (var trial = 0; trial < 40; trial++) {
      final n = 2 + rnd.nextInt(3);
      final discharge = rnd.nextBool();
      final reversed = rnd.nextBool();
      final tee = rnd.nextBool();
      final cal = rnd.nextBool();
      final ids = rnd.nextBool() ? ('CVd', 'CV') : ('CV', 'CVd');
      final net = _hotel(
          risers: n,
          discharge: discharge,
          reversedReturn: reversed,
          fixtureTee: tee,
          cvdId: ids.$1,
          cvId: ids.$2);
      final shuffled = Network(
          nodes: net.nodes,
          edges: [...net.edges]..shuffle(math.Random(500 + trial)));
      final s = _size(shuffled, cal: cal);
      final open =
          _size(_hotel(risers: n, ret: false, discharge: discharge), cal: cal);
      final why = 'trial $trial n=$n discharge=$discharge reversed=$reversed '
          'tee=$tee cal=$cal ids=$ids';
      for (final id in open.keys) {
        expect(s[id]!.flow.inLitersPerSecond,
            closeTo(open[id]!.flow.inLitersPerSecond, 1e-9),
            reason: '$why $id');
      }
      for (final id in ['ch', 'jc']) {
        expect(s[id]!.flow.inLitersPerSecond, closeTo(0, 1e-12),
            reason: '$why $id');
      }
    }
  });
}
