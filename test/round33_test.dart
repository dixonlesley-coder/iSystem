// Round 33 (2026-10-18) — app-side findings:
//
//   regression-sni-minimum-judged-only-at-critical-node   every delivery
//     node is judged against its OWN SNI floor: a flush-valve WC below
//     98 kPa fails although the faucet-fed critical node meets 49 kPa.
//   regression-heatmap-legend-low-against-comfort-target  LOW only below the
//     SNI floor; 'below target' between the floor and the comfort target.
//   hydraulics-3-2   the upfeed heatmap / probe / over-pressure judge read the
//     DELIVERED field (root pump + zone booster at their own duties).
//   hydraulics-3-3   a PDAM meter -> pump -> roof tank fill pump is a
//     TRANSFER pump, never a 225 kPa-at-the-meter booster.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/compliance_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sample_project.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/canvas/heatmap_layer.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/hydraulics.dart' show pressureFromHead;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

NetNode _n(String id, double x, int floor,
        {NodeComponent? c,
        NodeRole role = NodeRole.main,
        PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: kSampleSheetId,
        x: x,
        y: 600,
        floorIndex: floor,
        role: c?.role ?? role,
        component: c,
        fixture: fixture);

NetEdge _run(String id, String a, String b) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.coldWater);
NetEdge _riser(String id, String a, String b) => NetEdge(
    id: id,
    fromId: a,
    toId: b,
    service: ServiceType.coldWater,
    kind: EdgeKind.riser);

