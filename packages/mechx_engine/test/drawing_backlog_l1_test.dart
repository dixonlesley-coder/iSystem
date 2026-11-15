// Drawing backlog L-1 (2026-11-13) — the plan PDF and DXF draw ONE
// placement result: a plotted sheet's `PlanSheetPlot` carries the PDF's page
// frame, the DXF lays its annotations out in that frame and maps the placed
// geometry into model mm with `mapPlanAnnotations` (uniform k, y-up both).
import 'package:mechx_engine/report/plan_annotation_layout.dart';
import 'package:mechx_engine/report/plan_detail.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:test/test.dart';

import '../tool/generate_export_samples.dart'
    show
        buildNetwork,
        referenceGrid,
        planSheetChrome,
        projectName,
        dateString;

void main() {
  test('mapPlanAnnotations: X = ox + k x, Y = oy + k y, sizes x k', () {
    const a = PlanAnnotations(
      upDown: [PlanUpDownMark('UP', 10, 20, 3)],
      labels: [
        PlanPlacedLabel(
          PlanLabelKind.run,
          'e',
          LeaderedLabelPlacement(
            x: 1,
            y: 2,
            angleDeg: 30,
            leaderAnchor: (x: 0, y: 0),
            leaderEnd: (x: 4, y: 5),
            lines: [(text: 'DN50', x: 1, y: 2)],
            keyCircle: (x: 6, y: 7, r: 2),
          ),
          3,
        ),
      ],
      overlapCount: 1,
      marks: PlanMarks(
          circles: [PlanMarkCircle(1, 1, 2)],
          texts: [PlanMarkText(2, 3, 4, 'A')]),
      unresolvedAnchorsPx: [(x: 100, y: 200)],
    );
    final m = mapPlanAnnotations(a, k: 2.5, ox: 10, oy: -4);
    expect((m.upDown.single.x, m.upDown.single.y), (35.0, 46.0));
    expect(m.upDown.single.textSize, 7.5);
    final p = m.labels.single.placement;
    expect((p.x, p.y, p.angleDeg), (12.5, 1.0, 30.0));
    expect(p.leaderAnchor, (x: 10.0, y: -4.0));
    expect(p.leaderEnd, (x: 20.0, y: 8.5));
    expect(p.lines.single, (text: 'DN50', x: 12.5, y: 1.0));
    expect(p.keyCircle, (x: 25.0, y: 13.5, r: 5.0));
    expect(m.labels.single.textSize, 7.5);
    expect(m.marks.circles.single.r, 5.0);
    expect(m.marks.texts.single.size, 10.0);
    // Frame-free: the count and the sheet-pixel anchors stay as placed.
    expect(m.overlapCount, 1);
    expect(m.unresolvedAnchorsPx, a.unresolvedAnchorsPx);
  });

  test('a plotted sheet carries the PDF page frame; its occupied boxes are '
      'the PDF page boxes of occupiedPx', () {
    final net = buildNetwork();
    final chrome = planSheetChrome(net, 's0', 0, 1, 'GROUND FLOOR');
    final plot = planSheetPlot(
      net: net,
      sheetId: 's0',
      floorIndex: 0,
      projectName: projectName,
      sheetName: 'GROUND FLOOR',
      dateString: dateString,
      metersPerPixel: 0.02,
      grid: referenceGrid,
      chrome: chrome,
    )!;
    final f = plot.frame!;
    expect(f.occupiedPt.length, plot.occupiedPx.length);
    for (var i = 0; i < plot.occupiedPx.length; i++) {
      final px = plot.occupiedPx[i], pt = f.occupiedPt[i];
      expect(f.tx(px.minX), closeTo(pt.minX, 1e-6));
      expect(f.tx(px.maxX), closeTo(pt.maxX, 1e-6));
      expect(f.ty(px.maxY), closeTo(pt.minY, 1e-6));
      expect(f.ty(px.minY), closeTo(pt.maxY, 1e-6));
    }
    // The page scale is the plotted 1 : N: 0.02 m/px x 1000 / (scale x
    // 25.4 / 72) = N.
    expect((0.02 * 1000 / (f.scale * kPlanPaperMmPerPt)).round(),
        plot.scaleDenominator);
  });
}
