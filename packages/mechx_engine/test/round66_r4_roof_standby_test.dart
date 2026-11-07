// Round 66 r4 — a pump leg is oriented from the pump room's OWN suction
// source, never by a downstream gravity tank's hop count.
//
// regression-roof-standby-reverses-pump-room: a pumped hydrant riser with a
// ROOF-tank gravity standby feeding its top (GT -g- .. SH -s- P -d- DS
// -r1(riser)- X1 .. Xk, RT -o- Xk) became a MIXED fire system once a
// sprinkler branch was drawn, so the Round-66 mover-leg pass oriented the
// pump legs by `fireSourceHops` — and RT, seeded at hop 0 at the riser top,
// out-hopped GT along the discharge: d / r1 (and with a long suction s and
// the suction main g*) flowed toward the pump, the NFPA 20 suction /
// discharge floors were lost (DN125 -> DN100) and `firePumpsDrawnBackwards`
// named a correctly drawn pump. Each mover now reads its suction side from
// the sources reachable on each side of it with the other movers as walls:
// a side reaching a storage tank the other cannot is the suction; with tanks
// on both sides a ground tank beats a roof tank, then the lower (sizer
// `nodeElevation`) one.
//
// First principles: P lifts one Class I stack, standpipeFlow(1) = 500 gpm =
// 500 x 3.785411784 / 60 = 31.545 L/s, and NFPA 20 Table 4.28(a) for 500 gpm
// floors the suction and the discharge at 5 in = DN125 (150 % suction
// velocity 1.5 x 0.031545 / (pi 0.125^2 / 4) = 3.86 m/s <= 4.57 m/s), so
// every pump-room pipe from GT to the first riser junction flows away from GT
// at 31.545 L/s on DN125.
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

const _hy = ServiceType.fireHydrant, _sp = ServiceType.fireSprinkler;
const _cal = {'s1': ScaleCalibration(0.01)};

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

Map<String, EdgeSizing> _size(Network net, int floors) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {_hy: FlowRate(0.005), _sp: FlowRate(0.0015)},
      hydrantDesignFlow: standpipeFlow(1),
      sprinklerDemandCap: const FlowRate(0.012),
      building: BuildingLevels(
          [for (var i = 0; i < floors; i++) Floor('L$i', const Length(3.5))]),
      calibrationBySheet: _cal,
    );

