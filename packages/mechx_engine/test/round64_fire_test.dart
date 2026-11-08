// Round 64 — fire pipes are rated on what is DRAWN (a head, not a pipe
// label), fire pump legs follow the water (never the drawing direction),
// and a jockey leg stops at the shared header whatever its service.
//
//  * regression-sprinkler-drawn-pipe-without-heads-rates-hydrant-system-on-
//    sprinkler-demand: GT -> P -> a 4-storey Class I riser (4 hydrant boxes,
//    NO sprinkler head). The suction GT-SH-P drawn on the sprinkler service
//    must not give the system a sprinkler basis:
//      standpipeFlow(1) = 500 gpm = 500 x 3.785411784 / 60 = 31.545 L/s;
//      NFPA 20 Table 4.28(a) 500 gpm => 5 in suction = DN125; on DN125
//      v150 = 1.5 x 0.031545 / (pi 0.125^2 / 4) = 0.047318 / 0.012272
//      = 3.86 m/s <= 4.57 m/s. The extra-hazard remote area (10 mm/min x
//      260 m2 = 2600 L/min = 43.33 L/s, DN150) is NOT drawn: no head.
//  * regression-sprinkler-drawn-suction-leg-oriented-pump-to-header: room B's
//    suction SH-PB drawn on the sprinkler service flows SH -> PB (the leg is
//    fed through the hydrant header) and carries room B's 31.545 L/s on
//    DN125, never room A's 43.33 L/s backwards.
//  * fire-convergence-16-backwards-drawn-duty-standby-set / mixed-service-
//    pump-room: a duty / standby pair drawn backwards, or with one room on
//    the other fire service, sizes and orients exactly as the forward
//    all-hydrant drawing: rb = DN125 (NFPA 20 500 gpm discharge 5 in), the
//    standby legs flowing SH -> PB -> DB -> RB (seeded property).
//  * fire-convergence-16-jockey-leg-walk-swallows-duty-pump-suction: the
//    duty sprinkler pump's suction s1 is >= its discharge (OH2 12 L/s:
//    NFPA 20 190 gpm -> 3 in = DN80; 1.5 x 0.012 / (pi 0.08^2/4) =
//    0.018 / 0.005027 = 3.58 m/s <= 4.57), the jockey legs keep DN25.
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
        {EdgeKind k = EdgeKind.run, ServiceType s = ServiceType.fireHydrant}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

const _hy = ServiceType.fireHydrant, _sp = ServiceType.fireSprinkler;
const _cal = {'s1': ScaleCalibration(0.01)};

Map<String, EdgeSizing> _size(
  Network net, {
  required FlowRate cap,
  int floors = 5,
  Map<String, FlowRate> jockey = const {},
  Map<String, Diameter> overrides = const {},
}) =>
    autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {_hy: FlowRate(0.005), _sp: FlowRate(0.0015)},
      hydrantDesignFlow: standpipeFlow(1),
      sprinklerDemandCap: cap,
      jockeyLegFlows: jockey,
      sizeOverrides: overrides,
      building: BuildingLevels(
          [for (var i = 0; i < floors; i++) Floor('L$i', const Length(3.5))]),
      calibrationBySheet: _cal,
    );

