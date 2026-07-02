/// Tests for the report-body localisation surface (`report_strings.dart`) and
/// the ID rendering of the four flagship report builders.
///
/// Two contracts are pinned here:
///   1. EN/ID key parity — both tables carry EXACTLY the [RptStringKey] set,
///      and every `{placeholder}` in an EN template appears in its ID twin
///      (mirrors the app's `i18n_test.dart` parity pattern).
///   2. Default EN is byte-identical to the characterization output while ID
///      carries the natural Indonesian consulting-report headings — proving the
///      thread-through is additive (EN untouched) and the ID path is live.
library;

import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/report/mep_report.dart';
import 'package:mechx_engine/report/report_strings.dart';
import 'package:test/test.dart';

import 'report_test_fixtures.dart';

/// All `#`-prefixed lines of [md], in order (matches the characterization test).
List<String> _headingsOf(String md) =>
    md.split('\n').where((l) => l.startsWith('#')).toList();

void main() {
  // ── Key + placeholder parity ──────────────────────────────────────────────
  group('EN/ID report-string parity', () {
    test('both tables carry exactly the RptStringKey enum (no orphans)', () {
      final en = kReportStringsEn.keys.toSet();
      final id = kReportStringsId.keys.toSet();
      expect(id, en, reason: 'EN and ID tables must carry identical key sets');
      expect(en, RptStringKey.values.toSet(),
          reason: 'EN must cover the whole RptStringKey enum');
    });

    test('every {placeholder} in an EN template appears in its ID template', () {
      final placeholder = RegExp(r'\{(\w+)\}');
      for (final key in RptStringKey.values) {
        final enP = placeholder
            .allMatches(kReportStringsEn[key]!)
            .map((m) => m.group(1))
            .toSet();
        if (enP.isEmpty) continue;
        final idP = placeholder
            .allMatches(kReportStringsId[key]!)
            .map((m) => m.group(1))
            .toSet();
        expect(idP, enP,
            reason: 'ID template for $key must carry the same placeholders as '
                'EN');
      }
    });

    test('every value resolves non-empty under each locale', () {
      for (final loc in ReportLocale.values) {
        final s = ReportStrings(loc);
        for (final key in RptStringKey.values) {
          expect(s(key), isNotEmpty, reason: '$key under $loc');
        }
      }
    });

    test('format substitutes {name} placeholders and falls back to EN', () {
      const en = ReportStrings.en();
      const id = ReportStrings.id();
      // A parameterised template substitutes on both locales, no stray braces.
      final enTitle = en.format(RptStringKey.calcTitle, {'name': 'Menara'});
      expect(enTitle, 'MEP Calculation Report — Menara');
      final idTitle = id.format(RptStringKey.calcTitle, {'name': 'Menara'});
      expect(idTitle, 'LAPORAN PERHITUNGAN MEP — Menara');
      expect(idTitle, isNot(contains('{')));
    });
  });

  // ── Mechanical calc report: EN byte-identical, ID localized ───────────────
  group('mechanical calc report locale', () {
    final data = richMechData();

    test('explicit EN equals the default (byte-identical)', () {
      // The default path (no strings arg) is what the characterization pins
      // capture; passing ReportStrings.en() explicitly must not move a byte.
      expect(buildCalcReportMarkdown(data, const ReportStrings.en()),
          buildCalcReportMarkdown(data));
    });

    test('ID carries the Indonesian consulting-report headings', () {
      final id = buildCalcReportMarkdown(data, const ReportStrings.id());
      final headings = _headingsOf(id);
      expect(headings, contains('# LAPORAN PERHITUNGAN MEP — Menara Kencana'));
      expect(headings, contains('## Dasar Perancangan'));
      expect(headings, contains('## Bangunan'));
      expect(headings, contains('## Air hujan'));
      // A localized key label + a localized value connective survive.
      expect(id, contains('- Lantai:'));
      expect(id, contains('(metode rasional)'));
      // Every {placeholder} in every rendered template was substituted.
      expect(id, isNot(contains('{')));
    });

    test('ID differs from EN (the translation is actually applied)', () {
      expect(buildCalcReportMarkdown(data, const ReportStrings.id()),
          isNot(equals(buildCalcReportMarkdown(data))));
    });
  });

  // ── Electrical calc report ────────────────────────────────────────────────
  group('electrical calc report locale', () {
    final data = richElecData();

    test('explicit EN equals the default (byte-identical)', () {
      expect(buildElectricalCalcReport(data, const ReportStrings.en()),
          buildElectricalCalcReport(data));
    });

    test('ID carries Indonesian headings and labels', () {
      final id = buildElectricalCalcReport(data, const ReportStrings.id());
      final headings = _headingsOf(id);
      expect(
          headings, contains('# Laporan perhitungan kelistrikan — Menara '
              'Kencana'));
      expect(headings, contains('## Ringkasan pasokan'));
      expect(headings, contains('## Pembumian'));
      // A localized panel bullet (Indonesian for "Main busbar").
      expect(id, contains('- Busbar utama:'));
      expect(id, isNot(contains('{')));
    });
  });

  // ── Unified MEP report ────────────────────────────────────────────────────
  group('unified MEP report locale', () {
    final mech = richMechData();
    final elec = richElecData();
    const compliance = ComplianceSummary(
      date: '2026-07-02',
      items: [
        ComplianceItem('Air velocities within band',
            pass: true, detail: 'all within band'),
        ComplianceItem('Standards verification',
            pass: false, detail: '2 unverified values'),
      ],
    );

    test('explicit EN equals the default (byte-identical)', () {
      expect(
        buildMepUnifiedReport(
            mechanical: mech,
            electrical: elec,
            compliance: compliance,
            strings: const ReportStrings.en()),
        buildMepUnifiedReport(
            mechanical: mech, electrical: elec, compliance: compliance),
      );
    });

    test('ID carries the unified head + compliance verdict in Indonesian', () {
      final id = buildMepUnifiedReport(
          mechanical: mech,
          electrical: elec,
          compliance: compliance,
          strings: const ReportStrings.id());
      final headings = _headingsOf(id);
      expect(headings,
          contains('# Laporan Layanan Bangunan MEP — Menara Kencana'));
      expect(headings, contains('## Ringkasan kepatuhan'));
      expect(headings, contains('# Mekanikal & plambing'));
      // The overall compliance verdict is localized (fixture has a failure).
      expect(id, contains('keseluruhan: **PERLU TINJAUAN**'));
      expect(id, isNot(contains('{')));
    });
  });

  // ── Equipment schedule ────────────────────────────────────────────────────
  group('equipment schedule locale', () {
    final data = richEquipmentData();

    test('explicit EN equals the default (byte-identical)', () {
      expect(buildEquipmentScheduleMarkdown(data, const ReportStrings.en()),
          buildEquipmentScheduleMarkdown(data));
    });

    test('ID carries the Indonesian section headings + project line', () {
      final id = buildEquipmentScheduleMarkdown(data, const ReportStrings.id());
      final headings = _headingsOf(id);
      expect(headings, contains('# Jadwal peralatan'));
      expect(headings, contains('## Pompa'));
      expect(headings, contains('## Panel listrik'));
      // The hard-break project line keeps its two-space break, localized label.
      expect(id, contains('**Proyek:** Menara Kencana  \n**Tanggal:** '
          '2026-07-02'));
      expect(id, isNot(contains('{')));
    });
  });
}
