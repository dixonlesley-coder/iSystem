// Round 66 r3 — a tank the water is PUMPED UP to (a transfer pump's
// destination roof tank, a series stage's break tank) is never a fire-source
// hop seed (`fireSourceHops`).
//
// regression-transfer-suction-reversed-by-destination-seed: with the
// destination tank seeded at hop 0, a pump sitting nearer that tank than the
// suction tank in hop count (a suction of >= 2 junctions, GT -g- A -g2- SH
// -s- P) saw MORE hops at its suction node than at itself, so the Round-66
// r2 mover-leg pass reversed the (correct) suction arrow into SH, and the
// suction main g / g2 fell DN125 -> DN100 under the Round-61 NFPA 20
// suction floor whenever only the discharge (`d` / `tr`) was drawn on the
// sprinkler service. The hops a pump leg is judged on now grow from the
// SOURCE part only: a plant strictly above its component's lowest mover,
// joined to no source at / below that mover without passing a mover, is not
// seeded.
//
// First principles: P (or P1) lifts the zone the upper tank feeds — one
// Class I stack, standpipeFlow(1) = 500 gpm = 500 x 3.785411784 / 60 =
// 31.545 L/s — and NFPA 20 Table 4.28(a) for 500 gpm floors the suction and
// the discharge at 5 in = DN125 (150 % suction velocity 1.5 x 0.031545 /
// (pi 0.125^2 / 4) = 3.86 m/s <= 4.57 m/s), so every pump-room pipe from GT
// to the tank flows away from GT at 31.545 L/s on DN125. Which fire service a
// pump-room pipe is drawn on, and how long the suction is, must not move a
// size, a flow or an arrow.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: floor,
        role: role,
        component: c);

const _hy = ServiceType.fireHydrant, _sp = ServiceType.fireSprinkler;
const _cal = {'s1': ScaleCalibration(0.01)};

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {_hy: FlowRate(0.005), _sp: FlowRate(0.0015)},
      hydrantDesignFlow: standpipeFlow(1),
      sprinklerDemandCap: const FlowRate(0.012),
      building: BuildingLevels(
          [for (var i = 0; i < 9; i++) Floor('L$i', const Length(3.5))]),
      calibrationBySheet: _cal,
    );

