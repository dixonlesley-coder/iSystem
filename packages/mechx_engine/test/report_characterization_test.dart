/// CHARACTERIZATION pins for the four flagship Markdown report builders.
///
/// These tests capture the EXACT output of `buildCalcReportMarkdown`,
/// `buildElectricalCalcReport`, `buildMepUnifiedReport` and
/// `buildEquipmentScheduleMarkdown` for rich fixtures — headings in order,
/// every table header row, line count, and an FNV-1a hash of the whole string
/// — recorded BEFORE the block-model refactor (report_blocks.dart) and kept
/// GREEN through it: the block builders + `renderRptMarkdown` must reproduce
/// this output byte-identically.
///
/// If one of these pins breaks, the Markdown deliverable changed shape. That
/// is only acceptable for a deliberate, spec'd formatting change — update the
/// pin in the same commit and say why.
library;

import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/report/mep_report.dart';
import 'package:test/test.dart';

import 'report_test_fixtures.dart';

/// All `#`-prefixed lines of [md], in order.
List<String> headingsOf(String md) =>
    md.split('\n').where((l) => l.startsWith('#')).toList();

void main() {
  // ── Mechanical calculation report ─────────────────────────────────────────
  group('buildCalcReportMarkdown characterization', () {
    final md = buildCalcReportMarkdown(richMechData());

    test('headings in order', () {
      expect(headingsOf(md), const [
        '# MEP Calculation Report — Menara Kencana',
        '## Design basis',
        '## Revision history',
        // N25: ASCII heading (was '## ⚠ Unverified values').
        '## Unverified values',
        '## Building',
        '## Water supply',
        '### Pressure zones (PRV)',
        '## Fire protection',
        '## HVAC (air)',
        '## Storm / rainwater',
        '## Bill of materials',
        '### Fittings (estimated)',
      ]);
    });

    test('every table header row present, with its exact separator', () {
      expect(md, contains('| Date | Description |\n|---|---|\n'));
      expect(md,
          contains('| Floor | Height (m) | Elevation (m) |\n|---|---:|---:|\n'));
      expect(
          md,
          contains('| Zone (floors) | Top residual (kPa) | Bottom static (kPa) '
              '| Within limit |\n|---|---:|---:|---|\n'));
      // N14: the BOM table gained a Material column. N13: + a Tag column.
      expect(
          md,
          contains('| Service | Type | Tag | Size | Material | Length (m) | '
              'Segments |\n|---|---|---|---|---|---:|---:|\n'));
      expect(md,
          contains('| Service | Fitting | Size | Count |\n|---|---|---|---:|\n'));
    });

    test('load-bearing rows survive verbatim', () {
      // Revision-table pipe escaping.
      expect(md, contains(r'| 2026-07-02 | Pipe\|escape check |'));
      // The tight unverified heading (NO blank line after it) — N25 ASCII.
      expect(md, contains('## Unverified values\nThe following values'));
      // Operating-point sub-bullets keep their two-space indent.
      expect(md, contains('\n  - System curve: static 15.0 m'));
      // The closing advisory footer after the rule.
      expect(md, contains('\n---\n_Sizes are auto-calculated'));
    });

    test('whole-document pin (FNV-1a + line count)', () {
      // Re-baselined 2026-07-06 (Wave 7 N14/N18/N25): the BOM table gained a
      // Material column, the size cell uses the one Ø/DN/W×H notation, the
      // standards line is a governed statement and the Unverified heading is
      // ASCII. Re-baselined again 2026-07-06 (Wave 7 N13): the BOM table gained a
      // Tag column (the shared element tag) between Type and Size — the fixture's
      // run line now reads `CW-F1`, the duct riser `SA-R1`. Line count unchanged.
      expect(md.split('\n').length, 94);
      expect(fnv1a32(md), 0xa529ba98);
    });
  });

  // ── Electrical calculation report ─────────────────────────────────────────
  group('buildElectricalCalcReport characterization', () {
    final md = buildElectricalCalcReport(richElecData());

    test('headings in order', () {
      expect(headingsOf(md), const [
        '# Electrical calculation report — Menara Kencana',
        '## Design basis',
        '## Revision history',
        '## Supply summary',
        '## Panels',
        '### MDP [MDP] — 3-phase, 400 V',
        '### SP-1 — 3-phase, 400 V',
        '## Earthing',
        '## Power one-line',
        '### Source interlocks',
        '## Warnings',
        '## Unverified values',
      ]);
    });

    test('every table header row present, with its exact separator', () {
      expect(md, contains('| Date | Description |\n| --- | --- |\n'));
      expect(
          md,
          contains('| Way | Type | Ib | Phase | Breaker | Cable | Length '
              '| Vdrop (cum) | RCD |\n'
              '| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n'));
    });

    test('load-bearing rows survive verbatim', () {
      // Feeder way row (the second panel is fed through it).
      expect(md, contains('| Feeder SP-1 | feeder |'));
      // Per-panel warning bullet style.
      expect(md, contains('- _WARN_: Phase loading is unbalanced'));
      // Interlock bullet under its own sub-heading.
      expect(md,
          contains('### Source interlocks\n\n- _mechanical_: ATS mechanical'));
    });

    test('whole-document pin (FNV-1a + line count)', () {
      // Recorded 2026-07-02 against the pre-refactor string builder.
      // Re-baselined 2026-07-06 (Wave 7 N8): the per-way circuits table gained a
      // Length column (geo-derived run length, driving the printed Vdrop) between
      // Cable and Vdrop — the header/separator widened from 8 to 9 columns and
      // each way row gained a length/'—' cell. Line count is unchanged (no new
      // rows). The unified-report pin below already reflects this column (it was
      // re-baselined with the column present); this standalone pin was the last
      // to catch up.
      expect(md.split('\n').length, 87);
      expect(fnv1a32(md), 0xe8363417);
    });
  });

  // ── Unified MEP report ────────────────────────────────────────────────────
  group('buildMepUnifiedReport characterization', () {
    final md = buildMepUnifiedReport(
      mechanical: richMechData(),
      electrical: richElecData(),
      compliance: const ComplianceSummary(
        date: '2026-07-02',
        items: [
          ComplianceItem('Air velocities within band',
              pass: true, detail: 'all within band'),
          ComplianceItem('Standards verification',
              pass: false, detail: '2 unverified values'),
        ],
      ),
    );

    test('headings in order (unified head + both demoted bodies)', () {
      expect(headingsOf(md), const [
        '# MEP Building-Services Report — Menara Kencana',
        '## Design basis',
        '### Mechanical / plumbing',
        '### Electrical',
        '## Compliance summary',
        '# Mechanical & plumbing',
        '## Design basis',
        '## Revision history',
        // N25: ASCII heading in the embedded mechanical body.
        '## Unverified values',
        '## Building',
        '## Water supply',
        '### Pressure zones (PRV)',
        '## Fire protection',
        '## HVAC (air)',
        '## Storm / rainwater',
        '## Bill of materials',
        '### Fittings (estimated)',
        '# Electrical',
        '## Design basis',
        '## Revision history',
        '## Supply summary',
        '## Panels',
        '### MDP [MDP] — 3-phase, 400 V',
        '### SP-1 — 3-phase, 400 V',
        '## Earthing',
        '## Power one-line',
        '### Source interlocks',
        '## Warnings',
        '## Unverified values',
        '# Revision history',
        '## Revision history',
      ]);
    });

    test('compliance table + overall verdict', () {
      expect(md, contains('| Check | Verdict | Detail |\n|---|---|---|\n'));
      expect(md,
          contains('| Air velocities within band | PASS | all within band |'));
      expect(md, contains('overall: **REVIEW REQUIRED**'));
    });

    test('whole-document pin (FNV-1a + line count)', () {
      // Re-baselined 2026-07-06 (Wave 7): the embedded mechanical body carries
      // the N14/N18/N25 changes (BOM Material column, Ø/DN notation, governed
      // standards line, ASCII Unverified heading). Re-baselined again 2026-07-06
      // (Wave 7 N13): the embedded mechanical BOM table gained the shared-element
      // Tag column (run `CW-F1`, duct riser `SA-R1`). Line count is unchanged.
      expect(md.split('\n').length, 228);
      expect(fnv1a32(md), 0x681c9890);
    });
  });

  // ── Equipment schedule ────────────────────────────────────────────────────
  group('buildEquipmentScheduleMarkdown characterization', () {
    final md = buildEquipmentScheduleMarkdown(richEquipmentData());

    test('headings in order', () {
      expect(headingsOf(md), const [
        '# Equipment schedule',
        '## Pumps',
        '## Fans',
        '## Air-handling (AHU / FCU / AC)',
        '## Electrical panels',
      ]);
    });

    test('table header + the Markdown hard-break project line', () {
      expect(
          md,
          contains('| Tag | Service | Duty | Size | Model / spec | Qty |\n'
              '| --- | --- | --- | --- | --- | --- |\n'));
      // The project line carries a trailing two-space Markdown hard break.
      expect(md, contains('**Project:** Menara Kencana  \n**Date:** 2026-07-02'));
    });

    test('whole-document pin (FNV-1a + line count)', () {
      // Recorded 2026-07-02 against the pre-refactor string builder.
      expect(md.split('\n').length, 33);
      expect(fnv1a32(md), 0x12a57440);
    });
  });
}
