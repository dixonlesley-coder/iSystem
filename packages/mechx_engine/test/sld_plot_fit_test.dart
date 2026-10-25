// drafting-6 / drafting-9: the single-line PLOT fit — labels grown in place to
// the minimum plotted size (ISO 3098 2.5 mm body, kMinPlotLabelPt = 7 pt) on a
// scaled-down sheet, never moving an anchor and never creating an overlap, and
// bounds that cover every label's real text extent.
import 'dart:convert';
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/sld_plot_fit.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// The text box the plot fit measures a label with (y-down drawing space).
({double l, double t, double r, double b}) _box(SldLabel x) => (
      l: x.x,
      t: x.y - kSldLabelAscent * x.size,
      r: x.x + helveticaTextWidth(x.text, x.size),
      b: x.y + kSldLabelDescent * x.size,
    );

bool _overlap(({double l, double t, double r, double b}) a,
        ({double l, double t, double r, double b}) b) =>
    a.l < b.r && b.l < a.r && a.t < b.b && b.t < a.b;

SldSheet _sheet(List<SldPrim> prims,
        {double minX = 0, double minY = 0, double maxX = 100, double maxY = 100}) =>
    SldSheet(
        prims: prims,
        minX: minX,
        minY: minY,
        maxX: maxX,
        maxY: maxY,
        legend: const [],
        supplyNote: '');

/// A tall riser: an MV service (so the source spine draws) feeding one board
/// per floor on 8 floors, each with 6 load ways — tall enough that the A3 fit
/// scales the drawing well below 1:1.
ElectricalProject _tallRiser() {
  final panels = <ElectricalPanel>[
    ElectricalPanel(
      id: 'MDP',
      name: 'MDP',
      layoutPos: const LayoutPos(sheetId: 's', floorIndex: 0, x: 0, y: 0),
      circuits: [
        for (var f = 1; f < 8; f++)
          ElectricalCircuit(
              id: 'f$f',
              name: 'Feeder LP-$f',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'LP$f',
              length: Length(4.0 * f + 6)),
      ],
    ),
    for (var f = 1; f < 8; f++)
      ElectricalPanel(
        id: 'LP$f',
        name: 'LP-$f',
        sourceType: PanelSource.feeder,
        layoutPos: LayoutPos(sheetId: 's', floorIndex: f, x: 0, y: 0),
        circuits: [
          for (var w = 0; w < 6; w++)
            ElectricalCircuit(
                id: 'l$f-$w',
                name: 'Lighting L.$f.$w',
                loadKind: LoadKind.lighting,
                isLighting: true,
                loadW: 600.0 + 100 * w,
                length: const Length(15)),
        ],
      ),
  ];
  return ElectricalProject(
    id: 'tall',
    name: 'Tall riser',
    panels: panels,
    transformerKva: const ApparentPower(630000),
  );
}

const _tallBuilding = BuildingLevels([
  Floor('G', Length(4)),
  Floor('L1', Length(4)),
  Floor('L2', Length(4)),
  Floor('L3', Length(4)),
  Floor('L4', Length(4)),
  Floor('L5', Length(4)),
  Floor('L6', Length(4)),
  Floor('L7', Length(4)),
]);

