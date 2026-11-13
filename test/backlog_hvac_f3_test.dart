/// Backlog F-3 (2026-11-13) — ONE headline air-unit duty per room.
///
/// When a drawn duct system roots at the room's unit, the Rooms inspector,
/// the equipment schedule and the calc report print the drawn-system duty;
/// the room-air figure is printed only when no drawn system serves the room,
/// labelled "estimate (no ducts drawn)". No calculation changes.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/room_air_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/sizing/room_air.dart';
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

// A 10 x 8 m office room (0.01 m/px ⇒ 1000 x 800 px).
const _room = RoomArea(
    id: 'r0', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 1000, by: 800);

void _setUp(ProviderContainer c) {
  c
      .read(projectControllerProvider.notifier)
      .setCalibration('s1', const ScaleCalibration(0.01));
  c.read(roomAreasProvider.notifier).set(const [_room]);
}

void main() {
  testWidgets('an unpiped FCU in the room: the estimate, labelled "no ducts '
      'drawn", in the inspector basis AND the schedule row', (tester) async {
    final (ref, c) = await _harness(tester);
    _setUp(c);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('u', 100, 100, c: NodeComponent.fcu, role: NodeRole.plant),
    ]));
    final s = c.read(roomSizingProvider)['r0']!;
    final head = c.read(roomAirHeadlineProvider)['r0']!;
    expect(head.drawn, isFalse);
    expect(head.estimate, FanDutyBasis.estimateNoDucts);
    expect(head.duty.totalStaticPressure.pascals,
        s.equipment.totalStaticPressure.pascals);
    final data = gatherEquipmentScheduleData(ref);
    final row = data.fans.singleWhere((f) => f.airHandling);
    expect(row.estimate, FanDutyBasis.estimateNoDucts);
    final printed = buildEquipmentScheduleRows(data)
        .singleWhere((r) => r.tag == row.tag);
    expect(printed.duty, endsWith(' · estimate (no ducts drawn)'));
    expect(printed.duty,
        contains('${s.equipment.totalStaticPressure.pascals.round()} Pa'));
  });

  testWidgets('ducts drawn to the room\'s FCU: the drawn duty is the ONE '
      'headline and no room-estimate row is scheduled', (tester) async {
    final (ref, c) = await _harness(tester);
    _setUp(c);
    final s0 = sizeRoomAir(
      floorArea: const Area(80),
      ceilingHeight: Length(_room.ceilingHeightM),
      airChangesPerHour: _room.effectiveAch(),
    );
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('u', 100, 100, c: NodeComponent.fcu, role: NodeRole.plant),
      _n('d1', 500, 100,
          c: NodeComponent.supplyDiffuser,
          role: NodeRole.fixture,
          airflow: s0.airflow),
    ], edges: const [
      NetEdge(id: 'sa', fromId: 'u', toId: 'd1', service: ServiceType.duct),
    ]));
    final drawn = c.read(supplyFanDutiesByRootProvider)['u']!;
    final head = c.read(roomAirHeadlineProvider)['r0']!;
    expect(head.drawn, isTrue);
    expect(head.unitId, 'u');
    expect(head.duty.totalStaticPressure.pascals,
        drawn.totalStaticPressure.pascals);
    // The two figures differ (the estimate assumes a 15 m run) — only one is
    // printed.
    expect(drawn.totalStaticPressure.pascals,
        isNot(closeTo(s0.equipment.totalStaticPressure.pascals, 1e-6)));
    final data = gatherEquipmentScheduleData(ref);
    expect(data.fans.where((f) => f.estimate != null), isEmpty);
    expect(
        data.fans.where((f) =>
            (f.duty.totalStaticPressure.pascals -
                        drawn.totalStaticPressure.pascals)
                    .abs() <
                1e-9),
        hasLength(1));
  });

  testWidgets('a room with no unit and no ducts: the estimate row says so',
      (tester) async {
    final (ref, c) = await _harness(tester);
    _setUp(c);
    c.read(networkControllerProvider.notifier).loadNetwork(const Network());
    expect(c.read(roomAirHeadlineProvider)['r0']!.estimate,
        FanDutyBasis.estimateNoDucts);
    final row = gatherEquipmentScheduleData(ref)
        .fans
        .singleWhere((f) => f.airHandling);
    expect(row.estimate, FanDutyBasis.estimateNoDucts);
  });
}
