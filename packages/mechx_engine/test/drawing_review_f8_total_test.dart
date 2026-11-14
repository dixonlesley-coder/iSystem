// Drawing review F8 (2026-11-13, drafting checklist item 21 "totals add up to
// the rows shown") — the panel-schedule TOTAL line prints BOTH figures,
// labelled: TERPASANG / CONNECTED = the sum of the DAYA cells printed, and
// KEBUTUHAN / DEMAND = the solved diversified demand (never re-derived). A
// standby way (demand factor 0) is marked in its row, and a way whose factor
// is below 1 prints it, so the demand is reproducible from the rows.
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const profile = PuilProfile();

  ElectricalCircuit way(String id, String name, double w, double df,
          {LoadKind kind = LoadKind.general}) =>
      ElectricalCircuit(
          id: id,
          name: name,
          loadKind: kind,
          phases: 3,
          loadW: w,
          cosPhi: 1,
          demandFactor: df,
          demandFactorUserSet: true,
          length: const Length(10));

  // A 3-phase board: a 4 000 W way at DF 0.7, a 6 000 W duty way at 1 and a
  // 6 000 W standby way at 0 (the duty/standby pair's machine that never runs
  // with its partner).
  final project = ElectricalProject(id: 'p', name: 'P', panels: [
    ElectricalPanel(
      id: 'PP',
      name: 'PP',
      voltage: const Voltage(400),
      circuits: [
        way('a', 'Lighting', 4000, 0.7),
        way('b', 'Duty set', 6000, 1),
        way('c', 'Standby set', 6000, 0),
      ],
    ),
  ]);
  final sys = computeSystem(profile, project);
  final sheet = buildElectricalSld(project: project, result: sys);
  final labels = [
    for (final p in sheet.prims)
      if (p is SldLabel) p.text
  ];

  test('CONNECTED = the sum of the DAYA cells shown', () {
    // DAYA cells: 4.000 + 6.000 + 6.000 WATT = 16 000 W.
    final daya = [
      for (final t in labels)
        if (RegExp(r'^[\d.]+ WATT$').hasMatch(t))
          int.parse(t.split(' ').first.replaceAll('.', ''))
    ];
    expect(daya, [4000, 6000, 6000]);
    final total = labels.singleWhere((t) => t.startsWith('TOTAL'));
    expect(total, contains('TERPASANG / CONNECTED 16.000 WATT'));
  });

  test('DEMAND = the solved demand (4000 x 0.7 + 6000 x 1 + 6000 x 0)', () {
    final pr = sys.panels['PP']!;
    // 2 800 + 6 000 + 0 = 8 800 W ⇒ 8.8 kW, the engine's own figure.
    expect(pr.demandW, closeTo(8800, 1e-6));
    final total = labels.singleWhere((t) => t.startsWith('TOTAL'));
    expect(total, contains('KEBUTUHAN / DEMAND 8.8kW / '));
  });

  test('the standby way is marked, the DF 0.7 way prints its factor', () {
    expect(labels, contains('Standby set (STANDBY)'));
    expect(labels, contains('Lighting DF 0.7'));
    expect(labels, contains('Duty set'));
    final keys = sheet.legend.map((e) => e.code).toList();
    expect(keys, containsAll(['TERPASANG / KEBUTUHAN', 'DF', 'STANDBY']));
    expect(sheet.legend.firstWhere((e) => e.code == 'STANDBY').meaning,
        contains('excluded from the demand'));
  });

  test('a paginated board: the last page total names its ways + sheets', () {
    final big = ElectricalProject(id: 'q', name: 'Q', panels: [
      ElectricalPanel(
        id: 'BIG',
        name: 'BIG',
        voltage: const Voltage(400),
        circuits: [
          for (var i = 0; i < 40; i++) way('w$i', 'Way $i', 1000, 1),
        ],
      ),
    ]);
    final s = computeSystem(profile, big);
    final pages = electricalBoardScheduleSheets(
        project: big, result: s, panelId: 'BIG', firstSheetNo: 3);
    expect(pages.length, greaterThan(1));
    String? totalOf(SldSheet sh) => [
          for (final p in sh.prims)
            if (p is SldLabel && p.text.startsWith('TOTAL')) p.text
        ].firstOrNull;
    for (final pg in pages.take(pages.length - 1)) {
      expect(totalOf(pg), isNull);
    }
    expect(
        totalOf(pages.last),
        startsWith('TOTAL (W1-W40, LEMBAR / SHEETS 3-${2 + pages.length})  '
            'TERPASANG / CONNECTED 40.000 WATT'));
  });
}
