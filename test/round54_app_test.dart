// Round 54 (2026-10-18) — the app half of the round-54 audit:
//
//   fire-convergence-6-staged-system-jockey-rated-at-summed-system-churn —
//     a series-staged system's jockey is sized on its ROOT stage's churn.
//   fire-convergence-6-gravity-head-check-subtracts-worst-friction-from-top-
//     terminal-static — the gravity verdict is judged per terminal.
//   plumbing-hvac-convergence-4-downfeed-source-picks-top-storey-heater — a
//     top-storey water heater never becomes the downfeed gravity source.
//   plumbing-hvac-convergence-4-autoplace-deletes-hand-drawn-exhaust-grilles
//     — re-running Auto-place keeps a hand-drawn smoke-exhaust branch.
//
// First principles: NFPA 20 churn = 1.40 x rated head at 0 % flow; the jockey
// point = 1 % of the rated flow at churn + 5 m (`checkFirePumpRating`).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart' show FireHazardClass;
import 'package:mechx_engine/sizing/fire_standpipe.dart' show kHoseOutletHeightM;
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';

NetNode _n(
  String id,
  double x, {
  int floor = 0,
  double y = 0,
  NodeRole role = NodeRole.main,
  NodeComponent? c,
  Length? elevation,
  PlumbingFixture? fixture,
  FlowRate? airflow,
}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: floor,
      role: role,
      component: c,
      elevation: elevation,
      fixture: fixture,
      airflow: airflow,
    );

NetEdge _e(
  String id,
  String a,
  String b, {
  ServiceType s = ServiceType.fireHydrant,
  EdgeKind k = EdgeKind.run,
  double? dn,
}) =>
    NetEdge(
        id: id,
        fromId: a,
        toId: b,
        service: s,
        kind: k,
        sizeOverride: dn == null ? null : Diameter(dn / 1000));

