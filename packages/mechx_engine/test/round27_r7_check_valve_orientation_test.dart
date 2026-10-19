/// Round 27 r7 (binding orchestrator decision) — how a cycle check valve is
/// oriented, highest precedence first:
///  1. a DRAWN valve direction (one pipe into the valve, one out of it);
///  2. an adjacent MOVER (pump / booster set / supply fan) on the same
///     degree-2 leg drawn COHERENTLY — its drawn direction orients the leg
///     and every valve on it, never overridden by any distance or chain
///     choice (a coherent circulator drawn toward the source on a root chain
///     is a recirculation return);
///  3. STRUCTURAL root-chain cues only (a mover / a drawn valve pointing
///     away from the source makes a chain a discharge, a drawn valve toward
///     it a return);
///  4. NO DISTANCES — when several root chains stay undecided, the ENVELOPE
///     of every plausible discharge is sized (each edge on the largest |flow|
///     any reading gives).
/// A mover leg is never zero-forced or reversed: when the balance runs
/// against its pump the leg stays open, sized on |flow| in the pump's
/// direction, and the valve is reported.
///
/// The references are the engine's own networks: the open network (no
/// return drawn), the same drawing with valves drawn as the reading assumes,
/// or with a closed valve's chain removed. The envelope reference is the
/// per-edge maximum over those readings.
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
///  * [cvd]: 'drawn' (H -> CVd -> M), 'amb' (H -> CVd and M -> CVd), 'plain'
///    (a bare junction), 'back' (M -> CVd -> H: CVd drawn as a return, the
///    reference for "CVd closed"), 'none' (no discharge chain at all);
///  * [ret]: 'drawn' (RJ -> CV -> H), 'amb' (RJ -> CV and H -> CV),
///    'backwards' (H -> CV -> RJ), 'valveless' (RJ -> H plain pipe 'rh'),
///    'none' (no return drawn);
///  * [retDx]: the return risers' x offset from their supply riser (plan
///    pixels; 0 = drawn colinear); [mainY]: the header M's y (a jogged main);
///  * [bends] inserts a bare bend on hm1 and on rj0 (same drawn route).
Network _hotel({
  int risers = 2,
  String cvd = 'drawn',
  String ret = 'drawn',
  double retDx = 20,
  double mainY = 0,
  bool bends = false,
}) {
  final nodes = <NetNode>[
    _n('H', 0, 0, role: NodeRole.plant),
    _n('M', 50, mainY),
    if (cvd != 'none')
      _n('CVd', 25, 0, c: cvd == 'plain' ? null : NodeComponent.checkValve),
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

  if (cvd == 'back') {
    pipe('hm1', 'CVd', 'H');
    pipe('hm2', 'M', 'CVd');
  } else if (cvd != 'none') {
    pipe('hm1', 'H', 'CVd');
    if (cvd == 'amb') {
      pipe('hm2', 'M', 'CVd');
    } else {
      pipe('hm2', 'CVd', 'M');
    }
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
        nodes.add(_n('R${r}_$f', x + retDx, 0, floor: f));
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
  final Set<String> against;
  _Run(this.s, this.amb, this.ring, this.par, this.against);
  double q(String id) => s[id]?.flow.inLitersPerSecond ?? 0.0;
  int dn(String id) => s[id]!.diameter.inMillimeters.round();
}

_Run _size(Network net,
    {bool cal = false,
    ServiceType service = ServiceType.hotWater,
    double ubap = 2.0}) {
  final amb = <String, CheckValveAmbiguity>{};
  final ring = <String>{};
  final par = <String>{};
  final against = <String>{};
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
    checkValveAgainstPumpOut: against,
  );
  return _Run(s, amb, ring, par, against);
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

/// The ENVELOPE: every edge of [got] carries the largest flow any of the
/// readings [refs] gives it (an edge absent from a reading — a closed
/// valve's removed chain — carries 0 there).
void _envelope(_Run got, List<_Run> refs, String why) {
  for (final id in got.s.keys) {
    // A bend splits an id into `id` + `idk`; both carry `id`'s flow.
    final stem = id.substring(0, id.length - 1);
    final base = id.endsWith('k') && got.s.containsKey(stem) ? stem : id;
    final want = refs.map((r) => r.q(base)).reduce(math.max);
    expect(got.q(id), closeTo(want, 1e-9), reason: '$why $id');
  }
}

void main() {
  test('first principles: curve(8) = 0.400 L/s needs DN20, curve(16) DN25', () {
    // Flush-tank Gambar 1: a riser base carries 4 floors x 2 UBAP = 8 UBAP
    // => 8/10 x 0.5 = 0.400 L/s; DN15 at 0.4 L/s is 4Q/(pi D^2) = 2.26 m/s
    // > the 2.0 m/s cap. Two risers: 16 UBAP on the heater feed.
    expect(_curve(8), closeTo(0.400, 1e-12));
    expect(4 * 0.400e-3 / (math.pi * 0.015 * 0.015), greaterThan(2.0));
    final r = _size(_hotel(ret: 'none'));
    expect(r.q('hm1'), closeTo(_curve(16), 1e-9));
    expect(r.dn('hm1'), 25);
    expect(r.dn('m0'), 20);
  });

  test(
      'probe 1: BOTH the heater discharge CVd and the return CV ambiguous — '
      'two undecided root chains: the ENVELOPE of both readings, drawing-'
      'invariant (return riser colinear / left / right, a jogged main, '
      'calibration): hm1 = curve(16) DN25 always', () {
    // No drawn valve, no mover, no structural cue separates the two chains
    // leaving the heater, and no distance may (r6 picked the discharge by
    // the plan route, so moving the return riser 30 px flipped it). So both
    // readings are solved: (A) CVd the discharge, CV closed => the open
    // network (no return) for the supply, the return at zero; (B) CV the
    // discharge (drawn H -> CV -> RJ), CVd closed => the hotel fed down the
    // return risers. Every edge carries the larger. hm1 / hm2 take A's
    // curve(16) = 0.6533 L/s (DN25); the return takes B's flows.
    final labels = <Map<String, CheckValveAmbiguity>>[];
    for (final cal in [false, true]) {
      for (final retDx in [-20.0, -10.0, 0.0, 20.0]) {
        for (final mainY in [0.0, 60.0]) {
          for (final risers in [2, 3]) {
            final why = 'cal=$cal retDx=$retDx mainY=$mainY risers=$risers';
            Network h({required String cvd, required String ret}) => _hotel(
                risers: risers, cvd: cvd, ret: ret, retDx: retDx, mainY: mainY);
            final r = _size(h(cvd: 'amb', ret: 'amb'), cal: cal);
            final a = _size(h(cvd: 'drawn', ret: 'drawn'), cal: cal);
            final b = _size(h(cvd: 'back', ret: 'backwards'), cal: cal);
            expect(
                r.amb,
                {
                  'CVd': CheckValveAmbiguity.envelope,
                  'CV': CheckValveAmbiguity.envelope,
                },
                reason: why);
            labels.add(r.amb);
            _envelope(r, [a, b], why);
            expect(r.q('hm1'), closeTo(_curve(8.0 * risers), 1e-9),
                reason: why);
            expect(r.q('hm2'), closeTo(_curve(8.0 * risers), 1e-9),
                reason: why);
            expect(r.s['hm2']!.flowFromId, 'CVd', reason: why);
            if (risers == 2) expect(r.dn('hm1'), 25, reason: why);
            for (var k = 0; k < risers; k++) {
              expect(r.q('m$k'), closeTo(_curve(8), 1e-9), reason: why);
              expect(r.dn('m$k'), 20, reason: why);
            }
            // The return is sized for the reading in which it feeds.
            expect(r.q('ch'), closeTo(_curve(8.0 * risers), 1e-9), reason: why);
            expect(r.ring, isEmpty, reason: why);
          }
        }
      }
    }
    // Bends never move it either.
    final bent = _size(_hotel(cvd: 'amb', ret: 'amb', bends: true));
    expect(bent.amb, labels.first);
    expect(bent.q('hm1'), closeTo(_curve(16), 1e-9));
  });

  test(
      'probe 2: an ambiguous heater discharge CVd + a VALVELESS return — one '
      'undecided root chain beside a plain pipe: the r5 rule (closed), '
      'identical for every return-riser offset, jog and calibration', () {
    // Topologically this IS the r5 hotel with an ambiguous return (one
    // valveless chain and one ambiguous-valve chain leave the heater); with
    // no distance allowed the two cannot be told apart, so CVd is read
    // CLOSED (r5: every main upstream — here the valveless return — carries
    // the full peak) and named for redraw. Residual recorded: the heater's
    // real discharge is then DN15; redrawing CVd fixes it.
    for (final cal in [false, true]) {
      for (final retDx in [-20.0, -10.0, 0.0, 20.0]) {
        for (final mainY in [0.0, 60.0]) {
          final why = 'cal=$cal retDx=$retDx mainY=$mainY';
          final r = _size(
              _hotel(cvd: 'amb', ret: 'valveless', retDx: retDx, mainY: mainY),
              cal: cal);
          final ref = _size(
              _hotel(cvd: 'back', ret: 'valveless', retDx: retDx, mainY: mainY),
              cal: cal);
          expect(r.amb, {'CVd': CheckValveAmbiguity.closedReturn}, reason: why);
          _sameFlows(r, ref, why);
          expect(r.q('hm1'), 0, reason: why);
          expect(r.q('hm2'), 0, reason: why);
          // The valveless return carries the whole curve(16).
          expect(r.q('rh'), closeTo(_curve(16), 1e-9), reason: why);
        }
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
    // The pump T -> P -> CV is drawn coherently away from the tank: it
    // orients its leg (precedence 2). r5 read CV as a closed return: tp / pc
    // / jc = 0 (DN15), the bypass carried the whole curve(16) and the mover
    // duty (the flow THROUGH it) read ZERO. 4 fixtures x 4 UBAP = 16 UBAP
    // => curve(16) through T, split between the pump leg and the bypass
    // exactly as with CV a bare node.
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
      'drawn valve on a pump leg pointing back at its (incoherently drawn) '
      'pump: read as a feed and named drawnAgainstSupplyLeg; drawn forward: '
      'a plain feed, unnamed', () {
    final ref = _size(pumpBypass(plain: true),
        service: ServiceType.coldWater, ubap: 4.0);
    final back = _size(pumpBypass(drawn: 'back'),
        service: ServiceType.coldWater, ubap: 4.0);
    expect(back.amb, {'CV': CheckValveAmbiguity.drawnAgainstSupplyLeg});
    _sameFlows(back, ref, 'back');
    expect(back.q('pc'), greaterThan(0));
    final fwd = _size(pumpBypass(drawn: 'fwd'),
        service: ServiceType.coldWater, ubap: 4.0);
    expect(fwd.amb, isEmpty);
    _sameFlows(fwd, ref, 'fwd');
  });

  /// H -> S0 supply riser (2-UBAP fixture per floor, 4 floors); return
  /// R3 .. R0 from the riser top back to the heater through a check valve
  /// CVr and a circulator Pr. [cv]: 'drawn' (R0 -> CVr -> ..), 'amb' (both
  /// CVr pipes drawn OUT of CVr / INTO CVr). [pumpNearHeater]: the
  /// circulator between CVr and H (R0 - CVr - Pr - H), else between R0 and
  /// CVr (R0 - Pr - CVr - H). The pump's own two pipes are always drawn
  /// coherently toward the heater.
  Network circulator(
      {required bool ret, String cv = 'drawn', bool pumpNearHeater = true}) {
    final nodes = <NetNode>[
      _n('H', 0, 0, role: NodeRole.plant),
      for (var f = 0; f < 4; f++) ...[
        _n('S$f', 100, 0, floor: f),
        _n('fx$f', 140, 0, floor: f, role: NodeRole.fixture),
        if (ret) _n('R$f', 120, 40, floor: f),
      ],
      if (ret) ...[
        _n('CVr', pumpNearHeater ? 60 : 30, 40, c: NodeComponent.checkValve),
        _n('Pr', pumpNearHeater ? 30 : 60, 40,
            role: NodeRole.plant, c: NodeComponent.pump),
      ],
    ];
    final edges = <NetEdge>[
      _e('m', 'H', 'S0'),
      for (var f = 0; f < 4; f++) ...[
        _e('b$f', 'S$f', 'fx$f'),
        if (f > 0) _e('s$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser),
        if (ret && f > 0) _e('r$f', 'R$f', 'R${f - 1}', k: EdgeKind.riser),
      ],
      if (ret) _e('top', 'S3', 'R3'),
    ];
    if (ret && pumpNearHeater) {
      // R0 - CVr - Pr -> H; the pump drawn CVr -> Pr -> H.
      edges.addAll([
        if (cv == 'drawn') _e('rc', 'R0', 'CVr') else _e('rc', 'CVr', 'R0'),
        _e('cp', 'CVr', 'Pr'),
        _e('ph', 'Pr', 'H'),
      ]);
    } else if (ret) {
      // R0 -> Pr -> CVr - H; the pump drawn R0 -> Pr -> CVr.
      edges.addAll([
        _e('rc', 'R0', 'Pr'),
        _e('cp', 'Pr', 'CVr'),
        if (cv == 'drawn') _e('ph', 'CVr', 'H') else _e('ph', 'H', 'CVr'),
      ]);
    }
    return Network(nodes: nodes, edges: edges);
  }

  test(
      'a circulator drawn COHERENTLY toward the heater on a recirculation '
      'return orients its leg (precedence 2): a drawn OR AMBIGUOUS CVr is a '
      'return with zero draw-off, in either pump position — the supply main '
      'curve(8) = 0.400 L/s DN20 (as on 4e5e9d9), calibrated or not', () {
    // r6 read an ambiguous CVr on the heater's chain as "the source's
    // discharge" (a feed away from H), feeding the riser from the top down
    // the return (m 0.2 L/s). The circulator's own pipes say the leg flows
    // toward the heater: a coherent circulator on a root chain drawn toward
    // the root is a recirculation return.
    for (final pumpNearHeater in [true, false]) {
      for (final cv in ['drawn', 'amb']) {
        for (final cal in [false, true]) {
          final why = 'pumpNearHeater=$pumpNearHeater cv=$cv cal=$cal';
          final r = _size(
              circulator(ret: true, cv: cv, pumpNearHeater: pumpNearHeater),
              cal: cal);
          final open = _size(circulator(ret: false), cal: cal);
          expect(r.amb,
              cv == 'amb' ? {'CVr': CheckValveAmbiguity.closedReturn} : isEmpty,
              reason: why);
          _sameFlows(r, open, why);
          expect(r.q('m'), closeTo(_curve(8), 1e-9), reason: why);
          expect(r.dn('m'), 20, reason: why);
          for (final id in ['rc', 'cp', 'ph', 'top']) {
            expect(r.q(id), 0, reason: '$why $id');
          }
          expect(r.against, isEmpty, reason: why);
        }
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
      'probe 4: duty/standby discharge valves onto a header ALSO reached by '
      'a valveless return stay a Round-13 set — the standby leg mirrors the '
      'duty leg, never check-valve-feeds-ring', () {
    // The legs share the leg ends {H, HDR}: structurally one parallel set.
    // The ring (duty leg + main + valveless return) is balanced as drawn;
    // the standby leg mirrors the duty leg exactly (a standby pump is a
    // full-duty machine).
    for (final cv2Amb in [false, true]) {
      for (final cal in [false, true]) {
        final why = 'cv2Amb=$cv2Amb cal=$cal';
        final r = _size(dutyStandby(cv2Amb: cv2Amb), cal: cal);
        expect(
            r.amb, cv2Amb ? {'CV2': CheckValveAmbiguity.standbySet} : isEmpty,
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
        final rhOut = r.s['rh']!.flowFromId == 'H' ? r.q('rh') : -r.q('rh');
        expect(r.q('h1') + rhOut, closeTo(_curve(8), 1e-9), reason: why);
      }
    }
  });

  test(
      'probe 5 (doubly mis-drawn): an ambiguous heater discharge CVd beside '
      'the return drawn backwards (H -> CV -> RJ, a drawn-valve-only '
      'discharge) — the envelope: the heater discharge always carries '
      'curve(16), and the feeds-ring advisory names CV in ONE step', () {
    // The drawn-away valve on CV's chain is exactly what a return drawn
    // backwards looks like, so it does not settle which chain is the
    // discharge: (A) CVd a feed too (both drawn as feeds); (B) CVd closed
    // (the hotel fed down the backwards return). Every edge carries the
    // larger. The same rule reads the mirror drawing (CVd drawn, CV
    // ambiguous: the r4-regression hotel) identically — no distance may
    // tell them apart.
    for (final cal in [false, true]) {
      for (final retDx in [-20.0, 0.0, 20.0]) {
        final why = 'cal=$cal retDx=$retDx';
        final r =
            _size(_hotel(cvd: 'amb', ret: 'backwards', retDx: retDx), cal: cal);
        final a = _size(_hotel(ret: 'backwards', retDx: retDx), cal: cal);
        final b = _size(_hotel(cvd: 'back', ret: 'backwards', retDx: retDx),
            cal: cal);
        final open = _size(_hotel(ret: 'none', retDx: retDx), cal: cal);
        expect(r.amb, {'CVd': CheckValveAmbiguity.envelope}, reason: why);
        expect(r.ring, {'CV'}, reason: why);
        _envelope(r, [a, b], why);
        // (A)'s heater feed is below curve(16) (the ring shares it), but the
        // open-network peak curve(16) is reached by... the (B) reading's
        // return 'ch' instead; the discharge itself is never zero.
        for (final id in ['hm1', 'hm2', 'm0', 'm1']) {
          expect(r.q(id), greaterThan(0), reason: '$why $id');
        }
        expect(r.q('ch'), closeTo(_curve(16), 1e-9), reason: why);
        expect(open.q('hm1'), closeTo(_curve(16), 1e-9));
      }
    }
  });

  /// The reviewer's interior booster: T -> R0; R0 - R1 a LONG pipe with a
  /// fixture off R1; R0 - R2 - R3 short pipes with a fixture off R3; the
  /// booster leg R1 -> P -> CV -> R3 (pump drawn R1 -> P coherently, the
  /// valve drawn P -> CV -> R3).
  Network interiorBooster() {
    NetEdge e(String id, String a, String b) =>
        _e(id, a, b, s: ServiceType.coldWater);
    return Network(nodes: [
      _n('T', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('R0', 20, 0),
      _n('R1', 420, 0),
      _n('R2', 20, 20),
      _n('R3', 20, 40),
      _n('P', 220, 40, role: NodeRole.plant, c: NodeComponent.pump),
      _n('CV', 120, 40, c: NodeComponent.checkValve),
      _n('f1', 440, 0, role: NodeRole.fixture),
      _n('f3', 0, 40, role: NodeRole.fixture),
    ], edges: [
      e('t0', 'T', 'R0'),
      e('r01', 'R0', 'R1'),
      e('r02', 'R0', 'R2'),
      e('r23', 'R2', 'R3'),
      e('r1p', 'R1', 'P'),
      e('pc', 'P', 'CV'),
      e('c3', 'CV', 'R3'),
      e('b1', 'R1', 'f1'),
      e('b3', 'R3', 'f3'),
    ]);
  }

  test(
      'interior booster: the balance runs AGAINST the drawn pump — the leg '
      'stays open, sized on |flow| in the pump direction R1 -> R3 and '
      'reported; calibration never turns it', () {
    // r6 closed the valve when the balance ran against it (and, calibrated,
    // read it a RETURN by metres: R3 is 2 short pipes from R0, P is past the
    // long pipe), zero-forcing a booster. A mover leg exists to pass flow.
    for (final cal in [false, true]) {
      final why = 'cal=$cal';
      final r = _size(interiorBooster(),
          cal: cal, service: ServiceType.coldWater, ubap: 4.0);
      for (final (id, from) in [('r1p', 'R1'), ('pc', 'P'), ('c3', 'CV')]) {
        expect(r.q(id), greaterThan(0), reason: '$why $id');
        expect(r.s[id]!.flowFromId, from, reason: '$why $id');
      }
      // The leg carries one |flow| throughout.
      expect(r.q('pc'), closeTo(r.q('r1p'), 1e-12), reason: why);
      expect(r.q('c3'), closeTo(r.q('r1p'), 1e-12), reason: why);
      expect(r.against, {'CV'}, reason: why);
      expect(r.amb, isEmpty, reason: why);
    }
  });

  test(
      'property (seeded): mover legs off the source AND between interior '
      'junctions, plus several valved root chains — (a) no mover-leg valve '
      'carries 0 or flows against its coherently drawn pump; (b) the reading '
      'is invariant to plan coordinates (every node jittered), bends and '
      'calibration, and every size to a length-ratio-preserving redraw', () {
    var checkedMover = 0;
    var envelopes = 0;
    for (var trial = 0; trial < 160; trial++) {
      final rnd = math.Random(7700 + trial);
      final nodes = <NetNode>[
        _n('T', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      ];
      final edges = <(String, String, String)>[];
      var eid = 0;
      void pipe(String a, String b) => edges.add(('e${eid++}', a, b));
      // Mover-leg valves: id -> (pump id, pump drawn coherently?).
      // Mover-leg valves: id -> (its pump-side pipe's id, pump coherent?).
      final moverValves = <String, (String, bool)>{};
      var vid = 0;
      String valve(String a, String b, double x, double y) {
        final id = 'V${rnd.nextInt(1 << 20)}_${vid++}';
        nodes.add(_n(id, x, y, c: NodeComponent.checkValve));
        switch (rnd.nextInt(4)) {
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

      // A pump leg a -> P - V - b: the pump's pipes drawn a -> P -> V
      // (coherent) or a -> P <- V (both into P: an incoherent pump); the
      // valve's other pipe drawn either way.
      void pumpLeg(String a, String b, double x, double y, int n) {
        final p = 'P$n';
        final v = 'V${rnd.nextInt(1 << 20)}_${vid++}';
        nodes
          ..add(_n(p, x, y, role: NodeRole.plant, c: NodeComponent.pump))
          ..add(_n(v, x + 20, y, c: NodeComponent.checkValve));
        final coherent = rnd.nextBool();
        pipe(a, p);
        coherent ? pipe(p, v) : pipe(v, p);
        final pv = edges.last.$1;
        rnd.nextBool() ? pipe(v, b) : pipe(b, v);
        moverValves[v] = (pv, coherent);
      }

      // A ring of k junctions, a fixture off EVERY one (so every mover leg
      // has something to feed — a leg with no demand beyond it honestly
      // carries 0).
      final k = 3 + rnd.nextInt(4);
      for (var i = 0; i < k; i++) {
        // (An irregular ring: a perfectly symmetric one can balance a leg
        // to exactly 0 — no demand difference across it.)
        final a = 2 * math.pi * i / k;
        final rad = 80 + 50 * rnd.nextDouble();
        final (x, y) = (300 + rad * math.cos(a), rad * math.sin(a));
        nodes
          ..add(_n('R$i', x, y))
          ..add(_n('f$i', x * 1.1, y * 1.1, role: NodeRole.fixture));
        pipe('R$i', 'f$i');
      }
      // The ring: plain pipes, or an INTERIOR pump leg between neighbours.
      var np = 0;
      for (var i = 0; i < k; i++) {
        final j = (i + 1) % k;
        if (rnd.nextDouble() < 0.2) {
          pumpLeg('R$i', 'R$j', 300.0 + 10 * i, 150, np++);
        } else {
          rnd.nextBool() ? pipe('R$i', 'R$j') : pipe('R$j', 'R$i');
        }
      }
      // 1..3 entries from T: a pump leg T -> P -> V -> R, a valve leg
      // T -> V -> R (a valved root chain), or a plain pipe.
      final entries = ([for (var i = 0; i < k; i++) i]..shuffle(rnd))
          .take(1 + rnd.nextInt(3))
          .toList();
      for (var n = 0; n < entries.length; n++) {
        final en = entries[n];
        switch (rnd.nextInt(3)) {
          case 0:
            pumpLeg('T', 'R$en', 40, 20.0 * n, np++);
          case 1:
            valve('T', 'R$en', 60, 20.0 * n);
          default:
            pipe('T', 'R$en');
        }
      }
      final bent = {
        for (final (id, _, _) in edges)
          if (rnd.nextDouble() < 0.3) id,
      };
      final jitter = {
        for (final n in nodes)
          n.id: (rnd.nextDouble() * 40 - 20, rnd.nextDouble() * 40 - 20),
      };
      // Variants: 0 base, 1 calibrated, 2 every node jittered, 3 jittered +
      // calibrated, 4 bends, 5 a uniform redraw (x2 scale + translation).
      Network build(int variant) {
        (double, double) at(NetNode n) {
          switch (variant) {
            case 2:
            case 3:
              final (dx, dy) = jitter[n.id]!;
              return (n.x + dx, n.y + dy);
            case 5:
              return (2 * n.x + 37, 2 * n.y - 11);
            default:
              return (n.x, n.y);
          }
        }

        final ns = [
          for (final n in nodes)
            _n(n.id, at(n).$1, at(n).$2, role: n.role, c: n.component),
        ];
        final pos = {for (final n in ns) n.id: (n.x, n.y)};
        final es = <NetEdge>[];
        for (final (id, a, b) in edges) {
          if (variant == 4 && bent.contains(id)) {
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

      final runs = <_Run>[];
      for (var v = 0; v < 6; v++) {
        final net = build(v);
        final r = _size(net,
            cal: v == 1 || v == 3, service: ServiceType.coldWater, ubap: 4.0);
        runs.add(r);
        final why = 'trial $trial variant $v';
        // (a) every mover-leg valve on a cycle passes flow, in its coherent
        // pump's direction.
        for (final MapEntry(key: cv, value: (pv, coherent))
            in moverValves.entries) {
          final legs = [
            for (final e in net.edges)
              if (e.fromId == cv || e.toId == cv) e,
          ];
          // (A bend splits the pump-side pipe into pv + pvk.)
          final pe = legs.firstWhere((e) => e.id == pv || e.id == '${pv}k');
          final oe = legs.firstWhere((e) => e.id != pe.id);
          final s1 = r.s[pe.id], s2 = r.s[oe.id];
          expect(r.amb[cv], isNot(CheckValveAmbiguity.closedReturn),
              reason: '$why $cv');
          expect(s1, isNotNull, reason: '$why $cv');
          expect(s2, isNotNull, reason: '$why $cv');
          expect(s1!.flow.inLitersPerSecond, greaterThan(0),
              reason: '$why $cv');
          expect(s2!.flow.inLitersPerSecond, greaterThan(0),
              reason: '$why $cv');
          if (coherent) {
            // Drawn a -> P -> V: the flow passes the pump INTO the valve and
            // out of it, whatever the balance wanted.
            expect(s1.flowFromId, isNot(cv), reason: '$why $cv');
            expect(s2.flowFromId, cv, reason: '$why $cv');
          }
          checkedMover++;
        }
      }
      // (b) the reading never moves; a length-ratio-preserving redraw keeps
      // the zero-flow set and every size. (A bare bend adds a HOP: rule 2
      // reads a drawn valve on hop counts — calibration- and coordinate-
      // free, but a bend is a node — so on the bends variant only the
      // reading of the ambiguous / mover valves is compared.)
      final base = runs.first;
      if (base.amb.values.contains(CheckValveAmbiguity.envelope)) envelopes++;
      Set<String> zeros(_Run r) => {
            for (final MapEntry(key: id, value: s) in r.s.entries)
              if (s.flow.inLitersPerSecond == 0 && !id.endsWith('k')) id,
          };
      for (var v = 1; v < runs.length; v++) {
        final why = 'trial $trial variant $v';
        expect(runs[v].amb, base.amb, reason: why);
        // (Whether the balance shuts a genuine FEED valve — a check valve
        // closing under reverse pressure — follows real lengths, like any
        // ring split: compared on the length-ratio-preserving redraws.)
        if (v == 5) {
          expect(zeros(runs[v]), zeros(base), reason: why);
          for (final (id, _, _) in edges) {
            final want = base.s[id], got = runs[v].s[id];
            expect(got == null, want == null, reason: '$why $id');
            if (got == null || want == null) continue;
            expect(got.flow.inLitersPerSecond,
                closeTo(want.flow.inLitersPerSecond, 1e-9),
                reason: '$why $id');
            expect(got.diameter.inMillimeters, want.diameter.inMillimeters,
                reason: '$why $id');
          }
        }
      }
    }
    expect(checkedMover, greaterThan(150));
    expect(envelopes, greaterThan(5));
  });
}
