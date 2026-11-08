/// Round 27 r8 (binding orchestrator decision; builds on r7) —
///  1. a MOVER leg (valved OR valveless) whose balanced split runs AGAINST
///     its coherently drawn pump is sized on the ENVELOPE of two scenarios:
///     (a) the leg CLOSED (zero draw-off, the r4 closed-return treatment incl.
///     the zero pockets) and (b) the leg OPEN as balanced — every edge on the
///     larger |flow|; the leg itself on its scenario-(b) |flow| in the pump's
///     direction (never 0, never backwards through the pump); (a) is skipped
///     when closing the leg starves a draw-off point;
///  2. VALVELESS mover legs are classifier inputs: a coherently drawn mover on
///     a valveless ROOT chain is a structural cue (toward the root => a
///     RETURN chain, away => a discharge chain), and a valveless leg the
///     balance runs against is named on its pump (`moverAgainstBalanceOut`);
///  3. rule 2 reads the BEND-FREE metric: adding elbows to a drawn leg never
///     flips FEED / RETURN;
///  4. envelope honesty: a scenario's side outputs are reported only when it
///     wins at least one edge of the element they name.
///
/// References are the engine's own networks: the open network (the leg
/// absent = scenario (a)), and the same drawing with the leg's valve / pump
/// replaced by bare nodes (a plain Hardy–Cross ring = scenario (b)). The
/// envelope is the per-edge maximum over those readings.
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

class _Run {
  final Map<String, EdgeSizing> s;
  final Map<String, CheckValveAmbiguity> amb;
  final Set<String> ring;
  final Set<String> against;
  final Set<String> moverAgainst;
  _Run(this.s, this.amb, this.ring, this.against, this.moverAgainst);
  double q(String id) => s[id]?.flow.inLitersPerSecond ?? 0.0;
  int dn(String id) => s[id]!.diameter.inMillimeters.round();
  String? from(String id) => s[id]?.flowFromId;
}

_Run _size(Network net,
    {bool cal = false,
    ServiceType service = ServiceType.hotWater,
    double ubap = 2.0}) {
  final amb = <String, CheckValveAmbiguity>{};
  final ring = <String>{};
  final against = <String>{};
  final moverAgainst = <String>{};
  final s = autoSizeNetwork(
    net,
    const SizingContext(),
    leafDemand: {service: const FlowRate(0)},
    leafFixtureUnits: {service: ubap},
    building: cal ? _levels : null,
    calibrationBySheet: cal ? const {'s1': ScaleCalibration(0.05)} : const {},
    checkValveAmbiguousOut: amb,
    checkValveFeedsRingOut: ring,
    checkValveAgainstPumpOut: against,
    moverAgainstBalanceOut: moverAgainst,
  );
  return _Run(s, amb, ring, against, moverAgainst);
}

/// Every edge of [got] carries the largest flow any reading of [refs] gives
/// it (an edge absent from a reading carries 0 there).
void _envelope(_Run got, List<_Run> refs, String why) {
  for (final id in got.s.keys) {
    final want = refs.map((r) => r.q(id)).reduce(math.max);
    expect(got.q(id), closeTo(want, 1e-9), reason: '$why $id');
  }
}