/// GT -g- SH -sa- P -d- X0 -> 4-storey Class I riser, one box a floor, NO
/// sprinkler head. [suction] is the service of g and sa.
Network _headless(ServiceType suction) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    _n('P', 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('X0', 300),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'SH', s: suction),
    _e('sa', 'SH', 'P', s: suction),
    _e('d', 'P', 'X0'),
  ];
  for (var f = 1; f <= 4; f++) {
    nodes
      ..add(_n('X$f', 300, floor: f))
      ..add(_n('B$f', 400,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges
      ..add(_e('r$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser))
      ..add(_e('b$f', 'X$f', 'B$f'));
  }
  return Network(nodes: nodes, edges: edges);
}

/// The Round-63 two-room drawing: room A combined (riser + 6 heads a floor),
/// room B one hydrant box; room B's suction sb drawn on [sb].
Network _twoRooms(ServiceType sb) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    _n('P', 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('X0', 300),
    _n('PB', 200, y: 800, role: NodeRole.plant, c: NodeComponent.pump),
    _n('YB', 300, y: 800),
    _n('BB', 400, y: 800, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'SH'),
    _e('sa', 'SH', 'P'),
    _e('d', 'P', 'X0'),
    _e('sb', 'SH', 'PB', s: sb),
    _e('db', 'PB', 'YB'),
    _e('bb', 'YB', 'BB'),
  ];
  for (var f = 1; f <= 4; f++) {
    nodes
      ..add(_n('X$f', 300, floor: f))
      ..add(_n('B$f', 400,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges
      ..add(_e('r$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser))
      ..add(_e('b$f', 'X$f', 'B$f'));
    var prev = 'X$f';
    for (var h = 0; h < 6; h++) {
      nodes
        ..add(_n('M$f$h', 600.0 + 300 * h, floor: f, y: 200))
        ..add(_n('S$f$h', 600.0 + 300 * h,
            floor: f,
            y: 300,
            role: NodeRole.fixture,
            c: NodeComponent.sprinklerHead));
      edges
        ..add(_e('m$f$h', prev, 'M$f$h', s: _sp))
        ..add(_e('h$f$h', 'M$f$h', 'S$f$h', s: _sp));
      prev = 'M$f$h';
    }
  }
  return Network(nodes: nodes, edges: edges);
}

/// A duty / standby pair SH -> PA / PB -> RB -> 6-storey Class I riser.
/// Room A (g, a1, a2, da) on [svcA]; room B + rb on hydrant. [flip] names
/// the pump-leg pipes drawn backwards.
Network _pair(ServiceType svcA, {Set<String> flip = const {}}) {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    _n('PA', 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DA', 300),
    _n('PB', 200, y: 300, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DB', 300, y: 300),
    _n('RB', 400),
    _n('H0', 500),
  ];
  NetEdge leg(String id, String a, String b, ServiceType s) =>
      flip.contains(id) ? _e(id, b, a, s: s) : _e(id, a, b, s: s);
  final edges = <NetEdge>[
    leg('g', 'GT', 'SH', svcA),
    leg('a1', 'SH', 'PA', svcA),
    leg('a2', 'PA', 'DA', svcA),
    leg('da', 'DA', 'RB', svcA),
    leg('b1', 'SH', 'PB', _hy),
    leg('b2', 'PB', 'DB', _hy),
    leg('db', 'DB', 'RB', _hy),
    leg('rb', 'RB', 'H0', _hy),
  ];
  for (var f = 1; f <= 6; f++) {
    nodes
      ..add(_n('H$f', 500, floor: f))
      ..add(_n('B$f', 600,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges
      ..add(_e('r$f', 'H${f - 1}', 'H$f', k: EdgeKind.riser))
      ..add(_e('x$f', 'H$f', 'B$f'));
  }
  return Network(nodes: nodes, edges: edges);
}

const _legIds = ['g', 'a1', 'a2', 'da', 'b1', 'b2', 'db', 'rb'];

/// The hospital pump room: GT -g- SH (hydrant), a hydrant room
/// SH -h1- PH -h2- DH -> 7-storey hydrant riser, and a sprinkler room off SH
/// on sprinkler pipe: s1 SH->PS, s2 PS->DS, a jockey j1 SH->JP, j2 JP->DS,
/// DS -sm- a 7-storey sprinkler riser with 4 heads a floor.
Network _hospital() {
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    _n('PH', 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DH', 300),
    _n('PS', 200, y: 400, role: NodeRole.plant, c: NodeComponent.pump),
    _n('JP', 200, y: 600, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DS', 300, y: 400),
    _n('Q0', 400, y: 400),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'SH'),
    _e('h1', 'SH', 'PH'),
    _e('h2', 'PH', 'DH'),
    _e('s1', 'SH', 'PS', s: _sp),
    _e('s2', 'PS', 'DS', s: _sp),
    _e('j1', 'SH', 'JP', s: _sp),
    _e('j2', 'JP', 'DS', s: _sp),
    _e('sm', 'DS', 'Q0', s: _sp),
  ];
  var prevH = 'DH';
  var prevQ = 'Q0';
  for (var f = 1; f <= 6; f++) {
    nodes
      ..add(_n('H$f', 300, floor: f))
      ..add(_n('B$f', 350,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox))
      ..add(_n('Q$f', 400, y: 400, floor: f));
    edges
      ..add(_e('rh$f', prevH, 'H$f', k: EdgeKind.riser))
      ..add(_e('bh$f', 'H$f', 'B$f'))
      ..add(_e('rq$f', prevQ, 'Q$f', k: EdgeKind.riser, s: _sp));
    prevH = 'H$f';
    prevQ = 'Q$f';
    var prev = 'Q$f';
    for (var h = 0; h < 4; h++) {
      nodes
        ..add(_n('K$f$h', 500.0 + 300 * h, floor: f, y: 400))
        ..add(_n('S$f$h', 500.0 + 300 * h,
            floor: f,
            y: 500,
            role: NodeRole.fixture,
            c: NodeComponent.sprinklerHead));
      edges
        ..add(_e('k$f$h', prev, 'K$f$h', s: _sp))
        ..add(_e('hd$f$h', 'K$f$h', 'S$f$h', s: _sp));
      prev = 'K$f$h';
    }
  }
  return Network(nodes: nodes, edges: edges);
}

double _lps(EdgeSizing s) => s.flow.inLitersPerSecond;
double _dn(EdgeSizing s) => s.diameter.inMillimeters;

void main() {
  const eh = FlowRate(0.04333); // 10 mm/min x 260 m2 = 2600 L/min
  const oh2 = FlowRate(0.012); // 5 x 144 L/min = 720 L/min

  group('a sprinkler pipe with no head is no sprinkler system', () {
    for (final svc in [_hy, _sp]) {
      test('suction on ${svc.name}: 31.545 L/s DN125, no sprinkler basis', () {
        final net = _headless(svc);
        final r = _size(net, cap: eh);
        for (final id in ['g', 'sa', 'd', 'r1']) {
          expect(_lps(r[id]!), closeTo(31.545, 0.001), reason: id);
          expect(_dn(r[id]!), 125, reason: id);
        }
        final systems = fireRatingSystems(net);
        expect(systems, hasLength(1));
        expect(systems.single.hasSprinklerHead(net), isFalse);
        expect(
            fireSystemDesignFlow(net, systems.single,
                    sprinklerDemand: eh, standpipeCap: standpipeFlow(1))!
                .inLitersPerSecond,
            closeTo(31.545, 0.001));
      });
    }
  });

  group('a suction leg on the other fire service flows source -> pump', () {
    for (final svc in [_hy, _sp]) {
      test('sb on ${svc.name}: 31.545 L/s DN125 from SH', () {
        final r = _size(_twoRooms(svc), cap: eh);
        expect(_lps(r['sb']!), closeTo(31.545, 0.001));
        expect(_dn(r['sb']!), 125);
        expect(r['sb']!.flowFromId, 'SH');
        // Room A keeps its combined 43.33 L/s (Round 63).
        expect(_lps(r['sa']!), closeTo(43.33, 1e-6));
      });
    }
  });

  group('a fire pump room sizes the same however it is drawn', () {
    final forward = _size(_pair(_hy), cap: oh2, floors: 8);
    test('forward all-hydrant: rb DN125 (NFPA 20 500 gpm discharge)', () {
      for (final id in _legIds) {
        expect(_lps(forward[id]!), closeTo(31.545, 0.001), reason: id);
        expect(_dn(forward[id]!), 125, reason: id);
      }
      expect(firePumpsDrawnBackwards(_pair(_hy), forward), isEmpty);
    });

    test('seeded: flips and the room-A service never move a size or arrow', () {
      final rnd = math.Random(64);
      for (var trial = 0; trial < 60; trial++) {
        final svc = rnd.nextBool() ? _hy : _sp;
        final flip = {
          for (final id in _legIds)
            if (rnd.nextBool()) id,
        };
        final net = _pair(svc, flip: flip);
        final r = _size(net, cap: oh2, floors: 8);
        for (final id in _legIds) {
          final why = 'trial $trial svc ${svc.name} flip $flip edge $id';
          expect(_lps(r[id]!), closeTo(_lps(forward[id]!), 1e-6), reason: why);
          expect(_dn(r[id]!), _dn(forward[id]!), reason: why);
          expect(r[id]!.flowFromId, forward[id]!.flowFromId, reason: why);
        }
        // A pump whose both pipes were flipped is drawn backwards and named.
        final named = firePumpsDrawnBackwards(net, r);
        expect(named.contains('PA'), flip.contains('a1') && flip.contains('a2'),
            reason: 'trial $trial');
        expect(named.contains('PB'), flip.contains('b1') && flip.contains('b2'),
            reason: 'trial $trial');
      }
    });
  });

  test('the jockey leg stops at the shared header (both fire services)', () {
    final r = _size(_hospital(),
        cap: oh2,
        floors: 7,
        jockey: const {'JP': FlowRate(0.00012)},
        overrides: {'j1': Diameter.mm(25), 'j2': Diameter.mm(25)});
    expect(jockeyLegEdgeIds(_hospital(), 'JP'), {'j1', 'j2'});
    expect(_lps(r['s2']!), closeTo(12.0, 1e-6));
    expect(_dn(r['s2']!), greaterThanOrEqualTo(80));
    expect(_lps(r['s1']!), greaterThanOrEqualTo(12.0 - 1e-6));
    expect(_dn(r['s1']!), greaterThanOrEqualTo(_dn(r['s2']!)));
    expect(_dn(r['j1']!), 25);
    expect(_dn(r['j2']!), 25);
  });
}
