// Round 30 (2026-10-18) — app-side findings:
//
//   regression-feed-line-any-pump-counts   the inspector feed line (and the
//     riser notes) read only WATER-network equipment: a fire pump on the
//     hydrant line never turns the water feed into 'booster pump'.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sample_project.dart';
import 'package:mechx/ui/inspector/feed_strategy_line.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';
import 'package:mechx_engine/report/riser_tags.dart';

/// Adds a fire pump feeding a hydrant box on the fireHydrant service.
void _addHydrantFirePump(ProviderContainer c) {
  final net = c.read(networkControllerProvider).network;
  final anchor = net.nodes.first;
  final fp = NetNode(
    id: 'r30fp',
    sheetId: anchor.sheetId,
    x: anchor.x + 50,
    y: anchor.y + 50,
    floorIndex: anchor.floorIndex,
    role: NodeComponent.pump.role,
    component: NodeComponent.pump,
  );
  final hb = NetNode(
    id: 'r30hb',
    sheetId: anchor.sheetId,
    x: anchor.x + 150,
    y: anchor.y + 50,
    floorIndex: anchor.floorIndex,
    role: NodeComponent.hydrantBox.role,
    component: NodeComponent.hydrantBox,
  );
  c
      .read(networkControllerProvider.notifier)
      .restoreNetwork(
        Network(
          nodes: [...net.nodes, fp, hb],
          edges: [
            ...net.edges,
            const NetEdge(
              id: 'r30e',
              fromId: 'r30fp',
              toId: 'r30hb',
              service: ServiceType.fireHydrant,
            ),
          ],
        ),
      );
}

