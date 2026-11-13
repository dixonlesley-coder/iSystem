// Drawing review S1 / S2 (2026-11-13) — the finishing cures for the last
// overlap stamps: S1 splits a detail too dense for one sheet (one cluster per
// sheet, then halves along the longer side with MATCH LINES); S2 gives a
// crowded riser floor band its own page / a second key row. Pure rules.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/plan_detail.dart';
import 'package:mechx_engine/report/plan_detail_sheet.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('S1 — split detail', () {
    test('a wide box splits across x in the anchor gap nearest the middle',
        () {
      const r = (minX: 0.0, minY: 0.0, maxX: 100.0, maxY: 40.0);
      // Anchors at 10, 30, 70 (x): gaps at 20 and 50; 50 is the middle.
      final (a, b) = planDetailSplitRect(
          r, const [(x: 10, y: 5), (x: 30, y: 5), (x: 70, y: 5), (x: 500, y: 5)]);
      expect(a, (minX: 0.0, minY: 0.0, maxX: 50.0, maxY: 40.0));
      expect(b, (minX: 50.0, minY: 0.0, maxX: 100.0, maxY: 40.0));
    });

    test('a tall box splits across y; no anchors -> the middle', () {
      const r = (minX: 0.0, minY: 0.0, maxX: 20.0, maxY: 80.0);
      final (a, b) = planDetailSplitRect(r, const []);
      expect(a.maxY, 40.0);
      expect(b.minY, 40.0);
      // An anchor never sits on the cut (each element labelled once).
      final (c, d) = planDetailSplitRect(
          r, const [(x: 5, y: 10), (x: 5, y: 12), (x: 5, y: 60)]);
      expect(c.maxY, 36.0); // gap 12..60 -> 36 (nearest the middle 40)
      expect(d.minY, 36.0);
    });

    test('shared cuts: touching pieces name each other, apart ones do not',
        () {
      final cuts = planDetailSharedCuts(const [
        (minX: 0.0, minY: 0.0, maxX: 50.0, maxY: 40.0),
        (minX: 50.0, minY: 10.0, maxX: 100.0, maxY: 60.0),
        (minX: 300.0, minY: 0.0, maxX: 310.0, maxY: 10.0),
      ]);
      expect(cuts[0], hasLength(1));
      expect(cuts[0].single, (x1: 50.0, y1: 10.0, x2: 50.0, y2: 40.0, other: 1));
      expect(cuts[1].single.other, 0);
      expect(cuts[2], isEmpty);
    });

    test('a split piece draws its match line and names the neighbour', () {
      final net = Network(nodes: [
        for (var i = 0; i < 4; i++)
          NetNode(
              id: 'n$i', sheetId: 's', x: 10.0 + 25 * i, y: 20, floorIndex: 0),
      ], edges: [
        for (var i = 0; i < 3; i++)
          NetEdge(
              id: 'e$i',
              fromId: 'n$i',
              toId: 'n${i + 1}',
              service: ServiceType.coldWater),
      ]);
      const match = PlanDetailMatch(50, 0, 50, 40,
          letter: 'B', sheetRef: 'M-502');
      final plot = planDetailSheetPlot(
        net: net,
        sizing: const {},
        edgeLengths: const {'e0': Length(0.25)},
        sheetId: 's',
        floorIndex: 0,
        metersPerPixel: 0.01,
        details: const [
          PlanDetailCallout(
              letter: 'A',
              rectPx: (minX: 0, minY: 0, maxX: 50, maxY: 40),
              sheetRef: 'M-501',
              matches: [match]),
        ],
        areaMm: (minX: 10, minY: 10, maxX: 400, maxY: 250),
      );
      expect(plot.marks.texts.map((t) => t.text),
          contains('MATCH LINE - LIHAT DETAIL B (M-502)'));
      final dashed = plot.marks.lines.where((l) => l.dashed).toList();
      expect(dashed, hasLength(1));
      // Vertical, at the cut, inside the frame.
      final f = plot.details.single.frameMm;
      expect(dashed.single.x1, dashed.single.x2);
      expect(dashed.single.x1, inInclusiveRange(f.minX, f.maxX));
      // The run crossing the cut (n2 at x=60 is outside the box) is drawn as
      // unlabelled context: labelled on the neighbour's sheet instead.
      expect(plot.unlabelledIds, contains('n2'));
    });
  });
}