ProviderContainer _c(Network net, int floors,
    {double h = 3.5, FireHazardClass? hazard}) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < floors; i++) Floor('L$i', Length(h))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  if (hazard != null) c.read(fireHazardProvider.notifier).set(hazard);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  // ── staged jockey ────────────────────────────────────────────────────────
  group('a series-staged hydrant tower', () {
    // 6 x 3.5 m: GT -> P1 -> D1 -> low riser (boxes L0-L2); D1 -> P2 (L3) ->
    // D2 -> upper riser (boxes L3-L5).
    Network series() => Network(
          nodes: [
            _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
            _n('P1', 100, role: NodeRole.plant, c: NodeComponent.pump),
            _n('D1', 200),
            _n('P2', 300,
                floor: 3, role: NodeRole.plant, c: NodeComponent.pump),
            _n('D2', 400, floor: 3),
            for (var f = 0; f < 6; f++) ...[
              _n('L$f', f < 3 ? 900 : 1900, floor: f),
              _n('HB$f', f < 3 ? 1000 : 2000,
                  floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
            ],
          ],
          edges: [
            _e('g1', 'GT', 'P1'),
            _e('p1', 'P1', 'D1'),
            _e('dl', 'D1', 'L0'),
            _e('d1p2', 'D1', 'P2', k: EdgeKind.riser),
            _e('p2', 'P2', 'D2'),
            _e('du', 'D2', 'L3'),
            for (var f = 0; f < 6; f++) ...[
              if (f > 0 && f != 3)
                _e('q$f', 'L${f - 1}', 'L$f', k: EdgeKind.riser),
              _e('hb$f', 'L$f', 'HB$f'),
            ],
          ],
        );

    test('the jockey is 1 % of the rated flow at the ROOT stage churn + 5 m '
        '— never 1.4 x the summed system head + 5 m', () {
      final c = _c(series(), 6);
      final b = c.read(fireSystemBasesProvider).single;
      expect(b.stages, hasLength(2));
      final stage1 = b.stageHeads['P1']!.meters;
      // churn = 1.40 x stage-1 head, jockey = churn + 5 m.
      expect(b.jockeyRating.jockeyHead.meters, closeTo(1.4 * stage1 + 5, 1e-6));
      expect(b.jockey!.head.meters, closeTo(1.4 * stage1 + 5, 1e-6));
      expect(b.jockey!.flow.cubicMetersPerSecond,
          closeTo(b.rating.jockeyFlow.cubicMetersPerSecond, 1e-12));
      // The summed-head figure the jockey used to carry.
      final summed =
          checkFirePumpRating(ratedFlow: b.flow, ratedHead: b.head).jockeyHead;
      expect(summed.meters, closeTo(1.4 * b.head.meters + 5, 1e-6));
      expect(b.jockey!.head.meters, lessThan(summed.meters - 1));
      // The jockey duty every surface reads agrees with the basis.
      final jd = c.read(fireJockeyDutyProvider);
      if (jd != null) {
        expect(jd.head.meters, closeTo(b.jockey!.head.meters, 1e-9));
      }
    });
  });

  // ── gravity verdict per terminal ──────────────────────────────────────────
  test('a gravity sprinkler system with heads beside the tank on L3 and a '
      'long L0 main: judged per terminal, no false "head insufficient"', () {
    // 4 x 4 m, light hazard. Roof tank at an explicit 26 m; a riser down to
    // L0 (DN100); four DN50-fed heads beside the riser on L3 and four DN32-
    // fed heads at the end of a 60 m (6000 px at 0.01 m/px) DN50 L0 main.
    final net = Network(
      nodes: [
        _n('RT', 0,
            floor: 3,
            role: NodeRole.plant,
            c: NodeComponent.roofTank,
            elevation: const Length(26)),
        for (var f = 0; f < 4; f++) _n('S$f', 100, floor: f),
        for (var k = 0; k < 4; k++)
          _n('A$k', 200 + 100.0 * k,
              floor: 3, role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
        _n('M', 6100),
        for (var k = 0; k < 4; k++)
          _n('G$k', 6200 + 100.0 * k,
              role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
      ],
      edges: [
        _e('t', 'RT', 'S3', s: ServiceType.fireSprinkler, dn: 100),
        for (var f = 3; f > 0; f--)
          _e('r$f', 'S$f', 'S${f - 1}',
              s: ServiceType.fireSprinkler, k: EdgeKind.riser, dn: 100),
        for (var k = 0; k < 4; k++)
          _e('a$k', k == 0 ? 'S3' : 'A${k - 1}', 'A$k',
              s: ServiceType.fireSprinkler, dn: 50),
        _e('m', 'S0', 'M', s: ServiceType.fireSprinkler, dn: 50),
        for (var k = 0; k < 4; k++)
          _e('g$k', k == 0 ? 'M' : 'G${k - 1}', 'G$k',
              s: ServiceType.fireSprinkler, dn: 32),
      ],
    );
    final c = _c(net, 4, h: 4, hazard: FireHazardClass.lightHazard);
    final b = c.read(fireSystemBasesProvider).single;
    expect(b.gravityFed, isTrue);
    final project = c.read(projectControllerProvider);
    final sizing = c.read(sizingProvider);
    final sys = fireSystems(c.read(sizingNetworkProvider)).single;
    double lengthOf(NetEdge e) => edgeLength(e, c.read(sizingNetworkProvider),
            calibrationBySheet: project.calibrations,
            building: project.building,
            mounting: project.mounting)
        .meters;
    final byTerminal = <String, double>{};
    final worst = fireIndexPathFrictionM(
      net: c.read(sizingNetworkProvider),
      system: sys,
      pumpId: 'RT',
      sizing: sizing,
      lengthOf: lengthOf,
      terminals: FireTerminalKind.sprinkler,
      frictionByTerminalOut: byTerminal,
    )!;
    double z(String id) => project.building
        .ceilingElevationOf(net.nodeById(id)!.floorIndex)
        .meters;
    // available = min over heads of (26 - own ceiling - own friction).
    final perTerminal = byTerminal.entries
        .map((t) => 26 - z(t.key) - t.value)
        .reduce((a, b) => a < b ? a : b);
    expect(b.gravityAvailableHeadM, closeTo(perTerminal, 1e-9));
    // Every head is satisfied ...
    expect(b.gravityHeadShort, isFalse);
    // ... although pairing the TOP head's static with the far L0 head's
    // (worst) friction falls short — the false verdict this round removes.
    final paired = 26 - z('A0') - worst;
    expect(paired, lessThan(b.gravityRequiredHeadM!));
    expect(
        c.read(designIssuesProvider).where(
            (i) => i.kind.startsWith('fire-gravity-head-insufficient')),
        isEmpty);
    expect(kHoseOutletHeightM, greaterThan(0)); // hydrant basis unchanged
  });

  // ── downfeed source vs a top-storey heater ────────────────────────────────
  test('a top-storey water heater never becomes the downfeed source: the '
      'solve is the same whatever the heater\'s id', () {
    // 3 x 3.5 m: roof tank RT on L2 joined to the top header T2 by a 39 m
    // run; risers T2-T1-T0; one WC per floor; an untyped plant heater on L2
    // (cold run from T2, hot run to a lavatory).
    Network probe(String heater) => Network(
          nodes: [
            _n('RT', 0, floor: 2, role: NodeRole.plant, c: NodeComponent.roofTank),
            for (var f = 0; f < 3; f++) ...[
              _n('T$f', 3900, floor: f),
              _n('W$f', 4000,
                  floor: f,
                  role: NodeRole.fixture,
                  fixture: PlumbingFixture.waterClosetFlushTank),
            ],
            _n(heater, 3900, y: 200, floor: 2, role: NodeRole.plant),
            _n('LAV', 4000,
                y: 200,
                floor: 2,
                role: NodeRole.fixture,
                fixture: PlumbingFixture.lavatory),
          ],
          edges: [
            _e('m', 'RT', 'T2', s: ServiceType.coldWater),
            _e('r2', 'T2', 'T1', s: ServiceType.coldWater, k: EdgeKind.riser),
            _e('r1', 'T1', 'T0', s: ServiceType.coldWater, k: EdgeKind.riser),
            for (var f = 0; f < 3; f++)
              _e('w$f', 'T$f', 'W$f', s: ServiceType.coldWater),
            _e('hc', 'T2', heater, s: ServiceType.coldWater),
            _e('hh', heater, 'LAV', s: ServiceType.hotWater),
          ],
        );
    ProviderContainer run(String heater) {
      final c = _c(probe(heater), 3);
      c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
      return c;
    }

    final a = run('A1'), z = run('ZZ');
    final da = a.read(downfeedProvider)!, dz = z.read(downfeedProvider)!;
    for (final w in ['W0', 'W1', 'W2']) {
      expect(da.residualPressure[w]!.pascals,
          closeTo(dz.residualPressure[w]!.pascals, 1e-6),
          reason: w);
    }
    expect(da.boosterHeadRequired.meters,
        closeTo(dz.boosterHeadRequired.meters, 1e-9));
    expect(da.criticalNodeId, dz.criticalNodeId);
    // The roof tank is the gravity datum on both drawings.
    expect(a.read(downfeedTankElevationProvider)?.meters,
        closeTo(z.read(downfeedTankElevationProvider)!.meters, 1e-9));
    // The source is the roof tank: the 39 m tank-outlet main's friction is in
    // the top WC's residual (it is below the roof-tank static head).
    final staticKpa = (z.read(downfeedTankElevationProvider)!.meters -
            nodeElevation(probe('ZZ').nodeById('W2')!,
                    z.read(projectControllerProvider).building,
                    z.read(projectControllerProvider).mounting)
                .meters) *
        9.81;
    expect(dz.residualPressure['W2']!.inKiloPascals, lessThan(staticKpa));
  });

  // ── Auto-place keeps a hand-drawn smoke-exhaust branch ────────────────────
  test('cinema: re-running Auto-place keeps the hand-drawn exhaust grilles '
      'and their ducts; the stale judge never counts them as room extract',
      () {
    // 30 x 20 m (3000 x 2000 px at 0.01 m/px), 7 m ceiling, office (6 ACH):
    // 600 x 7 x 6 / 3600 = 7.000 m3/s.
    const cinema = RoomArea(
        id: 'cinema',
        sheetId: 's1',
        floorIndex: 0,
        ax: 0,
        ay: 0,
        bx: 3000,
        by: 2000,
        ceilingHeightM: 7);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier)
      ..setFloors(const [Floor('L0', Length(8))])
      ..setCalibration('s1', const ScaleCalibration(0.01));
    c.read(roomAreasProvider.notifier).set(const [cinema]);
    final ctrl = c.read(networkControllerProvider.notifier)
      ..autoPlaceRoomTerminals(room: cinema, metersPerPixel: 0.01);
    final placed = c.read(networkControllerProvider).network;
    ctrl.loadNetwork(Network(
      nodes: [
        ...placed.nodes,
        _n('SEF', 3500, y: 100, role: NodeRole.plant, c: NodeComponent.exhaustFan),
        _n('XJ', 2900, y: 100),
        for (final (id, x) in [('SG1', 2800.0), ('SG2', 2600.0)])
          _n(id, x,
              y: 100,
              role: NodeRole.fixture,
              c: NodeComponent.exhaustGrille,
              airflow: const FlowRate(3.0)),
      ],
      edges: [
        ...placed.edges,
        _e('x0', 'XJ', 'SEF', s: ServiceType.exhaust),
        _e('x1', 'SG1', 'XJ', s: ServiceType.exhaust),
        _e('x2', 'SG2', 'SG1', s: ServiceType.exhaust),
      ],
    ));
    bool stale() => c
        .read(designIssuesProvider)
        .any((i) => i.kind == 'room-terminals-stale:cinema');
    expect(stale(), isFalse);
    ctrl.autoPlaceRoomTerminals(room: cinema, metersPerPixel: 0.01);
    final after = c.read(networkControllerProvider).network;
    for (final id in ['SG1', 'SG2', 'XJ', 'SEF']) {
      expect(after.nodeById(id), isNotNull, reason: id);
    }
    for (final id in ['x0', 'x1', 'x2']) {
      expect(after.edgeById(id), isNotNull, reason: id);
    }
    expect(stale(), isFalse);
    // The room's own bank: 7.000 m3/s supplied by its diffusers.
    final supply = after.nodes
        .where((n) => isSupplyAirTerminal(n.component))
        .fold<double>(0, (s, n) => s + n.airflow!.cubicMetersPerSecond);
    expect(supply, closeTo(600 * 7 * 6 / 3600, 1e-9));
  });
}
