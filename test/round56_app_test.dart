// Round 56 (2026-10-18) — app pins:
//
//   plumbing-hvac-convergence-6-zone-table-ignores-drawn-downfeed-booster —
//     the downfeed PRV zone table hangs off the tank elevation PLUS the head
//     of a booster the tank's whole delivery passes through, the same head
//     the delivered field (heatmap / probe / over-pressure judge) applies.
//
// First principles: a fixture's static under the zone datum D is
// rho g (D - z_fixture) = 9.81 kPa per metre. With a roof tank at 49.0 m
// (14 x 3.5 m) and a booster adding H m at its outlet, the datum is
// 49.0 + H; the SNI 8153 static limit 392 kPa (4 kgf/cm2) = 39.96 m of head
// below the datum. The tank alone keeps L3 (fixture 10.5 + 1.1 m) at
// 9.81 x (49 - 11.6) = 366.9 kPa — inside the limit, so the unboosted table
// printed L13..L3 tank-fed with no PRV; the booster raises L3 to
// 9.81 x (49 + H - 11.6) kPa, over the limit for any H > 2.6 m.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sample_project.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

NetNode _n(String id, double x, int floor,
        {NodeComponent? c, PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: kSampleSheetId,
        x: x,
        y: 600,
        floorIndex: floor,
        role: fixture != null ? NodeRole.fixture : (c?.role ?? NodeRole.main),
        component: c,
        fixture: fixture);

NetEdge _e(String id, String a, String b, {bool riser = false}) => NetEdge(
    id: id,
    fromId: a,
    toId: b,
    service: ServiceType.coldWater,
    kind: riser ? EdgeKind.riser : EdgeKind.run);

/// 14 storeys x 3.5 m: GT -> TP -> transfer riser -> RT (roof, 49.0 m);
/// RT -> [BP] -> the downfeed riser d13..d0 with two WCs per floor and a PRV
/// drawn at L2.
Network _tower({required bool booster}) {
  final nodes = <NetNode>[
    _n('GT', 100, 0, c: NodeComponent.groundTank),
    _n('TP', 150, 0, c: NodeComponent.pump),
    for (var f = 0; f < 14; f++) _n('t$f', 200, f),
    _n('RT', 250, 13, c: NodeComponent.roofTank),
    if (booster) _n('BP', 300, 13, c: NodeComponent.boosterSet),
    for (var f = 0; f < 14; f++) _n('d$f', 400, f),
    _n('d2a', 400, 2),
    _n('PRV', 420, 2, c: NodeComponent.prv),
    for (var f = 0; f < 14; f++)
      for (var k = 0; k < 2; k++)
        _n('W${f}_$k', 500.0 + 30 * k, f,
            fixture: PlumbingFixture.waterClosetFlushTank),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'TP'),
    _e('tp', 'TP', 't0'),
    for (var f = 0; f < 13; f++) _e('tr$f', 't$f', 't${f + 1}', riser: true),
    _e('trt', 't13', 'RT'),
    if (booster) ...[
      _e('rb', 'RT', 'BP'),
      _e('bd', 'BP', 'd13'),
    ] else
      _e('rd', 'RT', 'd13'),
    for (var f = 13; f > 3; f--) _e('dr$f', 'd$f', 'd${f - 1}', riser: true),
    _e('dr3', 'd3', 'd2a', riser: true),
    _e('p1', 'd2a', 'PRV'),
    _e('p2', 'PRV', 'd2'),
    _e('dr2', 'd2', 'd1', riser: true),
    _e('dr1', 'd1', 'd0', riser: true),
    for (var f = 0; f < 14; f++)
      for (var k = 0; k < 2; k++) _e('w${f}_$k', 'd$f', 'W${f}_$k'),
  ];
  return Network(nodes: nodes, edges: edges);
}

ProviderContainer _project({required bool booster}) {
  final c = _c();
  loadSampleLayoutProjectTo(c.read);
  c.read(projectControllerProvider.notifier).setFloors([
    for (var i = 0; i < 14; i++) Floor('L$i', const Length(3.5)),
  ]);
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
  c.read(networkControllerProvider.notifier).loadNetwork(_tower(booster: booster));
  return c;
}

