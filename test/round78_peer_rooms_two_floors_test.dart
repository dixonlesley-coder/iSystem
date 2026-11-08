// Round 78 (2026-10-18) — fire-convergence-29-peer-pump-rooms-on-different-
// floors-rated-as-series-stages.
//
// A 2-level mall (3.5 m storeys, calibrated 0.01 m/px). Room A: ground tank
// GA -> pump PA -> XA on floor 0, a riser XA -> R0 up to the floor-1 ring.
// Room B: tank GB -> pump PB -> R2 on floor 1. A 6-node hydrant ring on
// floor 1 carries 4 pillar hydrants; an OH2 sprinkler loop is teed off R1.
//
// First principles: the two rooms each draw from their OWN tank and neither
// takes suction from the other — they are PEER rooms feeding one ring in
// parallel (the Round-70 reading), never a series chain. Each room must
// develop the whole system head itself: the yard point 38 L/s at
// 350 kPa + 15 m friction allowance + the lift from the datum (the lowest
// pump floor) to the pillar outlet (3.5 + 1.1 m). PA (the lower room)
// therefore needs at least that head; reading the rooms as stages by floor
// gave PA 3.5 m (clamped to 5 m, a 4 kW motor) and PB the remaining 50 m.
// The ratings must equal the drawing with both rooms on floor 1 (computed
// with the same datum) — no stage, no clamp. Round 79: each room is rated
// above its OWN suction tank — the floor-1 room's tank is 3.5 m above the
// datum, so its pump develops the system head less 3.5 m.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, double y, {NodeComponent? c, int floor = 1}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: floor,
      role: c?.role ?? NodeRole.main,
      component: c,
    );

Network _mall({
  required int floorA,
  required int floorB,
  Set<String> sprinklerEdges = const {},
}) {
  final nodes = <NetNode>[];
  final edges = <NetEdge>[];
  NetEdge e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
      NetEdge(
        id: id,
        fromId: a,
        toId: b,
        service: sprinklerEdges.contains(id) || id.startsWith('sp')
            ? ServiceType.fireSprinkler
            : ServiceType.fireHydrant,
        kind: k,
      );
  for (var i = 0; i < 6; i++) {
    final a = i * math.pi / 3;
    nodes.add(_n('R$i', 400 * math.cos(a), 400 * math.sin(a)));
    edges.add(e('r$i', 'R$i', 'R${(i + 1) % 6}'));
  }
  for (final i in [0, 2, 3, 5]) {
    final a = i * math.pi / 3;
    nodes.add(
      _n(
        'PH$i',
        500 * math.cos(a),
        500 * math.sin(a),
        c: NodeComponent.pillarHydrant,
      ),
    );
    edges.add(e('ph$i', 'R$i', 'PH$i'));
  }
  // An OH2 sprinkler loop teed off R1.
  nodes.add(_n('ZS', 200, 600));
  edges.add(e('spz', 'R1', 'ZS'));
  for (var k = 0; k < 12; k++) {
    nodes.add(
      _n('SP$k', 200 + 50.0 * k, 650, c: NodeComponent.sprinklerHead),
    );
    edges.add(e('sp$k', k == 0 ? 'ZS' : 'SP${k - 1}', 'SP$k'));
  }
  // Room A (into R0 at x = 400).
  nodes
    ..add(_n('GA', 800, 0, c: NodeComponent.groundTank, floor: floorA))
    ..add(_n('PA', 700, 0, c: NodeComponent.pump, floor: floorA))
    ..add(_n('XA', 600, 0, floor: floorA));
  edges
    ..add(e('ga', 'GA', 'PA'))
    ..add(e('pa', 'PA', 'XA'))
    ..add(e('xa', 'XA', 'R0', k: floorA == 1 ? EdgeKind.run : EdgeKind.riser));
  // Room B (into R2).
  nodes
    ..add(_n('GB', -400, 700, c: NodeComponent.groundTank, floor: floorB))
    ..add(_n('PB', -300, 600, c: NodeComponent.pump, floor: floorB))
    ..add(_n('XB', -250, 450, floor: floorB));
  edges
    ..add(e('gb', 'GB', 'PB'))
    ..add(e('pb', 'PB', 'XB'))
    ..add(e('xb', 'XB', 'R2', k: floorB == 1 ? EdgeKind.run : EdgeKind.riser));
  return Network(nodes: nodes, edges: edges);
}