void main() {
  group('fitSldSheetForPlot (drafting-6)', () {
    test('a sheet that fits at 1:1 with every label >= 7 is left as drawn', () {
      final s = _sheet([
        const SldLine(0, 50, 100, 50),
        const SldLabel(10, 30, 'MDP', size: 9),
      ]);
      final fit = fitSldSheetForPlot(s, availW: 1000, availH: 700);
      expect(fit.scale, 1.0);
      final l = fit.sheet.prims.whereType<SldLabel>().single;
      expect(l.size, 9);
      expect((l.x, l.y), (10.0, 30.0));
    });

    test('a label in clear space grows to plot at exactly kMinPlotLabelPt', () {
      // 2000 units wide into 1000 pt ⇒ scale 0.5; a 6-unit label would plot
      // at 3 pt, so it grows to 7 / 0.5 = 14 units and plots at 7 pt.
      final s = _sheet([const SldLabel(100, 300, 'NYY 4x16 mm2', size: 6)],
          maxX: 2000, maxY: 600);
      final fit = fitSldSheetForPlot(s, availW: 1000, availH: 700);
      expect(fit.scale, closeTo(0.5, 1e-3));
      final l = fit.sheet.prims.whereType<SldLabel>().single;
      expect(l.size * fit.scale, closeTo(kMinPlotLabelPt, 0.02));
      // The anchor never moves.
      expect((l.x, l.y), (100.0, 300.0));
    });

    test('a boxed-in label grows only as far as clear space allows', () {
      // A wall 60 units right of the label start: the label may not grow into
      // it, and never shrinks below the size it was drawn at.
      final s = _sheet([
        const SldLabel(100, 300, 'Lighting L.1 10A', size: 6),
        const SldLine(160, 250, 160, 350),
      ], maxX: 2000, maxY: 600);
      final fit = fitSldSheetForPlot(s, availW: 1000, availH: 700);
      final l = fit.sheet.prims.whereType<SldLabel>().single;
      expect(l.size, greaterThanOrEqualTo(6));
      expect(l.size * fit.scale, lessThan(kMinPlotLabelPt)); // boxed in
      expect(_box(l).r, lessThanOrEqualTo(160.0));
    });

    test('two stacked labels never grow into each other', () {
      // Rows 8 units apart: at 14 units each would overlap the other.
      final s = _sheet([
        const SldLabel(100, 300, 'Row one', size: 6),
        const SldLabel(100, 308, 'Row two', size: 6),
      ], maxX: 2000, maxY: 600);
      final fit = fitSldSheetForPlot(s, availW: 1000, availH: 700);
      final ls = fit.sheet.prims.whereType<SldLabel>().toList();
      expect(_overlap(_box(ls[0]), _box(ls[1])), isFalse);
      expect(ls.every((l) => l.size >= 6), isTrue);
    });

    test('a tag written over its own run may grow across that run', () {
      // The run already passes through the label: it does not block growth.
      final s = _sheet([
        const SldLine(80, 298, 400, 298),
        const SldLabel(100, 300, 'Tag', size: 6),
      ], maxX: 2000, maxY: 600);
      final fit = fitSldSheetForPlot(s, availW: 1000, availH: 700);
      final l = fit.sheet.prims.whereType<SldLabel>().single;
      expect(l.size * fit.scale, closeTo(kMinPlotLabelPt, 0.02));
    });

    test('drafting-9: the bounds cover the top label\'s glyphs, not its baseline',
        () {
      final s = _sheet([const SldLabel(0, 0, 'PLN MV STATION', size: 10)],
          maxX: 200, maxY: 100);
      final fit = fitSldSheetForPlot(s, availW: 1000, availH: 700);
      expect(fit.sheet.minY, closeTo(-kSldLabelAscent * 10, 1e-9));
    });

    test('a real tall riser: anchors kept, no new overlap, labels reach 7 pt',
        () {
      final p = _tallRiser();
      final r = computeSystem(const PuilProfile(), p);
      final sheet = buildElectricalRiser(
          project: p, result: r, building: _tallBuilding, sourceChain: true);
      const availW = 1000.0, availH = 600.0;
      final fit = fitSldSheetForPlot(sheet, availW: availW, availH: availH);
      expect(fit.scale, lessThan(1.0)); // genuinely scaled down
      final before = sheet.prims.whereType<SldLabel>().toList();
      final after = fit.sheet.prims.whereType<SldLabel>().toList();
      expect(after.length, before.length);
      var reached = 0;
      for (var i = 0; i < before.length; i++) {
        expect((after[i].x, after[i].y), (before[i].x, before[i].y));
        expect(after[i].text, before[i].text);
        expect(after[i].size, greaterThanOrEqualTo(before[i].size));
        if (after[i].size * fit.scale >= kMinPlotLabelPt - 0.05) reached++;
      }
      // Growth never makes two labels overlap that did not already.
      for (var i = 0; i < after.length; i++) {
        for (var j = i + 1; j < after.length; j++) {
          if (_overlap(_box(before[i]), _box(before[j]))) continue;
          expect(_overlap(_box(after[i]), _box(after[j])), isFalse,
              reason: '"${after[i].text}" vs "${after[j].text}"');
        }
      }
      // Every feeder cable / breaker tag (the finding's 5 pt cable specs)
      // reaches the minimum; the stacked fan-out rows, 13 units apart, are
      // boxed in by their neighbours at this scale (0.37) and keep the largest
      // size that fits — honest, never overlapping.
      for (final l in after.where((l) => l.text.contains('mm2'))) {
        expect(l.size * fit.scale, greaterThanOrEqualTo(kMinPlotLabelPt - 0.3),
            reason: l.text);
      }
      expect(reached, greaterThan(0));
    });
  });

  group('the SLD PDF + DXF print the fitted labels (drafting-6)', () {
    final p = _tallRiser();
    final r = computeSystem(const PuilProfile(), p);
    final sheet = buildElectricalRiser(
        project: p, result: r, building: _tallBuilding, sourceChain: true);

    test('every feeder cable/breaker tag on the PDF prints at >= 7 pt', () {
      final pdf = latin1.decode(electricalSldToPdf(sheet: sheet));
      final tf = RegExp(r'BT /F1 ([0-9.]+) Tf [0-9. ]+ rg [-0-9.]+ [-0-9.]+ Td '
          r'\(([^)]*mm2[^)]*)\) Tj');
      final sizes = [
        for (final m in tf.allMatches(pdf)) double.parse(m.group(1)!)
      ];
      expect(sizes, isNotEmpty);
      expect(sizes.reduce(math.min), greaterThanOrEqualTo(kMinPlotLabelPt));
    });

    test('the DXF text heights follow the same fit as the PDF', () {
      // Round 27 (export-files-2-2) — the DXF writes each label's CAP height
      // (group 40) = its fitted em x Helvetica's cap height 0.718, so it
      // prints the same size as the PDF's em (was 1.3 x em, ~1.8x the PDF).
      final fit = fitSldSheetForPlot(sheet,
          availW: kSldA3PlotAvailW, availH: kSldA3PlotAvailH);
      final grown = fit.sheet.prims
          .whereType<SldLabel>()
          .firstWhere((l) => l.text.contains('mm2'));
      final dxf = electricalSldToDxf(sheet: sheet);
      final h = (grown.size * 0.718).toString();
      expect(kHelveticaCapHeightEm, 0.718);
      expect(dxf, contains('\n40\n$h\n'));
    });
  });
}