ProviderContainer _project(List<Floor> floors, Network net,
    {FeedStrategy feed = FeedStrategy.downfeed}) {
  final c = _c();
  loadSampleLayoutProjectTo(c.read);
  c.read(projectControllerProvider.notifier).setFloors(floors);
  c.read(feedStrategyProvider.notifier).set(feed);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  group('SNI minimum is judged at every delivery node', () {
    // Ground 4 m, L1 3 m, L2 4.5 m (roof 11.5 m). Roof tank T on L2 ->
    // R2 -riser- R1 (L1) -riser- R0 (Ground). A lavatory FA teed at R1, a
    // flush-valve WC FV teed at R0.
    // First principles: FA at the L1 fixture height (4 + 1.1 = 5.1 m) sees
    // 6.4 m of static (≈ 63 kPa) less friction; its path holds no flush
    // valve, so its SNI floor is 0.5 kgf/cm² = 49 kPa and it is the critical
    // (least-pressure) node. FV at 1.1 m sees 10.4 m (≈ 102 kPa) less the
    // flush-valve flow's friction — below ITS OWN 1.0 kgf/cm² = 98 kPa floor.
    const floors = [
      Floor('Ground', Length(4)),
      Floor('L1', Length(3)),
      Floor('L2', Length(4.5)),
    ];
    Network net() => Network(nodes: [
          _n('T', 550, 2, c: NodeComponent.roofTank),
          _n('R2', 600, 2),
          _n('R1', 600, 1),
          _n('R0', 600, 0),
          _n('FA', 650, 1,
              role: NodeRole.fixture, fixture: PlumbingFixture.lavatory),
          _n('FV', 650, 0,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.waterClosetFlushValve),
        ], edges: [
          _run('t', 'T', 'R2'),
          _riser('r21', 'R2', 'R1'),
          _riser('r10', 'R1', 'R0'),
          _run('fa', 'R1', 'FA'),
          _run('fv', 'R0', 'FV'),
        ]);

    test('a flush-valve WC below 98 kPa is a blocking warning', () {
      final c = _project(floors, net());
      final d = c.read(downfeedDeliveredProvider)!;
      final fa = d.residualPressure['FA']!.inKiloPascals;
      final fv = d.residualPressure['FV']!.inKiloPascals;
      const sni = SniProfile();
      final faucet = sni.minResidualPressureFaucet.value.inKiloPascals;
      final valve = sni.minResidualPressureFlushValve.value.inKiloPascals;
      expect(d.criticalNodeId, 'FA');
      expect(fa, greaterThan(faucet));
      expect(fv, lessThan(valve));
      final floorsByNode = c.read(downfeedSniFloorsProvider);
      expect(floorsByNode['FA']!.inKiloPascals, closeTo(faucet, 1e-9));
      expect(floorsByNode['FV']!.inKiloPascals, closeTo(valve, 1e-9));
      final issue = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'downfeed-below-target');
      expect(issue.severity, IssueSeverity.warning);
      // Names the WORST offender: FV, its own floor and residual.
      expect(issue.locate?.nodeId, 'FV');
      expect(issue.message, contains('${valve.toStringAsFixed(0)} kPa'));
      expect(issue.message, contains('${fv.toStringAsFixed(0)} kPa'));
      final row = c
          .read(complianceSummaryProvider)
          .items
          .firstWhere((i) => i.category == 'Supply pressure');
      expect(row.pass, isFalse);
      // The heatmap legend reads the same verdict.
      final h = c.read(heatmapSniSummaryProvider);
      expect(h.belowFloor, isTrue);
      expect(h.floorKpa, closeTo(valve, 1e-9));
    });

    test('per-node floors: a faucet off the flush-valve branch keeps 49 kPa',
        () {
      final c = _project(floors, net());
      final floorsByNode = sniMinimumResidualByNode(
        net: c.read(networkControllerProvider).network,
        sourceId: 'T',
        nodeIds: const ['FA', 'FV', 'R0', 'R1'],
        flushValveNodeIds: const {'FV'},
      );
      expect(floorsByNode['FA']!.inKiloPascals, closeTo(49.03, 0.01));
      expect(floorsByNode['FV']!.inKiloPascals, closeTo(98.07, 0.01));
      expect(floorsByNode['R0']!.inKiloPascals, closeTo(49.03, 0.01));
    });
  });

  group('residual verdict ladder (heatmap legend + probe)', () {
    test('pure ladder', () {
      expect(
          residualVerdict(residualPa: 60e3, targetPa: 225e3, sniFloorPa: 49e3),
          ResidualVerdict.belowTarget);
      expect(
          residualVerdict(residualPa: 40e3, targetPa: 225e3, sniFloorPa: 49e3),
          ResidualVerdict.low);
      expect(
          residualVerdict(residualPa: 230e3, targetPa: 225e3, sniFloorPa: 49e3),
          ResidualVerdict.pass);
      // No floor known: the legacy target-only verdict.
      expect(residualVerdict(residualPa: 60e3, targetPa: 225e3),
          ResidualVerdict.low);
    });

    Widget host(Widget child) => MechXTheme(
          data: MechXThemeData.light,
          child: Directionality(
              textDirection: TextDirection.ltr, child: Center(child: child)),
        );

    testWidgets('uniform 60 kPa above a 49 kPa floor reads below target',
        (t) async {
      await t.pumpWidget(host(const HeatmapLegend(
          minKpa: 60, maxKpa: 60, targetKpa: 225, sniFloorKpa: 49)));
      expect(find.text('LOW'), findsNothing);
      expect(find.text('below target'), findsOneWidget);
    });

    testWidgets('a node below its floor reads LOW', (t) async {
      await t.pumpWidget(host(const HeatmapLegend(
          minKpa: 60,
          maxKpa: 60,
          targetKpa: 225,
          sniFloorKpa: 98,
          belowSniFloor: true)));
      expect(find.text('LOW'), findsOneWidget);
    });

    testWidgets('spread field: the tick is the Target; SNI min labelled',
        (t) async {
      await t.pumpWidget(host(const HeatmapLegend(
          minKpa: 30, maxKpa: 260, targetKpa: 225, sniFloorKpa: 49)));
      expect(find.text('Min 225 kPa'), findsNothing);
      expect(find.text('Target 225 kPa'), findsOneWidget);
      expect(find.text('SNI min 49 kPa'), findsOneWidget);
    });
  });

  group('upfeed delivered field with drawn movers', () {
    test('root pump + zone booster: the field is shifted per mover', () {
      // 8 storeys x 3.5 m; root pump P (Ground) feeds L0-L4 directly; a
      // booster BS on the riser at L4 feeds L5-L7. Two WCs per floor.
      final floors = [
        for (var i = 0; i < 8; i++) Floor('L$i', const Length(3.5)),
      ];
      final nodes = <NetNode>[
        _n('P', 300, 0, c: NodeComponent.pump),
        for (var i = 0; i < 8; i++) _n('m$i', 500, i),
        _n('BS', 520, 4, c: NodeComponent.boosterSet),
        _n('m4b', 540, 4),
        for (var i = 0; i < 8; i++)
          _n('W$i', 800, i,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.waterClosetFlushTank),
      ];
      final edges = <NetEdge>[
        _run('p0', 'P', 'm0'),
        for (var i = 0; i < 4; i++) _riser('r$i', 'm$i', 'm${i + 1}'),
        _run('b0', 'm4', 'BS'),
        _run('b1', 'BS', 'm4b'),
        _riser('r4', 'm4b', 'm5'),
        for (var i = 5; i < 7; i++) _riser('r$i', 'm$i', 'm${i + 1}'),
        for (var i = 0; i < 8; i++) _run('w$i', 'm$i', 'W$i'),
      ];
      final c = _project(floors, Network(nodes: nodes, edges: edges),
          feed: FeedStrategy.upfeed);
      final base = c.read(solveProvider)!;
      final duties = c.read(supplyMoverDutiesProvider);
      expect(duties.keys, containsAll(['P', 'BS']));
      final delivered = c.read(upfeedDeliveredProvider)!;
      expect(identical(delivered, base), isFalse);
      // First principles: residuals are linear in the source head; the root
      // pump develops its OWN duty head (not the whole-system head), the
      // booster adds its head beyond itself.
      final shift = pressureFromHead(Head(
              base.requiredPumpHead.meters - duties['P']!.head.meters))
          .pascals;
      final boost = pressureFromHead(duties['BS']!.head).pascals;
      expect(delivered.residualPressure['W0']!.pascals,
          closeTo(base.residualPressure['W0']!.pascals - shift, 1e-6));
      expect(delivered.residualPressure['W7']!.pascals,
          closeTo(base.residualPressure['W7']!.pascals - shift + boost, 1e-6));
      // The heatmap field is the delivered one.
      expect(c.read(residualByNodeProvider), same(delivered.residualPressure));
      // Every delivery node meets the target with the movers at their duty.
      final target = c.read(targetResidualProvider).pascals;
      for (final id in delivered.deliveryNodeIds) {
        expect(delivered.residualPressure[id]!.pascals,
            greaterThanOrEqualTo(target - 1), reason: id);
      }
    });
  });

  group('PDAM meter -> pump -> roof tank (hydraulics-3-3)', () {
    test('the fill pump is a TRANSFER pump; no booster duty', () {
      const floors = [
        Floor('L0', Length(3.5)),
        Floor('L1', Length(3.5)),
        Floor('L2', Length(3.5)),
      ];
      final net = Network(nodes: [
        _n('WM', 300, 0, c: NodeComponent.waterMeter),
        _n('P', 400, 0, c: NodeComponent.pump),
        _n('m0', 500, 0),
        _n('m1', 500, 1),
        _n('m2', 500, 2),
        _n('T', 600, 2, c: NodeComponent.roofTank),
        _n('d2', 700, 2),
        _n('d1', 700, 1),
        _n('d0', 700, 0),
        _n('W0', 900, 0,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushTank),
        _n('W1', 900, 1,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushTank),
      ], edges: [
        _run('wp', 'WM', 'P'),
        _run('pm', 'P', 'm0'),
        _riser('fr0', 'm0', 'm1'),
        _riser('fr1', 'm1', 'm2'),
        _run('ft', 'm2', 'T'),
        _run('td', 'T', 'd2'),
        _riser('dr1', 'd2', 'd1'),
        _riser('dr0', 'd1', 'd0'),
        _run('w0', 'd0', 'W0'),
        _run('w1', 'd1', 'W1'),
      ]);
      final c = _project(floors, net);
      expect(c.read(transferPumpNodeIdsProvider), {'P'});
      expect(c.read(pumpDutyProvider), isNull);
      final duty = c.read(supplyMoverDutiesProvider)['P']!;
      // Lift: P on the L0 surface (0 m) to the roof tank at the roof
      // (10.5 m), plus the fill-line friction (> 0).
      expect(duty.head.meters, greaterThan(10.5));
      expect(duty.head.meters, lessThan(10.5 + 5));
    });
  });
}
