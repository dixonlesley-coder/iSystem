// Audit 2026-10, group C2 — drawing-output honesty pins.
//
// Each group below pins one confirmed drawing-output finding with a geometric
// or textual invariant derived from first principles (the arithmetic is in the
// comments), not from a captured byte stream.
import 'dart:convert';
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

// ── drawing-output-1 / -6 fixture: two boards on the ground floor ───────────
// MDP (ground, first column) feeds LP-1 (L1), EMG (ground, second column) and
// PP-1 (L2). An ordinary layout — two boards sharing one floor.
ElectricalProject _riserProject() => const ElectricalProject(
        id: 'p',
        name: 'P',
        transformerKva: ApparentPower(630000),
        panels: [
          ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              layoutPos: LayoutPos(sheetId: 's0', floorIndex: 0, x: 0, y: 0),
              circuits: [
                ElectricalCircuit(
                    id: 'f1',
                    name: 'F LP',
                    loadKind: LoadKind.feeder,
                    feedsPanelId: 'LP',
                    length: Length(18)),
                ElectricalCircuit(
                    id: 'f2',
                    name: 'F EMG',
                    loadKind: LoadKind.feeder,
                    feedsPanelId: 'EMG',
                    length: Length(20)),
                ElectricalCircuit(
                    id: 'f3',
                    name: 'F PP',
                    loadKind: LoadKind.feeder,
                    feedsPanelId: 'PP',
                    length: Length(24)),
              ]),
          ElectricalPanel(
              id: 'LP',
              name: 'LP-1',
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f1',
              layoutPos: LayoutPos(sheetId: 's1', floorIndex: 1, x: 0, y: 0),
              circuits: [
                ElectricalCircuit(
                    id: 'l1',
                    name: 'Light',
                    loadKind: LoadKind.lighting,
                    isLighting: true,
                    loadW: 1200,
                    length: Length(20))
              ]),
          ElectricalPanel(
              id: 'PP',
              name: 'PP-1',
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f3',
              layoutPos: LayoutPos(sheetId: 's2', floorIndex: 2, x: 0, y: 0),
              circuits: [
                ElectricalCircuit(
                    id: 'p1',
                    name: 'Gen',
                    loadKind: LoadKind.general,
                    loadW: 3000,
                    length: Length(20))
              ]),
          ElectricalPanel(
              id: 'EMG',
              name: 'EMG',
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f2',
              layoutPos: LayoutPos(sheetId: 's0', floorIndex: 0, x: 5, y: 0),
              circuits: [
                ElectricalCircuit(
                    id: 'e1',
                    name: 'EL',
                    loadKind: LoadKind.lighting,
                    isLighting: true,
                    loadW: 800,
                    length: Length(20))
              ]),
        ]);

const _threeStoreys = BuildingLevels(
    [Floor('G', Length(4)), Floor('L1', Length(4)), Floor('L2', Length(4))]);

/// True when the axis-aligned segment [l] passes through the INTERIOR of [r]
/// (a 0.5 pt inset, so a leg that merely TOUCHES a box edge — its own endpoint
/// board — is fine).
bool _crossesInterior(SldLine l, SldRect r) {
  const e = 0.5;
  final x0 = r.x + e, x1 = r.x + r.w - e, y0 = r.y + e, y1 = r.y + r.h - e;
  if (l.y1 == l.y2) {
    final lo = math.min(l.x1, l.x2), hi = math.max(l.x1, l.x2);
    return l.y1 > y0 && l.y1 < y1 && lo < x1 && hi > x0;
  }
  if (l.x1 == l.x2) {
    final lo = math.min(l.y1, l.y2), hi = math.max(l.y1, l.y2);
    return l.x1 > x0 && l.x1 < x1 && lo < y1 && hi > y0;
  }
  return false;
}