/// The repro: [storeys] riser storeys X1..Xk (floors L0..Lk), a suction of
/// [suction] nodes from GT to SH (GT -g1- V1 .. -g{m}- SH), simplex P or a
/// duplex Pa / Pb, RT on the top floor (or [rtFloor]) tied to the riser top,
/// a hydrant box per storey and — when [sprinkler] — a sprinkler branch at
/// X1. [svc] moves pipes onto another service; [flip] redraws pipes in
/// reverse; [shuffle] reorders the lists.
(Network, List<String>) _repro({
  required int storeys,
  required int suction,
  bool duplex = false,
  bool sprinkler = true,
  int? rtFloor,
  Map<String, ServiceType> svc = const {},
  Set<String> flip = const {},
  math.Random? shuffle,
}) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    for (var j = 1; j < suction; j++) _n('V$j', 10.0 * j),
    _n('SH', 100),
    if (duplex) ...[
      _n('Pa', 200, role: NodeRole.plant, c: NodeComponent.pump),
      _n('Pb', 200, y: 50, role: NodeRole.plant, c: NodeComponent.pump),
    ] else
      _n('P', 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DS', 300),
    for (var f = 1; f <= storeys; f++) ...[
      _n('X$f', 300, floor: f),
      _n('B$f', 400,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
    ],
    _n('RT', 300,
        floor: rtFloor ?? storeys,
        y: 60,
        role: NodeRole.plant,
        c: NodeComponent.roofTank),
    if (sprinkler)
      _n('H1', 300,
          floor: 1,
          y: -60,
          role: NodeRole.fixture,
          c: NodeComponent.sprinklerHead),
  ];
  final room = <String>[];
  final edges = <NetEdge>[];
  void add(String id, String a, String b,
      {EdgeKind k = EdgeKind.run, ServiceType? s, bool inRoom = true}) {
    if (inRoom) room.add(id);
    final f = flip.contains(id);
    edges.add(NetEdge(
        id: id,
        fromId: f ? b : a,
        toId: f ? a : b,
        service: svc[id] ?? s ?? _hy,
        kind: k));
  }

  var prev = 'GT';
  for (var j = 1; j < suction; j++) {
    add('g$j', prev, 'V$j');
    prev = 'V$j';
  }
  add('g$suction', prev, 'SH');
  if (duplex) {
    add('sa', 'SH', 'Pa');
    add('sb', 'SH', 'Pb');
    add('da', 'Pa', 'DS');
    add('db', 'Pb', 'DS');
  } else {
    add('s', 'SH', 'P');
    add('d', 'P', 'DS');
  }
  add('r1', 'DS', 'X1', k: EdgeKind.riser);
  for (var f = 2; f <= storeys; f++) {
    add('r$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser, inRoom: false);
  }
  for (var f = 1; f <= storeys; f++) {
    add('b$f', 'X$f', 'B$f', inRoom: false);
  }
  add('o', 'RT', 'X$storeys',
      k: (rtFloor ?? storeys) == storeys ? EdgeKind.run : EdgeKind.riser,
      inRoom: false);
  if (sprinkler) add('sh1', 'X1', 'H1', s: _sp, inRoom: false);
  if (shuffle != null) {
    nodes.shuffle(shuffle);
    edges.shuffle(shuffle);
  }
  return (Network(nodes: nodes, edges: edges), room);
}

/// The pump-room pipes and the node each must flow FROM.
Map<String, String> _upstream(int suction, bool duplex) => {
      'g1': 'GT',
      for (var j = 2; j <= suction; j++) 'g$j': 'V${j - 1}',
      if (duplex) ...{
        'sa': 'SH',
        'sb': 'SH',
        'da': 'Pa',
        'db': 'Pb'
      } else ...{
        's': 'SH',
        'd': 'P'
      },
      'r1': 'DS',
    };

void _expectRoom(
    Map<String, EdgeSizing> r, int suction, bool duplex, String why) {
  for (final MapEntry(key: id, value: up)
      in _upstream(suction, duplex).entries) {
    expect(r[id], isNotNull, reason: '$why $id');
    expect(r[id]!.flowFromId, up, reason: '$why $id arrow');
    // Recorded residual (pre-existing, Round 61): past a duplex discharge
    // HEADER the NFPA 20 walk stops at a riser edge, so the riser main r1
    // leaving the header keeps its Class I standpipe DN100 (all-hydrant
    // too) — its flow and arrow are pinned.
    if (!(duplex && id == 'r1')) {
      expect(r[id]!.diameter.inMillimeters, 125, reason: '$why $id DN');
    }
    expect(r[id]!.flow.inLitersPerSecond, closeTo(31.545, 0.001),
        reason: '$why $id flow');
  }
}

void _expectSameRoom(Map<String, EdgeSizing> r, Map<String, EdgeSizing> base,
    List<String> room, String why) {
  for (final id in room) {
    expect(r[id]?.flow.inLitersPerSecond,
        closeTo(base[id]!.flow.inLitersPerSecond, 1e-6),
        reason: '$why $id flow');
    expect(r[id]!.diameter.inMillimeters, base[id]!.diameter.inMillimeters,
        reason: '$why $id DN');
    expect(r[id]!.flowFromId, base[id]!.flowFromId, reason: '$why $id arrow');
  }
}

void main() {
  test('the reviewer repro: 2 storeys, 2-node suction, sprinkler at X1', () {
    final (net, _) = _repro(storeys: 2, suction: 2);
    final r = _size(net, 3);
    _expectRoom(r, 2, false, 'repro');
    expect(firePumpsDrawnBackwards(net, r), isEmpty);
  });

  test(
      'simplex + duplex x 1..3 storeys x 2..4-node suctions: the pump room '
      'flows tank -> pump -> riser at DN125 == the all-hydrant drawing', () {
    for (final duplex in [false, true]) {
      for (var storeys = 1; storeys <= 3; storeys++) {
        for (var suction = 2; suction <= 4; suction++) {
          final why = 'duplex $duplex storeys $storeys suction $suction';
          final (hy, room) = _repro(
              storeys: storeys,
              suction: suction,
              duplex: duplex,
              sprinkler: false);
          final base = _size(hy, storeys + 1);
          _expectRoom(base, suction, duplex, '$why all-hydrant');
          final (net, _) =
              _repro(storeys: storeys, suction: suction, duplex: duplex);
          final r = _size(net, storeys + 1);
          _expectRoom(r, suction, duplex, why);
          _expectSameRoom(r, base, room, why);
          expect(firePumpsDrawnBackwards(net, r), isEmpty, reason: why);
        }
      }
    }
  });

  test('a same-floor roof tank (RT on L0) does not reverse the suction', () {
    for (final svcd in [
      const <String, ServiceType>{},
      const {'d': _sp},
      const {'s': _sp},
    ]) {
      final (net, _) = _repro(storeys: 1, suction: 2, rtFloor: 0, svc: svcd);
      final r = _size(net, 2);
      _expectRoom(r, 2, false, 'rt L0 $svcd');
      expect(firePumpsDrawnBackwards(net, r), isEmpty);
    }
  });

  test(
      'seeded: pump-room services x drawn direction x list order never move '
      'a pump-room size, flow or arrow', () {
    final rnd = math.Random(664);
    for (final duplex in [false, true]) {
      for (var storeys = 1; storeys <= 3; storeys++) {
        for (var suction = 2; suction <= 4; suction++) {
          final (hy, room) = _repro(
              storeys: storeys,
              suction: suction,
              duplex: duplex,
              sprinkler: false);
          final base = _size(hy, storeys + 1);
          for (var t = 0; t < 6; t++) {
            final svc = {
              for (final id in room)
                if (rnd.nextBool()) id: _sp,
            };
            final flip = {
              for (final id in room)
                if (rnd.nextBool()) id,
            };
            final (net, _) = _repro(
                storeys: storeys,
                suction: suction,
                duplex: duplex,
                svc: svc,
                flip: flip,
                shuffle: math.Random(rnd.nextInt(1 << 30)));
            final why = 'duplex $duplex storeys $storeys suction $suction '
                'svc $svc flip $flip';
            final r = _size(net, storeys + 1);
            _expectSameRoom(r, base, room, why);
          }
        }
      }
    }
  });

  // The bare-entry (MAINS-fed) pump room: M -g- SH -s{a,b}- P{a,b}
  // -d{a,b}- DH -t- T0 -tr(riser)- X4 .. X8 (a box on L5..L8). With no tank
  // drawn the movers' suction is the side holding no fire terminal, and the
  // bare entry M on it seeds the hops (`fireHopSources`): the whole train
  // flows M -> pumps -> DH -> T0 at 31.545 L/s, the header main t on the
  // NFPA 20 DN125 discharge floor, whichever service tr is drawn on (it used
  // to root at the service-change join T0: t 5.0 L/s DN65, flowing T0 -> DH).
  test('mains-fed simplex + duplex: the header main t keeps 31.545 L/s DN125',
      () {
    for (final duplex in [false, true]) {
      for (final trSvc in [_hy, _sp]) {
        final nodes = <NetNode>[
          _n('M', 0),
          _n('SH', 100),
          _n('Pa', 200, role: NodeRole.plant, c: NodeComponent.pump),
          if (duplex)
            _n('Pb', 200, y: 50, role: NodeRole.plant, c: NodeComponent.pump),
          _n('DH', 300),
          _n('T0', 400),
          for (var f = 4; f <= 8; f++) _n('X$f', 500, floor: f),
          for (var f = 5; f <= 8; f++)
            _n('B$f', 600,
                floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        ];
        NetEdge e(String id, String a, String b,
                {ServiceType s = _hy, EdgeKind k = EdgeKind.run}) =>
            NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);
        final edges = [
          e('g', 'M', 'SH'),
          e('sa', 'SH', 'Pa'),
          e('da', 'Pa', 'DH'),
          if (duplex) ...[e('sb', 'SH', 'Pb'), e('db', 'Pb', 'DH')],
          e('t', 'DH', 'T0'),
          e('tr', 'T0', 'X4', s: trSvc, k: EdgeKind.riser),
          for (var f = 5; f <= 8; f++)
            e('r$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
          for (var f = 5; f <= 8; f++) e('b$f', 'X$f', 'B$f'),
        ];
        final net = Network(nodes: nodes, edges: edges);
        final r = _size(net, 9);
        final from = {
          'g': 'M',
          'sa': 'SH',
          'da': 'Pa',
          if (duplex) ...{'sb': 'SH', 'db': 'Pb'},
          't': 'DH',
          'tr': 'T0',
        };
        for (final MapEntry(key: id, value: up) in from.entries) {
          final why = 'duplex $duplex tr $trSvc $id';
          expect(r[id]!.flowFromId, up, reason: why);
          expect(r[id]!.flow.inLitersPerSecond, closeTo(31.545, 0.001),
              reason: why);
          // tr past a duplex header keeps the Class I DN100 (Round-61 walk
          // residual, as r1 above).
          if (id != 'tr' || !duplex) {
            expect(r[id]!.diameter.inMillimeters, 125, reason: why);
          }
        }
        expect(firePumpsDrawnBackwards(net, r), isEmpty);
      }
    }
  });
}
