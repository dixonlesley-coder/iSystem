import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/report/reference_grid_builder.dart';
import 'package:mechx/store/reference_line_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';

void main() {
  group('buildReferenceGrid', () {
    test('a labelled vertical line becomes a lettered column axis', () {
      final grid = buildReferenceGrid([
        const ReferenceLine(
            id: 'r1', sheetId: 's1', x1: 300, y1: 20, x2: 300, y2: 500,
            label: 'A'),
      ], 's1');
      expect(grid.rows, isEmpty);
      expect(grid.columns, hasLength(1));
      expect(grid.columns.single.label, 'A');
      expect(grid.columns.single.position, closeTo(300, 0.01));
    });

    test('a horizontal line becomes a numbered row axis; auto labels order', () {
      final grid = buildReferenceGrid([
        // Two unlabelled horizontal lines (rows) + one unlabelled vertical.
        const ReferenceLine(id: 'r1', sheetId: 's1', x1: 0, y1: 400, x2: 900, y2: 400),
        const ReferenceLine(id: 'r2', sheetId: 's1', x1: 0, y1: 100, x2: 900, y2: 100),
        const ReferenceLine(id: 'r3', sheetId: 's1', x1: 200, y1: 0, x2: 200, y2: 600),
      ], 's1');
      // Rows sorted top→bottom get 1,2.
      expect(grid.rows.map((a) => a.label).toList(), ['1', '2']);
      expect(grid.rows[0].position, closeTo(100, 0.01)); // top first
      // The single column gets 'A'.
      expect(grid.columns.map((a) => a.label).toList(), ['A']);
    });

    test('a diagonal line is snap-only (never a grid axis)', () {
      final grid = buildReferenceGrid([
        const ReferenceLine(id: 'r1', sheetId: 's1', x1: 0, y1: 0, x2: 500, y2: 500),
      ], 's1');
      expect(grid.isEmpty, isTrue);
    });

    test('lines on another sheet are ignored', () {
      final grid = buildReferenceGrid([
        const ReferenceLine(id: 'r1', sheetId: 'other', x1: 300, y1: 20, x2: 300, y2: 500),
      ], 's1');
      expect(grid.isEmpty, isTrue);
    });
  });

  group('export wiring', () {
    // A minimal net with one horizontal run so planToPdf has content to draw.
    const net = Network(
      nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 100, y: 300, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 700, y: 300, floorIndex: 0),
      ],
      edges: [
        NetEdge(id: 'e0', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      ],
    );
    const sizing = {
      'e0': EdgeSizing(
        edgeId: 'e0',
        service: ServiceType.coldWater,
        flow: FlowRate(0.005),
        diameter: Diameter(0.032),
        velocity: Velocity(1.5),
      ),
    };
    const lengths = {'e0': Length(6.0)};

    test('a labelled vertical reference line reaches planToPdf grid param', () {
      final grid = buildReferenceGrid([
        const ReferenceLine(
            id: 'r1', sheetId: 's1', x1: 400, y1: 20, x2: 400, y2: 560,
            label: 'GL-A'),
      ], 's1');
      expect(grid.columns.single.label, 'GL-A');

      final withGrid = latin1.decode(planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: lengths,
        sheetId: 's1',
        floorIndex: 0,
        projectName: 'T',
        sheetName: 'G',
        dateString: '2026-07-06',
        grid: grid,
      ));
      final withoutGrid = latin1.decode(planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: lengths,
        sheetId: 's1',
        floorIndex: 0,
        projectName: 'T',
        sheetName: 'G',
        dateString: '2026-07-06',
        grid: null,
      ));
      // The bubble label from the reference line is drawn only when the grid
      // reaches the exporter.
      expect(withGrid, contains('(GL-A) Tj'));
      expect(withoutGrid, isNot(contains('(GL-A) Tj')));
      // And the setting-out chain linetype appears with the grid.
      expect(withGrid, contains('[8 3 2 3] 0 d'));
    });
  });
}
