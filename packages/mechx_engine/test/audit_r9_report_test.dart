// Round 9 (2026-10-18) — report-parity findings:
//   pdf-citation-garbled   every non-ASCII character in the engine's strings
//                          reaches the report PDF legibly (no new '?');
//   pdf-chrome-english     the PDF cover roles + footer localize (ID);
//   enum-names-leak        no raw Dart enum identifier in a report body;
//   engine-messages        the PUIL 'Standard:' line is the edition label, the
//                          provenance paragraph rides the honesty surface;
//   quotation-separators   proposal quantities use the money convention.
import 'dart:convert';
import 'dart:io';

import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/number_format.dart';
import 'package:mechx_engine/report/report_blocks.dart';
import 'package:mechx_engine/report/report_pdf.dart';
import 'package:mechx_engine/report/report_strings.dart';
import 'package:mechx_engine/sizing/bom.dart' show FittingType;
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:test/test.dart';

import 'report_test_fixtures.dart';

int _q(String s) => '?'.allMatches(s).length;

void main() {
  group('report-parity-pdf-citation-garbled', () {
    test('the cited clauses survive: § → cl., ± → +/-, ρ → rho', () {
      expect(pdfSafeText('IEC 60364-4-44 §443 / PUIL 2011 §3.20'),
          'IEC 60364-4-44 cl.443 / PUIL 2011 cl.3.20');
      expect(pdfSafeText('±5 %'), '+/-5 %');
      expect(pdfSafeText('ρ_Cu at 70 °C'), 'rho_Cu at 70 degC');
      expect(pdfSafeText('½″…12″'), '1/2in...12in');
    });

    // Property over the WHOLE engine: every non-ASCII rune used on a code
    // (non-comment) line of lib/** is transliterated, never '?'. Adding a new
    // symbol to any string without a mapping fails here.
    test('property: every non-ASCII rune in lib/** maps to non-"?"', () {
      // The PDF binary-marker bytes (%âãÏÓ) are not report text.
      const pdfMarker = {0xE2, 0xE3, 0xCF, 0xD3};
      final runes = <int>{};
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        for (final line in f.readAsLinesSync()) {
          final t = line.trimLeft();
          if (t.startsWith('//') || t.startsWith('*')) continue;
          for (final r in line.runes) {
            if (r > 0x7e && !pdfMarker.contains(r)) runes.add(r);
          }
        }
      }
      expect(runes, isNotEmpty);
      for (final r in runes) {
        final out = pdfSafeText(String.fromCharCode(r));
        expect(out.contains('?'), isFalse,
            reason: 'U+${r.toRadixString(16)} (${String.fromCharCode(r)})');
      }
    });

    test('every SNI + PUIL verify string prints without a new "?"', () {
      final strings = <String>[
        for (final v in const SniProfile().verifyChecklist) ...[
          v.citation,
          v.note ?? '',
        ],
        for (final v in const PuilProfile().verifyChecklist) ...[
          v.citation,
          v.note ?? '',
        ],
        const PuilProfile().provenanceNote,
      ];
      for (final s in strings) {
        expect(_q(pdfSafeText(s)), _q(s), reason: s);
      }
    });
  });

  group('report-parity-pdf-chrome-english', () {
    final blocks = <RptBlock>[const RptParagraph('Isi.')];
    test('ID: cover roles + "Halaman X dari Y" footer', () {
      final pdf = latin1.decode(reportBlocksToPdf(blocks,
          docTitle: 'Laporan',
          projectName: 'Proyek',
          preparedBy: 'AB',
          checkedBy: 'CD',
          approvedBy: 'EF',
          strings: const ReportStrings.id()));
      expect(pdf, contains('Halaman 1 dari 1'));
      expect(pdf, contains('Disiapkan oleh'));
      expect(pdf, contains('Diperiksa oleh'));
      expect(pdf, contains('Disetujui oleh'));
      expect(pdf, isNot(contains('Page 1 of 1')));
      expect(pdf, isNot(contains('Prepared by')));
    });
    test('EN default is byte-identical to explicit EN', () {
      final a = reportBlocksToPdf(blocks,
          docTitle: 'R', projectName: 'P', preparedBy: 'AB');
      final b = reportBlocksToPdf(blocks,
          docTitle: 'R',
          projectName: 'P',
          preparedBy: 'AB',
          strings: const ReportStrings.en());
      expect(a, b);
      expect(latin1.decode(a), contains('Page 1 of 1'));
    });
  });

  group('report-parity-enum-names-leak', () {
    final camel = RegExp(r'^[a-z]+[A-Z0-9]');
    for (final s in [const ReportStrings.en(), const ReportStrings.id()]) {
      test('${s.locale}: no label is a raw camelCase identifier', () {
        final labels = [
          for (final k in LoadKind.values) loadKindLabel(k, s),
          for (final k in PowerNodeKind.values) powerNodeKindLabel(k, s),
          for (final k in PowerInterlockKind.values) interlockKindLabel(k, s),
          for (final h in FireHazardClass.values) fireHazardLabel(h, s),
          for (final t in FittingType.values) fittingTypeLabel(t, s),
        ];
        for (final l in labels) {
          expect(camel.hasMatch(l), isFalse, reason: l);
        }
      });
    }
    test('ID uses the SNI hazard term', () {
      expect(fireHazardLabel(
              FireHazardClass.ordinaryHazard1, const ReportStrings.id()),
          'Bahaya Kebakaran Sedang Kelompok I');
    });
  });

  group('report-parity-engine-messages-english', () {
    test('PUIL revision is a short edition label', () {
      expect(const PuilProfile().revision,
          'PUIL 2011 (SNI 0225:2011, amd. 2020)');
      expect(const PuilProfile().revision.length, lessThan(60));
    });
    test('the provenance note prints in the Unverified section', () {
      final base = richElecData();
      final md = buildElectricalCalcReport(ElectricalCalcReportData(
        projectName: base.projectName,
        date: base.date,
        standardsName: base.standardsName,
        standardsRevision: base.standardsRevision,
        project: base.project,
        result: base.result,
        verifyItems: base.verifyItems,
        standardsProvenance: const PuilProfile().provenanceNote,
      ));
      final unverified = md.substring(md.indexOf('## Unverified values'));
      expect(unverified, contains('PanelMaker reference app'));
      final head = md.substring(0, md.indexOf('## Design basis'));
      expect(head, isNot(contains('PanelMaker')));
    });
    test('ID warnings carry a localized lead-in naming the code', () {
      final md = buildElectricalCalcReport(
          richElecData(), const ReportStrings.id());
      expect(md,
          contains('[phase-imbalance-inherent] (pesan dalam bahasa Inggris) '));
    });
  });

  group('report-parity-quotation-separators', () {
    test('quantity() follows the money() convention', () {
      expect(quantity(1234.567), '1.234,57');
      expect(quantity(246.9), '246,9');
      expect(quantity(1234), '1.234');
      expect(quantity(12), '12');
      expect(money(45000, dp: 2), '45.000,00');
    });
  });
}
