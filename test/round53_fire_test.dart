// Round 53 (2026-10-18) — one fire partition for the sizer, the rating and
// the panel feed; fire flow carried across services; transfer pumps rated on
// the zone they fill; a drawn hot-water return sized on its recirculation:
//
//   regression-shared-header-sizer-partitions-on-fireSystems
//   regression-cross-service-fire-suction-leg-zero-flow
//   regression-transfer-set-assumed-jockey-wired-at-default-kw
//   regression-transfer-pump-rated-class-i-flow
//   regression-stage-head-clamp-silent
//   regression-sprinkler-floor-not-system-bounded
//   regression-feed-role-partition-fireSystems
//   fire-convergence-5-transfer-pump-rated-below-its-own-discharge-flow
//   fire-convergence-5-sprinkler-trunk-feeding-hydrant-not-floored-at-
//     standpipe-flow
//   plumbing-hvac-convergence-3-drawn-hw-return-sized-at-zero-flow
//
// First principles used throughout: 1 US gpm = 3.785411784 L / 60 s, so the
// Class I most-remote standpipe 500 gpm = 31.545 L/s, the Class II hose
// station 100 gpm = 6.309 L/s and two Class I stacks 750 gpm = 47.318 L/s.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart' show headLossHazenWilliams;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart' show FireHazardClass;
import 'package:mechx_engine/sizing/fire_standpipe.dart' show StandpipeClass;
import 'package:mechx_engine/sizing/hot_water.dart' show waterSpecificHeat;
import 'package:mechx_engine/units.dart';

import 'r53_fire_fixtures.dart';

const _gpm = 3.785411784 / 60; // L/s per US gpm
const _classI = 500 * _gpm; // 31.545 L/s
const _classII = 100 * _gpm; // 6.309 L/s
const _twoStacks = 750 * _gpm; // 47.318 L/s

ProviderContainer _c(
  Network net,
  int floors, {
  double h = 3.5,
  FireHazardClass? hazard,
}) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  final p = c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < floors; i++) Floor('L$i', Length(h))]);
  p.setCalibration('s1', const ScaleCalibration(0.01));
  if (hazard != null) c.read(fireHazardProvider.notifier).set(hazard);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

double _q(ProviderContainer c, String id) =>
    c.read(sizingProvider)[id]!.flow.inLitersPerSecond;
double _dn(ProviderContainer c, String id) =>
    c.read(sizingProvider)[id]!.diameter.inMillimeters;