void main() {
  group('drawing-output-1: riser feeders/supply never cross a board box', () {
    test('two boards on one floor: no medium line through any panel interior',
        () {
      // Before the fix the three MDP feeders ran MDP-right-edge -> channel at
      // MDP mid-height, i.e. straight through EMG (the next column on the same
      // band), and the source drop came down MDP's centre column (x = 174 + 84
      // = 258) through LP-1, which occupies the same column on L1.
      final p = _riserProject();
      final r = computeSystem(const PuilProfile(), p);
      final sheet = buildElectricalRiser(
          project: p, result: r, building: _threeStoreys, sourceChain: true);
      // Panel boxes are the 168 x 46 compact nodes (wider than any glyph rect).
      final rects =
          sheet.prims.whereType<SldRect>().where((x) => x.w > 100).toList();
      final lines = sheet.prims
          .whereType<SldLine>()
          .where((l) => l.weight == SldWeight.medium)
          .toList();
      expect(rects.length, greaterThanOrEqualTo(4));
      final hits = <String>[
        for (final l in lines)
          for (final rc in rects)
            if (_crossesInterior(l, rc))
              '(${l.x1},${l.y1})-(${l.x2},${l.y2}) through [${rc.x},${rc.y}]'
      ];
      expect(hits, isEmpty);
    });

    test('one board per band keeps the straight legacy feeder legs', () {
      // MDP alone on G, LP-1 alone on L1: nothing blocks, so the MDP->LP-1
      // feeder is exactly the legacy three legs — parent right edge (174+168 =
      // 342) at MDP mid -> channel, channel vertical, channel -> LP-1 right.
      const p = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            layoutPos: LayoutPos(sheetId: 's0', floorIndex: 0, x: 0, y: 0),
            circuits: [
              ElectricalCircuit(
                  id: 'f1',
                  name: 'F LP',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'LP',
                  length: Length(18)),
            ]),
        ElectricalPanel(
            id: 'LP',
            name: 'LP-1',
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f1',
            layoutPos: LayoutPos(sheetId: 's1', floorIndex: 1, x: 0, y: 0),
            circuits: [
              ElectricalCircuit(
                  id: 'l1',
                  name: 'Light',
                  loadKind: LoadKind.lighting,
                  isLighting: true,
                  loadW: 1200,
                  length: Length(20))
            ]),
      ]);
      final r = computeSystem(const PuilProfile(), p);
      const b = BuildingLevels([Floor('G', Length(4)), Floor('L1', Length(4))]);
      final sheet = buildElectricalRiser(project: p, result: r, building: b);
      // Bands: L1 (top) at y 0, G at y 160 (_riserBandH). MDP mid = 160 + 23 =
      // 183, LP-1 mid = 23. sheetMaxX = 150 + 24 + 192 = 366 -> channel 406.
      final medium = sheet.prims
          .whereType<SldLine>()
          .where((l) => l.weight == SldWeight.medium)
          // Undirected: a segment reads the same either way it is stroked
          // (the trunk merge emits each piece low->high).
          .map((l) {
        final fwd = l.x1 < l.x2 || (l.x1 == l.x2 && l.y1 <= l.y2);
        return fwd
            ? '${l.x1},${l.y1},${l.x2},${l.y2}'
            : '${l.x2},${l.y2},${l.x1},${l.y1}';
      }).toSet();
      expect(medium, {
        '342.0,183.0,406.0,183.0',
        '406.0,23.0,406.0,183.0',
        '342.0,23.0,406.0,23.0'
      });
    });
  });

  group('drawing-output-6: overview escaped label clears its branch line', () {
    test('no feeder label glyph box contains a horizontal it overlaps in x',
        () {
      // Three feeders leave MDP on one shared mid horizontal (y = midY). The
      // default tag baseline is midY - 4; the first escape below used to be
      // midY + 5, whose glyph box [midY + 5 - 6.5, midY + 5] = [midY - 1.5,
      // midY + 5] straddles the line. It must now start at midY + 4 + 6.5 +
      // 2.5 - 4 = midY + 9 (box [midY + 2.5, midY + 9]).
      final p = _riserProject();
      final r = computeSystem(const PuilProfile(), p);
      final sheet = buildElectricalOverview(project: p, result: r);
      final labels = sheet.prims
          .whereType<SldLabel>()
          .where((t) => t.text.contains('mm2'))
          .toList();
      final hLines = sheet.prims
          .whereType<SldLine>()
          .where((l) => l.y1 == l.y2 && l.weight == SldWeight.medium)
          .toList();
      expect(labels.length, 3);
      final hits = <String>[];
      for (final t in labels) {
        final w = t.text.length * t.size * kElectricalRiserLabelCharW;
        final top = t.y - t.size;
        for (final l in hLines) {
          final lo = math.min(l.x1, l.x2), hi = math.max(l.x1, l.x2);
          if (l.y1 > top && l.y1 < t.y && lo < t.x + w && hi > t.x) {
            hits.add('"${t.text}" @${t.y} struck by y=${l.y1}');
          }
        }
      }
      expect(hits, isEmpty);
    });
  });

  group('drawing-output-2: plan CL labels stay within the storey', () {
    // 3 x 4.0 m storeys, default mounting (ceilingDrop 0.3 m): floor-0 ceiling
    // main at 0 + 4.0 - 0.3 = 3.70 m; roof (the solve's plant datum) at 12.0 m.
    const net = Network(nodes: [
      NetNode(
          id: 'tk',
          sheetId: 's',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant,
          component: NodeComponent.groundTank),
      NetNode(
          id: 'pu',
          sheetId: 's',
          x: 100,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant,
          component: NodeComponent.pump),
      NetNode(id: 'm', sheetId: 's', x: 300, y: 0, floorIndex: 0),
      NetNode(
          id: 'hi',
          sheetId: 's',
          x: 300,
          y: 200,
          floorIndex: 0,
          role: NodeRole.plant,
          component: NodeComponent.pump,
          elevation: Length(12)),
    ], edges: [
      NetEdge(
          id: 'tp', fromId: 'tk', toId: 'pu', service: ServiceType.coldWater),
      NetEdge(
          id: 'pm', fromId: 'pu', toId: 'm', service: ServiceType.coldWater),
      NetEdge(
          id: 'hm', fromId: 'hi', toId: 'm', service: ServiceType.coldWater),
    ]);

    test(
        'a floor-standing plant prints its solved floor height, never the roof',
        () {
      final labels = planEdgeElevationLabels(net, _threeStoreys);
      // The solve puts a datum-less pump / ground tank on its floor surface
      // (water-drainage-1): FFL 0.00. The label renders those elevations.
      // tank->pump: both ends at 0.00 ⇒ a level run, bare token (was +12.00).
      expect(labels['tp'], 'CL +0.00');
      // pump->main: the horizontal leg hangs at the MAIN (3.70 above FFL) and
      // the 3.70 - 0.00 difference is a vertical drop to the pump (R3
      // reports-4) — never the misleading mean (0 + 3.7)/2 = 1.85.
      expect(labels['pm'], 'CL +3.70 drop 3.70 m');
      for (final v in labels.values) {
        final h = double.parse(v.substring(4).split(' ').first); // 'CL +x.xx'
        expect(h, inInclusiveRange(0, 4.0), reason: v);
      }
    });

    test('a CL outside [0, storey] is omitted, never printed', () {
      // The explicit-datum pump at 12.0 m on a 4 m storey: its leg to the 3.70
      // main is 8.30 m > the 4.0 m storey — not settable on this floor, so no
      // token.
      final labels = planEdgeElevationLabels(net, _threeStoreys);
      expect(labels.containsKey('hm'), isFalse);
    });

    test('the label equals the solve datum for a floor-standing plant', () {
      // One elevation source (golden rule 5): label == nodeElevation == FFL 0.
      expect(nodeElevation(net.nodeById('pu')!, _threeStoreys).meters, 0.0);
      expect(planSettingOutElevation(net.nodeById('pu')!, _threeStoreys).meters,
          0.0);
    });

    test('a datum-less ROOF tank on a lower sheet falls back to its ceiling',
        () {
      const rt = NetNode(
          id: 'rt',
          sheetId: 's',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant,
          component: NodeComponent.roofTank);
      // Solve: roof datum 12.0 m; the plan label uses floor 0's ceiling 3.70 m.
      expect(nodeElevation(rt, _threeStoreys).meters, 12.0);
      expect(planSettingOutElevation(rt, _threeStoreys).meters,
          closeTo(3.70, 1e-9));
    });
  });

  group('drawing-output-8: whole-metre lengths print consistently', () {
    test('elevation-delta float noise prints like the exact value', () {
      // ceiling(2) - ceiling(1) = 11.7 - 7.7 = 3.999999999999999 in doubles;
      // rounding to the printed 0.1 m first gives 4.0 -> '4.0 m', the same as
      // the exact ceiling(1) - ceiling(0) = 7.7 - 3.7 = 4.0 (Round 20: one
      // fixed 0.1 m precision on every sheet, plan == riser == report).
      const noisy = 11.7 - 7.7;
      expect(noisy, isNot(4.0));
      expect(planLengthLabel(const Length(noisy)), '4.0 m');
      expect(planLengthLabel(const Length(4.0)), '4.0 m');
      expect(planLengthLabel(const Length(3.5)), '3.5 m');
      // 4.44 -> 4.4 (one decimal kept); 4.96 -> 5.0 -> '5.0 m'.
      expect(planLengthLabel(const Length(4.44)), '4.4 m');
      expect(planLengthLabel(const Length(4.96)), '5.0 m');
    });
  });

  // ── Plan fixtures for -3/-4/-5/-7 ──────────────────────────────────────────
  // A run network spanning x 100..600 px, y 300..500 px at 0.02 m/px (10 m x
  // 4 m), with a setting-out grid whose column D (x 1100) and row 1 (y 230)
  // lie OUTSIDE the network extent — the normal case.
  const planNet = Network(nodes: [
    NetNode(id: 'a', sheetId: 's', x: 100, y: 300, floorIndex: 0),
    NetNode(id: 'b', sheetId: 's', x: 600, y: 300, floorIndex: 0),
    NetNode(id: 'c', sheetId: 's', x: 600, y: 500, floorIndex: 0),
  ], edges: [
    NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
    NetEdge(id: 'e2', fromId: 'b', toId: 'c', service: ServiceType.coldWater),
  ]);
  EdgeSizing dn(String id, double mm,
          {ServiceType s = ServiceType.coldWater}) =>
      EdgeSizing(
          edgeId: id,
          service: s,
          flow: FlowRate.litersPerSecond(1),
          diameter: Diameter.mm(mm),
          velocity: const Velocity(1.2));
  final planSizing = {'e': dn('e', 32), 'e2': dn('e2', 32)};
  const planGrid = ReferenceGrid(
    columns: [
      GridAxis('A', 100),
      GridAxis('B', 350),
      GridAxis('C', 600),
      GridAxis('D', 1100)
    ],
    rows: [GridAxis('1', 230), GridAxis('2', 300), GridAxis('3', 500)],
  );
  // A3 landscape page 1190.55 x 841.89 pt with a 48 pt margin ⇒ the frame is
  // x 48..1142.55, y 48..793.89.
  const frameL = 48.0, frameR = 1190.55 - 48, frameB = 48.0;
  const frameT = 841.89 - 48;

  group('drawing-output-3: the setting-out grid joins the plan fit', () {
    test('PDF: every grid line + bubble inside the frame; rows reach columns',
        () {
      final pdf = latin1.decode(planToPdf(
        net: planNet,
        sizing: planSizing,
        edgeLengths: {'e': const Length(10)},
        sheetId: 's',
        floorIndex: 0,
        projectName: 'P',
        sheetName: 'S',
        dateString: '2026-01-01',
        metersPerPixel: 0.02,
        grid: planGrid,
        chrome: const DrawingChrome(drawingNumber: 'M-101'),
      ));
      final start = pdf.indexOf('[8 3 2 3] 0 d');
      final block = pdf.substring(start, pdf.indexOf('[] 0 d', start));
      final lines = RegExp(r'([\d.-]+) ([\d.-]+) m ([\d.-]+) ([\d.-]+) l S')
          .allMatches(block)
          .toList();
      expect(lines.length, 7); // 4 columns + 3 rows
      final cols = <double>[];
      final rows = <(double, double)>[];
      for (final m in lines) {
        final x1 = double.parse(m[1]!), y1 = double.parse(m[2]!);
        final x2 = double.parse(m[3]!), y2 = double.parse(m[4]!);
        for (final x in [x1, x2]) {
          expect(x, inInclusiveRange(frameL, frameR));
        }
        for (final y in [y1, y2]) {
          expect(y, inInclusiveRange(frameB, frameT));
        }
        if (x1 == x2) cols.add(x1);
        if (y1 == y2) rows.add((math.min(x1, x2), math.max(x1, x2)));
        // Column line top / row line left end + the 20 pt bubble strip
        // (centre r + 2 = 11 off the end, radius 9) stays in the frame too.
        if (x1 == x2) expect(math.max(y1, y2) + 20, lessThanOrEqualTo(frameT));
        if (y1 == y2)
          expect(math.min(x1, x2) - 20, greaterThanOrEqualTo(frameL));
      }
      for (final r in rows) {
        for (final cx in cols) {
          expect(cx, inInclusiveRange(r.$1 - 0.01, r.$2 + 0.01));
        }
      }
    });

    test('DXF: column lines span every row axis and vice versa', () {
      final dxf = networkToDxf(
          net: planNet,
          sizing: planSizing,
          sheetId: 's',
          floorIndex: 0,
          metersPerPixel: 0.02,
          grid: planGrid);
      final ents = _dxfEntities(dxf);
      final grid = ents.where(
          (e) => e['0']!.first == 'LINE' && e['8']?.first == 'G-ANNO-GRID');
      // mm world, Y negated: rows at -230/-300/-500 px x 20 = -4600 / -6000 /
      // -10000 mm; columns at 2000 / 7000 / 12000 / 22000 mm.
      for (final l in grid) {
        final x1 = double.parse(l['10']!.first),
            y1 = double.parse(l['20']!.first);
        final x2 = double.parse(l['11']!.first),
            y2 = double.parse(l['21']!.first);
        if (x1 == x2) {
          expect({math.min(y1, y2), math.max(y1, y2)}, {-10000.0, -4600.0});
        } else {
          expect({math.min(x1, x2), math.max(x1, x2)}, {2000.0, 22000.0});
        }
      }
    });
  });

  group('drawing-output-4: plan DXF chrome sits outside the grid', () {
    test('no title / legend / north TEXT box meets a grid line or bubble', () {
      final dxf = networkToDxf(
        net: planNet,
        sizing: planSizing,
        sheetId: 's',
        floorIndex: 0,
        metersPerPixel: 0.02,
        grid: planGrid,
        chrome: const DrawingChrome(
            drawingNumber: 'M-101',
            revisionNumber: 'Rev. 0',
            sheetIndex: 1,
            sheetTotal: 3,
            legendServices: [ServiceType.coldWater]),
      );
      final ents = _dxfEntities(dxf);
      final gridLines = ents.where(
          (e) => e['0']!.first == 'LINE' && e['8']?.first == 'G-ANNO-GRID');
      final bubbles = ents.where(
          (e) => e['0']!.first == 'CIRCLE' && e['8']?.first == 'G-ANNO-GRID');
      final chromeText = ents.where((e) =>
          e['0']!.first == 'TEXT' &&
          // Round 14 (drafting-visual-5): the calibrated plan chrome rides the
          // G-ANNO-* layers and now includes the full ISO title block.
          const {'G-ANNO-TTLB', 'G-ANNO-LEGN', 'G-ANNO-SCAL', 'G-ANNO-NRTH'}
              .contains(e['8']?.first));
      expect(chromeText, isNotEmpty);
      for (final t in chromeText) {
        final tx = double.parse(t['10']!.first),
            ty = double.parse(t['20']!.first);
        final h = double.parse(t['40']!.first);
        final w = t['1']!.first.length * h * 0.6;
        // TEXT box: x tx..tx+w, y ty..ty+h (baseline at ty).
        for (final l in gridLines) {
          final x1 = double.parse(l['10']!.first),
              y1 = double.parse(l['20']!.first);
          final x2 = double.parse(l['11']!.first),
              y2 = double.parse(l['21']!.first);
          final hitsBox = math.max(x1, x2) >= tx &&
              math.min(x1, x2) <= tx + w &&
              math.max(y1, y2) >= ty &&
              math.min(y1, y2) <= ty + h;
          expect(hitsBox, isFalse, reason: '"${t['1']!.first}" on grid line');
        }
        for (final c in bubbles) {
          final cx = double.parse(c['10']!.first),
              cy = double.parse(c['20']!.first);
          final r = double.parse(c['40']!.first);
          final hitsBox = cx + r >= tx &&
              cx - r <= tx + w &&
              cy + r >= ty &&
              cy - r <= ty + h;
          expect(hitsBox, isFalse, reason: '"${t['1']!.first}" on a bubble');
        }
      }
    });
  });

  group('drawing-output-5: plan PDF run labels stay inside the frame', () {
    test('a supply fan at the sheet edge keeps every tag in the frame', () {
      // The sample's floor-1 supply-air fan: an AHU branch at x 940 fanning to
      // three diffusers at the right-most point (x 1040) of the sheet. The
      // width-bound fit puts x 1040 at the frame edge, so a 45-degree tag's
      // perpendicular escape used to run to x = 1228 pt (off the page).
      const net = Network(nodes: [
        NetNode(id: 'w', sheetId: 's', x: 90, y: 320, floorIndex: 1),
        NetNode(id: 'w2', sheetId: 's', x: 380, y: 320, floorIndex: 1),
        NetNode(id: 'ahu', sheetId: 's', x: 940, y: 520, floorIndex: 1),
        NetNode(id: 'h', sheetId: 's', x: 940, y: 320, floorIndex: 1),
        NetNode(id: 'd1', sheetId: 's', x: 1040, y: 220, floorIndex: 1),
        NetNode(id: 'd2', sheetId: 's', x: 1040, y: 320, floorIndex: 1),
        NetNode(id: 'd3', sheetId: 's', x: 1040, y: 420, floorIndex: 1),
      ], edges: [
        NetEdge(id: 'cw', fromId: 'w', toId: 'w2', service: ServiceType.duct),
        NetEdge(id: 't', fromId: 'ahu', toId: 'h', service: ServiceType.duct),
        NetEdge(id: 'e1', fromId: 'h', toId: 'd1', service: ServiceType.duct),
        NetEdge(id: 'e2', fromId: 'h', toId: 'd2', service: ServiceType.duct),
        NetEdge(id: 'e3', fromId: 'h', toId: 'd3', service: ServiceType.duct),
      ]);
      final ids = ['cw', 't', 'e1', 'e2', 'e3'];
      final pdf = latin1.decode(planToPdf(
        net: net,
        sizing: {
          for (final i in ids)
            i: dn(i, i == 't' ? 315 : 200, s: ServiceType.duct)
        },
        edgeLengths: {for (final i in ids) i: const Length(2.8)},
        sheetId: 's',
        floorIndex: 1,
        projectName: 'P',
        sheetName: 'S',
        dateString: '2026-01-01',
        metersPerPixel: 0.02,
        edgeTags: {for (final i in ids) i: 'SA-F2'},
        edgeElevationLabels: {for (final i in ids) i: 'CL +2.40'},
        chrome: const DrawingChrome(drawingNumber: 'M-102'),
      ));
      final tags = RegExp(r'BT /F1 9 Tf 0 0 0 rg ([\d.-]+) ([\d.-]+) '
              r'([\d.-]+) ([\d.-]+) ([\d.-]+) ([\d.-]+) Tm \((.*?)\) Tj ET')
          .allMatches(pdf)
          .toList();
      // R5: a tag may now print on TWO lines (`SA-F2 · Ø200` over
      // `2.8 m - CL +2.40`) before it ever escapes, each line its own `Tm`;
      // every one of the 5 tags is still present exactly once (its identity
      // line), and EVERY printed line must sit inside the frame.
      expect(tags.where((m) => m[7]!.startsWith('SA-F2')).length, 5);
      expect(tags.length, inInclusiveRange(5, 10));
      for (final m in tags) {
        final c = double.parse(m[1]!), s = double.parse(m[2]!);
        final x = double.parse(m[5]!), y = double.parse(m[6]!);
        // The placer's own metric: width = chars x 9 pt x 0.55, height 9 pt;
        // the rotated rect's corners are the anchor, + width along (c, s), +
        // height along (-s, c).
        final w = m[7]!.length * 9 * 0.55;
        final xs = [x, x + c * w, x - s * 9, x + c * w - s * 9];
        final ys = [y, y + s * w, y + c * 9, y + s * w + c * 9];
        expect(xs.reduce(math.max), lessThanOrEqualTo(frameR), reason: m[7]);
        expect(xs.reduce(math.min), greaterThanOrEqualTo(frameL), reason: m[7]);
        expect(ys.reduce(math.max), lessThanOrEqualTo(frameT), reason: m[7]);
        expect(ys.reduce(math.min), greaterThanOrEqualTo(frameB), reason: m[7]);
      }
    });
  });

  group('drawing-output-7: plan DXF labels == plan PDF labels', () {
    // A 220 px CW run at 0.02 m/px = 4.4 m, plus a CW riser to floor 1 whose
    // §10 length is a ceiling delta carrying float noise (11.7 - 7.7).
    const net = Network(nodes: [
      NetNode(id: 'a', sheetId: 's', x: 100, y: 300, floorIndex: 0),
      NetNode(id: 'b', sheetId: 's', x: 320, y: 300, floorIndex: 0),
      NetNode(id: 'up', sheetId: 's', x: 320, y: 300, floorIndex: 1),
    ], edges: [
      NetEdge(
          id: 'run', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      NetEdge(
          id: 'ris',
          fromId: 'b',
          toId: 'up',
          service: ServiceType.coldWater,
          kind: EdgeKind.riser),
    ]);
    final sizing = {'run': dn('run', 32), 'ris': dn('ris', 32)};
    const tags = {'run': 'CW-F1', 'ris': 'CW-R1'};
    const elev = {'run': 'CL +2.70'};
    final lengths = {
      'run': const Length(4.4),
      'ris': const Length(11.7 - 7.7),
    };

    test('run + riser TEXT carry size AND length, composed like the PDF', () {
      final dxf = networkToDxf(
        net: net,
        sizing: sizing,
        sheetId: 's',
        floorIndex: 0,
        metersPerPixel: 0.02,
        edgeTags: tags,
        edgeElevationLabels: elev,
        edgeLengths: lengths,
      );
      final pdf = latin1.decode(planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: lengths,
        sheetId: 's',
        floorIndex: 0,
        projectName: 'P',
        sheetName: 'S',
        dateString: '2026-01-01',
        metersPerPixel: 0.02,
        edgeTags: tags,
        edgeElevationLabels: elev,
      ));
      final texts = _dxfEntities(dxf)
          .where((e) => e['0']!.first == 'TEXT')
          .map((e) => e['1']!.first)
          .toList();
      const runLabel = 'CW-F1 · DN32 - 4.4 m - CL +2.70';
      // Round 20 — one fixed 0.1 m length precision (4.0 m, not 4 m).
      const riserLabel = 'CW-R1 · DN32 - 4.0 m';
      // The DXF carries the SAME label through the R12 code-page-safe encoder
      // (drafting-5: '·' -> '-', so AutoCAD never shows 'Â·').
      expect(texts, containsAll([dxfText(runLabel), dxfText(riserLabel)]));
      expect(pdf, contains('($runLabel)'));
      expect(pdf, contains('($riserLabel)'));
    });

    test('a run absent from the map falls back to its calibrated length', () {
      // 220 px x 0.02 m/px = 4.4 m — the same figure the PDF prints.
      final dxf = networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's',
          floorIndex: 0,
          metersPerPixel: 0.02,
          edgeTags: tags);
      final texts = _dxfEntities(dxf)
          .where((e) => e['0']!.first == 'TEXT')
          .map((e) => e['1']!.first);
      expect(texts, contains(dxfText('CW-F1 · DN32 - 4.4 m')));
      // No map ⇒ a riser has no honest length (it needs the elevation delta).
      expect(texts, contains(dxfText('CW-R1 · DN32')));
    });
  });
}

/// Parse a DXF group-code stream into entities (code -> values), keyed by the
/// `0` entity-type code.
List<Map<String, List<String>>> _dxfEntities(String dxf) {
  final l = dxf.split('\n');
  final ents = <Map<String, List<String>>>[];
  Map<String, List<String>>? cur;
  for (var i = 0; i + 1 < l.length; i += 2) {
    final c = l[i].trim(), v = l[i + 1];
    if (c == '0') {
      cur = {
        '0': [v]
      };
      ents.add(cur);
    } else {
      cur?.putIfAbsent(c, () => []).add(v);
    }
  }
  return ents;
}
