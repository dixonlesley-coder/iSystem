// Round 60 (2026-10-18) — fire-convergence-12-duty-standby-fire-pump-legs-
// split-when-pump-drawn-outward.
//
// A valveless duty / standby fire-pump set S - PE - H, S - PD - H (+ a
// jockey S -> PJ -> H) is ONE parallel set whichever way each pump's two
// pipes were drawn: a pump whose pipes are both drawn OUT of it (a pump room
// drawn from each pump outward) is oriented away from the source like an
// incoherent valved pump leg (r7), so the Round-28 parallel-set rule applies
// and every leg carries the full set flow — never a Hardy–Cross split that
// sizes each leg on a fraction of the flow ONE running pump pushes.
//
// First principles: whichever pump runs alone carries the whole set flow Q
// (the duty is a parallel set, df 0 on the standby), so every pump leg needs
// d >= sqrt(4 Q / (pi x 6 m/s)) under the 6 m/s fire velocity cap — the same
// bore as the common discharge H -> system (h0), which carries Q too.
// Sprinkler warehouse: 40 heads x 1.3 L/s capped at the Extra Hazard remote
// area 43.33 L/s => d >= sqrt(4 x 0.04333 / (pi x 6)) = 0.0959 m => DN100
// (a Hardy–Cross split of ~19.5 L/s per leg gave DN65 — 13.1 m/s when one
// pump runs alone).
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's',
        floorIndex: floor,
        x: x,
        y: y,
        role: role,
        component: c);

