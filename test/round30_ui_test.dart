// Round 30 (2026-10-18) — app-side findings:
//
//   regression-feed-line-any-pump-counts   the inspector feed line (and the
//     riser notes) read only WATER-network equipment: a fire pump on the
//     hydrant line never turns the water feed into 'booster pump'.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sample_project.dart';
import 'package:mechx/ui/inspector/feed_strategy_line.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/riser_tags.dart';

void main() {
  testWidgets(
      'feed line: a fire pump on the hydrant line leaves the meter-fed sample '
      'reading Direct mains (and the assumed upfeed pump), as Review does',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    loadSampleLayoutProjectTo(c.read);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: SizedBox(width: 300, child: FeedStrategyLine())),
        ),
      ),
    ));
    expect(find.text('Direct mains (water meter)'), findsOneWidget);

    // Add a fire pump feeding a hydrant box on the fireHydrant service.
    final net = c.read(networkControllerProvider).network;
    final anchor = net.nodes.first;
    final fp = NetNode(
        id: 'r30fp',
        sheetId: anchor.sheetId,
        x: anchor.x + 50,
        y: anchor.y + 50,
        floorIndex: anchor.floorIndex,
        role: NodeComponent.pump.role,
        component: NodeComponent.pump);
    final hb = NetNode(
        id: 'r30hb',
        sheetId: anchor.sheetId,
        x: anchor.x + 150,
        y: anchor.y + 50,
        floorIndex: anchor.floorIndex,
        role: NodeComponent.hydrantBox.role,
        component: NodeComponent.hydrantBox);
    c.read(networkControllerProvider.notifier).restoreNetwork(Network(
          nodes: [...net.nodes, fp, hb],
          edges: [
            ...net.edges,
            const NetEdge(
                id: 'r30e',
                fromId: 'r30fp',
                toId: 'r30hb',
                service: ServiceType.fireHydrant),
          ],
        ));
    await tester.pump();
    // The water feed evidence ignores the fire pump.
    expect(
        drawnWaterFeedEquipment(c.read(networkControllerProvider).network)
            .hasPump,
        isFalse);
    // Was 'Booster pump (no roof tank)' while Review said mains-fed.
    expect(find.text('Direct mains (water meter)'), findsOneWidget);
    expect(
        c.read(designIssuesProvider).any((i) => i.kind == 'mains-fed:coldWater'),
        isTrue);

    c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
    await tester.pump();
    // Was 'Upfeed pump' (drawn) beside Review's upfeed-pump-assumed.
    expect(find.text('Upfeed pump (assumed, not drawn)'), findsOneWidget);
    expect(
        c
            .read(designIssuesProvider)
            .any((i) => i.kind == 'upfeed-pump-assumed:coldWater'),
        isTrue);
    // Drain any transient timers (status toasts / throttles).
    await tester.pump(const Duration(seconds: 10));
  });

  test('drawnWaterFeedEquipment: a pump on a cold-water edge counts; one on '
      'drainage or fire does not', () {
    NetNode n(String id, NodeComponent comp) => NetNode(
        id: id,
        sheetId: 's',
        x: 0,
        y: 0,
        floorIndex: 0,
        role: comp.role,
        component: comp);
    for (final svc in ServiceType.values) {
      final net = Network(nodes: [
        n('p', NodeComponent.pump),
        n('t', NodeComponent.roofTank),
      ], edges: [
        NetEdge(id: 'e', fromId: 'p', toId: 't', service: svc),
      ]);
      final eq = drawnWaterFeedEquipment(net);
      final water =
          svc == ServiceType.coldWater || svc == ServiceType.hotWater;
      expect(eq.hasPump, water, reason: svc.name);
      expect(eq.hasRoofTank, water, reason: svc.name);
      expect(eq.anyWaterNode, water, reason: svc.name);
    }
  });
}
