// Round 23 (2026-10-18) — the issued-document half of the round-23 audit:
//
//   report-pdf-cover-standards-overflow    cover runs wrap inside the page
//   report-pdf-table-midword-breaks        no word is split while room exists
//   report-pdf-figure-illegible            figure labels never print < 5 pt
//   report-pdf-orphan-headings             a heading starts on its body's page
//   report-pdf-glyph-transliteration       WinAnsi glyphs (Ø, ·, ²) print
//   report-pdf-mep-duplicate-revision-heading
//   report-pdf-literal-md-rule             '---' is a rule, not text
//   report-pdf-board-order-reversed        boards list in pre-order
//   elec-drafting-2-1  the electrical riser + overview paginate at 7 pt
//   elec-drafting-2-2  power one-line lanes never run collinear; MV sub-label
//   elec-drafting-2-3  the electrical layout DXF is in world millimetres
//   elec-drafting-2-4  a right-hand child's feeder tag sits on its own bus
//   elec-drafting-2-5  ACB frames; a saturated incomer says OVER RANGE
//   elec-drafting-2-6  the riser spine sits beside a ground-floor root
//   elec-drafting-2-7  a capacitor-only board prints its kvar
import 'dart:convert' show latin1;
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart'
    show powerOneLineUtilitySub;
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/drawing_chrome.dart'
    show DrawingChrome, kMinPlotLabelPt;
import 'package:mechx_engine/report/electrical_pagination.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart'
    show sldSinglePageMinLabelPt;
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/mep_report.dart';
import 'package:mechx_engine/report/report_blocks.dart';
import 'package:mechx_engine/report/report_pdf.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'report_test_fixtures.dart';

const _profile = PuilProfile();
const _pageW = 595.28;
const _margin = 48.0;
const _contentW = _pageW - 2 * _margin;

/// Page content streams of a PDF, in order (page 0 = the report cover).
List<String> _streams(List<int> bytes) => [
      for (final m in RegExp(r'stream\n(.*?)\nendstream', dotAll: true)
          .allMatches(latin1.decode(bytes)))
        m.group(1)!,
    ];

ElectricalCircuit _light(String id, {double w = 600}) => ElectricalCircuit(
    id: id,
    name: 'Lighting $id',
    loadKind: LoadKind.lighting,
    isLighting: true,
    loadW: w,
    length: const Length(15));

ElectricalCircuit _feeder(String id, String to) => ElectricalCircuit(
    id: id,
    name: 'Feeder $to',
    loadKind: LoadKind.feeder,
    feedsPanelId: to,
    length: const Length(20));

/// MDP feeding [n] sub-boards in drawn order, each with [ways] lighting ways.
ElectricalProject _fan(int n, {int ways = 4, int floors = 0}) =>
    ElectricalProject(id: 'fan', name: 'Fan', panels: [
      ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          layoutPos: floors > 0
              ? const LayoutPos(sheetId: 's', floorIndex: 0, x: 0, y: 0)
              : null,
          circuits: [for (var i = 1; i <= n; i++) _feeder('f$i', 'LP$i')]),
      for (var i = 1; i <= n; i++)
        ElectricalPanel(
            id: 'LP$i',
            name: 'LP-$i',
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f$i',
            layoutPos: floors > 0
                ? LayoutPos(sheetId: 's', floorIndex: i % floors, x: 0, y: 0)
                : null,
            circuits: [for (var k = 0; k < ways; k++) _light('l$i-$k')]),
    ]);

