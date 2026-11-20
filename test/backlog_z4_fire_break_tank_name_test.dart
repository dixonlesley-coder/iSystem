// Backlog Z-4 (2026-11-14) — the reference tower's fire zone break tank BT
// (roof-TYPED below the top storey, the zone chain's fill tank) is named
// 'Fire break tank' on the equipment schedule and the issued riser (M-201),
// never 'Roof tank', and raises no `roof-tank-below-top`. It has only fire
// pipes, so the domestic paths never see it: the water reserve counts GT
// 60 000 + RT 30 000 = 90 000 L (90 m3).
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/tank_fill_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart'
    show gatherEquipmentScheduleData;
import 'package:mechx/ui/schematic/schematic_export.dart'
    show buildLiveRiserPages;
import 'package:mechx_engine/network/network.dart' show NodeComponent;
import 'package:mechx_engine/report/cover_sheet.dart'
    show buildMasterLegendSections, masterLegendComponentsOf;
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/report/plan_symbols.dart' show equipmentNodeTags;
import 'package:mechx_engine/report/sld_sheet.dart';

import 'reference_drawing_loader.dart';

void main() {
  testWidgets('tower: BT is a "Fire break tank" on the schedule and riser',
      (tester) async {
    final spec = kRefDrawingSpecs.firstWhere((s) => s.key == 'tower');
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.runAsync(() => loadRefDrawingSpec(c, spec));
    late WidgetRef ref;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Consumer(builder: (context, r, _) {
          ref = r;
          return const SizedBox.shrink();
        }),
      ),
    ));
    await tester.pump();

    expect(c.read(fireBreakTankIdsProvider), {'BT'});
    final tag = equipmentNodeTags(c.read(sizingNetworkProvider))['BT']!;
    expect(tag, 'TK-04');

    // Equipment schedule: 'Fire break tank (fire zone relay)', 90 m3
    // (backlog W-7: the one capacity formatter; was '90.0 m3').
    final rows = buildEquipmentScheduleRows(gatherEquipmentScheduleData(ref));
    final bt = rows.singleWhere((r) => r.tag == tag);
    expect(bt.service, 'Fire break tank (fire zone relay)');
    expect(bt.duty, '90 m3');
    expect(rows.where((r) => r.service.startsWith('Roof tank')), hasLength(1));

    // Issued riser: 'TK-04 Fire break tank · 90 m3' (was 'TK-04 Roof tank ·
    // 90 m3' on the Lantai 15 - PLANT page).
    final texts = [
      for (final p in buildLiveRiserPages(ref, null))
        for (final x in p.prims)
          if (x is SldLabel) x.text,
    ];
    expect(texts.where((t) => t.startsWith('$tag Fire break tank')),
        isNotEmpty);
    expect(texts.where((t) => t.startsWith('$tag Roof tank')), isEmpty);

    // No roof-tank-below-top for the break tank.
    final kinds = [for (final i in c.read(designIssuesProvider)) i.kind];
    expect(kinds.where((k) => k.startsWith('roof-tank-below-top')), isEmpty);

    // Domestic paths ignore BT: reserve GT 150 000 (backlog T-1) + RT
    // 30 000 = 180 000 L,
    // no tank-fill line, no auto capacity.
    final reserve = c.read(waterReserveProvider);
    expect(reserve.tanks.map((t) => t.tankId).toSet(), {'GT', 'RT'});
    expect(reserve.storedLitres, closeTo(180000, 1e-9));
    expect(c.read(tankFillsProvider).map((t) => t.tankId), isNot(contains('BT')));

    // Backlog K-4 — the G-003 master legend's inputs (the split the package
    // front matter reads): RT stays a genuine roof tank ('RT Roof tank'), BT
    // keys 'BT Fire break tank' with its roof-tank glyph.
    final legend = masterLegendComponentsOf(
        c.read(networkControllerProvider).network,
        c.read(fireBreakTankIdsProvider));
    expect(legend.components, contains(NodeComponent.roofTank));
    expect(legend.fireBreakTankComponents, {NodeComponent.roofTank});
    final legendRows = [
      for (final s in buildMasterLegendSections(
          components: legend.components,
          fireBreakTankComponents: legend.fireBreakTankComponents))
        for (final e in s.entries) '${e.code} ${e.meaning}',
    ];
    expect(legendRows, containsAll(['RT Roof tank', 'BT Fire break tank']));
  });
}
