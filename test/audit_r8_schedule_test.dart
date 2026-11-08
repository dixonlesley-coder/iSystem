/// Audit round 8 — equipment schedule ↔ plan ↔ electrical coupling.
///
///   coupling-3  the AHU-fan row takes the tag of the unit the duct system is
///               ROOTED at (never the exhaust fan's); the exhaust row takes the
///               exhaust root fan's plan tag; a room-fallback tag never
///               collides with a drawn unit's tag.
///   coupling-6  no phantom FCU row for a room served by AC units; each placed
///               AC unit gets ONE row on the same input its panel way carries.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/units.dart';

Future<(WidgetRef, ProviderContainer)> _harness(WidgetTester tester) async {
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
  final container = ProviderScope.containerOf(
    tester.element(find.byType(Consumer)),
    listen: false,
  );
  return (capturedRef, container);
}

NetNode _n(String id, double x, double y,
        {NodeComponent? c,
        NodeRole role = NodeRole.main,
        FlowRate? airflow}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: 0,
        role: role,
        component: c,
        airflow: airflow);

void main() {
  testWidgets('coupling-3: duct-fan + exhaust rows carry their ROOT units\' '
      'plan tags', (tester) async {
    final (ref, c) = await _harness(tester);
    final net = Network(nodes: [
      _n('n0', 0, 0, c: NodeComponent.ahu, role: NodeRole.plant),
      _n('n1', 300, 0,
          c: NodeComponent.supplyDiffuser,
          role: NodeRole.fixture,
          airflow: const FlowRate(0.4)),
      _n('n3', 0, 600, c: NodeComponent.exhaustFan, role: NodeRole.plant),
      _n('n4', 300, 600,
          c: NodeComponent.returnGrille,
          role: NodeRole.fixture,
          airflow: const FlowRate(0.3)),
    ], edges: const [
      NetEdge(id: 'd', fromId: 'n0', toId: 'n1', service: ServiceType.duct),
      NetEdge(id: 'x', fromId: 'n3', toId: 'n4', service: ServiceType.exhaust),
    ]);
    c.read(networkControllerProvider.notifier).loadNetwork(net);
    final tags = equipmentNodeTags(net);
    final data = gatherEquipmentScheduleData(ref);
    final duct = data.fans.firstWhere((f) => f.service == 'Mechanical ventilation');
    final ex = data.fans.firstWhere((f) => f.service == 'Exhaust ventilation');
    expect(duct.tag, tags['n0']);
    expect(ex.tag, tags['n3']);
    expect(duct.tag, isNot(ex.tag));
  });

  testWidgets('coupling-3: a room-fallback tag never collides with a drawn '
      'unit tag', (tester) async {
    final (ref, c) = await _harness(tester);
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.01));
    // Room r0 (natural fallback AHU-01); an AHU drawn OUTSIDE it, unpiped.
    c.read(roomAreasProvider.notifier).set(const [
      RoomArea(id: 'r0', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 400, by: 400),
    ]);
    final net = Network(nodes: [
      _n('u', 2000, 2000, c: NodeComponent.ahu, role: NodeRole.plant),
    ]);
    c.read(networkControllerProvider.notifier).loadNetwork(net);
    final drawn = equipmentNodeTags(net)['u']!;
    final data = gatherEquipmentScheduleData(ref);
    final roomRow = data.fans.firstWhere((f) => f.airHandling);
    // An id with no trailing integer takes the first free AHU number.
    expect(drawn, 'AHU-01');
    expect(roomRow.tag, isNot(drawn));
    expect(roomRow.tag, 'AHU-R01');
  });

  testWidgets('coupling-6: an AC-served room schedules its AC unit (with the '
      'panel way\'s input), not a phantom FCU', (tester) async {
    final (ref, c) = await _harness(tester);
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.01));
    c.read(roomAreasProvider.notifier).set(const [
      RoomArea(id: 'r0', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 500, by: 400),
    ]);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
          _n('ac', 250, 200, c: NodeComponent.acCassette, role: NodeRole.plant),
        ]));
    final data = gatherEquipmentScheduleData(ref);
    expect(data.fans.where((f) => f.airHandling), isEmpty);
    expect(data.acUnits, hasLength(1));
    final way = c.read(placedEquipmentCircuitsProvider).single;
    // One scheduled unit ⇔ one electrical way, on the same input.
    expect(data.acUnits.single.inputW, closeTo(way.loadW, 1e-6));
  });
}
