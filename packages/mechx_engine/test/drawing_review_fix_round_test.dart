// Drawing review fix round (2026-11-13) — F1..F7 from
// docs/DRAWING-REVIEW-RECORD.md, each pinned to the pure rule it broke.
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:test/test.dart';

void main() {
  group('F3 legibility stamp fires only below the printed floor', () {
    test('a page fitted to 6.9995 pt prints 7.0 pt: no stamp', () {
      expect(sldPrintsBelowMinPt(6.9995), isFalse);
      expect(sldLegibilityWarning(6.9995), isNull);
      expect(sldLegibilityWarning(7.0), isNull);
    });
    test('a page at 6.9 pt (prints 6.9) is stamped with that size', () {
      expect(sldPrintsBelowMinPt(6.9), isTrue);
      expect(sldLegibilityWarning(6.9), contains('6.9 pt (< 7 pt)'));
      // The printed number is always strictly below the printed floor.
      for (var t = 1.0; t < 7.2; t += 0.013) {
        final w = sldLegibilityWarning(t);
        if (w == null) continue;
        final shown =
            double.parse(RegExp(r'tercetak ([\d.]+) pt').firstMatch(w)!.group(1)!);
        expect(shown, lessThan(7.0), reason: 'pt=$t');
      }
    });
  });

  group('F1/F2 electrical layout tags stay in the frame and never stack', () {
    const area = (minX: 0.0, minY: 0.0, maxX: 400.0, maxY: 300.0);
    bool hit(a, b) =>
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY;
    bool inside(b) =>
        b.minX >= area.minX &&
        b.maxX <= area.maxX &&
        b.minY >= area.minY &&
        b.maxY <= area.maxY;
    ElectricalPlanAnnotations lay(ElectricalPlanData d) =>
        layoutElectricalPlanAnnotations(d,
            map: (x, y) => (x: x, y: y),
            sizes: kElectricalPlanPdfSizes,
            area: area);

    test('F1: a load at the right frame edge flips its tag inside', () {
      const d = ElectricalPlanData(nodes: [
        ElectricalPlanNode(
            x: 392,
            y: 150,
            tag: 'Pump P-01',
            sub: 'MCCB 125A',
            kind: ElectricalPlanNodeKind.load),
      ]);
      final ann = lay(d);
      final t = ann.nodeTags[0]!;
      expect(inside(t.box), isTrue);
      expect(t.box.maxX, lessThan(392)); // the left-hand slot
      expect(ann.overlapCount, 0);
    });

    test('F2: co-located loads get separate, symbol-clear tag blocks', () {
      const d = ElectricalPlanData(nodes: [
        ElectricalPlanNode(
            x: 200,
            y: 150,
            tag: 'Pump P-01',
            sub: 'MCCB 40A',
            kind: ElectricalPlanNodeKind.load),
        ElectricalPlanNode(
            x: 204,
            y: 152,
            tag: 'Pump P-02',
            sub: 'MCCB 40A',
            kind: ElectricalPlanNodeKind.load),
        ElectricalPlanNode(
            x: 198,
            y: 147,
            tag: 'Pump P-03',
            sub: 'MCCB 40A',
            kind: ElectricalPlanNodeKind.load),
      ]);
      final ann = lay(d);
      final boxes = [for (var i = 0; i < 3; i++) ann.nodeTags[i]!.box];
      for (var i = 0; i < 3; i++) {
        expect(inside(boxes[i]), isTrue);
        for (var j = 0; j < 3; j++) {
          final n = d.nodes[j];
          final sym = (minX: n.x - 5, minY: n.y - 5, maxX: n.x + 5, maxY: n.y + 5);
          expect(hit(boxes[i], sym), isFalse, reason: 'tag $i on symbol $j');
          if (i != j) expect(hit(boxes[i], boxes[j]), isFalse);
        }
      }
      // A block stacked off its symbol's row is leadered back to it.
      expect(ann.nodeTags.values.where((t) => t.leader != null), isNotEmpty);
      expect(ann.overlapCount, 0);
    });

    test('F2: a pile with no clear slot is COUNTED (the sheet stamps it)', () {
      final d = ElectricalPlanData(nodes: [
        for (var i = 0; i < 40; i++)
          ElectricalPlanNode(
              x: 200,
              y: 150,
              tag: 'Load L-$i',
              sub: 'MCB 16A',
              kind: ElectricalPlanNodeKind.load),
      ]);
      expect(lay(d).overlapCount, greaterThan(0));
    });
  });

  group('F5 electrical layout legend lists exactly what is drawn', () {
    test('loads only: no Panel / Kabel rows', () {
      const d = ElectricalPlanData(nodes: [
        ElectricalPlanNode(
            x: 0, y: 0, tag: 'L', kind: ElectricalPlanNodeKind.load),
      ], unplaced: [
        'Panel PP-1 (belum ditempatkan)'
      ]);
      expect(electricalPlanLegendRows(d), [ElectricalPlanLegendRow.load]);
    });
    test('panel + load + route: all three', () {
      const d = ElectricalPlanData(nodes: [
        ElectricalPlanNode(
            x: 0, y: 0, tag: 'P', kind: ElectricalPlanNodeKind.panel),
        ElectricalPlanNode(
            x: 9, y: 0, tag: 'L', kind: ElectricalPlanNodeKind.load),
      ], routes: [
        ElectricalPlanRoute(x1: 0, y1: 0, x2: 9, y2: 0),
      ]);
      expect(electricalPlanLegendRows(d), ElectricalPlanLegendRow.values);
    });
    test('the PDF / DXF print no row the sheet does not draw', () {
      const d = ElectricalPlanData(nodes: [
        ElectricalPlanNode(
            x: 0, y: 0, tag: 'L', kind: ElectricalPlanNodeKind.load),
      ]);
      final dxf = electricalPlanToDxf(
          data: d, projectName: 'P', sheetName: 'S');
      expect(dxf, contains('Beban / titik'));
      expect(dxf.contains('\nKabel\n'), isFalse);
      expect(dxf.contains('\nPanel\n'), isFalse);
    });
  });
}
