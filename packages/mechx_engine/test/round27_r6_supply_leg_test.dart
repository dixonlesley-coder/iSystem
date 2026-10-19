/// Round 27 r6 (binding orchestrator refinement) — a check valve on a SUPPLY
/// LEG is never zero-forced. A leg exists to pass flow when (i) it carries a
/// MOVER (pump / booster set / supply fan) between the valve and the next
/// junction, or (ii) it is the root's own DISCHARGE leg (the chain from the
/// source through degree-2 nodes / inline devices to the first junction).
/// Such a valve is read as a FEED leading away from the source — never an
/// ambiguous closed return, never the self-contradictory fallback, never a
/// reopen/close decision — and a DRAWN one pointing back toward the source
/// (it would starve its own pump / source) is read as a feed and named.
///
/// The references are the engine's own networks: the open network (no
/// return drawn) when the return valve is closed, and the same drawing with
/// the supply-leg valve replaced by a bare junction (a feed valve is a
/// transparent pipe) when the ring is balanced as drawn.
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

NetEdge _e(String id, String a, String b,
        {EdgeKind k = EdgeKind.run, ServiceType s = ServiceType.hotWater}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

const _levels = BuildingLevels([
  Floor('L1', Length(3.0)),
  Floor('L2', Length(3.0)),
  Floor('L3', Length(3.0)),
  Floor('L4', Length(3.0)),
]);

const _sni = SniProfile();
double _curve(double ubap) =>
    _sni.probableFlowForFixtureUnits(ubap).inLitersPerSecond;

/// The hotel recirculation of the Round-27 suite: heater H, the discharge
/// H -> CVd -> M (ids hm1 / hm2), [risers] supply risers of 4 floors with a
/// 2-UBAP fixture per floor, each riser top down a return riser to RJ, then
/// RJ -> CV -> H.
///  * [cvdAmb] draws CVd with both pipes INTO it (hm1 H -> CVd, hm2 M -> CVd);
///    [cvdPlain] replaces CVd by a bare junction (the reference);
///  * [ret]: 'drawn' (RJ -> CV -> H), 'amb' (RJ -> CV and H -> CV),
///    'backwards' (H -> CV -> RJ), 'valveless' (RJ -> H plain pipe 'rh'),
///    'none' (no return drawn);
///  * [bends] inserts a bare bend on hm1 and on rj0 (same drawn route).
Network _hotel({
  int risers = 2,
  bool cvdAmb = false,
  bool cvdPlain = false,
  String ret = 'drawn',
  bool bends = false,
}) {
  final nodes = <NetNode>[
    _n('H', 0, 0, role: NodeRole.plant),
    _n('M', 50, 0),
    _n('CVd', 25, 0, c: cvdPlain ? null : NodeComponent.checkValve),
  ];
  final edges = <NetEdge>[];
  void pipe(String id, String a, String b, {EdgeKind k = EdgeKind.run}) {
    final na = nodes.firstWhere((n) => n.id == a);
    final nb = nodes.firstWhere((n) => n.id == b);
    if (bends && (id == 'hm1' || id == 'rj0')) {
      nodes.add(_n('K$id', (na.x + nb.x) / 2, (na.y + nb.y) / 2,
          floor: na.floorIndex));
      edges
        ..add(_e(id, a, 'K$id', k: k))
        ..add(_e('${id}k', 'K$id', b, k: k));
    } else {
      edges.add(_e(id, a, b, k: k));
    }
  }

  pipe('hm1', 'H', 'CVd');
  if (cvdAmb) {
    pipe('hm2', 'M', 'CVd');
  } else {
    pipe('hm2', 'CVd', 'M');
  }
  for (var r = 0; r < risers; r++) {
    final x = 100.0 + 200 * r;
    for (var f = 0; f < 4; f++) {
      nodes
        ..add(_n('S${r}_$f', x, 0, floor: f))
        ..add(_n('fx${r}_$f', x + 40, 0, floor: f, role: NodeRole.fixture));
      pipe('b${r}_$f', 'S${r}_$f', 'fx${r}_$f');
      if (f == 0) {
        pipe('m$r', 'M', 'S${r}_0');
      } else {
        pipe('s${r}_$f', 'S${r}_${f - 1}', 'S${r}_$f', k: EdgeKind.riser);
      }
    }
  }
  if (ret != 'none') {
    nodes.add(_n('RJ', 30, 0));
    for (var r = 0; r < risers; r++) {
      final x = 100.0 + 200 * r;
      for (var f = 0; f < 4; f++) {
        nodes.add(_n('R${r}_$f', x + 20, 0, floor: f));
      }
      pipe('top$r', 'S${r}_3', 'R${r}_3');
      for (var f = 3; f >= 1; f--) {
        pipe('r${r}_$f', 'R${r}_$f', 'R${r}_${f - 1}', k: EdgeKind.riser);
      }
      pipe('rj$r', 'R${r}_0', 'RJ');
    }
    if (ret == 'valveless') {
      pipe('rh', 'RJ', 'H');
    } else {
      nodes.add(_n('CV', 10, 0, c: NodeComponent.checkValve));
      switch (ret) {
        case 'drawn':
          pipe('jc', 'RJ', 'CV');
          pipe('ch', 'CV', 'H');
        case 'amb':
          pipe('jc', 'RJ', 'CV');
          pipe('ch', 'H', 'CV');
        case 'backwards':
          pipe('ch', 'H', 'CV');
          pipe('jc', 'CV', 'RJ');
      }
    }
  }
  return Network(nodes: nodes, edges: edges);
}

class _Run {
  final Map<String, EdgeSizing> s;
  final Map<String, CheckValveAmbiguity> amb;
  final Set<String> ring;
  final Set<String> par;
  _Run(this.s, this.amb, this.ring, this.par);
  double q(String id) => s[id]!.flow.inLitersPerSecond;
  int dn(String id) => s[id]!.diameter.inMillimeters.round();
}

_Run _size(Network net,
    {bool cal = false,
    ServiceType service = ServiceType.hotWater,
    double ubap = 2.0}) {
  final amb = <String, CheckValveAmbiguity>{};
  final ring = <String>{};
  final par = <String>{};
  final s = autoSizeNetwork(
    net,
    const SizingContext(),
    leafDemand: {service: const FlowRate(0)},
    leafFixtureUnits: {service: ubap},
    building: cal ? _levels : null,
    calibrationBySheet: cal ? const {'s1': ScaleCalibration(0.05)} : const {},
    checkValveAmbiguousOut: amb,
    checkValveFeedsRingOut: ring,
    parallelLegEdgeIdsOut: par,
  );
  return _Run(s, amb, ring, par);
}

/// Every edge of [ref] carries the same flow in [got] (a bend splits an id
/// into `id` + `idk`, both compared against `id`).
void _sameFlows(_Run got, _Run ref, String why, {Set<String> skip = const {}}) {
  for (final id in ref.s.keys) {
    if (skip.contains(id)) continue;
    expect(got.q(id), closeTo(ref.q(id), 1e-9), reason: '$why $id');
    if (got.s.containsKey('${id}k')) {
      expect(got.q('${id}k'), closeTo(ref.q(id), 1e-9), reason: '$why ${id}k');
    }
  }
}

void main() {
  test(
      'probe 1: BOTH the heater discharge CVd and the return CV ambiguous — '
      'CVd is the source discharge leg (a feed), CV a closed return: the '
      'feed is curve(16) DN25, the supply == the open network', () {
    // Flush-tank Gambar 1: 2 risers x 4 floors x 2 UBAP = 16 UBAP on the
    // heater feed => curve(16) = 0.5 + 6/10 x (0.65 - 0.5)... read off the
    // engine's own curve; a riser base carries 8 UBAP => curve(8) = 0.400
    // L/s (DN20: DN15 at 0.4 L/s is 4Q/(pi D^2) = 2.26 m/s > 2.0 m/s).
    // The heater's two chains: H -> CVd -> M reaches the nearest fixture
    // over 25 + 25 + 50 + 40 = 140 px, H -> CV -> RJ -> return riser over
    // 10 + 20 + 90 + 0 + 20 + 40 = 180 px (risers draw 0 px; calibrated the
    // return adds the 9 m of return riser): CVd's chain is the discharge.
    // r5 closed both, found the heater isolated and reopened BOTH
    // symmetrically — a full Hardy–Cross ring with the heater feed 0.3237
    // L/s DN15 (-50 %).
    expect(_curve(8), closeTo(0.400, 1e-12));
    expect(4 * 0.400e-3 / (math.pi * 0.015 * 0.015), greaterThan(2.0));
    for (final cal in [false, true]) {
      for (final bends in [false, true]) {
        for (final risers in [2, 3]) {
          final why = 'cal=$cal bends=$bends risers=$risers';
          final r = _size(
              _hotel(risers: risers, cvdAmb: true, ret: 'amb', bends: bends),
              cal: cal);
          final open = _size(_hotel(risers: risers, ret: 'none'), cal: cal);
          expect(r.amb, {
            'CVd': CheckValveAmbiguity.supplyLeg,
            'CV': CheckValveAmbiguity.closedReturn,
          }, reason: why);
          expect(r.q('hm1'), closeTo(_curve(8.0 * risers), 1e-9), reason: why);
          expect(r.q('hm2'), closeTo(_curve(8.0 * risers), 1e-9), reason: why);
          expect(r.s['hm2']!.flowFromId, 'CVd', reason: why);
          _sameFlows(r, open, why);
          for (final id in ['ch', 'jc', 'rj0', 'top0', 'r0_1']) {
            expect(r.q(id), 0, reason: '$why $id');
          }
          expect(r.ring, isEmpty, reason: why);
        }
      }
    }
    final r = _size(_hotel(cvdAmb: true, ret: 'amb'));
    expect(r.q('hm1'), closeTo(_curve(16), 1e-9));
    expect(r.dn('hm1'), 25);
  });

  test(
      'probe 2: an ambiguous heater discharge CVd + a VALVELESS return — '
      'CVd a feed, the valveless ring balanced as drawn (== CVd a bare '
      'junction), never the heater discharge zeroed', () {
    // r5 read CVd as a CLOSED RETURN (a valve-free path to the header
    // exists), zeroing hm1 / hm2 / m0 / m1 (DN15) and feeding the risers from
    // the TOP through the return riser. The plain return is a real pipe, so
    // the ring is Hardy–Cross split exactly as drawn.
    for (final cal in [false, true]) {
      for (final bends in [false, true]) {
        final why = 'cal=$cal bends=$bends';
        final r = _size(_hotel(cvdAmb: true, ret: 'valveless', bends: bends),
            cal: cal);
        final ref = _size(
            _hotel(cvdPlain: true, ret: 'valveless', bends: bends),
            cal: cal);
        expect(r.amb, {'CVd': CheckValveAmbiguity.supplyLeg}, reason: why);
        _sameFlows(r, ref, why);
        for (final id in ['hm1', 'hm2', 'm0', 'm1']) {
          expect(r.q(id), greaterThan(0), reason: '$why $id');
        }
        expect(r.s['hm2']!.flowFromId, 'CVd', reason: why);
        // Continuity at the heater: hm1 + rh deliver one diversified
        // curve(16).
        final rhFlow = r.q('rh');
        final rhOut = r.s['rh']!.flowFromId == 'H' ? rhFlow : -rhFlow;
        expect(r.q('hm1') + rhOut, closeTo(_curve(16), 1e-9), reason: why);
      }
    }
  });

  /// T -> P -> CV -> J (CV ambiguous unless [drawn]: 'fwd' P -> CV -> J,
  /// 'back' J -> CV -> P) with a plain bypass T -> J ([bypassBend] adds a
  /// bare bend on it); J -> 4 fixtures (4 UBAP each). [plain] replaces CV by
  /// a bare node (the reference).
  Network pumpBypass(
      {String drawn = 'amb', bool plain = false, bool bypassBend = false}) {
    final nodes = <NetNode>[
      _n('T', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('P', 30, -30, role: NodeRole.plant, c: NodeComponent.pump),
      _n('CV', 60, -30, c: plain ? null : NodeComponent.checkValve),
      _n('J', 90, 0),
      if (bypassBend) _n('KB', 45, 10),
      for (var i = 0; i < 4; i++)
        _n('f$i', 150, 30.0 * i, role: NodeRole.fixture),
    ];
    NetEdge e(String id, String a, String b) =>
        _e(id, a, b, s: ServiceType.coldWater);
    return Network(nodes: nodes, edges: [
      e('tp', 'T', 'P'),
      if (drawn == 'back') ...[e('pc', 'CV', 'P'), e('jc', 'J', 'CV')],
      if (drawn == 'fwd') ...[e('pc', 'P', 'CV'), e('jc', 'CV', 'J')],
      if (drawn == 'amb') ...[e('pc', 'P', 'CV'), e('jc', 'J', 'CV')],
      if (bypassBend) ...[e('tj', 'T', 'KB'), e('tjk', 'KB', 'J')],
      if (!bypassBend) e('tj', 'T', 'J'),
      for (var i = 0; i < 4; i++) e('b$i', 'J', 'f$i'),
    ]);
  }

  test(
      'probe 3: a pump + an AMBIGUOUS discharge valve + a plain bypass — the '
      'pump leg is a feed (never zero), the bypass splits by Hardy–Cross', () {
    // r5 read CV as a closed return: tp / pc / jc = 0 (DN15) and the bypass
    // carried the whole curve(16), so supplyMoverDutiesProvider (duty = the
    // flow THROUGH the mover) read ZERO duty. A pump exists to pass flow.
    // 4 fixtures x 4 UBAP = 16 UBAP => curve(16) through T, split between
    // the pump leg and the bypass exactly as with CV a bare node.
    for (final cal in [false, true]) {
      for (final bend in [false, true]) {
        final why = 'cal=$cal bend=$bend';
        final r = _size(pumpBypass(bypassBend: bend),
            cal: cal, service: ServiceType.coldWater, ubap: 4.0);
        final ref = _size(pumpBypass(plain: true, bypassBend: bend),
            cal: cal, service: ServiceType.coldWater, ubap: 4.0);
        expect(r.amb, {'CV': CheckValveAmbiguity.supplyLeg}, reason: why);
        _sameFlows(r, ref, why);
        for (final id in ['tp', 'pc', 'jc']) {
          expect(r.q(id), greaterThan(0), reason: '$why $id');
        }
        expect(r.s['jc']!.flowFromId, 'CV', reason: why);
        expect(r.q('tp') + r.q('tj'), closeTo(_curve(16), 1e-9), reason: why);
      }
    }
  });

  test(
      'drawn valve on a pump leg pointing back at its pump: read as a feed '
      'and named drawnAgainstSupplyLeg; drawn forward: a plain feed, unnamed',
      () {
    final ref = _size(pumpBypass(plain: true),
        service: ServiceType.coldWater, ubap: 4.0);
    final back =
        _size(pumpBypass(drawn: 'back'), service: ServiceType.coldWater, ubap: 4.0);
    expect(back.amb, {'CV': CheckValveAmbiguity.drawnAgainstSupplyLeg});
    _sameFlows(back, ref, 'back');
    expect(back.q('pc'), greaterThan(0));
    final fwd =
        _size(pumpBypass(drawn: 'fwd'), service: ServiceType.coldWater, ubap: 4.0);
    expect(fwd.amb, isEmpty);
    _sameFlows(fwd, ref, 'fwd');
  });

  test(
      'a circulator drawn COHERENTLY on a recirculation return (valve and '
      'pump both drawn toward the heater) keeps the drawn rule: a return '
      'with zero draw-off, unnamed', () {
    // H -> M supply; return R0 -> CVr -> Pr -> H with the pump's own pipes
    // drawn in -> out toward the heater: the drawing is coherent (the
    // circulator is not starved), so the drawn direction stands (rule 2: a
    // return => zero draw-off, the supply == the open network).
    Network build({required bool ret}) {
      final nodes = <NetNode>[
        _n('H', 0, 0, role: NodeRole.plant),
        for (var f = 0; f < 4; f++) ...[
          _n('S$f', 100, 0, floor: f),
          _n('fx$f', 140, 0, floor: f, role: NodeRole.fixture),
          if (ret) _n('R$f', 120, 40, floor: f),
        ],
        if (ret) ...[
          _n('CVr', 60, 40, c: NodeComponent.checkValve),
          _n('Pr', 30, 40, role: NodeRole.plant, c: NodeComponent.pump),
        ],
      ];
      final edges = <NetEdge>[
        _e('m', 'H', 'S0'),
        for (var f = 0; f < 4; f++) ...[
          _e('b$f', 'S$f', 'fx$f'),
          if (f > 0) _e('s$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser),
          if (ret && f > 0) _e('r$f', 'R$f', 'R${f - 1}', k: EdgeKind.riser),
        ],
        if (ret) ...[
          _e('top', 'S3', 'R3'),
          _e('rc', 'R0', 'CVr'),
          _e('cp', 'CVr', 'Pr'),
          _e('ph', 'Pr', 'H'),
        ],
      ];
      return Network(nodes: nodes, edges: edges);
    }

    for (final cal in [false, true]) {
      final r = _size(build(ret: true), cal: cal);
      final open = _size(build(ret: false), cal: cal);
      expect(r.amb, isEmpty, reason: 'cal=$cal');
      _sameFlows(r, open, 'cal=$cal');
      for (final id in ['rc', 'cp', 'ph']) {
        expect(r.q(id), 0, reason: 'cal=$cal $id');
      }
    }
  });

  /// Heater H with duty/standby circulation pumps H -> P1 -> CV1 -> HDR and
  /// H -> P2 -> CV2 -> HDR; HDR -> S0..S3 supply riser (2-UBAP fixture per
  /// floor), the riser top S3 -> R3 .. R0, and a VALVELESS return R0 -> H.
  /// [cv2Amb] draws CV2 with both pipes into it.
  Network dutyStandby({bool cv2Amb = false}) {
    final nodes = <NetNode>[
      _n('H', 0, 0, role: NodeRole.plant),
      _n('P1', 20, -20, role: NodeRole.plant, c: NodeComponent.pump),
      _n('P2', 20, 20, role: NodeRole.plant, c: NodeComponent.pump),
      _n('CV1', 40, -20, c: NodeComponent.checkValve),
      _n('CV2', 40, 20, c: NodeComponent.checkValve),
      _n('HDR', 60, 0),
    ];
    final edges = <NetEdge>[
      _e('h1', 'H', 'P1'),
      _e('p1', 'P1', 'CV1'),
      _e('c1', 'CV1', 'HDR'),
      _e('h2', 'H', 'P2'),
      _e('p2', 'P2', 'CV2'),
      cv2Amb ? _e('c2', 'HDR', 'CV2') : _e('c2', 'CV2', 'HDR'),
    ];
    for (var f = 0; f < 4; f++) {
      nodes
        ..add(_n('S$f', 100, 0, floor: f))
        ..add(_n('fx$f', 140, 0, floor: f, role: NodeRole.fixture))
        ..add(_n('R$f', 120, 40, floor: f));
      edges.add(_e('b$f', 'S$f', 'fx$f'));
      edges.add(f == 0
          ? _e('m', 'HDR', 'S0')
          : _e('s$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser));
      if (f > 0) edges.add(_e('r$f', 'R$f', 'R${f - 1}', k: EdgeKind.riser));
    }
    edges
      ..add(_e('top', 'S3', 'R3'))
      ..add(_e('rh', 'R0', 'H'));
    return Network(nodes: nodes, edges: edges);
  }

  test(
      'probe 4 + the r3-class advisory: duty/standby discharge valves onto a '
      'header ALSO reached by a valveless return stay a Round-13 set — the '
      'standby leg mirrors the duty leg, never check-valve-feeds-ring', () {
    // The Round-13 group needed HDR unreached with every valve cut, which a
    // plain return defeats: r5 read an ambiguous CV2 as a closed return
    // (h2 / p2 / c2 = 0 DN15) and, with both drawn, split the ring by
    // Hardy–Cross (each leg 0.1273 L/s) naming the pumps' own discharge
    // valves 'a second feed into a ring'. The legs share the leg ends
    // {H, HDR}: structurally one parallel set. The ring (duty leg + main +
    // valveless return) is balanced as drawn; the standby leg mirrors the
    // duty leg exactly (a standby pump is a full-duty machine).
    for (final cv2Amb in [false, true]) {
      for (final cal in [false, true]) {
        final why = 'cv2Amb=$cv2Amb cal=$cal';
        final r = _size(dutyStandby(cv2Amb: cv2Amb), cal: cal);
        expect(r.amb,
            cv2Amb ? {'CV2': CheckValveAmbiguity.standbySet} : isEmpty,
            reason: why);
        expect(r.ring, isEmpty, reason: why);
        expect(r.par, {'h2', 'p2', 'c2'}, reason: why);
        for (final (d, sb) in [('h1', 'h2'), ('p1', 'p2'), ('c1', 'c2')]) {
          expect(r.q(d), greaterThan(0), reason: '$why $d');
          expect(r.q(sb), closeTo(r.q(d), 1e-12), reason: '$why $sb');
        }
        expect(r.s['c2']!.flowFromId, 'CV2', reason: why);
        // Continuity at the heater: the duty leg + the return deliver one
        // diversified curve(8) (the standby leg is the idle machine).
        final rhOut =
            r.s['rh']!.flowFromId == 'H' ? r.q('rh') : -r.q('rh');
        expect(r.q('h1') + rhOut, closeTo(_curve(8), 1e-9), reason: why);
      }
    }
  });

  test(
      'probe 5 (doubly mis-drawn): an ambiguous heater discharge CVd AND the '
      'return drawn backwards (H -> CV -> RJ) — CVd a feed, the heater '
      'discharge carries draw-off, and the feeds-ring advisory names CV in '
      'ONE step', () {
    // r5 closed CVd (a valve-free alternative through the backwards return
    // existed), zeroing the heater's real discharge; closing CVd also hid
    // CV from the feeds-ring test, so the fix took two redraws.
    for (final cal in [false, true]) {
      final r = _size(_hotel(cvdAmb: true, ret: 'backwards'), cal: cal);
      expect(r.amb, {'CVd': CheckValveAmbiguity.supplyLeg}, reason: 'cal=$cal');
      expect(r.ring, {'CV'}, reason: 'cal=$cal');
      for (final id in ['hm1', 'hm2', 'm0', 'm1']) {
        expect(r.q(id), greaterThan(0), reason: 'cal=$cal $id');
      }
      expect(r.q('hm1') + r.q('ch'), closeTo(_curve(16), 1e-9),
          reason: 'cal=$cal');
      // As drawn: the same as both valves drawn H -> CVd -> M / H -> CV ->
      // RJ (two feeds).
      final drawn = _size(_hotel(ret: 'backwards'), cal: cal);
      _sameFlows(r, drawn, 'cal=$cal');
    }
  });

  test(
      'property (seeded): no check valve on a MOVER leg or on the source '
      'discharge leg is ever zero-forced — whatever the drawing direction, '
      'ids, bends or calibration', () {
    var checked = 0;
    for (var trial = 0; trial < 150; trial++) {
      final rnd = math.Random(6600 + trial);
      final nodes = <NetNode>[
        _n('T', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      ];
      final edges = <(String, String, String)>[];
      var eid = 0;
      void pipe(String a, String b) => edges.add(('e${eid++}', a, b));
      // Supply-leg valves: (id, mover-leg?)
      final supplyValves = <String>{};
      var vid = 0;
      var lastCase = 0;
      String valve(String a, String b, double x, double y) {
        final id = 'V${rnd.nextInt(1 << 20)}_${vid++}';
        nodes.add(_n(id, x, y, c: NodeComponent.checkValve));
        lastCase = rnd.nextInt(4);
        switch (lastCase) {
          case 0:
            pipe(a, id);
            pipe(id, b);
          case 1:
            pipe(b, id);
            pipe(id, a);
          case 2:
            pipe(a, id);
            pipe(b, id);
          default:
            pipe(id, a);
            pipe(id, b);
        }
        return id;
      }

      // A ring of k junctions (fixtures on some).
      final k = 3 + rnd.nextInt(4);
      var anyFixture = false;
      for (var i = 0; i < k; i++) {
        final a = 2 * math.pi * i / k;
        final (x, y) = (300 + 100 * math.cos(a), 100 * math.sin(a));
        nodes.add(_n('R$i', x, y));
        if (rnd.nextBool() || (i == k - 1 && !anyFixture)) {
          anyFixture = true;
          nodes.add(_n('f$i', x * 1.1, y * 1.1, role: NodeRole.fixture));
          pipe('R$i', 'f$i');
        }
      }
      for (var i = 0; i < k; i++) {
        final j = (i + 1) % k;
        rnd.nextBool() ? pipe('R$i', 'R$j') : pipe('R$j', 'R$i');
      }
      // 1..3 entries from T: each a pump leg T -> P -> V -> R (mover leg),
      // a valve leg T -> V -> R, or a plain pipe; at least one valve.
      final entries = ([for (var i = 0; i < k; i++) i]..shuffle(rnd))
          .take(1 + rnd.nextInt(3))
          .toList();
      var anyValve = false;
      for (var n = 0; n < entries.length; n++) {
        final en = entries[n];
        final kind = n == entries.length - 1 && !anyValve
            ? rnd.nextInt(2)
            : rnd.nextInt(3);
        if (kind == 0) {
          final p = 'P$n';
          nodes.add(_n(p, 40, 20.0 * n,
              role: NodeRole.plant, c: NodeComponent.pump));
          final pumpBack = rnd.nextBool();
          pumpBack ? pipe(p, 'T') : pipe('T', p);
          final v = valve(p, 'R$en', 80, 20.0 * n);
          // A valve AND its pump both drawn toward the source is a coherent
          // circulator drawing (the drawn rule stands) — outside this
          // property.
          if (!(pumpBack && lastCase == 1)) supplyValves.add(v);
          anyValve = true;
        } else if (kind == 1) {
          final v = valve('T', 'R$en', 60, 20.0 * n);
          // Only a single-chain source makes this the discharge leg for
          // sure; with several chains it is the nearest one's.
          if (entries.length == 1) supplyValves.add(v);
          anyValve = true;
        } else {
          pipe('T', 'R$en');
        }
      }
      final pos = {for (final n in nodes) n.id: (n.x, n.y)};
      final bent = {
        for (final (id, _, _) in edges)
          if (rnd.nextDouble() < 0.3) id,
      };
      Network build({required bool bends}) {
        final ns = [...nodes];
        final es = <NetEdge>[];
        for (final (id, a, b) in edges) {
          if (bends && bent.contains(id)) {
            final (xa, ya) = pos[a]!;
            final (xb, yb) = pos[b]!;
            ns.add(_n('K$id', (xa + xb) / 2, (ya + yb) / 2));
            es
              ..add(_e(id, a, 'K$id', s: ServiceType.coldWater))
              ..add(_e('${id}k', 'K$id', b, s: ServiceType.coldWater));
          } else {
            es.add(_e(id, a, b, s: ServiceType.coldWater));
          }
        }
        return Network(nodes: ns, edges: [...es]..shuffle(math.Random(trial)));
      }

      Map<CheckValveAmbiguity, int>? first;
      for (final bends in [false, true]) {
        for (final cal in [false, true]) {
          final net = build(bends: bends);
          final r = _size(net,
              cal: cal, service: ServiceType.coldWater, ubap: 4.0);
          final why = 'trial $trial bends=$bends cal=$cal';
          for (final v in supplyValves) {
            // Is it on a cycle at all (else a plain tree edge)?
            final legs = [
              for (final e in net.edges)
                if (e.fromId == v || e.toId == v) e,
            ];
            final label = r.amb[v];
            expect(label, isNot(CheckValveAmbiguity.closedReturn),
                reason: '$why $v');
            for (final e in legs) {
              expect(r.s[e.id], isNotNull, reason: '$why ${e.id}');
              expect(r.s[e.id]!.flow.inLitersPerSecond, greaterThan(0),
                  reason: '$why $v ${e.id}');
            }
            checked++;
          }
          final counts = <CheckValveAmbiguity, int>{};
          for (final l in r.amb.values) {
            counts[l] = (counts[l] ?? 0) + 1;
          }
          first ??= counts;
          expect(counts, first, reason: why);
        }
      }
    }
    expect(checked, greaterThan(200));
  });
}