NetEdge _e(String id, String a, String b, Map<String, ServiceType> svc,
        {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: svc[id] ?? _hy, kind: k);

/// The upper zone: a hydrant riser X4..X8, one box on L5..L8.
void _zone(List<NetNode> nodes, List<NetEdge> edges) {
  for (var f = 5; f <= 8; f++) {
    nodes
      ..add(_n('X$f', 500, floor: f))
      ..add(_n('B$f', 600,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges
      ..add(_e('r$f', 'X${f - 1}', 'X$f', const {}, k: EdgeKind.riser))
      ..add(_e('b$f', 'X$f', 'B$f', const {}));
  }
}

/// GT -g1- J1 ... -g{n}- SH -s- P (the suction: [junctions] bare junctions
/// before SH), then the discharge to the upper tank on L4 feeding X4:
///  * [series] false: P -d- DS -tr(riser)- BT (roof tank) -o- X4
///    ([discharge] 'riser' instead: P -d(riser)- BT);
///  * [series] true: P1 -d- DS -tr(riser)- BT (break tank) -s2- P2 -d2- X4.
/// Returns the network and the pump-room pipe ids.
(Network, List<String>) _room(Map<String, ServiceType> svc,
    {required int junctions, bool series = false, bool riserOnly = false}) {
  final p = series ? 'P1' : 'P';
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    for (var j = 1; j < junctions; j++) _n('J$j', 20.0 * j),
    _n('SH', 100),
    _n(p, 200, role: NodeRole.plant, c: NodeComponent.pump),
    if (!riserOnly) _n('DS', 300),
    _n('BT', 300,
        floor: 4,
        role: NodeRole.plant,
        c: series ? NodeComponent.groundTank : NodeComponent.roofTank),
    if (series)
      _n('P2', 400, floor: 4, role: NodeRole.plant, c: NodeComponent.pump),
    _n('X4', 500, floor: 4),
  ];
  final ids = <String>[];
  final edges = <NetEdge>[];
  void add(String id, String a, String b, {EdgeKind k = EdgeKind.run}) {
    ids.add(id);
    edges.add(_e(id, a, b, svc, k: k));
  }

  // `junctions` = the suction main's junction count incl. SH.
  var prev = 'GT';
  for (var j = 1; j < junctions; j++) {
    add('g$j', prev, 'J$j');
    prev = 'J$j';
  }
  add('g$junctions', prev, 'SH');
  add('s', 'SH', p);
  if (riserOnly) {
    add('d', p, 'BT', k: EdgeKind.riser);
  } else {
    add('d', p, 'DS');
    add('tr', 'DS', 'BT', k: EdgeKind.riser);
  }
  if (series) {
    add('s2', 'BT', 'P2');
    add('d2', 'P2', 'X4');
  } else {
    add('o', 'BT', 'X4');
  }
  _zone(nodes, edges);
  return (Network(nodes: nodes, edges: edges), ids);
}

void _expectSame(
    Map<String, EdgeSizing> r, Map<String, EdgeSizing> base, String why) {
  expect(r.keys.toSet(), base.keys.toSet(), reason: why);
  for (final id in base.keys) {
    expect(r[id]!.flow.inLitersPerSecond,
        closeTo(base[id]!.flow.inLitersPerSecond, 1e-6),
        reason: '$why $id');
    expect(r[id]!.diameter.inMillimeters, base[id]!.diameter.inMillimeters,
        reason: '$why $id');
    expect(r[id]!.flowFromId, base[id]!.flowFromId, reason: '$why $id');
  }
}

void main() {
  test('probe (a): GT -g- A -g2- SH -s- P -d(riser)- BT, d on sprinkler', () {
    final (hy, _) = _room(const {}, junctions: 2, riserOnly: true);
    final base = _size(hy);
    for (final id in ['g1', 'g2', 's', 'd']) {
      expect(base[id]!.diameter.inMillimeters, 125, reason: id);
      expect(base[id]!.flow.inLitersPerSecond, closeTo(31.545, 0.001),
          reason: id);
    }
    expect(base['g1']!.flowFromId, 'GT');
    expect(base['g2']!.flowFromId, 'J1');
    expect(base['s']!.flowFromId, 'SH');
    expect(base['d']!.flowFromId, 'P');
    final (sp, _) = _room(const {'d': _sp}, junctions: 2, riserOnly: true);
    _expectSame(_size(sp), base, 'd sprinkler');
  });

  test('probe (b): 3-junction suction, run + riser discharge', () {
    final (hy, _) = _room(const {}, junctions: 3);
    final base = _size(hy);
    const from = {
      'g1': 'GT', 'g2': 'J1', 'g3': 'J2', 's': 'SH', 'd': 'P', 'tr': 'DS', //
    };
    for (final MapEntry(key: id, value: up) in from.entries) {
      expect(base[id]!.flowFromId, up, reason: id);
      expect(base[id]!.diameter.inMillimeters, 125, reason: id);
      expect(base[id]!.flow.inLitersPerSecond, closeTo(31.545, 0.001),
          reason: id);
    }
    for (final id in ['d', 'tr']) {
      final (sp, _) = _room({id: _sp}, junctions: 3);
      _expectSame(_size(sp), base, '$id sprinkler');
    }
  });

  test('probe (c): series room GT-A-SH-P1-d-BT(break)-P2, d on sprinkler', () {
    final (hy, _) =
        _room(const {}, junctions: 2, series: true, riserOnly: true);
    final base = _size(hy);
    for (final id in ['g1', 'g2', 's', 'd', 's2', 'd2']) {
      expect(base[id]!.diameter.inMillimeters, 125, reason: id);
    }
    expect(base['s']!.flowFromId, 'SH');
    expect(base['s2']!.flowFromId, 'BT');
    expect(base['d2']!.flowFromId, 'P2');
    final (sp, _) =
        _room(const {'d': _sp}, junctions: 2, series: true, riserOnly: true);
    _expectSame(_size(sp), base, 'd sprinkler');
  });

  test(
      'seeded: pump-room services x suction length x transfer / series '
      '== all-hydrant', () {
    final rnd = math.Random(663);
    for (final series in [false, true]) {
      for (final riserOnly in [false, true]) {
        for (var junctions = 1; junctions <= 3; junctions++) {
          final (hy, ids) = _room(const {},
              junctions: junctions, series: series, riserOnly: riserOnly);
          final base = _size(hy);
          // Every single pipe alone on the sprinkler service, then random
          // subsets.
          final cases = <Map<String, ServiceType>>[
            for (final id in ids) {id: _sp},
            for (var t = 0; t < 12; t++)
              {
                for (final id in ids)
                  if (rnd.nextBool()) id: _sp,
              },
          ];
          for (final svc in cases) {
            final (net, _) = _room(svc,
                junctions: junctions, series: series, riserOnly: riserOnly);
            _expectSame(_size(net), base,
                'series $series riser $riserOnly j $junctions $svc');
          }
        }
      }
    }
  });
}