void main() {
  // ── report PDF ────────────────────────────────────────────────────────────
  group('report-pdf-cover-standards-overflow', () {
    test('the real standards provenance line wraps inside the content width',
        () {
      const sni = SniProfile();
      final line = '${sni.name} (${sni.revision})';
      // Precondition (the defect): one line would be far wider than the page.
      expect(reportTextWidth(line, 10), greaterThan(_contentW));
      final pdf = reportBlocksToPdf(const [RptParagraph('x')],
          docTitle: 'A calculation report whose title is long enough to wrap '
              'past one line on an A4 cover page',
          projectName: 'Proyek',
          standardsLine: line);
      final cover = _streams(pdf).first;
      final runs = RegExp(r'([0-9.]+) Tf [0-9. ]+ rg ([0-9.-]+) [0-9.-]+ Td '
              r'\((.*?)\) Tj ET')
          .allMatches(cover)
          .toList();
      expect(runs.length, greaterThan(4));
      for (final m in runs) {
        final x = double.parse(m.group(2)!);
        // Every line starts inside the left margin and (centred) ends inside
        // the right one: x >= margin  ⇔  width <= content width.
        expect(x, greaterThanOrEqualTo(_margin - 1e-6), reason: m.group(3));
      }
      // No word of the provenance line is lost across the wrap.
      final text = runs.map((m) => m.group(3)!).join(' ');
      for (final w in ['2026-06-30', 'supersedes']) {
        if (line.contains(w)) expect(text, contains(w));
      }
    });
  });

  group('report-pdf-table-midword-breaks', () {
    test('property: no column is narrower than its widest word (seeded)', () {
      final rnd = math.Random(2310);
      const vocab = [
        'Phase',
        'Length',
        'socket',
        'HVAC',
        'lighting',
        '12.7 A',
        '30 mA',
        '2.5 mm2',
        '13.0 m',
        'penerangan',
        'kotak-kontak',
        'Panjang',
        'Fasa',
        'Lighting zone 1 corridor north wing',
        'NYY 4x25+16 mm2 MCCB 80A 3ph 19.5 m',
      ];
      for (var t = 0; t < 120; t++) {
        final cols = 2 + rnd.nextInt(8);
        final headers = [
          for (var c = 0; c < cols; c++) vocab[rnd.nextInt(vocab.length)],
        ];
        final rows = [
          for (var r = 0; r < 1 + rnd.nextInt(6); r++)
            [
              for (var c = 0; c < cols; c++) vocab[rnd.nextInt(vocab.length)],
            ],
        ];
        final w = reportTableColumnWidths(headers, rows);
        expect(w.reduce((a, b) => a + b), closeTo(_contentW, 1e-6));
        // The minimum each column needs: its widest unbreakable word
        // (a number + unit is ONE word, bound by a no-break space) + padding.
        final need = [
          for (var c = 0; c < cols; c++)
            math.max(
                28.0,
                [
                      for (final word in _words(headers[c]))
                        reportTextWidth(word, 8.5, bold: true),
                      for (final r in rows)
                        for (final word in _words(r[c]))
                          reportTextWidth(word, 8.5),
                    ].reduce(math.max) +
                    8),
        ];
        final needTotal = need.reduce((a, b) => a + b);
        if (needTotal > _contentW) continue; // the fallback regime
        for (var c = 0; c < cols; c++) {
          expect(w[c], greaterThanOrEqualTo(need[c] - 1e-6),
              reason: 'case $t col $c ${headers[c]}');
        }
      }
    });

    test('the panel-schedule cells print whole', () {
      final pdf = latin1.decode(reportBlocksToPdf([
        const RptTable([
          'Way',
          'Load',
          'Kind',
          'Phase',
          'Ib',
          'Breaker',
          'Cable',
          'Length',
          'Vd',
          'RCD',
        ], [
          [
            'C1',
            'Lighting zone 1 corridor north wing and the stair core',
            'socket',
            'R',
            '12.7 A',
            'MCB C16A/1P',
            '2.5 mm2',
            '13.0 m',
            '1.2 %',
            '30 mA',
          ],
        ]),
      ], docTitle: 'T', projectName: 'P'));
      for (final word in ['Phase', 'Length', 'socket']) {
        expect(pdf, contains('($word) Tj'), reason: word);
      }
      expect(pdf, isNot(contains('(Phas) Tj')));
      // The number stays with its unit (bound by a WinAnsi no-break space).
      expect(pdf, contains('(12.7 A) Tj'));
    });
  });

  group('report-pdf-figure-illegible', () {
    test('a multi-board single-line embeds with every label >= 5 pt', () {
      final project = _fan(6, ways: 14);
      final result = computeSystem(_profile, project);
      final sheet = buildElectricalSld(project: project, result: result);
      final pdf = reportBlocksToPdf(
          [RptFigure(sheet, caption: 'Electrical single-line diagram')],
          docTitle: 'T', projectName: 'P');
      final sizes = [
        for (final m
            in RegExp(r'/F[12] ([0-9.]+) Tf').allMatches(latin1.decode(pdf)))
          double.parse(m.group(1)!),
      ];
      expect(sizes.reduce(math.min), greaterThanOrEqualTo(kMinFigureLabelPt));
      // It needed more than one page to stay legible (cover + >= 2).
      expect(_streams(pdf).length, greaterThan(2));
    });
  });

  group('report-pdf-orphan-headings', () {
    test('sweep: a heading always shares its page with its table', () {
      for (var n = 0; n < 70; n++) {
        final pdf = reportBlocksToPdf([
          for (var i = 0; i < n; i++)
            RptParagraph('Filler paragraph $i with a little text.'),
          const RptHeading(2, 'ORPHANHEAD'),
          const RptTable([
            'TblHeadX',
            'B'
          ], [
            ['1', '2'],
            ['3', '4'],
          ]),
        ], docTitle: 'T', projectName: 'P');
        final pages = _streams(pdf).skip(1).toList();
        final hp = pages.indexWhere((p) => p.contains('(ORPHANHEAD) Tj'));
        expect(hp, isNot(-1));
        expect(pages[hp], contains('(TblHeadX) Tj'), reason: 'n = $n');
      }
    });
  });

  group('report-pdf-glyph-transliteration + literal rule', () {
    test('Ø / · / ² print as WinAnsi glyphs with their AFM widths', () {
      final pdf = latin1.decode(reportBlocksToPdf(
          const [RptParagraph('Duct Ø250 · k·Q² curve')],
          docTitle: 'T', projectName: 'P'));
      expect(pdf, contains('(Duct Ø250 · k·Q² curve) Tj'));
      expect(pdf, contains('/Encoding /WinAnsiEncoding'));
      // Helvetica AFM: Oslash 778, periodcentered 278, twosuperior 333.
      expect(reportTextWidth('Ø', 10), closeTo(7.78, 1e-9));
      expect(reportTextWidth('·', 10), closeTo(2.78, 1e-9));
      expect(reportTextWidth('²', 10), closeTo(3.33, 1e-9));
    });

    test('a Markdown thematic break is a rule, never the text "---"', () {
      final pdf = latin1.decode(reportBlocksToPdf(
          const [RptMarkdown('Above\n---\nBelow\n')],
          docTitle: 'T', projectName: 'P'));
      expect(pdf, isNot(contains('(---) Tj')));
      expect(pdf, contains('(Above) Tj'));
      expect(pdf, contains('(Below) Tj'));
    });
  });

  test('report-pdf-mep-duplicate-revision-heading: ONE heading', () {
    final md = buildMepUnifiedReport(
      mechanical: richMechData(),
      electrical: richElecData(),
      compliance: const ComplianceSummary(date: '2026-07-02', items: []),
    );
    expect('# Revision history'.allMatches(md).length, 1);
    expect(md, isNot(contains('## Revision history')));
  });

  group('report-pdf-board-order-reversed', () {
    test('three siblings list in drawn order after their parent', () {
      final r = computeSystem(_profile, _fan(3));
      expect(r.order, ['MDP', 'LP1', 'LP2', 'LP3']);
    });

    test('property: pre-order — parent first, siblings in model order', () {
      final rnd = math.Random(17);
      for (var t = 0; t < 40; t++) {
        final n = 2 + rnd.nextInt(8);
        final parent = <int, int>{
          for (var i = 1; i < n; i++) i: rnd.nextInt(i)
        };
        final project = ElectricalProject(id: 'p', name: 'p', panels: [
          for (var i = 0; i < n; i++)
            ElectricalPanel(
              id: 'B$i',
              name: 'B$i',
              sourceType: i == 0 ? PanelSource.utility : PanelSource.feeder,
              circuits: [
                _light('w$i'),
                for (var k = 1; k < n; k++)
                  if (parent[k] == i) _feeder('f$k', 'B$k'),
              ],
            ),
        ]);
        final order = computeSystem(_profile, project).order;
        expect(order.length, n);
        expect(order.first, 'B0');
        // Pre-order: every board after its parent, and a board's sub-tree is
        // contiguous; siblings keep model (index) order.
        for (var k = 1; k < n; k++) {
          expect(order.indexOf('B$k'),
              greaterThan(order.indexOf('B${parent[k]}')));
        }
        for (var a = 1; a < n; a++) {
          for (var b = a + 1; b < n; b++) {
            if (parent[a] == parent[b]) {
              expect(order.indexOf('B$a'), lessThan(order.indexOf('B$b')),
                  reason: 'case $t');
            }
          }
        }
      }
    });
  });

  // ── electrical drafting ──────────────────────────────────────────────────
  group('elec-drafting-2-5 ACB frames + OVER RANGE', () {
    ElectricalProject board(double w) =>
        ElectricalProject(id: 'b', name: 'B', panels: [
          ElectricalPanel(id: 'LVMDP', name: 'LVMDP', circuits: [
            ElectricalCircuit(
                id: 'h',
                name: 'Process load',
                loadKind: LoadKind.heating,
                loadW: w,
                cosPhi: 1.0,
                phases: 3,
                length: const Length(5)),
          ]),
        ]);

    test('1500 kW: Ib = 1 500 000 / (√3·400) = 2165 A ⇒ ACB 2500 A', () {
      final r = computeSystem(_profile, board(1500000));
      final inc = r.panels['LVMDP']!.incomer;
      expect(1500000 / (math.sqrt(3) * 400), closeTo(2165.1, 0.1));
      expect(inc.breaker.ratingA.amperes, 2500);
      expect(inc.breaker.deviceClass, BreakerClass.acb);
      expect(inc.overRange, isFalse);
      final sheet = buildElectricalSld(project: board(1500000), result: r);
      final text =
          sheet.prims.whereType<SldLabel>().map((l) => l.text).join('|');
      expect(text, contains('ACB 2500A'));
      expect(text, isNot(contains('OVER RANGE')));
    });

    test('3000 kW: 4330 A > the 4000 A top frame ⇒ OVER RANGE on every sheet',
        () {
      final project = board(3000000);
      final r = computeSystem(_profile, project);
      final inc = r.panels['LVMDP']!.incomer;
      expect(inc.breaker.ratingA.amperes, 4000);
      expect(inc.overRange, isTrue);
      final detail = buildElectricalSld(project: project, result: r)
          .prims
          .whereType<SldLabel>()
          .map((l) => l.text)
          .join('|');
      expect(
          detail,
          contains(
              '$kIncomerOverRangeToken (needs ${(3000000 / (math.sqrt(3) * 400)).toStringAsFixed(1)}A)'));
      final ov = buildElectricalOverview(project: project, result: r)
          .prims
          .whereType<SldLabel>()
          .map((l) => l.text)
          .join('|');
      expect(ov, contains('4000A 4P $kIncomerOverRangeToken'));
    });
  });

  test('elec-drafting-2-7: a capacitor-only board prints its kvar', () {
    final project = ElectricalProject(id: 'c', name: 'C', panels: [
      ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          circuits: [_light('a'), _feeder('fc', 'CAP')]),
      const ElectricalPanel(
          id: 'CAP',
          name: 'CAP-1',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'fc',
          circuits: [
            ElectricalCircuit(
                id: 'k',
                name: 'Capacitor bank',
                loadKind: LoadKind.capacitor,
                loadW: 300000,
                phases: 3,
                length: Length(5)),
          ]),
    ]);
    final r = computeSystem(_profile, project);
    final labels = buildElectricalOverview(project: project, result: r)
        .prims
        .whereType<SldLabel>()
        .map((l) => l.text)
        .toList();
    final sub = labels.firstWhere((t) => t.contains('kvar'));
    expect(sub, endsWith('300 kvar'));
    expect(labels.where((t) => t.contains('0kW / 0kVA')), isEmpty);
  });

  group('elec-drafting-2-2 power one-line', () {
    // Two edges may share a piece only where they genuinely meet — a common
    // source's drop or a common target's entry, i.e. collinear overlapping
    // segments that share an END point. A shared stretch with NO common end
    // (PLN's lane turn running along the genset's) draws two different
    // connections as one wire.
    bool collinearOverlap(SldSheet s) {
      final lines = s.prims
          .whereType<SldLine>()
          .where((l) => l.weight == SldWeight.medium)
          .toList();
      bool shareEnd(SldLine a, SldLine b) {
        final ea = [(a.x1, a.y1), (a.x2, a.y2)];
        final eb = [(b.x1, b.y1), (b.x2, b.y2)];
        return ea.any(eb.contains);
      }

      for (var i = 0; i < lines.length; i++) {
        for (var j = i + 1; j < lines.length; j++) {
          final a = lines[i], b = lines[j];
          var overlap = false;
          if (a.y1 == a.y2 && b.y1 == b.y2 && a.y1 == b.y1) {
            final lo = math.max(math.min(a.x1, a.x2), math.min(b.x1, b.x2));
            final hi = math.min(math.max(a.x1, a.x2), math.max(b.x1, b.x2));
            overlap = hi - lo > 1e-6;
          }
          if (a.x1 == a.x2 && b.x1 == b.x2 && a.x1 == b.x1) {
            final lo = math.max(math.min(a.y1, a.y2), math.min(b.y1, b.y2));
            final hi = math.min(math.max(a.y1, a.y2), math.max(b.y1, b.y2));
            overlap = hi - lo > 1e-6;
          }
          if (overlap && !shareEnd(a, b)) return true;
        }
      }
      return false;
    }

    test('property: no two edges share a collinear segment (every source mask)',
        () {
      for (var mask = 0; mask < 32; mask++) {
        final sources = ElectricalSources(
          generator: mask & 1 != 0
              ? GeneratorSource(backupFraction: mask & 16 != 0 ? 0.5 : 1.0)
              : null,
          solar: mask & 2 != 0 ? const SolarSource(panels: 24) : null,
          battery: mask & 4 != 0 ? const BatterySource(autonomyHours: 2) : null,
          hybridInverter: mask & 8 != 0 ? false : null,
        );
        final ol =
            buildPowerOneLine(sources, demand: const ApparentPower(120000));
        expect(collinearOverlap(buildPowerOneLineSheet(ol)), isFalse,
            reason: 'mask $mask');
      }
    });

    test('a declared MV service is never labelled "400 V LV"', () {
      const lv = ElectricalProject(id: 'l', name: 'L');
      expect(powerOneLineUtilitySub(lv, const ApparentPower(500000)), isNull);
      const mv = ElectricalProject(
          id: 'm', name: 'M', transformerKva: ApparentPower(1600000));
      final sub = powerOneLineUtilitySub(mv, const ApparentPower(900000))!;
      expect(sub, 'MV via TX 1600 kVA');
      final ol = buildPowerOneLine(
          const ElectricalSources(generator: GeneratorSource()),
          demand: const ApparentPower(900000),
          utilitySub: sub);
      expect(ol.nodeOfKind(PowerNodeKind.utility)!.sub, sub);
    });
  });

  test('elec-drafting-2-4: a right-hand child tag sits on its own bus', () {
    final project = _fan(3);
    final r = computeSystem(_profile, project);
    final s = buildElectricalOverview(project: project, result: r);
    final boxes = s.prims.whereType<SldRect>().toList();
    final mdp = boxes.reduce((a, b) => a.y < b.y ? a : b);
    final ax = mdp.x + mdp.w / 2;
    final kids = boxes.where((b) => b.y > mdp.y).toList()
      ..sort((a, b) => a.x.compareTo(b.x));
    final drops = [for (final k in kids) k.x + k.w / 2];
    final tags = s.prims
        .whereType<SldLabel>()
        .where((l) => l.size == 6.5 && l.y < kids.first.y)
        .toList();
    for (var i = 0; i < kids.length; i++) {
      final zx = drops[i];
      if (zx <= ax + 1e-6) continue;
      final prev = [
        ax,
        for (final d in drops)
          if (d < zx - 1e-6) d
      ].reduce(math.max);
      // Its tag lies on the bus segment between the nearest drop to its left
      // and its OWN drop — never starting at the parent's drop.
      final own = tags.where((t) => t.x >= prev + 4 - 1e-6 && t.x < zx);
      expect(own, isNotEmpty, reason: 'child $i');
    }
  });

  group('elec-drafting-2-6 + 2-1 riser', () {
    final building = BuildingLevels([
      for (var i = 0; i < 12; i++) Floor('Lantai ${i + 1}', const Length(3.8)),
    ]);
    final tower = _fan(18, ways: 6, floors: 12);
    final r = computeSystem(_profile, tower);

    test('a ground-floor root takes the spine BESIDE its band, not at the roof',
        () {
      final s = buildElectricalRiser(
          project: tower, result: r, building: building, sourceChain: true);
      final rootBox = s.prims
          .whereType<SldRect>()
          .where((b) => b.role != SldRole.source)
          .reduce((a, b) => a.y > b.y ? a : b); // the ground band
      final pln = s.prims
          .whereType<SldLabel>()
          .firstWhere((l) => l.text.startsWith('PLN'));
      // The supply head sits left of the floor gutter, near the ground band —
      // not above the top floor.
      expect(pln.x, lessThan(0));
      final topBoxY = s.prims
          .whereType<SldRect>()
          .where((b) => b.role != SldRole.source)
          .map((b) => b.y)
          .reduce(math.min);
      expect(pln.y, greaterThan(topBoxY));
      // No supply line runs down through the floors at x >= 0 above the
      // ground band's bus gap.
      for (final l in s.prims.whereType<SldLine>()) {
        if (l.role != SldRole.source) continue;
        if (math.min(l.x1, l.x2) < 0) continue;
        expect(
            math.min(l.y1, l.y2), greaterThanOrEqualTo(rootBox.y - 31 - 1e-6));
      }
    });

    test('a 12-storey riser paginates; every board on exactly one page', () {
      final whole = buildElectricalRiser(
          project: tower, result: r, building: building, sourceChain: true);
      expect(sldSinglePageMinLabelPt(whole), lessThan(kMinPlotLabelPt));
      final pages = paginatedElectricalRiserSheets(
          project: tower, result: r, building: building);
      expect(pages.length, greaterThan(1));
      final single = paginatedElectricalRiserSheets(
          project: tower, result: r, building: building);
      for (final p in single) {
        expect(sldSinglePageMinLabelPt(p),
            greaterThan(sldSinglePageMinLabelPt(whole)));
      }
      for (final name in ['MDP', for (var i = 1; i <= 18; i++) 'LP-$i']) {
        var n = 0;
        for (final p in pages) {
          n += p.prims
              .whereType<SldLabel>()
              .where((l) => l.bold && l.size == 10 && l.text == name)
              .length;
        }
        expect(n, 1, reason: name);
      }
      expect(
          pages.any((p) => p.prims
              .whereType<SldLabel>()
              .any((l) => l.text.startsWith('LANJUT KE '))),
          isTrue);
      // The spine rides exactly one page — the one carrying the ground band.
      expect(
          pages
              .where((p) => p.prims
                  .whereType<SldLabel>()
                  .any((l) => l.text.startsWith('PLN')))
              .length,
          1);
    });
  });

  test('elec-drafting-2-1: a wide overview paginates by sub-tree', () {
    // MDP -> 6 SDPs, each feeding 5 LPs (36 boards).
    final project = ElectricalProject(id: 'w', name: 'W', panels: [
      ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          circuits: [for (var i = 1; i <= 6; i++) _feeder('s$i', 'SDP$i')]),
      for (var i = 1; i <= 6; i++)
        ElectricalPanel(
            id: 'SDP$i',
            name: 'SDP-$i',
            sourceType: PanelSource.feeder,
            fedByCircuitId: 's$i',
            circuits: [
              for (var k = 1; k <= 5; k++) _feeder('l$i$k', 'LP$i$k'),
            ]),
      for (var i = 1; i <= 6; i++)
        for (var k = 1; k <= 5; k++)
          ElectricalPanel(
              id: 'LP$i$k',
              name: 'LP-$i$k',
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'l$i$k',
              circuits: [_light('w$i$k')]),
    ]);
    final r = computeSystem(_profile, project);
    final whole =
        buildElectricalOverview(project: project, result: r, sourceChain: true);
    expect(sldSinglePageMinLabelPt(whole), lessThan(kMinPlotLabelPt));
    final pages =
        paginatedElectricalOverviewSheets(project: project, result: r);
    expect(pages.length, 7); // the top page + one per SDP sub-tree
    for (final p in pages) {
      expect(sldSinglePageMinLabelPt(p),
          greaterThan(sldSinglePageMinLabelPt(whole)));
    }
    // Every board's node is drawn on exactly one page (the cut SDPs on the
    // top page; each SDP heads its own page too, as its sub-tree's root).
    for (var i = 1; i <= 6; i++) {
      for (var k = 1; k <= 5; k++) {
        var n = 0;
        for (final p in pages) {
          n += p.prims
              .whereType<SldLabel>()
              .where((l) => l.bold && l.text == 'LP-$i$k')
              .length;
        }
        expect(n, 1, reason: 'LP-$i$k');
      }
    }
    final top = pages.first.prims.whereType<SldLabel>().map((l) => l.text);
    expect(top.where((t) => t.startsWith('LANJUT KE DIAGRAM SDP-')).length, 6);
    expect(
        pages[1].prims.whereType<SldLabel>().any((l) => l.text == 'DARI MDP'),
        isTrue);
  });

  group('elec-drafting-2-3 electrical layout DXF units', () {
    const data = ElectricalPlanData(nodes: [
      ElectricalPlanNode(
          x: 100, y: 100, tag: 'LVMDP', kind: ElectricalPlanNodeKind.panel),
      ElectricalPlanNode(
          x: 600, y: 100, tag: 'PP-EM', kind: ElectricalPlanNodeKind.panel),
    ], routes: [
      ElectricalPlanRoute(x1: 100, y1: 100, x2: 600, y2: 100, label: '15.0 m'),
    ]);
    const chrome = DrawingChrome(drawingNumber: 'E-101');

    test('calibrated: world mm, INSUNITS 4, the snapped 1 : N row', () {
      final dxf = electricalPlanToDxf(
          data: data,
          projectName: 'P',
          sheetName: 'Lantai Dasar',
          chrome: chrome,
          metersPerPixel: 0.03);
      expect(dxf, contains('\$INSUNITS\n70\n4'));
      // The 500 px route at 0.03 m/px is 15.0 m = 15000 mm long.
      final m = RegExp(r'0\nLINE\n8\nE-FEEDER\n10\n([0-9.-]+)\n20\n'
              r'([0-9.-]+)\n11\n([0-9.-]+)\n21\n([0-9.-]+)')
          .firstMatch(dxf)!;
      final len = double.parse(m.group(3)!) - double.parse(m.group(1)!);
      expect(len, closeTo(15000, 1e-6));
      expect(dxf, contains(RegExp(r'1 : \d+ @ A3')));
      expect(dxf, isNot(contains('\nNTS\n')));
    });

    test('uncalibrated: the legacy sheet-pixel drawing, SCALE NTS', () {
      final dxf = electricalPlanToDxf(
          data: data, projectName: 'P', sheetName: 'L', chrome: chrome);
      expect(dxf, isNot(contains('INSUNITS')));
      expect(dxf, contains('\nNTS\n'));
    });
  });
}

List<String> _words(String s) => s
    .replaceAllMapped(
        RegExp(r'(\d) (mA|A|kA|mm2|mm|m|kW|W|kVA|kvar|V|kPa|Pa|L/s|m/s|m3|Hz|%)'
            r'(?![A-Za-z0-9])'),
        (m) => '${m[1]} ${m[2]}')
    .split(' ');
