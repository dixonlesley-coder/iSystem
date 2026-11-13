// Drawing backlog I-3 (2026-11-13) — detail sheets: fewer, fuller.
// (a) a cluster whose detail would not plot at least twice as large as its
// plan is keyed on the plan instead of issued; (b) a plan's details are
// packed as many to a sheet as fit at their own scales; (c) identical
// typical-floor detail content is recognised after masking the level code.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/plan_detail.dart';
import 'package:mechx_engine/report/plan_detail_sheet.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:test/test.dart';

void main() {
  const area = (minX: 10.0, minY: 10.0, maxX: 400.0, maxY: 260.0);

  group('(b) mixed-scale packing', () {
    test('each detail at its own scale; null when they do not fit', () {
      final frames = planDetailMixedPack(
          sizesM: [(w: 2.0, h: 2.0), (w: 4.0, h: 2.0)],
          scales: [20, 50],
          area: area)!;
      // Frame = extent at its own scale + 18 mm pad all round.
      expect(frames[0].maxX - frames[0].minX, closeTo(2000 / 20 + 36, 1e-9));
      expect(frames[1].maxX - frames[1].minX, closeTo(4000 / 50 + 36, 1e-9));
      // Largest first: the 1:20 detail (136 x 136) leads the row.
      expect(frames[0].minX, lessThan(frames[1].minX));
      expect(
          planDetailMixedPack(
              sizesM: [(w: 9.0, h: 9.0)], scales: [20], area: area),
          isNull);
    });

    test('bins fill a sheet before starting another, deterministically', () {
      final sizes = [
        (w: 2.0, h: 2.0),
        (w: 2.0, h: 2.0),
        (w: 2.0, h: 2.0),
        (w: 6.0, h: 4.0),
      ];
      final scales = [20, 20, 20, 25];
      final bins = planDetailBins(sizesM: sizes, scales: scales, area: area);
      // Every detail on exactly one sheet; fewer sheets than details.
      expect([for (final b in bins) ...b]..sort(), [0, 1, 2, 3]);
      expect(bins.length, lessThan(4));
      for (final b in bins) {
        expect(
            planDetailMixedPack(
                sizesM: [for (final i in b) sizes[i]],
                scales: [for (final i in b) scales[i]],
                area: area),
            isNotNull);
      }
      expect(planDetailBins(sizesM: sizes, scales: scales, area: area), bins);
    });
  });

  group('(a) a keyed cluster', () {
    test('keeps its box but issues no sheet reference', () {
      const c = PlanDetailCallout(
          letter: 'B',
          rectPx: (minX: 0, minY: 0, maxX: 10, maxY: 10),
          sheetRef: 'M-503',
          scale: 100);
      final k = c.asKeyed();
      expect(k.keyed, isTrue);
      expect(k.sheetRef, isEmpty);
      expect(k.rectPx, c.rectPx);
      expect(c.renamed('A', 'M-501').scale, 100);
      expect(c.atScale(50).scale, 50);
    });
  });

  group('(c) typical floors', () {
    test('the level code is masked in tags', () {
      expect(planDetailMaskLevel('CW-L12 · DN25 - 3.0 m'),
          planDetailMaskLevel('CW-L3 · DN25 - 3.0 m'));
      expect(planDetailMaskLevel('D-GF'), 'D-#');
      expect(planDetailMaskLevel('DN25'), 'DN25');
    });

    test('two floors drawing the same thing share a signature', () {
      Network floor(int f) => Network(nodes: [
            NetNode(id: 'a$f', sheetId: 's$f', x: 0, y: 0, floorIndex: f),
            NetNode(
                id: 'b$f',
                sheetId: 's$f',
                x: 100,
                y: 0,
                floorIndex: f,
                role: NodeRole.fixture,
                fixture: PlumbingFixture.lavatory),
          ], edges: [
            NetEdge(
                id: 'e$f',
                fromId: 'a$f',
                toId: 'b$f',
                service: ServiceType.coldWater),
          ]);
      String sig(int f, {double x = 100}) {
        final net = floor(f);
        final n = Network(nodes: [
          net.nodes.first,
          net.nodes.last.copyWith(x: x),
        ], edges: net.edges);
        return planDetailContentSignature(planDetailSheetPlot(
            net: n,
            sizing: const {},
            edgeLengths: const {},
            sheetId: 's$f',
            floorIndex: f,
            metersPerPixel: 0.01,
            details: const [
              PlanDetailCallout(
                  letter: 'A',
                  rectPx: (minX: -20, minY: -20, maxX: 120, maxY: 20),
                  sheetRef: 'M-501')
            ],
            areaMm: area,
            edgeTags: {'e$f': 'CW-L${f + 1}'}));
      }

      expect(sig(1), sig(7));
      expect(sig(1), isNot(sig(7, x: 90)));
    });

    test('the typical sheet names its floors', () {
      expect(planDetailTypicalName(['Lantai 2', 'Lantai 3', 'Lantai 4']),
          'TIPIKAL - Lantai 2..4');
      expect(planDetailTypicalName(['Lantai 2', 'Lantai 3', 'Lantai 7']),
          'TIPIKAL - Lantai 2..3, 7');
      expect(planDetailTypicalName(['Dasar', 'Lantai 2']),
          'TIPIKAL - Dasar, Lantai 2');
    });
  });
}