void main() {
  test('first principles: curve(8) = 0.400 L/s needs DN20, curve(16) DN25', () {
    // Flush-tank Gambar 1: 4 floors x 2 UBAP = 8 UBAP => 8/10 x 0.5 = 0.400
    // L/s; DN15 at 0.4 L/s is 4Q/(pi D^2) = 2.26 m/s > the 2.0 m/s cap.
    expect(_curve(8), closeTo(0.400, 1e-12));
    expect(4 * 0.400e-3 / (math.pi * 0.015 * 0.015), greaterThan(2.0));
    expect(_curve(16), closeTo(0.6533, 1e-4));
  });

  /// The reviewer's regression probe: heater H -> M -> S0..S3 supply riser
  /// (a 2-UBAP fixture per floor), the riser top S3 -> R3 .. R0 -> RJ ->
  /// CV -> Pr -> M — the return lands on the header M, not on the heater, so
  /// the circulator leg runs between two junctions (S3 and M). The pump is
  /// drawn CV -> Pr -> M (coherently toward M); CV drawn RJ -> CV ([cv]
  /// 'drawn') or with both its pipes out of it ('amb'). [plain] replaces CV
  /// and Pr by bare nodes (scenario (b): the plain ring); [open] leaves the
  /// return out (scenario (a): the leg closed).
  Network headerReturn(
      {String cv = 'drawn', bool plain = false, bool open = false}) {
    final nodes = <NetNode>[
      _n('H', 0, 0, role: NodeRole.plant),
      _n('M', 50, 0),
      for (var f = 0; f < 4; f++) ...[
        _n('S$f', 100, 0, floor: f),
        _n('fx$f', 140, 0, floor: f, role: NodeRole.fixture),
        if (!open) _n('R$f', 120, 40, floor: f),
      ],
      if (!open) ...[
        _n('RJ', 90, 40),
        _n('CV', 70, 40, c: plain ? null : NodeComponent.checkValve),
        // (One explicit elevation for the pump and its bare stand-in, so
        // the calibrated run lengths agree: a plant and a bare main sit at
        // different heights.)
        NetNode(
            id: 'Pr',
            sheetId: 's1',
            x: 50,
            y: 40,
            floorIndex: 0,
            elevation: const Length(2.0),
            role: plain ? NodeRole.main : NodeRole.plant,
            component: plain ? null : NodeComponent.pump),
      ],
    ];
    final edges = <NetEdge>[
      _e('hm', 'H', 'M'),
      _e('m', 'M', 'S0'),
      for (var f = 0; f < 4; f++) ...[
        _e('b$f', 'S$f', 'fx$f'),
        if (f > 0) _e('s$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser),
        if (!open && f > 0) _e('r$f', 'R$f', 'R${f - 1}', k: EdgeKind.riser),
      ],
      if (!open) ...[
        _e('top', 'S3', 'R3'),
        _e('rj', 'R0', 'RJ'),
        if (cv == 'drawn') _e('jc', 'RJ', 'CV') else _e('jc', 'CV', 'RJ'),
        _e('cp', 'CV', 'Pr'),
        _e('pm', 'Pr', 'M'),
      ],
    ];
    return Network(nodes: nodes, edges: edges);
  }

  test(
      'decision 1 (the r7 regression): a circulator leg on a return that '
      'lands on the HEADER, its balanced split against the drawn pump — '
      'the ENVELOPE of the leg closed and the leg open: supply main m = '
      'curve(8) = 0.400 L/s DN20 (as on 4e5e9d9), the circulator leg > 0 '
      'in the pump direction, advisory raised; drawn or ambiguous CV, '
      'calibrated or not', () {
    // r7 kept the leg open as balanced: the plain ring split the riser's
    // draw-off between the supply riser and the return (both fed from M), so
    // m carried only a share of curve(8) (DN15). (a) the leg closed is the
    // open network: m = curve(8) DN20, every return pipe 0. (b) the leg open
    // is the plain ring: the return carries its share, oriented by the
    // balance from M up toward S3 — against the pump CV -> Pr -> M. Each edge
    // takes the larger; the leg keeps (b)'s |flow| in the pump's direction.
    for (final cv in ['drawn', 'amb']) {
      for (final cal in [false, true]) {
        final why = 'cv=$cv cal=$cal';
        final r = _size(headerReturn(cv: cv), cal: cal);
        final a = _size(headerReturn(open: true), cal: cal);
        final b = _size(headerReturn(cv: cv, plain: true), cal: cal);
        _envelope(r, [a, b], why);
        expect(r.q('m'), closeTo(_curve(8), 1e-9), reason: why);
        expect(r.dn('m'), 20, reason: why);
        expect(r.q('hm'), closeTo(_curve(8), 1e-9), reason: why);
        // (b) really ran against the pump: the plain ring feeds the return
        // from M.
        expect(b.from('pm'), 'M', reason: why);
        for (final (id, from) in [
          ('top', 'S3'),
          ('r2', 'R2'),
          ('rj', 'R0'),
          ('jc', 'RJ'),
          ('cp', 'CV'),
          ('pm', 'Pr'),
        ]) {
          expect(r.q(id), greaterThan(0), reason: '$why $id');
          expect(r.q(id), closeTo(b.q(id), 1e-9), reason: '$why $id');
          expect(r.from(id), from, reason: '$why $id');
        }
        expect(r.against, {'CV'}, reason: why);
        expect(r.moverAgainst, isEmpty, reason: why);
        expect(r.amb,
            cv == 'amb' ? {'CV': CheckValveAmbiguity.supplyLeg} : isEmpty,
            reason: why);
      }
    }
  });

  /// The Round-27 hotel: heater H, the discharge H -> CVd -> M (hm1 / hm2;
  /// [cvd] 'drawn' H -> CVd -> M, 'amb' both pipes out of CVd, 'plain' a bare
  /// node), two supply risers of 4 floors (a 2-UBAP fixture per floor), each
  /// riser top down a return riser to RJ, then RJ -> Pr -> H: a VALVELESS
  /// circulator ([pump] 'toward' drawn RJ -> Pr -> H, 'away' H -> Pr -> RJ,
  /// 'plain' a bare node, 'none' no return at all). Pr sits on the straight
  /// RJ - H line, so the plain return has the same length.
  Network hotel({String cvd = 'amb', String pump = 'toward'}) {
    final nodes = <NetNode>[
      _n('H', 0, 0, role: NodeRole.plant),
      _n('M', 50, 0),
      _n('CVd', 25, 0, c: cvd == 'plain' ? null : NodeComponent.checkValve),
    ];
    final edges = <NetEdge>[
      _e('hm1', 'H', 'CVd'),
      if (cvd == 'amb') _e('hm2', 'CVd', 'M') else _e('hm2', 'CVd', 'M'),
    ];
    if (cvd == 'amb') {
      edges[0] = _e('hm1', 'CVd', 'H');
    }
    for (var r = 0; r < 2; r++) {
      final x = 100.0 + 200 * r;
      for (var f = 0; f < 4; f++) {
        nodes
          ..add(_n('S${r}_$f', x, 0, floor: f))
          ..add(_n('fx${r}_$f', x + 40, 0, floor: f, role: NodeRole.fixture));
        edges.add(_e('b${r}_$f', 'S${r}_$f', 'fx${r}_$f'));
        edges.add(f == 0
            ? _e('m$r', 'M', 'S${r}_0')
            : _e('s${r}_$f', 'S${r}_${f - 1}', 'S${r}_$f', k: EdgeKind.riser));
      }
    }
    if (pump != 'none') {
      nodes
        ..add(_n('RJ', 30, 40))
        ..add(_n('Pr', 15, 20,
            role: pump == 'plain' ? NodeRole.main : NodeRole.plant,
            c: pump == 'plain' ? null : NodeComponent.pump));
      for (var r = 0; r < 2; r++) {
        final x = 100.0 + 200 * r;
        for (var f = 0; f < 4; f++) {
          nodes.add(_n('R${r}_$f', x + 20, 0, floor: f));
        }
        edges.add(_e('top$r', 'S${r}_3', 'R${r}_3'));
        for (var f = 3; f >= 1; f--) {
          edges.add(
              _e('r${r}_$f', 'R${r}_$f', 'R${r}_${f - 1}', k: EdgeKind.riser));
        }
        edges.add(_e('rj$r', 'R${r}_0', 'RJ'));
      }
      if (pump == 'away') {
        edges
          ..add(_e('hp', 'H', 'Pr'))
          ..add(_e('pj', 'Pr', 'RJ'));
      } else {
        edges
          ..add(_e('pj', 'RJ', 'Pr'))
          ..add(_e('hp', 'Pr', 'H'));
      }
    }
    return Network(nodes: nodes, edges: edges);
  }

  test(
      'P-A: an AMBIGUOUS heater discharge CVd + a VALVELESS circulator '
      'return drawn RJ -> Pr -> H — the circulator makes its root chain a '
      'RETURN, so CVd is THE discharge (a feed, never closed): hm1 = '
      'curve(16) DN25, every riser main curve(8) DN20, no backwards flow '
      'through the pump, the pump named', () {
    // r7 counted the valveless circulator chain as a candidate discharge, so
    // CVd was the "lone undecided chain beside a valveless chain" and read
    // CLOSED (r5): the heater's real discharge sized at zero and the whole
    // building fed backwards through the circulator. Now CVd is a feed; the
    // ring H -> CVd -> M -> risers -> returns -> RJ -> Pr -> H balances with
    // the return leg carrying draw-off from H (against the pump), so the
    // decision-1 envelope applies: (a) the leg closed = the r4 closed return
    // (returns walked from both sides => zero draw-off, the supply a tree:
    // hm1 curve(16), each riser main curve(8)); (b) the plain ring.
    for (final cal in [false, true]) {
      final why = 'cal=$cal';
      final r = _size(hotel(), cal: cal);
      final b = _size(hotel(cvd: 'plain', pump: 'plain'), cal: cal);
      expect(r.amb, {'CVd': CheckValveAmbiguity.supplyLeg}, reason: why);
      expect(r.q('hm1'), closeTo(_curve(16), 1e-9), reason: why);
      expect(r.dn('hm1'), 25, reason: why);
      expect(r.q('hm2'), closeTo(_curve(16), 1e-9), reason: why);
      expect(r.from('hm1'), 'H', reason: why);
      for (final k in [0, 1]) {
        expect(r.q('m$k'), closeTo(_curve(8), 1e-9), reason: '$why m$k');
        expect(r.dn('m$k'), 20, reason: '$why m$k');
      }
      // (b) ran against the pump: the plain ring feeds RJ from H.
      expect(b.from('hp'), 'H', reason: why);
      for (final (id, from) in [('pj', 'RJ'), ('hp', 'Pr')]) {
        expect(r.q(id), greaterThan(0), reason: '$why $id');
        expect(r.q(id), closeTo(b.q(id), 1e-9), reason: '$why $id');
        expect(r.from(id), from, reason: '$why $id');
      }
      expect(r.moverAgainst, {'Pr'}, reason: why);
      expect(r.against, isEmpty, reason: why);
      expect(r.ring, isEmpty, reason: why);
    }
  });

  test(
      'P-L: a DRAWN heater discharge CVd + a valveless circulator toward H — '
      'hm1 curve(16) DN25, the feeds-ring advisory does NOT name CVd (the '
      'circulator chain is a return, not a second path to M)', () {
    // r7 judged CVd against the valveless return as if it were a supply
    // path: with CVd removed the heater still "reached" M up the returns, so
    // the heater's own discharge was named a backwards return.
    for (final cal in [false, true]) {
      final why = 'cal=$cal';
      final r = _size(hotel(cvd: 'drawn'), cal: cal);
      expect(r.amb, isEmpty, reason: why);
      expect(r.ring, isEmpty, reason: why);
      expect(r.q('hm1'), closeTo(_curve(16), 1e-9), reason: why);
      expect(r.dn('hm1'), 25, reason: why);
      for (final k in [0, 1]) {
        expect(r.q('m$k'), closeTo(_curve(8), 1e-9), reason: '$why m$k');
      }
      expect(r.from('pj'), 'RJ', reason: why);
      expect(r.from('hp'), 'Pr', reason: why);
      expect(r.moverAgainst, {'Pr'}, reason: why);
    }
  });

  test(
      'a valveless circulator drawn AWAY from the heater is a discharge '
      'chain: beside it an ambiguous CVd is the lone undecided chain and '
      'keeps the r5 rule (a closed return)', () {
    for (final cal in [false, true]) {
      final r = _size(hotel(pump: 'away'), cal: cal);
      expect(r.amb, {'CVd': CheckValveAmbiguity.closedReturn},
          reason: 'cal=$cal');
      expect(r.q('hm1'), 0, reason: 'cal=$cal');
      expect(r.from('hp'), 'H', reason: 'cal=$cal');
      expect(r.from('pj'), 'Pr', reason: 'cal=$cal');
    }
  });

  /// The reviewer's dual feed: T -> V1 -> J1 and T -> [bends] bare elbows ->
  /// V2 -> J2, both valves drawn AWAY from T; a ring J1 - A - B - J2 - J1
  /// with a 4-UBAP fixture off A and off B. [plain] makes both valves bare.
  Network dualFeed({int bends = 0, bool plain = false}) {
    NetEdge e(String id, String a, String b) =>
        _e(id, a, b, s: ServiceType.coldWater);
    final c = plain ? null : NodeComponent.checkValve;
    // The second leg's bends sit on the straight T - V2 line, so its length
    // never changes.
    return Network(nodes: [
      _n('T', 0, 0, role: NodeRole.plant),
      _n('V1', 20, -20, c: c),
      _n('V2', 20, 60, c: c),
      _n('J1', 40, -20),
      _n('J2', 40, 60),
      _n('A', 80, -20),
      _n('B', 80, 60),
      _n('fA', 100, -20, role: NodeRole.fixture),
      _n('fB', 100, 60, role: NodeRole.fixture),
      for (var i = 0; i < bends; i++)
        _n('K$i', 20.0 * (i + 1) / (bends + 1), 60.0 * (i + 1) / (bends + 1)),
    ], edges: [
      e('t1', 'T', 'V1'),
      e('v1', 'V1', 'J1'),
      for (var i = 0; i <= bends; i++)
        e(i == 0 ? 't2' : 't2_$i', i == 0 ? 'T' : 'K${i - 1}',
            i == bends ? 'V2' : 'K$i'),
      e('v2', 'V2', 'J2'),
      e('ja', 'J1', 'A'),
      e('ab', 'A', 'B'),
      e('bj', 'B', 'J2'),
      e('jj', 'J1', 'J2'),
      e('fa', 'A', 'fA'),
      e('fb', 'B', 'fB'),
    ]);
  }

  test(
      'rule 2 is BEND-FREE: a dual feed with 0 or 4 bare elbows on the '
      'second leg — both valves FEEDS with identical flows (exactly the '
      'plain-pipe ring), calibrated or not', () {
    // With hops, the 4-bend leg put V2's inlet neighbour 4 hops from T while
    // J2 was 3 (T - V1 - J1 - J2): V2 read a RETURN and its leg was zeroed.
    // Bend-free, V2's effective inlet neighbour is T itself (0) and J2 > 0:
    // a feed.
    for (final cal in [false, true]) {
      final flows = <int, _Run>{};
      for (final bends in [0, 4]) {
        final why = 'cal=$cal bends=$bends';
        final r = _size(dualFeed(bends: bends),
            cal: cal, service: ServiceType.coldWater, ubap: 4.0);
        final ref = _size(dualFeed(bends: bends, plain: true),
            cal: cal, service: ServiceType.coldWater, ubap: 4.0);
        for (final id in ref.s.keys) {
          expect(r.q(id), closeTo(ref.q(id), 1e-12), reason: '$why $id');
        }
        expect(r.q('v1'), greaterThan(0), reason: why);
        expect(r.q('v2'), greaterThan(0), reason: why);
        expect(r.from('v1'), 'V1', reason: why);
        expect(r.from('v2'), 'V2', reason: why);
        expect(r.q('t1') + r.q('t2'), closeTo(_curve(8), 1e-9), reason: why);
        flows[bends] = r;
      }
      for (final id in ['t1', 'v1', 't2', 'v2', 'ja', 'ab', 'bj', 'jj']) {
        expect(flows[4]!.q(id), closeTo(flows[0]!.q(id), 1e-12),
            reason: 'cal=$cal $id');
      }
      for (var i = 1; i <= 4; i++) {
        expect(flows[4]!.q('t2_$i'), closeTo(flows[0]!.q('t2'), 1e-12),
            reason: 'cal=$cal t2_$i');
      }
    }
  });

  test(
      'envelope honesty: a scenario-(a) reading never reports the advisory '
      'of a leg it does not win', () {
    // In P-A, scenario (a) closes the circulator leg (zero) and scenario (b)
    // wins every one of its pipes: the "against the pump" name is (b)'s and
    // is reported; (a) reports nothing for the leg. In the decision-1 probe
    // the same holds for the valved leg.
    final r = _size(hotel());
    expect(r.moverAgainst, {'Pr'});
    final h = _size(headerReturn());
    expect(h.against, {'CV'});
    expect(h.moverAgainst, isEmpty);
  });
}