ProviderContainer _c(Network net) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 3; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  test('engine: two peer rooms on different floors are ONE root stage', () {
    final net = _mall(floorA: 0, floorB: 1);
    final sys = fireSystems(net).single;
    final sets = fireParallelPumpSets(net, sys, ['PA', 'PB']);
    final st = fireSeriesPumpStages(net, sys, sets)!;
    expect(st, hasLength(1));
    expect(st.single.pumpIds, ['PA', 'PB']);
    expect(st.single.upstream, isNull);
    expect(splitFireSystemAtSharedSource(net, sys), hasLength(1));
  });

  test('two-floor mall: one root stage, each room above its own tank', () {
    final c = _c(_mall(floorA: 0, floorB: 1));
    final b = c.read(fireSystemBasesProvider).single;
    expect(b.pumpIds, unorderedEquals(['PA', 'PB']));
    expect(b.flow.inLitersPerSecond, closeTo(38.0, 0.01));
    expect(b.stages, isEmpty);
    // The yard point: 350 kPa (35.68 m) + 15 m + (3.5 + 1.1) m lift.
    expect(b.head.meters, closeTo(350000 / 9810 + 15 + 4.6, 0.05));
    // Round 79 (regression-roof-booster-peer-rated-with-datum-lift) — room
    // B draws from ITS OWN tank GB on floor 1, 3.5 m above the datum: PB
    // develops the system head less that rise (35.68 + 15 + 1.1 m), never
    // the floor-0 lift it never sees. PA keeps the full head.
    expect(b.stageHeads.keys, ['PB']);
    expect(b.stageHeads['PB']!.meters, closeTo(b.head.meters - 3.5, 1e-9));
    final duties = c.read(equipmentNodeDutiesProvider);
    final pa = duties['PA']!.motor.watts, pb = duties['PB']!.motor.watts;
    expect(pb, lessThanOrEqualTo(pa));
    expect(pb, greaterThanOrEqualTo(0.038 * 9810 * (b.head.meters - 3.5) / 0.7));
    // 38 L/s x 9810 x 55.28 m / 0.7 = 29.4 kW shaft => a 30 kW+ frame.
    expect(pa, greaterThanOrEqualTo(0.038 * 9810 * b.head.meters / 0.7));
    // One duty, the peer room's pump its standby.
    final bind = c.read(mepDutyBindingProvider);
    expect(bind.fireStandbyPumpNodeIds, hasLength(1));
    // Jockey (if any) on the full-system churn: 1.4 x head + 5 m.
    if (b.jockey != null) {
      expect(b.jockey!.head.meters, closeTo(1.4 * b.head.meters + 5, 0.05));
    }
    final kinds = c.read(designIssuesProvider).map((i) => i.kind);
    expect(kinds.where((k) => k.startsWith('fire-stage-head-clamped')),
        isEmpty);
  });

  test('seeded: rooms on any two floors x service flips rate every pump at '
      'the head above their own tank (== the same-floor reading)', () {
    final rnd = math.Random(7829);
    final flippable = ['ga', 'pa', 'xa', 'gb', 'pb', 'xb'];
    for (var t = 0; t < 10; t++) {
      final fa = rnd.nextInt(2), fb = rnd.nextInt(2);
      final spr = {
        for (final id in flippable)
          if (rnd.nextInt(4) == 0) id,
      };
      final c = _c(_mall(floorA: fa, floorB: fb, sprinklerEdges: spr));
      final bases = c.read(fireSystemBasesProvider);
      final withPumps = bases.where((b) => b.pumpIds.isNotEmpty).toList();
      expect(withPumps, hasLength(1), reason: 'fa=$fa fb=$fb spr=$spr');
      final b = withPumps.single;
      expect(b.stages, isEmpty, reason: 'fa=$fa fb=$fb spr=$spr');
      final datumLift = (1 - math.min(fa, fb)) * 3.5 + 1.1;
      expect(b.head.meters, closeTo(350000 / 9810 + 15 + datumLift, 0.05),
          reason: 'fa=$fa fb=$fb spr=$spr');
      // Round 79 — each room above its OWN tank: a room on the upper floor
      // (its tank 3.5 m above the datum) develops head − 3.5 m.
      final lo = math.min(fa, fb);
      for (final (id, f) in [('PA', fa), ('PB', fb)]) {
        final want = b.head.meters - (f - lo) * 3.5;
        expect(b.stageHeads[id]?.meters ?? b.head.meters, closeTo(want, 1e-9),
            reason: '$id fa=$fa fb=$fb spr=$spr');
      }
      final duties = c.read(equipmentNodeDutiesProvider);
      if (fa == fb) {
        expect(duties['PA']!.motor.watts, duties['PB']!.motor.watts,
            reason: 'fa=$fa fb=$fb spr=$spr');
      }
      // Sizes are untouched by the rating fix: the ring main stays on the
      // yard floor (>= DN150).
      final sz = c.read(sizingProvider);
      expect(sz['r0']!.diameter.inMillimeters, greaterThanOrEqualTo(150));
    }
  });
}
