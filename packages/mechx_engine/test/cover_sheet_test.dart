import 'package:mechx_engine/electrical/cable_family.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/cover_sheet.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/sld_export.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:test/test.dart';

// All SldLabel texts on a sheet, joined — a cheap way to assert content.
String _labels(SldSheet s) =>
    s.prims.whereType<SldLabel>().map((l) => l.text).join(' | ');

void main() {
  group('N24 — cable-family descriptions are distinct', () {
    test('NYY and NYM no longer share the identical "Cable construction"', () {
      final nyy = cableFamilyDescription('NYY');
      final nym = cableFamilyDescription('NYM');
      expect(nyy, isNot(equals(nym)));
      expect(nyy, isNot(equals('Cable construction')));
      expect(nym, isNot(equals('Cable construction')));
      // Each family gets a distinct, real description.
      final all = [
        for (final f in ['NYY', 'NYM', 'NYA', 'NYAF', 'FRC', 'BC'])
          cableFamilyDescription(f)
      ];
      expect(all.toSet().length, all.length, reason: 'all descriptions differ');
    });

    test('an unknown family degrades to a labelled generic (never blank)', () {
      final d = cableFamilyDescription('XYZ');
      expect(d, isNotEmpty);
      expect(d, contains('XYZ'));
    });
  });

  group('N21 — front matter sheets', () {
    test('DrawingListEntry.fromChrome reads number/title/rev/date', () {
      const chrome = DrawingChrome(
        drawingNumber: 'M-101',
        revisionNumber: 'Rev. 0',
        drawingTitle: 'GROUND FLOOR PLUMBING',
        dateString: '2026-07-06',
      );
      final e = DrawingListEntry.fromChrome(chrome);
      expect(e.number, 'M-101');
      expect(e.title, 'GROUND FLOOR PLUMBING');
      expect(e.revision, 'Rev. 0');
      expect(e.date, '2026-07-06');
    });

    test('fromChrome falls back to the supplied title when chrome has none', () {
      const chrome = DrawingChrome(drawingNumber: 'E-201');
      final e =
          DrawingListEntry.fromChrome(chrome, fallbackTitle: 'ELECTRICAL SLD');
      expect(e.title, 'ELECTRICAL SLD');
    });

    test('cover sheet carries the project + identity register', () {
      final s = buildCoverSheet(
        projectName: 'Menara Contoh',
        clientName: 'PT Contoh',
        drawingNumber: 'G-001',
        revision: 'Rev. 0',
        date: '2026-07-06',
        sheetCount: 6,
      );
      final text = _labels(s);
      expect(text, contains('Menara Contoh'));
      expect(text, contains('PT Contoh'));
      expect(text, contains('G-001'));
      expect(text, contains('6'));
      expect(s.prims, isNotEmpty);
    });

    test('drawing-list sheet lists every entry with its number + title', () {
      final drawings = [
        const DrawingListEntry(
            number: 'M-101', title: 'PLAN LANTAI 1', revision: 'Rev. 0'),
        const DrawingListEntry(
            number: 'M-201', title: 'RISER AIR BERSIH', revision: 'Rev. 0'),
        const DrawingListEntry(
            number: 'E-201', title: 'DIAGRAM PANEL', revision: 'Rev. 0'),
      ];
      final s = buildDrawingListSheet(drawings, projectName: 'Menara Contoh');
      final text = _labels(s);
      for (final d in drawings) {
        expect(text, contains(d.number));
        expect(text, contains(d.title));
      }
      expect(text, contains('DAFTAR GAMBAR'));
    });

    test('front matter is exactly cover + list + notes', () {
      final sheets = buildSubmittalFrontMatter(
        projectName: 'Menara Contoh',
        drawings: const [
          DrawingListEntry(number: 'M-101', title: 'PLAN'),
        ],
        services: const [ServiceType.coldWater, ServiceType.duct],
        components: const [NodeComponent.pump, NodeComponent.ahu],
        cableFamilies: const ['NYY', 'NYM'],
      );
      expect(sheets.length, 3);
      expect(kFrontMatterDiagramTitles.length, 3);
      // Renders to a real 3-page PDF via the shared SLD path.
      final pdf = sldSheetsToPdf(sheets,
          diagramTitles: kFrontMatterDiagramTitles,
          projectName: 'Menara Contoh');
      expect(pdf, isNotEmpty);
      expect(String.fromCharCodes(pdf.take(8)), '%PDF-1.4');
    });
  });

  group('N24 — master legend dictionary', () {
    test('has the plan MARKERS the plan draws but keys nowhere', () {
      final sections = buildMasterLegendSections(
        services: const [ServiceType.coldWater, ServiceType.vent],
        components: const [NodeComponent.pump],
        cableFamilies: const ['NYY'],
      );
      final codes = [
        for (final sec in sections)
          for (final e in sec.entries) e.code,
      ];
      // UP / DN / flow chevron / fixture terminal are present.
      expect(codes, containsAll(<String>['UP', 'DN', '>', 'FIX']));
      // Cold water + vent line conventions.
      expect(codes, contains('CW'));
      expect(codes, contains('V'));
      // The vent line is dashed, cold water solid (line convention honesty).
      MasterLegendEntry find(String c) =>
          sections.expand((s) => s.entries).firstWhere((e) => e.code == c);
      expect(find('V').kind, LegendGlyphKind.lineDashed);
      expect(find('CW').kind, LegendGlyphKind.line);
    });

    test('the plan-legend subset is a true subset of the master dictionary',
        () {
      const services = [ServiceType.coldWater, ServiceType.duct];
      const components = [NodeComponent.pump, NodeComponent.supplyDiffuser];
      final master = {
        for (final s in buildMasterLegendSections(
            services: services,
            components: components,
            cableFamilies: const ['NYY']))
          for (final e in s.entries) e.code,
      };
      final subset =
          planLegendSubset(services: services, components: components)
              .map((e) => e.code)
              .toSet();
      expect(subset, isNotEmpty);
      expect(master.containsAll(subset), isTrue);
      // The subset excludes the electrical CABLES section.
      expect(subset, isNot(contains('NYY')));
    });

    test('cables section carries each family DISTINCT description', () {
      final sections = buildMasterLegendSections(
        services: const [],
        components: const [],
        cableFamilies: const ['NYY', 'NYM'],
      );
      final cables =
          sections.firstWhere((s) => s.title.contains('CABLES')).entries;
      final meanings = cables.map((e) => e.meaning).toList();
      expect(meanings.toSet().length, meanings.length);
    });
  });

  test('component legend code + name are exhaustive over NodeComponent', () {
    for (final c in NodeComponent.values) {
      expect(componentLegendCode(c), isNotEmpty);
      expect(componentLegendName(c), isNotEmpty);
    }
  });
}