void main() {
  testWidgets(
    'feed line: a fire pump on the hydrant line leaves the meter-fed sample '
    'reading Direct mains (and the assumed upfeed pump), as Review does',
    (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      loadSampleLayoutProjectTo(c.read);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MechXTheme(
            data: MechXThemeData.dark,
            child: const Directionality(
              textDirection: TextDirection.ltr,
              child: Center(
                child: SizedBox(width: 300, child: FeedStrategyLine()),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Direct mains (water meter)'), findsOneWidget);

      // Add a fire pump feeding a hydrant box on the fireHydrant service.
      _addHydrantFirePump(c);
      await tester.pump();
      // The water feed evidence ignores the fire pump.
      expect(
        drawnWaterFeedEquipment(
          c.read(networkControllerProvider).network,
        ).hasPump,
        isFalse,
      );
      // Was 'Booster pump (no roof tank)' while Review said mains-fed.
      expect(find.text('Direct mains (water meter)'), findsOneWidget);
      expect(
        c
            .read(designIssuesProvider)
            .any((i) => i.kind == 'mains-fed:coldWater'),
        isTrue,
      );

      c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
      await tester.pump();
      // Was 'Upfeed pump' (drawn) beside Review's upfeed-pump-assumed.
      expect(find.text('Upfeed pump (assumed, not drawn)'), findsOneWidget);
      expect(
        c
            .read(designIssuesProvider)
            .any((i) => i.kind == 'upfeed-pump-assumed:coldWater'),
        isTrue,
      );
      // Drain any transient timers (status toasts / throttles).
      await tester.pump(const Duration(seconds: 10));
    },
  );

  test('drawnWaterFeedEquipment: a pump on a cold-water edge counts; one on '
      'drainage or fire does not', () {
    NetNode n(String id, NodeComponent comp) => NetNode(
      id: id,
      sheetId: 's',
      x: 0,
      y: 0,
      floorIndex: 0,
      role: comp.role,
      component: comp,
    );
    for (final svc in ServiceType.values) {
      final net = Network(
        nodes: [n('p', NodeComponent.pump), n('t', NodeComponent.roofTank)],
        edges: [NetEdge(id: 'e', fromId: 'p', toId: 't', service: svc)],
      );
      final eq = drawnWaterFeedEquipment(net);
      final water = svc == ServiceType.coldWater || svc == ServiceType.hotWater;
      expect(eq.hasPump, water, reason: svc.name);
      expect(eq.hasRoofTank, water, reason: svc.name);
      expect(eq.anyWaterNode, water, reason: svc.name);
    }
  });

  testWidgets(
    'calc report: a fire pump on the hydrant line leaves the meter-fed '
    'sample reporting Direct mains (not Booster pump)',
    (tester) async {
      late WidgetRef capturedRef;
      await tester.pumpWidget(
        ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Consumer(
              builder: (context, ref, _) {
                capturedRef = ref;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      final c = ProviderScope.containerOf(
        tester.element(find.byType(Consumer)),
        listen: false,
      );
      loadSampleLayoutProjectTo(c.read);
      await tester.pump();
      expect(
        buildMechanicalReportData(capturedRef).feedStrategy,
        'Direct mains',
      );
      _addHydrantFirePump(c);
      await tester.pump();
      // Was 'Booster pump (no roof tank)' while the inspector read Direct
      // mains and Review raised mains-fed.
      expect(
        buildMechanicalReportData(capturedRef).feedStrategy,
        'Direct mains',
      );
      expect(
        c
            .read(designIssuesProvider)
            .any((i) => i.kind == 'mains-fed:coldWater'),
        isTrue,
      );
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets(
    'mech-sim-4-ejector: a drawn sewage ejector is scheduled as "Sewage '
    'ejector" and its MDP way is fed its solved duty, not the 1.5 kW default',
    (tester) async {
      late WidgetRef capturedRef;
      await tester.pumpWidget(
        ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Consumer(
              builder: (context, ref, _) {
                capturedRef = ref;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      final c = ProviderScope.containerOf(
        tester.element(find.byType(Consumer)),
        listen: false,
      );
      final project = c.read(projectControllerProvider.notifier);
      project.setFloors(const [Floor('L0', Length(3)), Floor('L1', Length(3))]);
      final sheet = c.read(networkControllerProvider).network.nodes.isEmpty
          ? 's1'
          : c.read(networkControllerProvider).network.nodes.first.sheetId;
      project.setCalibration(sheet, const ScaleCalibration(0.05));
      c.read(electricalProjectProvider); // build the MEP-feed listener
      NetNode n(
        String id,
        double x,
        int floor, {
        NodeRole role = NodeRole.main,
        NodeComponent? comp,
      }) => NetNode(
        id: id,
        sheetId: sheet,
        x: x,
        y: 0,
        floorIndex: floor,
        role: comp?.role ?? role,
        component: comp,
      );
      // WC -> pit (ground tank) -> ejector pump -> riser up to the L1 sewer.
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(
            Network(
              nodes: [
                n('WC', -50, 0, role: NodeRole.fixture),
                n('PIT', 0, 0, comp: NodeComponent.groundTank),
                n('EJ', 20, 0, comp: NodeComponent.pump),
                n('R1', 20, 1),
                n('SW', 120, 1),
              ],
              edges: const [
                NetEdge(
                  id: 'in',
                  fromId: 'WC',
                  toId: 'PIT',
                  service: ServiceType.drainage,
                ),
                NetEdge(
                  id: 'pe',
                  fromId: 'PIT',
                  toId: 'EJ',
                  service: ServiceType.drainage,
                ),
                NetEdge(
                  id: 'rs',
                  fromId: 'EJ',
                  toId: 'R1',
                  service: ServiceType.drainage,
                  kind: EdgeKind.riser,
                ),
                NetEdge(
                  id: 'sw',
                  fromId: 'R1',
                  toId: 'SW',
                  service: ServiceType.drainage,
                ),
              ],
            ),
          );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      final duty = c.read(ejectorDutiesProvider)['EJ'];
      expect(duty, isNotNull, reason: 'the ejector has a solved duty');
      expect(duty!.flow.inLitersPerSecond, greaterThan(0));
      expect(duty.head.meters, greaterThan(0));

      // The schedule row: service 'Sewage ejector', on THAT duty.
      final rows = gatherEquipmentScheduleData(
        capturedRef,
      ).pumps.where((p) => p.service.startsWith('Sewage ejector')).toList();
      expect(rows, hasLength(1));
      expect(
        identical(rows.single.duty, duty) || rows.single.duty == duty,
        isTrue,
      );

      // The MDP way: the MEP-derived way for the EJ node is fed the ejector's
      // nameplate motor, never the 1.5 kW component default.
      final board = c
          .read(electricalProjectProvider)
          .panels
          .firstWhere((p) => p.id == kMepEquipmentPanelId);
      final way = board.circuits.firstWhere(
        (w) => w.sourceEquipmentId == 'node-EJ',
      );
      expect(way.motorKw, isNotNull);
      expect(way.motorKw, closeTo(duty.selectedMotor.inKiloWatts, 1e-9));
      expect(way.motorKw, isNot(closeTo(1.5, 1e-9)));
      await tester.pump(const Duration(seconds: 10));
    },
  );
}
