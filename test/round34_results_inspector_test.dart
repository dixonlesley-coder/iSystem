// Round 34 — the Results inspector reads the DELIVERED downfeed field and
// follows the Round-32 SNI split:
//
//   regression-inspector-top-residual-unboosted-when-booster-drawn
//     with a sized booster drawn, the top residual printed is the delivered
//     (boosted) figure the heatmap / probe / Review read, and the unboosted
//     gravity figure is a muted 'Gravity only' row.
//   ui-simplicity-5-booster-card-contradicts-pass
//     a downfeed whose every delivery node meets its SNI floor (but not the
//     comfort target) shows a success 'SNI min met' card, never the amber
//     'boost' card beside a compliance PASS.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/compliance_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

/// The plumbing sample (meter → lavatory → drain) with the meter turned into
/// a drawn ROOF TANK, optionally with a booster set inline on the supply.
void _roofTank(ProviderContainer c, {bool booster = false}) {
  final net = c.read(networkControllerProvider).network;
  final nodes = [
    for (final n in net.nodes)
      n.component == NodeComponent.waterMeter
          ? n.copyWith(component: NodeComponent.roofTank, role: NodeRole.plant)
          : n,
  ];
  var edges = net.edges;
  if (booster) {
    final cw = edges.firstWhere((e) => e.service == ServiceType.coldWater);
    final a = nodes.firstWhere((n) => n.id == cw.fromId);
    final b = nodes.firstWhere((n) => n.id == cw.toId);
    nodes.add(NetNode(
      id: 'bst',
      sheetId: a.sheetId,
      floorIndex: a.floorIndex,
      x: (a.x + b.x) / 2,
      y: (a.y + b.y) / 2,
      role: NodeRole.plant,
      component: NodeComponent.boosterSet,
    ));
    edges = [
      for (final e in edges)
        if (e.id != cw.id) e,
      NetEdge(
          id: '${cw.id}a', fromId: cw.fromId, toId: 'bst', service: cw.service),
      NetEdge(
          id: '${cw.id}b', fromId: 'bst', toId: cw.toId, service: cw.service),
    ];
  }
  c
      .read(networkControllerProvider.notifier)
      .loadNetwork(Network(nodes: nodes, edges: edges));
}

Future<ProviderContainer> _pumpSample(WidgetTester tester) async {
  setDesktopSurface(tester);
  await tester.pumpWidget(const ProviderScope(child: MechXApp()));
  await tester.pump();
  await tester.ensureVisible(find.text('Load plumbing sample'));
  await tester.tap(find.text('Load plumbing sample'));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(MechXApp)));
}

void main() {
  testWidgets(
      'SNI floor met below the comfort target: a success card, no amber '
      '"boost", and the compliance Supply pressure row passes', (tester) async {
    final c = await _pumpSample(tester);
    _roofTank(c);
    await tester.pumpAndSettle();
    final d = c.read(downfeedDeliveredProvider)!;
    // ~11 m of tank head over a ground lavatory ≈ 98 kPa: below the 225 kPa
    // comfort target, above the 49 kPa SNI 8153 faucet floor.
    expect(d.gravitySufficient, isFalse);
    expect(d.minResidual.inKiloPascals, greaterThan(49.03));
    final row = c
        .read(complianceSummaryProvider)
        .items
        .firstWhere((i) => i.category == 'Supply pressure');
    expect(row.pass, isTrue);
    expect(find.text('boost', skipOffstage: false), findsNothing);
    expect(find.text('Top residual · SNI min met', skipOffstage: false),
        findsOneWidget);
    expect(
        find.text('${d.minResidual.inKiloPascals.toStringAsFixed(0)} kPa',
            skipOffstage: false),
        findsWidgets);
    expect(find.text('none (tank head OK)', skipOffstage: false), findsNothing);
  });

  testWidgets(
      'with a sized booster drawn the headline residual is the DELIVERED '
      'figure, and the unboosted gravity figure is a muted row',
      (tester) async {
    final c = await _pumpSample(tester);
    _roofTank(c, booster: true);
    await tester.pumpAndSettle();
    final delivered = c.read(downfeedDeliveredProvider)!;
    final unboosted = c.read(downfeedProvider)!;
    // The booster lifts the field: the two solves now differ by its head.
    expect(delivered.minResidual.inKiloPascals,
        greaterThan(unboosted.minResidual.inKiloPascals + 0.5));
    String kpa(double v) => '${v.toStringAsFixed(0)} kPa';
    expect(
        find.text(kpa(delivered.minResidual.inKiloPascals),
            skipOffstage: false),
        findsWidgets);
    expect(find.text('Gravity only', skipOffstage: false), findsOneWidget);
    expect(
        find.text(kpa(unboosted.minResidual.inKiloPascals),
            skipOffstage: false),
        findsOneWidget);
  });
}