void main() {
  // ── regression-shared-header-sizer-partitions-on-fireSystems ───────────
  group('two pump rooms on one bare suction header', () {
    test('the hose-reel tower is sized exactly as on its own tank; the header '
        'carries the larger room (31.5 L/s), never the 750 gpm total', () {
      final shared = _c(r53TwoTowers(), 8, h: 4);
      final apart = _c(r53TwoTowers(separateTanks: true), 8, h: 4);
      // The reel tower's pump leg, risers and drops (Class II, 100 gpm).
      for (final id in [
        'sa', 'pa', 'da', for (var f = 1; f < 8; f++) 'a$f', //
        for (var f = 0; f < 8; f++) 'hr$f',
      ]) {
        expect(_dn(shared, id), _dn(apart, id), reason: id);
        expect(_q(shared, id), closeTo(_q(apart, id), 1e-9), reason: id);
      }
      expect(_q(shared, 'a3'), closeTo(_classII, 0.01));
      // The box tower: Class I, one stack.
      for (final id in ['sb', 'pb', 'db', 'b3', 'b7']) {
        expect(_q(shared, id), closeTo(_classI, 0.01), reason: id);
      }
      // The header: the LARGER room, both rooms never running together.
      expect(_q(shared, 'gs'), closeTo(_classI, 0.01));
      expect(_q(shared, 'gs'), lessThan(_twoStacks - 1));
      // The pump ratings read the same sizes: identical on both drawings.
      final a = shared
          .read(fireSystemBasesProvider)
          .firstWhere((b) => b.pumpIds.contains('FPA'));
      final b = apart
          .read(fireSystemBasesProvider)
          .firstWhere((b) => b.pumpIds.contains('FPA'));
      expect(a.standpipeClass, StandpipeClass.classII);
      expect(a.head.meters, closeTo(b.head.meters, 1e-9));
      expect(a.flow.inLitersPerSecond, closeTo(_classII, 0.01));
    });
  });

  // ── regression-cross-service-fire-suction-leg-zero-flow ────────────────
  group('a shared suction header drawn on the other fire service', () {
    for (final header in [ServiceType.fireSprinkler, ServiceType.fireHydrant]) {
      test('header + legs drawn as ${header.name}: each suction leg carries '
          'its room\'s rated flow and the header the larger', () {
        final c =
            _c(r53Cross(header), 6, h: 4, hazard: FireHazardClass.ordinaryHazard2);
        final bases = c.read(fireSystemBasesProvider);
        final fph = bases.firstWhere((b) => b.pumpIds.contains('FPH'));
        final fps = bases.firstWhere((b) => b.pumpIds.contains('FPS'));
        // FPH's suction leg carries FPH's rated flow (never 0 L/s / DN25).
        expect(_q(c, 'sh'), closeTo(fph.flow.inLitersPerSecond, 1e-6));
        expect(_q(c, 'sh'), closeTo(_classI, 0.01));
        // FPS's suction leg carries the remote-area demand FPS is rated on.
        expect(_q(c, 'ss'), closeTo(fps.flow.inLitersPerSecond, 1e-6));
        expect(_q(c, 'ss'), greaterThan(0));
        // The header carries the larger of the two rooms.
        expect(
            _q(c, 'gs'),
            closeTo(
                math.max(fph.flow.inLitersPerSecond,
                    fps.flow.inLitersPerSecond),
                1e-6));
        // FPH's discharge (hydrant only) never takes the sprinkler floor of
        // the other pump room (regression-sprinkler-floor-not-system-
        // bounded): it carries its own standpipe flow.
        expect(_q(c, 'ph'), closeTo(_classI, 0.01));
        // No reducer against the flow: a pipe is never smaller than the
        // pump leg it feeds.
        expect(_dn(c, 'gs'), greaterThanOrEqualTo(_dn(c, 'sh')));
        expect(_dn(c, 'sh'), greaterThanOrEqualTo(_dn(c, 'ph')));
      });
    }
  });

  // ── fire-convergence-5-sprinkler-trunk-feeding-hydrant ─────────────────
  test('a sprinkler-drawn supply main feeding a hydrant branch carries the '
      'standpipe flow: no DN65 -> DN100 reducer against the flow', () {
    final c = _c(r53Warehouse(), 1, h: 9, hazard: FireHazardClass.ordinaryHazard2);
    for (final id in ['ra', 'ab', 'bm']) {
      expect(_q(c, id), closeTo(_classI, 0.01), reason: id);
      expect(_dn(c, id), greaterThanOrEqualTo(_dn(c, 'mh')), reason: id);
    }
    // The sprinkler branch keeps the remote-area cap.
    final remote =
        c.read(sprinklerRemoteAreaProvider).remoteAreaDemand.inLitersPerSecond;
    expect(_q(c, 's1'), closeTo(remote, 1e-6));
    // The booster is rated on the flow its own pipe now carries.
    final b = c.read(fireSystemBasesProvider).single;
    expect(b.flow.inLitersPerSecond, closeTo(_q(c, 'bm'), 1e-6));
    // ... at a velocity inside the 6 m/s fire cap.
    expect(c.read(sizingProvider)['bm']!.velocity.metersPerSecond,
        lessThanOrEqualTo(6.0 + 1e-9));
  });

  // ── transfer pumps ─────────────────────────────────────────────────────
  group('a transfer pump is rated on the zone it fills', () {
    test('a hose-reel zone (Class II): the transfer pump and its pipe carry '
        '100 gpm, never the Class I 31.5 L/s', () {
      final c = _c(r53Transfer(reels: true, pumps: 1), 20, h: 3);
      final bases = c.read(fireSystemBasesProvider);
      final tp = bases.firstWhere((b) => b.transfer);
      final fp2 = bases.firstWhere((b) => b.pumpIds.contains('FP2'));
      expect(fp2.flow.inLitersPerSecond, closeTo(_classII, 0.01));
      expect(tp.flow.inLitersPerSecond, closeTo(fp2.flow.inLitersPerSecond, 1e-9));
      for (final id in ['g', 't1', 'r', 'a']) {
        expect(_q(c, id), closeTo(_classII, 0.01), reason: id);
      }
      // The transfer riser is a 100 gpm line (Class II floor DN50), never a
      // DN100 Class I standpipe.
      expect(_dn(c, 'r'), lessThan(100));
      // The motor follows the 6.3 L/s duty: well below the 22 kW frame the
      // Class I flow selected.
      expect(tp.duty!.selectedMotor.watts, lessThan(22000));
    });

    test('a two-stack Class I zone: the transfer pump is rated on the 750 gpm '
        'its own pipe carries and the pump it refills draws', () {
      final c = _c(r53Transfer(pumps: 1, stacks: 2, top: 30, tt: 15), 30);
      final bases = c.read(fireSystemBasesProvider);
      final tp = bases.firstWhere((b) => b.transfer);
      final fp2 = bases.firstWhere((b) => b.pumpIds.contains('FP2'));
      expect(fp2.flow.inLitersPerSecond, closeTo(_twoStacks, 0.01));
      expect(tp.flow.inLitersPerSecond, closeTo(_twoStacks, 0.01));
      expect(_q(c, 'r'), closeTo(tp.flow.inLitersPerSecond, 1e-6));
      // The panel feed wires the pump at its own basis motor.
      final duty = c.read(equipmentNodeDutiesProvider)['TP1']!;
      expect(duty.motor.watts, tp.duty!.selectedMotor.watts);
    });

    test('three identical transfer pumps: duty + two standbys at the transfer '
        'duty — never an assumed jockey wired at 1.5 kW', () {
      final c = _c(r53Transfer(), 20, h: 3);
      final bind = c.read(mepDutyBindingProvider);
      expect(bind.fireJockeyPumpNodeIds, isEmpty);
      expect(bind.fireAssumedJockeyPumpNodeIds, isEmpty);
      expect(bind.fireStandbyPumpNodeIds, {'TP2', 'TP3'});
      final tp = c.read(fireSystemBasesProvider).firstWhere((b) => b.transfer);
      final duties = c.read(equipmentNodeDutiesProvider);
      for (final id in ['TP1', 'TP2', 'TP3']) {
        expect(duties[id]!.motor.watts, tp.duty!.selectedMotor.watts,
            reason: id);
      }
      // Every leg mirrors the duty leg (no 1 % jockey leg).
      for (final id in ['s1', 's2', 's3', 't1', 't2', 't3']) {
        expect(_q(c, id), closeTo(tp.flow.inLitersPerSecond, 1e-6), reason: id);
      }
      // regression-feed-role-partition-fireSystems: every jockey the feed
      // designates has a basis jockey (here: the FP2 zone has a single pump).
      for (final id in bind.fireJockeyPumpNodeIds) {
        final b = c.read(firePumpBasisByNodeProvider)[id];
        expect(b?.jockey, isNotNull);
      }
    });
  });

  // ── regression-stage-head-clamp-silent ─────────────────────────────────
  test('a series stage raised to the 5 m minimum is named (judge-only); the '
      'pump heads are unchanged', () {
    final c = _c(r53StageClamp(), 19);
    final b = c.read(fireSystemBasesProvider).single;
    final p2 = b.stages.firstWhere((s) => s.pumpIds.contains('P2'));
    final p1 = b.stages.firstWhere((s) => s.pumpIds.contains('P1'));
    expect(p2.head.meters, kMinFireStageHeadM);
    // Its own derivation: the 3.5 m storey lift from the P2 floor to L18.
    expect(p2.clampedFromM, closeTo(3.5, 1e-9));
    expect(p1.clampedFromM, isNull);
    expect(p1.head.meters + p2.head.meters,
        closeTo(b.head.meters + (kMinFireStageHeadM - 3.5), 1e-9));
    final issues = c.read(designIssuesProvider);
    final hit = issues.where((i) => i.kind == 'fire-stage-head-clamped:P2');
    expect(hit, hasLength(1));
    expect(hit.single.severity, IssueSeverity.info);
    expect(hit.single.locate?.nodeId, 'P2');
  });

  // ── seeded property: one partition, fire flow never reduced across a
  //    service change, shared header == separate tanks ──────────────────────
  test('seeded property: 24 random two-room drawings — every reel/box tower '
      'is sized as on its own tank, every fire pipe carries at least the '
      'other-service pipe it feeds, every jockey has a basis jockey', () {
    final rnd = math.Random(53);
    for (var trial = 0; trial < 24; trial++) {
      final floors = 3 + rnd.nextInt(6);
      final reelsA = rnd.nextBool();
      final reelsB = rnd.nextBool();
      Network build(bool separate) {
        final base = r53TwoTowers(separateTanks: separate);
        // Re-type the towers' outlets (reels / boxes) and trim floors.
        final keep = <String>{};
        final nodes = <NetNode>[];
        for (final n in base.nodes) {
          if (n.floorIndex >= floors) continue;
          var m = n;
          if (n.id.startsWith('HR')) {
            m = n.copyWith(
                component:
                    reelsA ? NodeComponent.hoseReel : NodeComponent.hydrantBox);
          } else if (n.id.startsWith('HB')) {
            m = n.copyWith(
                component:
                    reelsB ? NodeComponent.hoseReel : NodeComponent.hydrantBox);
          }
          nodes.add(m);
          keep.add(n.id);
        }
        return Network(nodes: nodes, edges: [
          for (final e in base.edges)
            if (keep.contains(e.fromId) && keep.contains(e.toId)) e,
        ]);
      }

      final shared = _c(build(false), floors, h: 4);
      final apart = _c(build(true), floors, h: 4);
      final sz = shared.read(sizingProvider);
      for (final id in sz.keys) {
        if (id == 'gs' || id == 'gs2') continue;
        final other = apart.read(sizingProvider)[id];
        if (other == null) continue;
        expect(sz[id]!.diameter.inMillimeters, other.diameter.inMillimeters,
            reason: 'trial $trial $id');
      }
      // The header carries the larger room.
      final rooms = [
        for (final b in shared.read(fireSystemBasesProvider))
          b.flow.inLitersPerSecond,
      ];
      expect(sz['gs']!.flow.inLitersPerSecond,
          closeTo(rooms.reduce(math.max), 1e-6),
          reason: 'trial $trial');
      for (final id in shared.read(mepDutyBindingProvider).fireJockeyPumpNodeIds) {
        expect(shared.read(firePumpBasisByNodeProvider)[id]?.jockey, isNotNull,
            reason: 'trial $trial $id');
      }
    }
  });

  test('seeded property: random cross-service drawings — no fire pipe '
      'carries less than an other-service fire pipe directly downstream of it',
      () {
    final rnd = math.Random(5353);
    for (var trial = 0; trial < 16; trial++) {
      final header = rnd.nextBool()
          ? ServiceType.fireSprinkler
          : ServiceType.fireHydrant;
      final base = r53Cross(header);
      // Randomly re-draw individual supply pipes on the other service.
      final flip = <String>{
        for (final id in ['gs', 'sh', 'ss', 'ph', 'dq', 'ps', 'dr'])
          if (rnd.nextInt(3) == 0) id,
      };
      ServiceType other(ServiceType s) => s == ServiceType.fireSprinkler
          ? ServiceType.fireHydrant
          : ServiceType.fireSprinkler;
      final net = Network(nodes: base.nodes, edges: [
        for (final e in base.edges)
          flip.contains(e.id) ? e.copyWith(service: other(e.service)) : e,
      ]);
      final c = _c(net, 6, h: 4, hazard: FireHazardClass.ordinaryHazard2);
      final sz = c.read(sizingProvider);
      for (final e in net.edges) {
        final s = sz[e.id];
        if (s == null || s.flowFromId == null) continue;
        final down = s.flowFromId == e.fromId ? e.toId : e.fromId;
        final node = net.nodeById(down)!;
        if (node.component == NodeComponent.groundTank) continue;
        for (final x in net.edgesAt(down)) {
          if (x.id == e.id || x.service == e.service) continue;
          final sx = sz[x.id];
          if (sx == null || sx.flowFromId != down) continue;
          expect(s.flow.inLitersPerSecond,
              greaterThanOrEqualTo(sx.flow.inLitersPerSecond - 1e-9),
              reason: 'trial $trial ${e.id} -> ${x.id} flipped $flip');
        }
      }
    }
  });

  // ── plumbing-hvac-convergence-3-drawn-hw-return-sized-at-zero-flow ─────
  test('a drawn hot-water return is sized on its share of the recirculation '
      'flow, never DN15 at zero; the circulator head reads those bores', () {
    final c = _c(r53HotelReturn(), 7, h: 4);
    final sys = c.read(hotWaterRecircSystemsProvider).single;
    expect(sys.drawnReturn, isTrue);
    // Q = heat loss / (rho c dT), heat loss 25 W per metre of circulated pipe.
    final loop = hotWaterRecircLoops(
      c.read(sizingNetworkProvider),
      c.read(sizingProvider),
      lengthOf: (e) => edgeLengthFor(c, e),
    ).single;
    final dT = c.read(hotWaterDeltaTProvider);
    final q = 25 * loop.circulatedLengthM / (1000 * waterSpecificHeat * dT);
    expect(sys.design.recircFlow.cubicMetersPerSecond, closeTo(q, 1e-12));
    // The common return main carries the whole recirculation flow, each
    // riser's return its share, every return pipe >= DN20 (the bore the
    // assumed return is modelled at) and inside the 2 m/s supply cap.
    final sz = c.read(sizingProvider);
    expect(sz['qm0']!.flow.cubicMetersPerSecond, closeTo(q, 1e-12));
    expect(sz['ph']!.flow.cubicMetersPerSecond, closeTo(q, 1e-12));
    for (final id in [
      for (var r = 0; r < 4; r++) ...['top$r', 'qb$r', 'qm$r', 'qr$r-3'],
      'rj', 'cv', 'ph',
    ]) {
      final s = sz[id]!;
      expect(s.flow.cubicMetersPerSecond,
          closeTo(q * loop.loopEdgeShares[id]!, 1e-12),
          reason: id);
      expect(s.diameter.inMillimeters, greaterThanOrEqualTo(20), reason: id);
      expect(s.velocity.metersPerSecond, lessThanOrEqualTo(2.0 + 1e-9),
          reason: id);
    }
    // The pumped head is the friction round the index loop at those bores:
    // strictly below the same loop through DN15 at the full share.
    var dn15 = 0.0;
    for (final seg in loop.indexPath) {
      dn15 += headLossHazenWilliams(
        flow: FlowRate(q),
        length: seg.length,
        diameter: Diameter.mm(15),
        hazenWilliamsC: 150,
      ).meters;
    }
    expect(sys.design.loopHead.meters, lessThan(dn15));
  });
}

double edgeLengthFor(ProviderContainer c, NetEdge e) {
  final project = c.read(projectControllerProvider);
  return edgeLength(
    e,
    c.read(sizingNetworkProvider),
    calibrationBySheet: project.calibrations,
    building: project.building,
    mounting: project.mounting,
  ).meters;
}