void main() {
  group('plumbing-hvac-convergence-6 zone table follows the drawn booster', () {
    final maxKpa =
        const SniProfile().maxFixtureStaticPressure.value.inKiloPascals;

    test('no booster: the datum is the bare tank (byte-identical)', () {
      final c = _project(booster: false);
      expect(c.read(downfeedMoverHeadsProvider), isEmpty);
      final tank = c.read(downfeedTankElevationProvider)!;
      expect(tank.meters, closeTo(49.0, 1e-9));
      expect(c.read(effectiveDownfeedDatumProvider), same(tank));
      // L3 fixture 10.5 + 1.1 = 11.6 m: 9.81 x 37.4 = 366.9 kPa <= 392 kPa.
      final top = c.read(zoneStaticsProvider).first;
      expect(top.viaPrv, isFalse);
      expect(top.zone.bottomFloorIndex, lessThanOrEqualTo(3));
    });

    test(
        'a booster at the roof-tank outlet lifts the datum by its head; no '
        'tank-fed zone is printed within limit when the solve exceeds it', () {
      final c = _project(booster: true);
      final heads = c.read(downfeedMoverHeadsProvider);
      expect(heads.keys, ['BP']);
      final h = heads['BP']!.meters;
      expect(h, greaterThan(2.6));
      final datum = c.read(effectiveDownfeedDatumProvider)!;
      expect(datum.meters, closeTo(49.0 + h, 1e-9));
      final statics = c.read(zoneStaticsProvider);
      final building = c.read(projectControllerProvider).building;
      final mounting = c.read(projectControllerProvider).mounting;
      for (final z in statics.where((z) => !z.viaPrv)) {
        // The tank-fed zone's bottom static is rho g (datum - fixture).
        final zf = building
            .fixtureElevationOf(z.zone.bottomFloorIndex, mounting)
            .meters;
        expect(z.bottomStatic.inKiloPascals,
            closeTo(9.80665 * (datum.meters - zf), 0.5));
        expect(z.bottomStatic.inKiloPascals, lessThanOrEqualTo(maxKpa + 1e-6));
        // L3 at 9.81 x (49 + H - 11.6) > 392 kPa is no longer tank-fed.
        expect(z.zone.bottomFloorIndex, greaterThan(3));
      }
      // The delivered field (the booster applied) never shows a fixture of a
      // tank-fed zone above that zone's printed static.
      final delivered = c.read(downfeedDeliveredProvider)!;
      final tankFed = statics.firstWhere((z) => !z.viaPrv);
      for (final n in c.read(networkControllerProvider).network.nodes) {
        if (n.role != NodeRole.fixture) continue;
        if (n.floorIndex < tankFed.zone.bottomFloorIndex) continue;
        final r = delivered.residualPressure[n.id];
        if (r == null) continue;
        expect(r.inKiloPascals,
            lessThanOrEqualTo(tankFed.bottomStatic.inKiloPascals + 1e-6),
            reason: n.id);
      }
    });

    test('a booster serving only part of the building leaves the datum', () {
      // The booster on a side branch: the riser is fed straight from RT and
      // BP only feeds an extra top-floor fixture.
      final base = _tower(booster: false);
      final net = Network(nodes: [
        ...base.nodes,
        _n('BP', 300, 13, c: NodeComponent.boosterSet),
        _n('X', 320, 13, fixture: PlumbingFixture.waterClosetFlushTank),
      ], edges: [
        ...base.edges,
        _e('rb', 'RT', 'BP'),
        _e('bx', 'BP', 'X'),
      ]);
      final c = _c();
      loadSampleLayoutProjectTo(c.read);
      c.read(projectControllerProvider.notifier).setFloors([
        for (var i = 0; i < 14; i++) Floor('L$i', const Length(3.5)),
      ]);
      c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
      c.read(networkControllerProvider.notifier).loadNetwork(net);
      expect(c.read(effectiveDownfeedDatumProvider)!.meters,
          closeTo(c.read(downfeedTankElevationProvider)!.meters, 1e-9));
    });
  });
}
