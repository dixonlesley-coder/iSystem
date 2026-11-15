// Backlog T-3 (2026-11-14) — the SNI 03-7065-2005 Tabel 1 building-use
// presets (as quoted in secondary sources, `// VERIFY`): a pick fills the
// per-person figure (then an ordinary editable override) and records the use
// the calc report names; persisted additively, an unknown name loads as none.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/sizing/tank_fill.dart' show WaterReserve;
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

void main() {
  test('the table rows (hospital and per-m2 rows left out)', () {
    expect({for (final u in kSniDailyDemandUses) u.name: u.litres}, {
      'Rumah tinggal': 120, 'Rumah susun': 100, 'Asrama': 120, //
      'Ruko / rukan': 100, 'Kantor / pabrik': 50,
      'Gedung pertunjukan / bioskop': 10, 'Gedung serba guna': 25,
      'Restoran': 15, 'Hotel berbintang': 250, 'Peribadatan': 5,
    });
    expect(dailyDemandUseNamed('Rumah sakit'), isNull);
    // The occupancy fallbacks equal the rumah tinggal / kantor / gedung
    // pertunjukan rows.
    expect(dailyDemandPerPersonDefault(Occupancy.private), 120);
    expect(dailyDemandPerPersonDefault(Occupancy.public), 50);
    expect(dailyDemandPerPersonDefault(Occupancy.assembly), 10);
  });

  test('a pick fills the figure; an edit keeps it an override; undo is one '
      'step', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(populationProvider.notifier).set(40);
    pickDemandUseUndoable(c.read, 'Hotel berbintang');
    expect(c.read(demandPerPersonProvider), 250);
    expect(c.read(demandUseInForceProvider)?.unit, 'tempat tidur');
    expect(c.read(dailyDemandLitresProvider), 10000); // 40 x 250
    // Edit after the pick: an ordinary override; the preset no longer the
    // basis.
    c.read(demandPerPersonOverrideProvider.notifier).set(220);
    expect(c.read(dailyDemandLitresProvider), 8800); // 40 x 220
    expect(c.read(demandUseInForceProvider), isNull);
    // A fresh pick, then one undo restores both the use and the figure.
    pickDemandUseUndoable(c.read, 'Restoran');
    expect(c.read(demandPerPersonProvider), 15);
    c.read(historyProvider.notifier).undo();
    expect(c.read(demandUseProvider), 'Hotel berbintang');
    expect(c.read(demandPerPersonOverrideProvider), 220);
  });

  test('.mechx: the use round-trips; unknown / absent loads as none', () {
    const set = DesignSettings(demandUse: 'Rumah susun', demandPerPersonL: 100);
    expect(DesignSettings.fromJson(set.toJson()).demandUse, 'Rumah susun');
    expect(const DesignSettings().toJson().containsKey('demand_use'), isFalse);
    expect(DesignSettings.fromJson(const {}).demandUse, isNull);
    expect(
        DesignSettings.fromJson(const {'demand_use': 'Rumah sakit'}).demandUse,
        isNull);
  });

  test('the calc report names the basis', () {
    final md = buildCalcReportMarkdown(CalcReportData(
      projectName: 'P',
      date: '2026-11-14',
      standardsName: 'SNI',
      standardsRevision: 'x',
      verifyItems: const [],
      building: const BuildingLevels([Floor('G', Length(3))]),
      feedStrategy: 'downfeed',
      targetResidual: const Pressure(225000),
      dailyDemand: (population: 96, litresPerPerson: 100, litresPerDay: 9600),
      dailyDemandUse: dailyDemandUseNamed('Rumah susun'),
      waterReserve: const WaterReserve(tanks: [], dailyLitres: 9600),
    ));
    expect(
        md,
        contains('Daily demand basis: Rumah susun, 100 L/penghuni/day '
            '(SNI 03-7065-2005 Tabel 1)'));
    expect(md, contains('96 persons x 100 L/person/day = **9.60 m3/day**'));
  });
}
