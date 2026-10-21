// Round 51 — fire pumps rated on their OWN system and stage:
//   regression-independent-same-floor-pumps-take-combined-duty
//   fire-convergence-3-shared-tank-merges-independent-sprinkler-and-hydrant-
//     pumps-into-one-rating
//   regression-same-floor-series-booster-full-head
//   regression-class-i-combined-riser-not-floored-at-sprinkler-demand
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart' show FireHazardClass;
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart'
    show sprinklerPumpRatedPoint;
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(
  String id,
  double x, {
  int floor = 0,
  double y = 0,
  NodeRole role = NodeRole.main,
  NodeComponent? c,
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: y,
  floorIndex: floor,
  role: role,
  component: c,
);

NetEdge _e(
  String id,
  String a,
  String b, {
  ServiceType s = ServiceType.fireHydrant,
  EdgeKind k = EdgeKind.run,
}) => NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

ProviderContainer _container(
  Network net,
  int floors, {
  double h = 3.5,
  bool calibrated = true,
}) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  final p = c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < floors; i++) Floor('L$i', Length(h))]);
  if (calibrated) p.setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

const _sp = ServiceType.fireSprinkler;

/// GT -> FPH -> DH -> hydrant stack (a box per floor) and GT -> FPS -> DS ->
/// sprinkler riser ([heads] per floor), [floors] storeys; the sprinkler pump
/// room on [fpsFloor].
Network _sharedTank({required int floors, int heads = 1, int fpsFloor = 0}) =>
    Network(
      nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('FPH', 100, role: NodeRole.plant, c: NodeComponent.pump),
        _n('DH', 200),
        _n(
          'FPS',
          100,
          y: 300,
          floor: fpsFloor,
          role: NodeRole.plant,
          c: NodeComponent.pump,
        ),
        _n('DS', 200, y: 300, floor: fpsFloor),
        for (var f = 0; f < floors; f++) ...[
          _n('Q$f', 900, floor: f),
          _n(
            'HB$f',
            1000,
            floor: f,
            role: NodeRole.fixture,
            c: NodeComponent.hydrantBox,
          ),
          _n('R$f', 1500, y: 300, floor: f),
          for (var k = 1; k <= heads; k++)
            _n(
              'SH$f-$k',
              1500 + 300.0 * k,
              y: 300,
              floor: f,
              role: NodeRole.fixture,
              c: NodeComponent.sprinklerHead,
            ),
        ],
      ],
      edges: [
        _e('gh', 'GT', 'FPH'),
        _e('ph', 'FPH', 'DH'),
        _e('dq', 'DH', 'Q0'),
        _e(
          'gs',
          'GT',
          'FPS',
          s: _sp,
          k: fpsFloor == 0 ? EdgeKind.run : EdgeKind.riser,
        ),
        _e('ps', 'FPS', 'DS', s: _sp),
        _e('dr', 'DS', 'R$fpsFloor', s: _sp),
        for (var f = 0; f < floors; f++) ...[
          if (f > 0) _e('q$f', 'Q${f - 1}', 'Q$f', k: EdgeKind.riser),
          _e('hb$f', 'Q$f', 'HB$f'),
          if (f > 0) _e('r$f', 'R${f - 1}', 'R$f', s: _sp, k: EdgeKind.riser),
          for (var k = 1; k <= heads; k++)
            _e('sh$f-$k', k == 1 ? 'R$f' : 'SH$f-${k - 1}', 'SH$f-$k', s: _sp),
        ],
      ],
    );