/// GT -> S; pumps PE / PD between S and H, their four pipes drawn
/// suction-to-discharge ([outward] false) or each out of its pump ([outward]
/// true: PE->S, PE->H, PD->S, PD->H); a jockey S -> PJ -> H; H -> a 4-storey
/// hydrant stack with a box per floor, or ([sprinkler]) a 10-branch x 4-head
/// sprinkler grid.
Network _pumpRoom(
    {required bool outward,
    bool sprinkler = false,
    Set<String> flip = const {}}) {
  final svc = sprinkler ? ServiceType.fireSprinkler : ServiceType.fireHydrant;
  NetEdge e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
      NetEdge(id: id, fromId: a, toId: b, service: svc, kind: k);
  NetEdge leg(String id, String suction, String pump, String discharge,
      {required bool isSuction}) {
    final a = isSuction ? (outward ? pump : suction) : pump;
    final b = isSuction ? (outward ? suction : pump) : discharge;
    return flip.contains(id) ? e(id, b, a) : e(id, a, b);
  }

  final nodes = <NetNode>[
    _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('S', 40, 0),
    _n('PE', 100, 0, role: NodeRole.plant, c: NodeComponent.pump),
    _n('PD', 100, 40, role: NodeRole.plant, c: NodeComponent.pump),
    _n('PJ', 100, 80, role: NodeRole.plant, c: NodeComponent.pump),
    _n('H', 160, 0),
  ];
  final edges = <NetEdge>[
    e('g', 'GT', 'S'),
    leg('se', 'S', 'PE', 'H', isSuction: true),
    leg('ed', 'S', 'PE', 'H', isSuction: false),
    leg('sd', 'S', 'PD', 'H', isSuction: true),
    leg('dd', 'S', 'PD', 'H', isSuction: false),
    e('sj', 'S', 'PJ'),
    e('jh', 'PJ', 'H'),
  ];
  if (sprinkler) {
    for (var b = 0; b < 10; b++) {
      nodes.add(_n('M$b', 200.0 + 20 * b, 0));
      edges.add(e(b == 0 ? 'h0' : 'm$b', b == 0 ? 'H' : 'M${b - 1}', 'M$b'));
      for (var k = 0; k < 4; k++) {
        nodes.add(_n('K$b$k', 200.0 + 20 * b, 20.0 + 15 * k,
            role: NodeRole.fixture, c: NodeComponent.sprinklerHead));
        edges.add(e('k$b$k', k == 0 ? 'M$b' : 'K$b${k - 1}', 'K$b$k'));
      }
    }
  } else {
    for (var f = 0; f < 4; f++) {
      nodes
        ..add(_n('R$f', 300, 0, floor: f))
        ..add(_n('HB$f', 340, 0,
            floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
      edges
        ..add(e('hb$f', 'R$f', 'HB$f'))
        ..add(f == 0
            ? e('h0', 'H', 'R0')
            : e('r$f', 'R${f - 1}', 'R$f', k: EdgeKind.riser));
    }
  }
  return Network(nodes: nodes, edges: edges);
}

Map<String, EdgeSizing> _size(Network net, [Set<String>? par]) =>
    autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {
        ServiceType.fireHydrant: FlowRate(0.0063),
        ServiceType.fireSprinkler: FlowRate(0.0013),
      },
      sprinklerDemandCap: FlowRate.litersPerSecond(43.33),
      hydrantDesignFlow: FlowRate.litersPerSecond(47.32),
      parallelLegEdgeIdsOut: par,
    );

void main() {
  const legs = ['se', 'ed', 'sd', 'dd', 'sj', 'jh'];

  for (final sprinkler in [true, false]) {
    final what = sprinkler ? 'sprinkler warehouse' : 'hydrant stack';
    test('$what: the pump legs carry the full set flow drawn either way', () {
      final ref = _size(_pumpRoom(outward: false, sprinkler: sprinkler));
      final q = ref['h0']!.flow.inLitersPerSecond;
      if (sprinkler) {
        // 40 x 1.3 = 52 L/s capped at 43.33 L/s => 0.0959 m => DN100.
        expect(q, closeTo(43.33, 1e-6));
        expect(math.sqrt(4 * q / 1000 / (math.pi * 6)),
            closeTo(0.0959, 0.0005));
      } else {
        // ONE drawn stack: 500 gpm = 31.545 L/s rides the set (47.32 L/s is
        // only the cap) => 0.0818 m => DN100.
        expect(q, closeTo(500 * 3.785411784 / 60, 1e-3));
      }
      // Round 61 — the legs are the pumps' SUCTION / DISCHARGE and h0 the
      // discharge header main: NFPA 20 Table 4.28(a) for the set flow —
      // 500 gpm (hydrant) 5 in = DN125; 43.33 L/s = 687 gpm (sprinkler)
      // the 750 gpm row 6 in = DN150 (suction at 150 %: 0.065 / 0.017671
      // = 3.68 m/s <= 4.57 m/s).
      final pumpRoomMm = sprinkler ? 150 : 125;
      expect(ref['h0']!.diameter.inMillimeters, pumpRoomMm);
      final par = <String>{};
      final out =
          _size(_pumpRoom(outward: true, sprinkler: sprinkler), par);
      for (final id in legs) {
        expect(ref[id]!.flow.inLitersPerSecond, closeTo(q, 1e-9), reason: id);
        expect(out[id]!.flow.inLitersPerSecond, closeTo(q, 1e-9), reason: id);
        expect(out[id]!.diameter.inMillimeters, pumpRoomMm, reason: id);
      }
      // Two of the three legs are mirrored standbys, as in the coherent set.
      expect(par.length, 4);
    });

    // Each pump drawn forward (S -> P -> H), outward (both pipes out of P) or
    // inward (both into P). Flipping BOTH pipes of one pump draws it
    // coherently BACKWARDS — a drawn direction the sizer honours (r7), not a
    // drawing variant — so that case is not part of the property.
    test('$what seeded property: drawing each pump forward / outward / '
        'inward never changes a pump-room size, flow or flow direction', () {
      final rnd = math.Random(sprinkler ? 6004 : 6005);
      final ref = _size(_pumpRoom(outward: false, sprinkler: sprinkler));
      for (var t = 0; t < 40; t++) {
        final flip = {
          for (final pair in const [
            ['se', 'ed'],
            ['sd', 'dd'],
          ])
            ...switch (rnd.nextInt(3)) {
              0 => const <String>[],
              1 => [pair[0]], // outward
              _ => [pair[1]], // inward
            },
        };
        final s = _size(
            _pumpRoom(outward: false, sprinkler: sprinkler, flip: flip));
        for (final id in ref.keys) {
          expect(s[id]!.diameter.inMillimeters,
              ref[id]!.diameter.inMillimeters, reason: '$id trial $t $flip');
          expect(s[id]!.flow.inLitersPerSecond,
              closeTo(ref[id]!.flow.inLitersPerSecond, 1e-9),
              reason: '$id trial $t $flip');
          expect(s[id]!.flowFromId, ref[id]!.flowFromId,
              reason: '$id trial $t $flip');
        }
      }
    });
  }
}
