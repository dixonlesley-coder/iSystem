// Round 15 (2026-10-18) — the app-side pressure-solve source + pump-duty
// root-metamorphic findings:
//   picksource-tank-pump-tie   a ground tank and a same-floor pump never tie;
//                              the upfeed head is edge-order-blind;
//   picksource-fixture-source  with no plant the solve sources at the sizer's
//                              entry, never a ground-floor fixture;
//   hybrid-booster-duty        an inline booster is sized on the flow THROUGH
//                              it, in both feed strategies;
//   pdam-fill (app half)       the fill line is not source delivery.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? component,
        PlumbingFixture? fixture}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: floor,
      role: role,
      component: component,
      fixture: fixture,
    );

NetEdge _e(String id, String a, String b, {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.coldWater, kind: kind);

NetNode _wc(String id, double x, double y, int floor) => _n(id, x, y,
    floor: floor,
    role: NodeRole.fixture,
    fixture: PlumbingFixture.waterClosetFlushTank);

ProviderContainer _container(Network net, FeedStrategy feed,
    {int floors = 3}) {
  final c = ProviderContainer();
  c.read(projectControllerProvider.notifier)
    ..setFloors([
      for (var i = 0; i < floors; i++) Floor('L$i', const Length(3.5)),
    ])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(feedStrategyProvider.notifier).set(feed);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  group('picksource-tank-pump-tie — the upfeed head is edge-order-blind', () {
    // GT (x = -2000 px ⇒ 21 m of suction main at 0.01 m/px) → P → H → riser
    // over 3 floors, 2 flush-tank WCs per floor. GT and P both sit on the
    // floor-0 surface (tie on elevation); the GT (supply rank 0) is the
    // source the sizer roots at, so the suction friction is ALWAYS in the
    // pump head.
    List<NetEdge> edges() => [
          _e('gp', 'GT', 'P'),
          _e('ph', 'P', 'H0'),
          _e('r1', 'H0', 'H1', kind: EdgeKind.riser),
          _e('r2', 'H1', 'H2', kind: EdgeKind.riser),
          for (var f = 0; f < 3; f++)
            for (var i = 0; i < 2; i++) _e('w${f}_$i', 'H$f', 'W${f}_$i'),
        ];
    final nodes = [
      _n('GT', -2000, 0,
          role: NodeRole.plant, component: NodeComponent.groundTank),
      _n('P', 100, 0, role: NodeRole.plant, component: NodeComponent.pump),
      for (var f = 0; f < 3; f++) _n('H$f', 200, 0, floor: f),
      for (var f = 0; f < 3; f++)
        for (var i = 0; i < 2; i++) _wc('W${f}_$i', 400, i * 200.0, f),
    ];

    test('every edge order gives the GT-sourced head (suction included)', () {
      double? reference;
      for (var seed = 0; seed < 12; seed++) {
        final es = edges();
        if (seed == 1) {
          es.add(es.removeAt(0)); // [ph, …, gp] — the order that lost 4.6 m
        } else if (seed > 1) {
          es.shuffle(math.Random(seed));
        }
        final c = _container(Network(nodes: nodes, edges: es),
            FeedStrategy.upfeed);
        addTearDown(c.dispose);
        final sol = c.read(solveProvider)!;
        reference ??= sol.requiredPumpHead.meters;
        expect(sol.requiredPumpHead.meters, closeTo(reference, 1e-9),
            reason: 'seed $seed');
        // The solve SOURCE is the GT: its residual is the pump head itself
        // (zero friction, zero lift from the source) — no phantom 280 kPa
        // "residual" at a tank the solve walked INTO from the pump.
        expect(sol.residualPressure['GT']!.pascals,
            closeTo(pressureFromHead(sol.requiredPumpHead).pascals, 1e-6),
            reason: 'seed $seed');
      }
    });
  });

  group('picksource-fixture-source — no plant: source at the entry', () {
    // E → H0 → riser H1, H2; 2 WCs per floor. The critical WC is on the top
    // floor; lengthening a GROUND-floor WC's own branch (off the E → critical
    // path) cannot change the required head. It did (31.380 → 31.695 m) when
    // the solve sourced at that WC (1.1 m fixture height < 3.2 m ceiling main).
    Network build(double w00Branch) => Network(nodes: [
          _n('E', 0, 0),
          for (var f = 0; f < 3; f++) _n('H$f', 200, 0, floor: f),
          _wc('W0_0', 200 + w00Branch, 0, 0),
          _wc('W0_1', 400, 200, 0),
          for (var f = 1; f < 3; f++)
            for (var i = 0; i < 2; i++) _wc('W${f}_$i', 400, i * 200.0, f),
        ], edges: [
          _e('eh', 'E', 'H0'),
          _e('r1', 'H0', 'H1', kind: EdgeKind.riser),
          _e('r2', 'H1', 'H2', kind: EdgeKind.riser),
          for (var f = 0; f < 3; f++)
            for (var i = 0; i < 2; i++) _e('w${f}_$i', 'H$f', 'W${f}_$i'),
        ]);

    test('an off-path fixture branch length leaves the head unchanged', () {
      final short = _container(build(200), FeedStrategy.upfeed);
      final long = _container(build(900), FeedStrategy.upfeed);
      addTearDown(short.dispose);
      addTearDown(long.dispose);
      final a = short.read(solveProvider)!;
      final b = long.read(solveProvider)!;
      expect(a.criticalNodeId, startsWith('W2_'));
      expect(b.requiredPumpHead.meters, closeTo(a.requiredPumpHead.meters, 1e-9));
      // The source is the entry E, not a ground-floor fixture. Round 47 —
      // the pump ASSUMED at E sits on the L0 floor SURFACE (0.0 m), so E
      // itself, a bare main at the L0 ceiling, sees the pump head less that
      // ceiling lift (zero friction between the pump and E).
      final project = short.read(projectControllerProvider);
      final eCeiling = nodeElevation(
          short.read(networkControllerProvider).network.nodeById('E')!,
          project.building,
          project.mounting);
      expect(eCeiling.meters, greaterThan(0));
      expect(
          a.residualPressure['E']!.pascals,
          closeTo(
              pressureFromHead(Head(a.requiredPumpHead.meters - eCeiling.meters))
                  .pascals,
              1e-6));
    });
  });

  group('hybrid-booster-duty — the booster runs on its own flow', () {
    // RT (roof tank, degree 1) → T (top floor) → BS (booster) → 2 top-floor
    // WCs; T → D1 → D0 gravity downfeed riser, 2 WCs per lower floor.
    Network build() => Network(nodes: [
          _n('RT', 0, 0,
              floor: 2, role: NodeRole.plant, component: NodeComponent.roofTank),
          _n('T', 100, 0, floor: 2),
          _n('BS', 200, 0,
              floor: 2, role: NodeRole.plant, component: NodeComponent.boosterSet),
          _wc('U0', 300, 0, 2),
          _wc('U1', 300, 200, 2),
          _n('D1', 100, 0, floor: 1),
          _n('D0', 100, 0),
          for (var f = 0; f < 2; f++)
            for (var i = 0; i < 2; i++) _wc('L${f}_$i', 300, i * 200.0, f),
        ], edges: [
          _e('rt', 'RT', 'T'),
          _e('tb', 'T', 'BS'),
          _e('bu0', 'BS', 'U0'),
          _e('bu1', 'BS', 'U1'),
          _e('d1', 'T', 'D1', kind: EdgeKind.riser),
          _e('d0', 'D1', 'D0', kind: EdgeKind.riser),
          _e('l1a', 'D1', 'L1_0'),
          _e('l1b', 'D1', 'L1_1'),
          _e('l0a', 'D0', 'L0_0'),
          _e('l0b', 'D0', 'L0_1'),
        ]);

    test('upfeed: duty flow = the booster inlet curve(2 WC), not the root', () {
      final c = _container(build(), FeedStrategy.upfeed);
      addTearDown(c.dispose);
      final sizing = c.read(sizingProvider);
      final units = c.read(edgeFixtureUnitsProvider);
      // 6 identical WCs: the booster inlet carries exactly 2 of them.
      expect(units['tb']! * 3, closeTo(units['rt']!, 1e-9));
      final expected = const SniProfile()
          .probableFlowForFixtureUnits(units['tb']!)
          .cubicMetersPerSecond;
      expect(sizing['tb']!.flow.cubicMetersPerSecond, closeTo(expected, 1e-12));
      final duty = c.read(pumpDutyProvider)!;
      expect(duty.flow.cubicMetersPerSecond, closeTo(expected, 1e-12));
      expect(duty.flow.cubicMetersPerSecond,
          lessThan(sizing['rt']!.flow.cubicMetersPerSecond));
      // r2 — the head is what the booster must ADD downstream of the tank:
      // the upfeed residuals are linear in the source head, so the residual
      // at ZERO source head is r − p(H_req); the booster head is the worst
      // shortfall of that below the target over the fixtures it serves.
      final sol = c.read(solveProvider)!;
      final pH = pressureFromHead(sol.requiredPumpHead).pascals;
      final target = c.read(targetResidualProvider);
      var worst = double.negativeInfinity;
      for (final id in ['U0', 'U1']) {
        worst = math.max(worst,
            target.pascals - (sol.residualPressure[id]!.pascals - pH));
      }
      expect(duty.head.meters,
          closeTo(headFromPressure(Pressure(worst)).meters, 1e-9));
      expect(duty.head.meters,
          lessThanOrEqualTo(sol.requiredPumpHead.meters + 1e-9));
    });

    test('upfeed: the KETERANGAN peak flow is the building trunk, '
        'not the booster', () {
      final c = _container(build(), FeedStrategy.upfeed);
      addTearDown(c.dispose);
      final sizing = c.read(sizingProvider);
      final peak = c.read(supplyPeakFlowProvider)!;
      // RT is a degree-1 source: its delivery is the single trunk edge 'rt'
      // (curve of all 6 WCs).
      expect(peak.cubicMetersPerSecond,
          closeTo(sizing['rt']!.flow.cubicMetersPerSecond, 1e-12));
      expect(peak.cubicMetersPerSecond,
          greaterThan(c.read(pumpDutyProvider)!.flow.cubicMetersPerSecond));
    });

    test('downfeed: the booster gets a duty on its shortfall head', () {
      final c = _container(build(), FeedStrategy.downfeed);
      addTearDown(c.dispose);
      final down = c.read(downfeedProvider)!;
      final target = c.read(targetResidualProvider);
      // h = max over the booster's fixtures of (target − gravity residual)/ρg.
      var worst = double.negativeInfinity;
      for (final id in ['U0', 'U1']) {
        worst = math.max(
            worst, target.pascals - down.residualPressure[id]!.pascals);
      }
      final h = headFromPressure(Pressure(worst)).meters;
      expect(h, greaterThan(0));
      final duty = c.read(pumpDutyProvider);
      expect(duty, isNotNull, reason: 'the drawn booster must get a duty');
      expect(duty!.head.meters, closeTo(h, 1e-9));
      expect(duty.flow.cubicMetersPerSecond,
          closeTo(c.read(sizingProvider)['tb']!.flow.cubicMetersPerSecond,
              1e-12));
    });
  });

  group('booster PAIR — a duty/standby booster set is still a booster (r3)',
      () {
    // As the hybrid network, but the top-floor booster is drawn as the
    // Round-13/14 duty/standby idiom: T → B1 → CV1 → J and T → B2 → CV2 → J,
    // J → the 2 top-floor WCs. The served set must follow the solved flow
    // direction (and skip the mirrored standby leg) so the pair never walks
    // back to the roof tank through the standby leg and is misread as a
    // transfer pump.
    NetNode cv(String id, double x, double y) => _n(id, x, y,
        floor: 2, component: NodeComponent.checkValve);
    Network build() => Network(nodes: [
          _n('RT', 0, 0,
              floor: 2, role: NodeRole.plant, component: NodeComponent.roofTank),
          _n('T', 100, 0, floor: 2),
          _n('B1', 200, 0,
              floor: 2, role: NodeRole.plant, component: NodeComponent.boosterSet),
          _n('B2', 200, 100,
              floor: 2, role: NodeRole.plant, component: NodeComponent.boosterSet),
          cv('C1', 250, 0),
          cv('C2', 250, 100),
          _n('J', 300, 50, floor: 2),
          _wc('U0', 400, 0, 2),
          _wc('U1', 400, 200, 2),
          _n('D1', 100, 0, floor: 1),
          _n('D0', 100, 0),
          for (var f = 0; f < 2; f++)
            for (var i = 0; i < 2; i++) _wc('L${f}_$i', 300, i * 200.0, f),
        ], edges: [
          _e('rt', 'RT', 'T'),
          _e('tb1', 'T', 'B1'),
          _e('b1', 'B1', 'C1'),
          _e('c1', 'C1', 'J'),
          _e('tb2', 'T', 'B2'),
          _e('b2', 'B2', 'C2'),
          _e('c2', 'C2', 'J'),
          _e('ju0', 'J', 'U0'),
          _e('ju1', 'J', 'U1'),
          _e('d1', 'T', 'D1', kind: EdgeKind.riser),
          _e('d0', 'D1', 'D0', kind: EdgeKind.riser),
          _e('l1a', 'D1', 'L1_0'),
          _e('l1b', 'D1', 'L1_1'),
          _e('l0a', 'D0', 'L0_0'),
          _e('l0b', 'D0', 'L0_1'),
        ]);

    test('downfeed: the pair gets a booster duty on its shortfall head', () {
      final c = _container(build(), FeedStrategy.downfeed);
      addTearDown(c.dispose);
      final booster = c.read(supplyBoosterProvider);
      expect(booster, isNotNull,
          reason: 'a duty/standby booster pair must not read as a transfer');
      final down = c.read(downfeedProvider)!;
      final target = c.read(targetResidualProvider);
      var worst = double.negativeInfinity;
      for (final id in ['U0', 'U1']) {
        worst = math.max(
            worst, target.pascals - down.residualPressure[id]!.pascals);
      }
      final duty = c.read(pumpDutyProvider)!;
      expect(duty.head.meters,
          closeTo(headFromPressure(Pressure(worst)).meters, 1e-9));
      // ONE pump runs: the set flow is the curve of the 2 WCs it serves.
      final units = c.read(edgeFixtureUnitsProvider);
      final setFlow = const SniProfile()
          .probableFlowForFixtureUnits(units['ju0']! + units['ju1']!)
          .cubicMetersPerSecond;
      expect(duty.flow.cubicMetersPerSecond, closeTo(setFlow, 1e-9));
    });

    test('upfeed: the duty flow is the set flow, never the building trunk',
        () {
      final c = _container(build(), FeedStrategy.upfeed);
      addTearDown(c.dispose);
      final sizing = c.read(sizingProvider);
      final duty = c.read(pumpDutyProvider)!;
      expect(c.read(supplyBoosterProvider), isNotNull);
      expect(duty.flow.cubicMetersPerSecond,
          lessThan(sizing['rt']!.flow.cubicMetersPerSecond));
    });
  });

  group('transfer pump — GT -> TP -> RT downfeed is not a booster (r2)', () {
    // The standard Indonesian downfeed: ground tank → TRANSFER pump → roof
    // tank (floor 2) → gravity riser, 2 flush-tank WCs per floor. The
    // transfer pump is inline (degree 2, not the sizer root) but it FILLS a
    // tank: its duty is the lift to the roof tank, never the fixtures'
    // residual shortfall, so no booster duty is fabricated (null on
    // downfeed exactly as before Round 15).
    Network build() => Network(nodes: [
          _n('GT', 0, 0,
              role: NodeRole.plant, component: NodeComponent.groundTank),
          _n('TP', 100, 0, role: NodeRole.plant, component: NodeComponent.pump),
          _n('RT', 100, 0,
              floor: 2, role: NodeRole.plant, component: NodeComponent.roofTank),
          for (var f = 0; f < 3; f++) _n('H$f', 200, 0, floor: f),
          for (var f = 0; f < 3; f++)
            for (var i = 0; i < 2; i++) _wc('W${f}_$i', 400, i * 200.0, f),
        ], edges: [
          _e('gt', 'GT', 'TP'),
          _e('tr', 'TP', 'RT', kind: EdgeKind.riser),
          _e('rh', 'RT', 'H2'),
          _e('r1', 'H2', 'H1', kind: EdgeKind.riser),
          _e('r0', 'H1', 'H0', kind: EdgeKind.riser),
          for (var f = 0; f < 3; f++)
            for (var i = 0; i < 2; i++) _e('w${f}_$i', 'H$f', 'W${f}_$i'),
        ]);

    test('downfeed: no booster, no pump duty, notes print no peak flow', () {
      final c = _container(build(), FeedStrategy.downfeed);
      addTearDown(c.dispose);
      expect(c.read(downfeedProvider), isNotNull);
      // The mover sits inline with flow through it — the r1 over-reach.
      final sizing = c.read(sizingProvider);
      final inflow = [
        for (final id in ['gt', 'tr'])
          if (sizing[id]?.flowFromId != null &&
              sizing[id]!.flowFromId != 'TP' &&
              sizing[id]!.flow.cubicMetersPerSecond > 0)
            id,
      ];
      expect(inflow, isNotEmpty,
          reason: 'TP must carry flow through it, or the test proves nothing');
      final served = boosterServedNodes(c.read(sizingNetworkProvider), 'TP',
          inflow.single);
      expect(served, contains('RT'));
      expect(c.read(supplyBoosterProvider), isNull);
      expect(c.read(pumpDutyProvider), isNull);
      expect(c.read(supplyPeakFlowProvider), isNull);
    });

    test('a true inline booster with no tank beyond it is still found', () {
      // Control: the same layout with RT a plain junction ⇒ TP serves only
      // fixtures ⇒ it IS a booster (the Round-15 behaviour kept).
      final net = build();
      final plain = Network(nodes: [
        for (final n in net.nodes)
          n.id == 'RT' ? _n('RT', 100, 0, floor: 2) : n,
      ], edges: net.edges);
      final c = _container(plain, FeedStrategy.upfeed);
      addTearDown(c.dispose);
      final b = inlineSupplyBooster(
          c.read(sizingNetworkProvider), c.read(sizingProvider));
      expect(b?.nodeId, 'TP');
    });
  });

  group('pdam-fill (app) — the fill line is not source delivery', () {
    test('pump duty is curve(12) with or without the PDAM fill line', () {
      Network build(bool withFill) => Network(nodes: [
            if (withFill) _n('PDAM', -100, 0),
            _n('GT', 0, 0,
                role: NodeRole.plant, component: NodeComponent.groundTank),
            _n('P', 100, 0, role: NodeRole.plant, component: NodeComponent.pump),
            for (var f = 0; f < 3; f++) _n('H$f', 200, 0, floor: f),
            for (var f = 0; f < 3; f++)
              for (var i = 0; i < 2; i++) _wc('W${f}_$i', 400, i * 200.0, f),
          ], edges: [
            if (withFill) _e('pg', 'PDAM', 'GT'),
            _e('gp', 'GT', 'P'),
            _e('ph', 'P', 'H0'),
            _e('r1', 'H0', 'H1', kind: EdgeKind.riser),
            _e('r2', 'H1', 'H2', kind: EdgeKind.riser),
            for (var f = 0; f < 3; f++)
              for (var i = 0; i < 2; i++) _e('w${f}_$i', 'H$f', 'W${f}_$i'),
          ]);
      final a = _container(build(false), FeedStrategy.upfeed);
      final b = _container(build(true), FeedStrategy.upfeed);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final qa = a.read(pumpDutyProvider)!.flow.cubicMetersPerSecond;
      final qb = b.read(pumpDutyProvider)!.flow.cubicMetersPerSecond;
      expect(qb, closeTo(qa, 1e-12)); // was +8.1 % with the fill line drawn
      final ubap = a.read(edgeFixtureUnitsProvider)['gp']!;
      expect(qa,
          closeTo(const SniProfile().probableFlowForFixtureUnits(ubap)
              .cubicMetersPerSecond, 1e-12));
    });
  });
}
