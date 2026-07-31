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
      // Re-baselined 2026-07-30 (audit M12): the pump NPSH line prints the
      // suction-side NPSH_required estimate — for the fixture's 5 L/s duty
      // (2900·√0.005/160)^(4/3) = 1.39 m — instead of the old, physically
      // unrelated 15 % of the 30 m total head (4.5 m). Line count unchanged.
      // Re-baselined 2026-07-30 (audit M19): ONE line changed — the fire-pump
      // rating row's verdict. The flag behind it is the STANDARD MOTOR ladder
      // saturating, not a curve-acceptance failure, so the wording moved from
      // 'Rating curve within standard range' to 'Motor within standard frame
      // range' (and the oversized branch now names the action). Verified as the
      // SOLE delta: replacing the new sentence with the old one in the rendered
      // document reproduces 0xccecab38 exactly. Line count unchanged.
      expect(md.split('\n').length, 94);
      expect(fnv1a32(md), 0x109a3516);
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
        // 2026-07-30 (audit E7): both fixture boards are over the 15 %
        // imbalance limit with an IRREDUCIBLE spread (MDP has two single-phase
        // ways, SP-1 exactly one, over three lines), so each now carries the
        // INFO `phase-imbalance-inherent` note and the '## Warnings' section is
        // back — with info-level content, not warnings.
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
      // Feeder way row, whole: SP-1's incomer is 10 A (its 1500 W AC unit draws
      // 7.6 A), so the feeder carries the selectivity floor 1.6 × 10 = 16 A —
      // the first rung at/above it — on the 4 mm² 3φ trunk minimum.
      expect(
          md,
          contains('| Feeder SP-1 | feeder | 2.5 A | 3ph | 16 A MCB/C | 4 mm² '
              '| 30 m |'));
      // The warning section is INFO-only: `feeder-below-fed-demand` is cured by
      // the feeder floor, and both boards' imbalance is inherent (too few
      // single-phase ways for any assignment to even out) so the unactionable
      // `phase-imbalance` WARNING is still unraised — but audit E7 now prints
      // the irreducible figure as a note. No `- _WARN_:` bullet survives.
      expect(md, contains('## Warnings'));
      expect(md, isNot(contains('- _WARN_')));
      expect(md, contains('- _INFO_: Phase loading is unbalanced by '));
      expect(md, contains('inherent to the single-phase load set'));
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
      // to catch up. Re-baselined 2026-07-27: the fixture's SP-1 is imbalanced
      // and its feeder rounds below SP-1's worst-phase demand, so the new
      // judge-only `feeder-below-fed-demand` warning adds one bullet to the MDP
      // panel section AND one to the system Warnings section (+2 lines).
      // Re-baselined 2026-07-30 (phase-imbalance actionability): neither fixture
      // board can be evened out by ANY phase assignment (MDP has two
      // single-phase ways, SP-1 exactly one, over three lines), so the
      // unactionable `phase-imbalance` warning is no longer raised — 2 panel
      // bullets + 2 system bullets + the now-empty MDP warning line group
      // disappear (−5 lines), and the surviving feeder bullet names the
      // imbalance as inherent instead of offering a rebalance.
      // Re-baselined 2026-07-30 (selectivity-aware feeder sizing): the feeder to
      // SP-1 is now floored at 1.6 × SP-1's 10 A incomer ⇒ 16 A (was 6 A), which
      // clears SP-1's 7.6 A worst-phase demand — so the last
      // `feeder-below-fed-demand` warning is gone and with it the MDP panel
      // bullet group AND the whole '## Warnings' section (−6 lines). The feeder
      // way row prints the 16 A device.
      // Re-baselined 2026-07-30 (audit E7): an irreducible over-limit imbalance
      // is now an INFO note instead of silence, and BOTH fixture boards qualify
      // — 2 panel bullets + their 2 bullet-group lines, the restored
      // '## Warnings' heading + its blank line, and 2 system bullets + 1 blank
      // line (+9 lines: 78 -> 87).
      expect(md.split('\n').length, 87);
      expect(fnv1a32(md), 0x775ce2e6);
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
        // The embedded electrical body carries the audit-E7 inherent-imbalance
        // notes (see the standalone pin above), so its '## Warnings' section is
        // present — info-level content only.
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
      // Re-baselined 2026-07-27: the electrical body gained the two
      // `feeder-below-fed-demand` warning lines (see the standalone pin above).
      // Re-baselined 2026-07-30: the electrical body dropped the five
      // unactionable phase-imbalance lines (see the standalone pin above).
      // Re-baselined again 2026-07-30 (selectivity-aware feeder sizing): the
      // electrical body's last warning is cured by the feeder floor, dropping
      // its panel bullet group and '## Warnings' section (−6 lines), and its
      // feeder way row prints the floored 16 A device.
      // Re-baselined 2026-07-30 (audit M12): the embedded mechanical body's
      // pump NPSH line now carries the suction-side NPSH_required estimate
      // (1.4 m, not 4.5 m) — see the mechanical pin above. Line count unchanged.
      // Re-baselined 2026-07-30 (audit E7): the embedded electrical body gained
      // the same +9 lines as the standalone pin (the irreducible-imbalance INFO
      // notes on both boards + the restored '## Warnings' section): 219 -> 228.
      expect(md.split('\n').length, 228);
      expect(fnv1a32(md), 0x47b44e65);
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
