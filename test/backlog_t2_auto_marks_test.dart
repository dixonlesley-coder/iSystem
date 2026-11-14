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
  // House: RT auto 650 L = 0.65 m3 → '0.7 m3' (one decimal) + '(auto)'.
  // Shophouse: GT 650 L → '0.7 m3', RT 250 L = 0.25 m3 → '0.3 m3', each
  // '(auto)'. Office: GT 10 000 L → schedule '10.0 m3', riser '10 m3', both
  // '(auto)'; the fire tank FT (never auto-sized) keeps 'capacity not set'.
  final cases = <String, ({Map<String, String> schedule, Set<String> riser})>{
    'house': (
      schedule: {'TK-01': '0.7 m3 (auto)'},
      riser: {'TK-01 Roof tank · 0.7 m3 (auto)', 'Roof tank: 0.7 m3 (auto)'},
    ),
    'shophouse': (
      schedule: {
        'TK-01': '0.7 m3 (auto)', 'TK-02': '0.3 m3 (auto)', //
        'TK-03': '0.7 m3 (auto)', 'TK-04': '0.3 m3 (auto)',
        'TK-05': '0.7 m3 (auto)', 'TK-06': '0.3 m3 (auto)',
      },
      riser: {
        'TK-01 Ground tank · 0.7 m3 (auto)',
        'TK-02 Roof tank · 0.3 m3 (auto)',
      },
    ),
    'office': (
      schedule: {'TK-01': '10.0 m3 (auto)', 'TK-02': 'capacity not set'},
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
