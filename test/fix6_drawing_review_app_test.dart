// Fix round 6 (third drawing review, 2026-11-20) — app-level pins.
//
// T2: the tower's pump-set detail names its STANDBY transfer pump TPS
// (P-02, 8.3 L/s @ 128.8 m, 18.5 kW) 'TRANSFER PUMP' — the same rule M-601
// uses for 'Transfer pump (standby)' (a standby pump whose duty pump is a
// transfer pump) — never 'BOOSTER PUMP'. The booster set P-05 stays one.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart'
    show buildMechanicalReportData, gatherEquipmentScheduleData;
import 'package:mechx_engine/report/calc_report.dart'
    show buildCalcReportMarkdown;
import 'package:mechx_engine/report/equipment_schedule.dart'
    show buildEquipmentScheduleRows;
import 'package:mechx_engine/report/mechanical_sld_drawing.dart'
    show plantMoverCaptions;

import '../packages/mechx_engine/test/reference/tower.dart';
import 'reference_drawing_loader.dart';

late WidgetRef _ref;

Future<ProviderContainer> _load(WidgetTester tester, String key) async {
  final spec = kRefDrawingSpecs.firstWhere((s) => s.key == key);
  final c = ProviderContainer();
  addTearDown(c.dispose);
  await tester.runAsync(() => loadRefDrawingSpec(c, spec));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: Directionality(
        textDirection: TextDirection.ltr,
        child: Consumer(builder: (context, r, _) {
          _ref = r;
          return const SizedBox.shrink();
        })),
  ));
  await tester.pump();
  return c;
}

void main() {
  testWidgets('tower: T2 standby transfer pump captioned TRANSFER PUMP',
      (tester) async {
    final c = await _load(tester, 'tower');
    // The solve classifies only the duty pump as a transfer mover; the
    // schedule's rule adds its standby.
    expect(c.read(transferPumpNodeIdsProvider), contains(kTowerTransferPump));
    expect(c.read(transferPumpNodeIdsProvider),
        isNot(contains(kTowerStandbyTransferPump)));
    final ids = c.read(scheduledTransferPumpNodeIdsProvider);
    expect(ids, containsAll([kTowerTransferPump, kTowerStandbyTransferPump]));
    final caps = plantMoverCaptions(c.read(sizingNetworkProvider),
        detailByNodeId: {
          for (final e in c.read(issuedRiserEquipmentDetailsProvider).entries)
            e.key: e.value,
        },
        transferPumpNodeIds: ids);
    expect(caps.where((t) => t.startsWith('TRANSFER PUMP')), hasLength(2));
    expect(caps.where((t) => t.startsWith('BOOSTER PUMP')), hasLength(1));
    expect(caps.where((t) => t.contains('Q 8.3 L/s')).every(
        (t) => t.startsWith('TRANSFER PUMP')), isTrue);
  });

  // C1 / C2 / C3 / C6 — the tower's report and schedule.
  //  * C3: one jockey line per fire zone, each at its zone's rating basis
  //    jockey point (zone 1 204.6 m, zone 2 210.2 m — the M-601 rows P-08 /
  //    P-04), the head through formatPumpHead.
  //  * C1: the zone pumps print 142.5 / 146.5 m in the report (was 143 /
  //    147 on the rating-curve line).
  //  * C2: the break tank prints '90 m3' (was '90000 L').
  //  * C6: the fire rows name their zone; no two fire rows share a service.
  testWidgets('tower: C1 C2 C3 C6 report and schedule', (tester) async {
    await _load(tester, 'tower');
    final md = buildCalcReportMarkdown(buildMechanicalReportData(_ref));
    expect(md, contains('Jockey pump, fire zone 1:'));
    expect(md, contains('Jockey pump, fire zone 2:'));
    expect(md, contains('0.47 L/s @ 204.6 m'));
    expect(md, contains('0.47 L/s @ 210.2 m'));
    expect(md, isNot(contains('@ 143 m')));
    expect(md, isNot(contains('@ 147 m')));
    expect(md, contains('@ 142.5 m'));
    expect(md, contains('@ 146.5 m'));
    expect(md, isNot(contains('90000 L')));
    expect(md, contains('90 m3'));
    final rows = buildEquipmentScheduleRows(gatherEquipmentScheduleData(_ref));
    final fire = [
      for (final r in rows)
        if (r.service.startsWith('Fire')) r.service,
    ];
    expect(fire, isNotEmpty);
    expect(fire.toSet().length, fire.length, reason: '$fire');
    expect(fire.where((t) => t.endsWith(' - zone 1')), hasLength(3));
    expect(fire.where((t) => t.endsWith(' - zone 2')), hasLength(3));
  });
}
