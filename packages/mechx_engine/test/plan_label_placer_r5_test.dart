// R5 — the issued plan sheets read like a drafted plan: run tags hug their
// own run (both sides, several stations, parallel), split to two lines before
// escaping, never overprint another run when a clear slot exists, escape on a
// CAPPED leader; round ducts print the real diameter sign; gravity runs print
// no fabricated CL. Expected values are hand-derived from the placer's own
// metric (text width = chars × size × 0.55, height = size, beside offset
// 0.7 × size, two-line pitch 1.3 × size).
import 'dart:convert';
import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('composePlanEdgeLabelLines', () {
    test('identity + size over the set-out data', () {
      expect(
          composePlanEdgeLabelLines(
              tag: 'CW-F2',
              size: 'DN15',
              length: '4.6 m',
              elevation: 'CL +3.70',
              slope: null),
          ['CW-F2 · DN15', '4.6 m - CL +3.70']);
      expect(
          composePlanEdgeLabelLines(
              tag: 'D-F2', size: 'DN40', length: '2.4 m', slope: '1:100'),
          ['D-F2 · DN40', '2.4 m - 1:100']);
    });

    test('nothing to split ⇒ null', () {
      expect(composePlanEdgeLabelLines(tag: 'CW-F2', size: 'DN15'), isNull);
      expect(composePlanEdgeLabelLines(length: '4 m'), isNull);
    });
  });

  group('placePlanLabel', () {
    test('a label much longer than its run splits to two lines beside it', () {
      // Run (0,0)→(60,0); one-line width 31 × 9 × 0.55 = 153.45 > 60 × 1.15,
      // so the two-line form goes first. Block at the midpoint (30, 0), upper
      // side, near edge d = 6.3, height h = 9 + 11.7 = 20.7:
      //   line 0 baseline = d + h − 9 = 18.0, start x = 30 − 59.4/2 = 0.3
      //   line 1 baseline = 18.0 − 11.7 = 6.3, start x = 30 − 79.2/2 = −9.6
      final layout = PlanLabelLayout();
      final p = placePlanLabel(
        ax: 0,
        ay: 0,
        bx: 60,
        by: 0,
        text: 'CW-F2 · DN15 - 4.6 m - CL +3.70',
        splitLines: const ['CW-F2 · DN15', '4.6 m - CL +3.70'],
        textSize: 9,
        layout: layout,
      );
      expect(p.leaderAnchor, isNull);
      expect(p.lines, hasLength(2));
      expect(p.lines[0].text, 'CW-F2 · DN15');
      expect(p.lines[0].x, closeTo(0.3, 1e-9));
      expect(p.lines[0].y, closeTo(18.0, 1e-9));
      expect(p.lines[1].text, '4.6 m - CL +3.70');
      expect(p.lines[1].x, closeTo(-9.6, 1e-9));
      expect(p.lines[1].y, closeTo(6.3, 1e-9));
      expect(layout.labelCount, 1);
    });

    test('another run through the midpoint slides the tag along its own run',
        () {
      // Own run 'a' (0,0)→(200,0); run 'b' crosses it vertically at x = 100.
      // Both midpoint slots (u ±9.9 about x = 100) touch 'b' → rejected; the
      // quarter station x = 50 is clear, upper side, no leader:
      //   anchor = (50 − 19.8/2, 0.7·9) = (40.1, 6.3).
      final layout = PlanLabelLayout()
        ..addRun('a', 0, 0, 200, 0)
        ..addRun('b', 100, -50, 100, 50);
      final p = placePlanLabel(
          ax: 0,
          ay: 0,
          bx: 200,
          by: 0,
          text: 'DN50',
          textSize: 9,
          layout: layout,
          ownRunId: 'a');
      expect(p.leaderAnchor, isNull);
      expect(p.x, closeTo(40.1, 1e-9));
      expect(p.y, closeTo(6.3, 1e-9));
    });

    test('its OWN run never counts as an obstacle', () {
      final layout = PlanLabelLayout()..addRun('a', 0, 0, 100, 0);
      final p = placePlanLabel(
          ax: 0,
          ay: 0,
          bx: 100,
          by: 0,
          text: 'DN50',
          textSize: 9,
          layout: layout,
          ownRunId: 'a');
      // The original greedy first slot: (50 − 9.9, 6.3).
      expect(p.leaderAnchor, isNull);
      expect(p.x, closeTo(40.1, 1e-9));
      expect(p.y, closeTo(6.3, 1e-9));
    });

    test(
        'collision is ORIENTED: parallel diagonal tags whose bounds overlap '
        'both stay beside their runs', () {
      // Two parallel 45° runs 30 apart; 20-char tags (w = 99). Their
      // axis-aligned bounds overlap (each ±38.2 about centres ~30 apart), but
      // the rotated rectangles sit on opposite sides of run A — A's tag on its
      // far side, B's between the runs (v 6.3..15.3 of 30) — so neither moves.
      const s = 30 / math.sqrt2; // perpendicular offset components
      final layout = PlanLabelLayout()
        ..addRun('A', 0, 0, 100, 100)
        ..addRun('B', s, -s, 100 + s, 100 - s);
      const text = 'SA-F2 · Ø200 - 2.8 m';
      final a = placePlanLabel(
          ax: 0,
          ay: 0,
          bx: 100,
          by: 100,
          text: text,
          textSize: 9,
          layout: layout,
          ownRunId: 'A');
      final b = placePlanLabel(
          ax: s,
          ay: -s,
          bx: 100 + s,
          by: 100 - s,
          text: text,
          textSize: 9,
          layout: layout,
          ownRunId: 'B');
      expect(a.leaderAnchor, isNull);
      expect(b.leaderAnchor, isNull);
      // B kept its midpoint-upper slot: mid (50+s, 50−s) + normal × 6.3 −
      // bearing × 49.5, normal (−√½, √½), bearing (√½, √½).
      const r = math.sqrt1_2;
      expect(b.x, closeTo(50 + s - r * 6.3 - r * 49.5, 1e-9));
      expect(b.y, closeTo(50 - s + r * 6.3 - r * 49.5, 1e-9));
      expect(b.angleDeg, closeTo(45, 1e-9));
    });

    test('an escaped tag never sits further than the hard leader cap', () {
      // Every slot near the run is occupied (a dense band of boxes): the tag is
      // still placed (never dropped) on a leader no longer than 16 × 9 = 144.
      final layout = PlanLabelLayout(boxes: [
        for (var dy = -300.0; dy <= 300.0; dy += 5)
          (minX: -200, minY: dy, maxX: 200, maxY: dy + 4),
      ]);
      final p = placePlanLabel(
          ax: 0,
          ay: 0,
          bx: 40,
          by: 0,
          text: 'DN80',
          textSize: 9,
          layout: layout);
      expect(p.leaderAnchor, isNotNull);
      final a = p.leaderAnchor!, e = p.leaderEnd!;
      final len = math.sqrt(math.pow(e.x - a.x, 2) + math.pow(e.y - a.y, 2));
      expect(len, lessThanOrEqualTo(kPlanLeaderHardMaxFactor * 9 + 1e-9));
      // The leader starts ON the run.
      expect(a.y, closeTo(0, 1e-9));
      expect(a.x, inInclusiveRange(0, 40));
    });

    test('a clear slot is chosen within the PREFERRED cap when one exists', () {
      // Both beside rows blocked by a label above and below; one row further
      // out (d = 18) is clear on both sides ⇒ leader 18 − 1.35 = 16.65 ≤ 72.
      final layout = PlanLabelLayout(boxes: [
        (minX: -50, minY: 0.5, maxX: 150, maxY: 16),
        (minX: -50, minY: -16, maxX: 150, maxY: -0.5),
      ]);
      final p = placePlanLabel(
          ax: 0,
          ay: 0,
          bx: 100,
          by: 0,
          text: 'DN80',
          textSize: 9,
          layout: layout);
      final a = p.leaderAnchor!, e = p.leaderEnd!;
      expect((e.y - a.y).abs(), closeTo(16.65, 1e-9));
      expect((e.y - a.y).abs(),
          lessThanOrEqualTo(kPlanLeaderMaxFactor * 9 + 1e-9));
    });

    test('deterministic: identical inputs give identical placements', () {
      LeaderedLabelPlacement run() {
        final layout = PlanLabelLayout()
          ..addRun('a', 0, 0, 80, 0)
          ..addRun('b', 40, -30, 40, 30);
        placePlanLabel(
            ax: 40,
            ay: -30,
            bx: 40,
            by: 30,
            text: 'X · DN25 - 3 m',
            textSize: 9,
            layout: layout,
            ownRunId: 'b');
        return placePlanLabel(
            ax: 0,
            ay: 0,
            bx: 80,
            by: 0,
            text: 'Y · DN50 - 4 m - CL +2.70',
            splitLines: const ['Y · DN50', '4 m - CL +2.70'],
            textSize: 9,
            layout: layout,
            ownRunId: 'a');
      }

      final p1 = run(), p2 = run();
      expect(p1.lines.map((l) => '${l.text}@${l.x},${l.y}'),
          p2.lines.map((l) => '${l.text}@${l.x},${l.y}'));
    });
  });

  group('plan exporters (PDF == DXF)', () {
    const net = Network(nodes: [
      NetNode(id: 'a', sheetId: 's', x: 100, y: 100, floorIndex: 0),
      NetNode(id: 'b', sheetId: 's', x: 140, y: 100, floorIndex: 0),
      NetNode(id: 'c', sheetId: 's', x: 100, y: 300, floorIndex: 0),
      NetNode(id: 'd', sheetId: 's', x: 400, y: 300, floorIndex: 0),
    ], edges: [
      // A SHORT pipe run (40 px × 0.02 = 0.8 m) carrying a long label.
      NetEdge(id: 'w', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      // A round duct.
      NetEdge(id: 'r', fromId: 'c', toId: 'd', service: ServiceType.duct),
    ]);
    EdgeSizing sz(String id, ServiceType s, double mm) => EdgeSizing(
          edgeId: id,
          service: s,
          flow: const FlowRate(0.001),
          diameter: Diameter.mm(mm),
          velocity: const Velocity(1),
        );
    final sizing = {
      'w': sz('w', ServiceType.coldWater, 15),
      'r': sz('r', ServiceType.duct, 200),
    };
    const tags = {'w': 'CW-F1', 'r': 'SA-F1'};
    const elev = {'w': 'CL +3.70 drop 2.60 m', 'r': 'CL +3.70'};

    String pdf() => latin1.decode(planToPdf(
          net: net,
          sizing: sizing,
          edgeLengths: const {'w': Length(0.8), 'r': Length(6)},
          sheetId: 's',
          floorIndex: 0,
          projectName: 'P',
          sheetName: 'S',
          dateString: '2026-01-01',
          metersPerPixel: 0.02,
          edgeTags: tags,
          edgeElevationLabels: elev,
        ));
    String dxf() => networkToDxf(
          net: net,
          sizing: sizing,
          edgeLengths: const {'w': Length(0.8), 'r': Length(6)},
          sheetId: 's',
          floorIndex: 0,
          metersPerPixel: 0.02,
          edgeTags: tags,
          edgeElevationLabels: elev,
        );

    test('a round duct prints the real diameter sign in both formats', () {
      // PDF: WinAnsi 0xD8 (latin1 'Ø'), never the ASCII 'O' stand-in.
      expect(pdf(), contains('SA-F1 · Ø200'));
      expect(pdf(), isNot(contains('O200')));
      // DXF: the AutoCAD %%c control code (via dxfText; '·' → '-').
      expect(dxf(), contains('SA-F1 - %%c200'));
      expect(dxf(), isNot(contains('O200')));
    });

    test('the short run’s long tag prints as TWO lines in BOTH formats', () {
      // One-line width 33 × 0.55 × size ≫ the 0.8 m run ⇒ the shared placer
      // takes the split form first — the same choice in points and in mm.
      expect(pdf(), contains('(CW-F1 · DN15) Tj'));
      expect(pdf(), contains('(0.8 m - CL +3.70 drop 2.60 m) Tj'));
      expect(dxf(), contains('\n1\nCW-F1 - DN15\n'));
      expect(dxf(), contains('\n1\n0.8 m - CL +3.70 drop 2.60 m\n'));
    });
  });

  group('gravity runs print no fabricated CL (R5)', () {
    const one = BuildingLevels([Floor('L2', Length(4))]);
    const net = Network(nodes: [
      NetNode(id: 'm', sheetId: 's', x: 0, y: 0, floorIndex: 0),
      NetNode(id: 'm2', sheetId: 's', x: 100, y: 0, floorIndex: 0),
      NetNode(id: 'v', sheetId: 's', x: 0, y: 100, floorIndex: 0),
      NetNode(id: 'v2', sheetId: 's', x: 100, y: 100, floorIndex: 0),
      NetNode(id: 'w', sheetId: 's', x: 0, y: 200, floorIndex: 0),
      NetNode(id: 'w2', sheetId: 's', x: 100, y: 200, floorIndex: 0),
    ], edges: [
      NetEdge(id: 'd', fromId: 'm', toId: 'm2', service: ServiceType.drainage),
      NetEdge(id: 'vt', fromId: 'v', toId: 'v2', service: ServiceType.vent),
      NetEdge(
          id: 'cw', fromId: 'w', toId: 'w2', service: ServiceType.coldWater),
    ]);

    test('drainage + vent omit CL; a pressurized main keeps it', () {
      // The model resolves a gravity `main` to its own ceiling (no invert
      // datum), so no set-out height is printed; the cold-water main still
      // hangs at the 4.0 − 0.3 = 3.70 ceiling main level.
      final labels = planEdgeElevationLabels(net, one);
      expect(labels.containsKey('d'), isFalse);
      expect(labels.containsKey('vt'), isFalse);
      expect(labels['cw'], 'CL +3.70');
    });
  });
}
