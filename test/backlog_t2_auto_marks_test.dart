// Backlog T-2 (2026-11-14) — an auto-sized tank capacity (backlog W-5) is
// marked '(auto)' wherever an issued drawing prints it: the equipment
// schedule (M-601) duty cell + one note, the riser (M-201) tank tag and the
// KETERANGAN notes (one explaining line). Strings only; the PDF and DXF of
// each drawing render the same strings (issued_drawing_parity_test).
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/inspector/project_panel.dart'
    show gatherEquipmentScheduleData;
import 'package:mechx/ui/schematic/schematic_export.dart'
    show buildLiveRiserPages;
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/report/sld_sheet.dart';

import 'reference_drawing_loader.dart';

Future<(ProviderContainer, WidgetRef)> _load(
    WidgetTester tester, String key) async {
  final spec = kRefDrawingSpecs.firstWhere((s) => s.key == key);
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
  return (c, ref);
}

List<String> _riserTexts(WidgetRef ref) => [
      for (final p in buildLiveRiserPages(ref, null))
        for (final x in p.prims)
          if (x is SldLabel) x.text,
    ];

const _note = '(auto) = sized by the app from daily demand; not entered';

void main() {
  // Backlog W-7 — the one capacity formatter: whole litres below 1 m3, m3 to
  // 3 decimals trimmed above (was one-decimal m3: 650 L printed '0.7 m3',
  // 250 L '0.3 m3'). House: RT auto 650 L → '650 L (auto)'. Shophouse
  // (T-3 'Ruko / rukan'): GT 500 L → '500 L (auto)', RT 250 L → '250 L
  // (auto)'. Office: GT 10 000 L → '10 m3 (auto)' on both M-601 (was '10.0
  // m3') and M-201; the fire tank FT (never auto-sized) keeps 'capacity not
  // set'.
  final cases = <String, ({Map<String, String> schedule, Set<String> riser})>{
    'house': (
      schedule: {'TK-01': '650 L (auto)'},
      riser: {'TK-01 Roof tank · 650 L (auto)', 'Roof tank: 650 L (auto)'},
    ),
    'shophouse': (
      schedule: {
        'TK-01': '500 L (auto)', 'TK-02': '250 L (auto)', //
        'TK-03': '500 L (auto)', 'TK-04': '250 L (auto)',
        'TK-05': '500 L (auto)', 'TK-06': '250 L (auto)',
      },
      riser: {
        'TK-01 Ground tank · 500 L (auto)',
        'TK-02 Roof tank · 250 L (auto)',
      },
    ),
    'office': (
      schedule: {'TK-01': '10 m3 (auto)', 'TK-02': 'capacity not set'},
      riser: {'TK-01 Ground tank · 10 m3 (auto)', 'Ground tank: 10 m3 (auto)'},
    ),
  };
  for (final MapEntry(:key, :value) in cases.entries) {
    testWidgets('$key: auto capacities marked on M-601 and M-201',
        (tester) async {
      final (_, ref) = await _load(tester, key);
      final data = gatherEquipmentScheduleData(ref);
      final rows = buildEquipmentScheduleRows(data);
      expect({
        for (final r in rows)
          if (r.category == EquipmentCategory.tank) r.tag: r.duty,
      }, value.schedule);
      // One explaining note on the schedule.
      expect(
          buildEquipmentScheduleMarkdown(data)
              .split('\n')
              .where((l) => l.contains('$_note.')),
          hasLength(1));
      final texts = _riserTexts(ref);
      for (final t in value.riser) {
        expect(texts, contains(t), reason: t);
      }
      expect(texts, contains(_note));
    });
  }
}