void main() {
  group('a storage tank is a fire-system boundary', () {
    test('fireSystems: two pumps off one tank are two systems, the tank in '
        'both', () {
      final sys = fireSystems(_sharedTank(floors: 3));
      expect(sys, hasLength(2));
      for (final s in sys) {
        expect(s.nodeIds, contains('GT'));
      }
      final hyd = sys.singleWhere((s) => s.hasHydrant);
      final spr = sys.singleWhere((s) => s.hasSprinkler);
      expect(hyd.hasSprinkler, isFalse);
      expect(spr.hasHydrant, isFalse);
      expect(hyd.nodeIds.contains('FPS'), isFalse);
      expect(spr.nodeIds.contains('FPH'), isFalse);
      // A tank on ONE pipe changes nothing: every edge still lands in exactly
      // one system.
      expect(
        sys.fold<int>(0, (a, s) => a + s.edges.length),
        _sharedTank(floors: 3).edges.length,
      );
    });

    test('r50 r2 fixture (3 x 3.5 m): FPS rated on its own sprinkler point, '
        'FPH keeps the 500 gpm standpipe point', () {
      final c = _container(_sharedTank(floors: 3), 3);
      final bases = c.read(fireSystemBasesProvider);
      expect(bases, hasLength(2));
      final hyd = bases.singleWhere((b) => !b.sprinklerOnly);
      final spr = bases.singleWhere((b) => b.sprinklerOnly);
      expect(hyd.pumpIds, ['FPH']);
      expect(spr.pumpIds, ['FPS']);
      final remote = c.read(sprinklerRemoteAreaProvider);
      // The sprinkler pump: remote-area flow at the sprinkler head (lift +
      // remote-head pressure + friction) — its own point.
      expect(
        spr.flow.inLitersPerSecond,
        closeTo(remote.remoteAreaDemand.inLitersPerSecond, 1e-9),
      );
      final p = sprinklerPumpRatedPoint(
        remote: remote,
        staticLiftM: spr.staticLiftM,
        indexPathFriction: spr.indexFrictionM == null
            ? null
            : Head(spr.indexFrictionM!),
      );
      expect(spr.head.meters, closeTo(p.head.meters, 1e-9));
      final expectDuty = firePumpDuty(
        ratedFlow: p.flow,
        ratedHead: p.head,
        rating: checkFirePumpRating(ratedFlow: p.flow, ratedHead: p.head),
      );
      final duties = c.read(equipmentNodeDutiesProvider);
      expect(duties['FPS']!.motor.watts, expectDuty.selectedMotor.watts);
      // A small machine (≈ 6 L/s at ≈ 35 m), never the 55 kW standpipe frame.
      expect(duties['FPS']!.motor.watts, lessThan(15000));
      // The hydrant pump: unchanged 500 gpm (31.545 L/s) basis, 55 kW.
      expect(
        hyd.flow.inLitersPerSecond,
        closeTo(standpipeFlow(1).inLitersPerSecond, 1e-9),
      );
      expect(duties['FPH']!.motor.watts, 55000);
    });

    test('6 x 4 m OH2 (4 heads/floor): no false over-pressure, jockeys on '
        'their own systems', () {
      final c = _container(_sharedTank(floors: 6, heads: 4), 6, h: 4);
      c.read(fireHazardProvider.notifier).set(FireHazardClass.ordinaryHazard2);
      final bases = c.read(fireSystemBasesProvider);
      final hyd = bases.singleWhere((b) => !b.sprinklerOnly);
      final spr = bases.singleWhere((b) => b.sprinklerOnly);
      // Hydrant: lift to the L5 outlet (20 + 1.2 m) + 69 kPa-class residual
      // head + friction — the standpipe design of its own one stack.
      final st = designStandpipe(
        risers: 1,
        buildingHeight: Length(hyd.staticLiftM),
        indexPathFriction: hyd.indexFrictionM == null
            ? null
            : Head(hyd.indexFrictionM!),
      );
      expect(hyd.staticLiftM, closeTo(5 * 4 + kHoseOutletHeightM, 1e-9));
      expect(hyd.head.meters, closeTo(st.pumpHead.meters, 1e-9));
      // The sprinkler pump churns at its own head: 1.4 x its rated head.
      final chk = c.read(sprinklerPumpCheckProvider);
      expect(chk, isNotNull);
      expect(chk!.headShort, isFalse);
      expect(chk.flowShort, isFalse);
      expect(spr.head.meters, lessThan(hyd.head.meters));
      expect(c.read(fireOverPressureProvider), isEmpty);
      // The sprinkler system's jockey is 1 % of ITS rated flow.
      expect(spr.jockey, isNotNull);
      expect(
        spr.rating.jockeyFlow.cubicMetersPerSecond,
        closeTo(spr.flow.cubicMetersPerSecond * 0.01, 1e-12),
      );
      final duties = c.read(equipmentNodeDutiesProvider);
      expect(duties['FPS']!.motor.watts, spr.duty!.selectedMotor.watts);
      expect(duties['FPH']!.motor.watts, hyd.duty!.selectedMotor.watts);
    });

    test('worse variant: the sprinkler pump room on L1 never under-rates the '
        'hydrant pump (no phantom series stages)', () {
      final base = _container(_sharedTank(floors: 6, heads: 4), 6, h: 4);
      final l1 = _container(
        _sharedTank(floors: 6, heads: 4, fpsFloor: 1),
        6,
        h: 4,
      );
      for (final c in [base, l1]) {
        c
            .read(fireHazardProvider.notifier)
            .set(FireHazardClass.ordinaryHazard2);
      }
      final hyd0 = base
          .read(fireSystemBasesProvider)
          .singleWhere((b) => !b.sprinklerOnly);
      final hyd1 = l1
          .read(fireSystemBasesProvider)
          .singleWhere((b) => !b.sprinklerOnly);
      expect(hyd1.stageHeads, isEmpty);
      expect(hyd1.head.meters, closeTo(hyd0.head.meters, 1e-9));
      expect(
        l1.read(equipmentNodeDutiesProvider)['FPH']!.motor.watts,
        base.read(equipmentNodeDutiesProvider)['FPH']!.motor.watts,
      );
      // The L1 sprinkler pump lifts from ITS floor: rated on the remote heads
      // it serves, and the judge agrees.
      final spr1 = l1
          .read(fireSystemBasesProvider)
          .singleWhere((b) => b.sprinklerOnly);
      expect(spr1.stageHeads, isEmpty);
      expect(l1.read(sprinklerPumpCheckProvider)!.headShort, isFalse);
    });
  });

  group('series booster stages are topological, not by floor', () {
    // 6 x 3.5 m: GT -> P1 -> D1 -> low riser (boxes L0-L2); D1 -> P2 -> D2 ->
    // upper riser (boxes L3-L5). [p2Floor] = 0 (one ground pump room) or 3.
    Network series(int p2Floor) => Network(
      nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('P1', 100, role: NodeRole.plant, c: NodeComponent.pump),
        _n('D1', 200),
        _n(
          'P2',
          300,
          floor: p2Floor,
          role: NodeRole.plant,
          c: NodeComponent.pump,
        ),
        _n('D2', 400, floor: p2Floor),
        for (var f = 0; f < 6; f++) ...[
          _n('L$f', f < 3 ? 900 : 1900, floor: f),
          _n(
            'HB$f',
            f < 3 ? 1000 : 2000,
            floor: f,
            role: NodeRole.fixture,
            c: NodeComponent.hydrantBox,
          ),
        ],
      ],
      edges: [
        _e('g1', 'GT', 'P1'),
        _e('p1', 'P1', 'D1'),
        _e('dl', 'D1', 'L0'),
        _e('d1p2', 'D1', 'P2', k: p2Floor == 0 ? EdgeKind.run : EdgeKind.riser),
        _e('p2', 'P2', 'D2'),
        // The upper riser starts at L3, reached from D2 by a riser.
        _e('du', 'D2', 'L3', k: p2Floor == 3 ? EdgeKind.run : EdgeKind.riser),
        for (var f = 0; f < 6; f++) ...[
          if (f > 0 && f != 3) _e('q$f', 'L${f - 1}', 'L$f', k: EdgeKind.riser),
          _e('hb$f', 'L$f', 'HB$f'),
        ],
      ],
    );

    test('engine: P2 follows P1 whatever floor P2 sits on', () {
      for (final f in [0, 3]) {
        final net = series(f);
        final sys = fireSystems(net).single;
        final sets = fireParallelPumpSets(net, sys, ['P1', 'P2']);
        final st = fireSeriesPumpStages(net, sys, sets)!;
        expect(st, hasLength(2), reason: 'P2 on L$f');
        expect(st[0].pumpIds, ['P1']);
        expect(st[0].upstream, isNull);
        expect(st[1].pumpIds, ['P2']);
        expect(st[1].upstream, 0);
        // P1's own zone is the low riser; P2's the upper one.
        expect(st[0].discharge.nodeIds, containsAll(['HB0', 'HB1', 'HB2']));
        expect(st[0].discharge.nodeIds.contains('HB3'), isFalse);
        expect(st[1].discharge.nodeIds, containsAll(['HB3', 'HB4', 'HB5']));
      }
    });

    for (final calibrated in [false, true]) {
      test(
        'P1 rated on its own zone, P2 the rest (calibrated: $calibrated)',
        () {
          final c = _container(series(0), 6, calibrated: calibrated);
          final b = c.read(fireSystemBasesProvider).single;
          expect(b.stageHeads.keys, unorderedEquals(['P1', 'P2']));
          // P1: the standpipe point of its own zone (L2 outlet: 7 + 1.2 m) at
          // the system's friction term.
          final low = designStandpipe(
            risers: b.standpipeRisers,
            buildingHeight: const Length(2 * 3.5 + kHoseOutletHeightM),
            indexPathFriction: b.indexFrictionM == null
                ? null
                : Head(b.indexFrictionM!),
          );
          expect(
            b.stageHeads['P1']!.meters,
            closeTo(low.pumpHead.meters, 1e-9),
          );
          // P2: the rest of the system head (the two stages sum to it).
          expect(
            b.stageHeads['P1']!.meters + b.stageHeads['P2']!.meters,
            closeTo(b.head.meters, 1e-9),
          );
          expect(
            b.stageHeads['P2']!.meters,
            closeTo(3 * 3.5, 1e-6),
            reason: 'the upper zone adds exactly its 3 storeys of lift',
          );
          final duties = c.read(equipmentNodeDutiesProvider);
          expect(
            duties['P1']!.motor.watts,
            b.stageDuties['P1']!.selectedMotor.watts,
          );
          expect(
            duties['P2']!.motor.watts,
            b.stageDuties['P2']!.selectedMotor.watts,
          );
          expect(
            duties['P2']!.motor.watts,
            lessThan(duties['P1']!.motor.watts),
          );
        },
      );
    }

    test('uncalibrated: the ground pump room and the L3 booster rate '
        'identically', () {
      final a = _container(
        series(0),
        6,
        calibrated: false,
      ).read(fireSystemBasesProvider).single;
      final b = _container(
        series(3),
        6,
        calibrated: false,
      ).read(fireSystemBasesProvider).single;
      for (final id in ['P1', 'P2']) {
        expect(
          a.stageHeads[id]!.meters,
          closeTo(b.stageHeads[id]!.meters, 1e-9),
          reason: id,
        );
        expect(
          a.stageDuties[id]!.selectedMotor.watts,
          b.stageDuties[id]!.selectedMotor.watts,
        );
      }
    });
  });

  test('a Class I combined riser feeding extra-hazard sprinklers carries the '
      'remote-area demand the pump is rated on', () {
    const h = ServiceType.fireHydrant;
    final net = Network(
      nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('P', 50, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 0; f < 4; f++) ...[
          _n('R$f', 150, floor: f),
          _n(
            'HB$f',
            250,
            floor: f,
            role: NodeRole.fixture,
            c: NodeComponent.hydrantBox,
          ),
          for (var k = 1; k <= 6; k++)
            _n(
              'H$f-$k',
              150 + 300.0 * k,
              floor: f,
              y: 300,
              role: NodeRole.fixture,
              c: NodeComponent.sprinklerHead,
            ),
        ],
      ],
      edges: [
        _e('g', 'GT', 'P', s: h),
        _e('p', 'P', 'R0', s: h),
        for (var f = 0; f < 4; f++) ...[
          if (f > 0) _e('r$f', 'R${f - 1}', 'R$f', s: h, k: EdgeKind.riser),
          _e('hb$f', 'R$f', 'HB$f', s: h),
          for (var k = 1; k <= 6; k++)
            _e('b$f-$k', k == 1 ? 'R$f' : 'H$f-${k - 1}', 'H$f-$k', s: _sp),
        ],
      ],
    );
    final c = _container(net, 4, h: 4);
    c.read(fireHazardProvider.notifier).set(FireHazardClass.extraHazard);
    final demand = c
        .read(sprinklerRemoteAreaProvider)
        .remoteAreaDemand
        .inLitersPerSecond;
    // Extra hazard: above the one-stack Class I 500 gpm (31.545 L/s).
    expect(demand, greaterThan(standpipeFlow(1).inLitersPerSecond));
    final b = c.read(fireSystemBasesProvider).single;
    expect(b.flow.inLitersPerSecond, closeTo(demand, 1e-9));
    final sz = c.read(sizingProvider);
    for (final id in ['p', 'r1', 'r2', 'r3']) {
      expect(
        sz[id]!.flow.inLitersPerSecond,
        closeTo(b.flow.inLitersPerSecond, 1e-6),
        reason: id,
      );
      expect(
        sz[id]!.velocity.metersPerSecond,
        lessThanOrEqualTo(kMaxFireVelocityMps + 1e-9),
        reason: id,
      );
    }
    // A hose-only sub-branch stays below the riser flow.
    expect(sz['hb0']!.flow.inLitersPerSecond, lessThan(demand));
  });

  // Round 51 r2 — `parallelFirePumpRoles` groups pumps by FULL connectivity
  // (through the tank) but the shared tank splits them into two systems: the
  // group's duty must be resolved per system, whichever pump is listed first
  // and whichever has the larger bore (it used to throw `No element`).
  group('shared tank: per-system duty pumps, any node order', () {
    Network sprinklerFirst(
      Network net, {
      NodeComponent? outlet,
      String first = 'FPS',
    }) => Network(
      nodes: [
        for (final n in net.nodes)
          if (n.id == first) n,
        for (final n in net.nodes)
          if (n.id != first)
            outlet != null && n.component == NodeComponent.hydrantBox
                ? n.copyWith(component: outlet)
                : n,
      ],
      edges: net.edges,
    );

    void expectBothDuty(ProviderContainer c) {
      expect(() => c.read(sizingProvider), returnsNormally);
      final bind = c.read(mepDutyBindingProvider);
      expect(bind.fireStandbyPumpNodeIds, isEmpty);
      expect(bind.fireJockeyPumpNodeIds, isEmpty);
      expect(() => c.read(mepAutoFeedCircuitsProvider), returnsNormally);
      final loads = c.read(placedEquipmentLoadsProvider);
      double dfOf(String id) =>
          loads.firstWhere((l) => l.id.contains(id)).demandFactor ?? 1.0;
      expect(dfOf('FPS'), 1.0);
      expect(dfOf('FPH'), 1.0);
    }

    test('hydrant boxes + OH2, the sprinkler pump listed first (the '
        'larger-bore hydrant pump in the other system)', () {
      final c = _container(
        sprinklerFirst(_sharedTank(floors: 6, heads: 4)),
        6,
        h: 4,
      );
      c.read(fireHazardProvider.notifier).set(FireHazardClass.ordinaryHazard2);
      final sz = c.read(sizingProvider);
      // The pin is only meaningful when the group's larger-bore pump (its
      // overall duty) is NOT in the first-listed pump's system: here the
      // hydrant pump out-bores the first-listed sprinkler pump.
      expect(
        sz['ph']!.diameter.inMillimeters,
        greaterThan(sz['ps']!.diameter.inMillimeters),
      );
      expectBothDuty(c);
    });

    test('hose-reel (Class II) hydrant pump listed first + a larger-bore '
        'extra-hazard sprinkler pump off one tank', () {
      final c = _container(
        sprinklerFirst(
          _sharedTank(floors: 6, heads: 4),
          outlet: NodeComponent.hoseReel,
          first: 'FPH',
        ),
        6,
        h: 4,
      );
      c.read(fireHazardProvider.notifier).set(FireHazardClass.extraHazard);
      final sz = c.read(sizingProvider);
      // The hydrant pump is listed first but the extra-hazard sprinkler pump
      // carries the larger bore (the whole group's duty).
      expect(
        sz['ps']!.diameter.inMillimeters,
        greaterThan(sz['ph']!.diameter.inMillimeters),
      );
      expectBothDuty(c);
    });
  });
}
