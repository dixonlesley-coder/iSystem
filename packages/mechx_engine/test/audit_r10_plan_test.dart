// Round 10 (2026-10-18) — mechanical drawing-property findings (plan PDF/DXF
// parity, fit, tie figures, chrome reservation, chevrons; riser sheet tags,
// VTR stub, legend), each pinned as a (seeded where it fits) property test.
import 'dart:convert';
import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_annotation_layout.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/report/riser_tags.dart' show elementTags;
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/sizing/network_sizing.dart' show EdgeSizing;
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import '../tool/generate_export_samples.dart'
    show buildNetwork, sizeNetwork, calibrations, building;

NetNode _pn(String id, double x, double y,
        {int floor = 0, NodeComponent? component, NodeRole? role}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        component: component,
        role: role ?? (component != null ? NodeRole.plant : NodeRole.main));

NetEdge _pe(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

EdgeSizing _sz(String id, ServiceType s, double mm, {String? flowFrom}) =>
    EdgeSizing(
      edgeId: id,
      service: s,
      flow: const FlowRate(0.001),
      diameter: Diameter.mm(mm),
      velocity: const Velocity(1.0),
      flowFromId: flowFrom,
    );

List<Map<String, List<String>>> _dxfEntities(String dxf) {
  final lines = dxf.split('\n').map((l) => l.trim()).toList();
  final out = <Map<String, List<String>>>[];
  Map<String, List<String>>? cur;
  var inEntities = false;
  for (var i = 0; i + 1 < lines.length; i += 2) {
    final code = lines[i], value = lines[i + 1];
    if (code == '2' && value == 'ENTITIES') inEntities = true;
    if (!inEntities) continue;
    if (code == '0') {
      if (value == 'ENDSEC') break;
      cur = {
        '0': [value]
      };
      out.add(cur);
    } else {
      cur?.putIfAbsent(code, () => []).add(value);
    }
  }
  return out;
}

/// The plan PDF's rotated tag lines (`Tm`) as DXF-normalised text.
List<String> _pdfTagLines(String pdf) => [
      for (final m in RegExp(r'(-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) '
              r'(-?[\d.]+) (-?[\d.]+) Tm \((.*?)\) Tj')
          .allMatches(pdf))
        m.group(7)!.replaceAll('·', '-').replaceAll('Ø', '%%c'),
    ];

List<String> _dxfTagLines(String dxf) => [
      for (final e in _dxfEntities(dxf))
        if (e['0']!.first == 'TEXT' &&
            e['8']?.first == kDxfLayerAnno &&
            e['50'] != null)
          e['1']!.first,
    ];

bool _segCrossesBox(double x1, double y1, double x2, double y2, double l,
    double t, double r, double b) {
  const steps = 60;
  for (var i = 0; i <= steps; i++) {
    final k = i / steps;
    final x = x1 + (x2 - x1) * k, y = y1 + (y2 - y1) * k;
    if (x > l && x < r && y > t && y < b) return true;
  }
  return false;
}

void main() {
  // ── mech-drawing-props-1 ─────────────────────────────────────────────────
  group('mech-drawing-props-1 — an unsized run is tagged identically in the '
      'plan PDF and DXF', () {
    test('sized + unsized CW-F1 runs: both formats print both tags', () {
      final net = Network(nodes: [
        _pn('a', 0, 0),
        _pn('b', 300, 0),
        _pn('c', 300, 300),
      ], edges: [
        _pe('e1', 'a', 'b', ServiceType.coldWater),
        _pe('e2', 'b', 'c', ServiceType.coldWater),
      ]);
      final sizing = {'e1': _sz('e1', ServiceType.coldWater, 50)};
      const lengths = {'e1': Length(6), 'e2': Length(6)};
      const tags = {'e1': 'CW-F1', 'e2': 'CW-F1'};
      final pdf = latin1.decode(planToPdf(
          net: net,
          sizing: sizing,
          edgeLengths: lengths,
          edgeTags: tags,
          sheetId: 's1',
          floorIndex: 0,
          projectName: 'P',
          sheetName: 'S',
          dateString: '2026-10-18',
          metersPerPixel: 0.02));
      final dxf = networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's1',
          floorIndex: 0,
          metersPerPixel: 0.02,
          edgeLengths: lengths,
          edgeTags: tags);
      final p = _pdfTagLines(pdf), d = _dxfTagLines(dxf);
      expect(d, p);
      // The unsized run carries its tag + take-off length in BOTH.
      expect(d.join(' | '), contains('CW-F1 - 6 m'));
    });

    test('property: PDF == DXF tag lines with ~10% of runs unsized (seeded)',
        () {
      final net = buildNetwork();
      final full = sizeNetwork(net);
      final lengths = {
        for (final e in net.edges)
          e.id: edgeLength(e, net,
              calibrationBySheet: calibrations, building: building),
      };
      final tags = elementTags(net);
      final rnd = math.Random(1010);
      for (var i = 0; i < 12; i++) {
        final sizing = <String, EdgeSizing>{
          for (final e in full.entries)
            if (rnd.nextDouble() >= 0.1) e.key: e.value,
        };
        for (final (sid, floor) in const [('s0', 0), ('s1', 1)]) {
          final pdf = latin1.decode(planToPdf(
              net: net,
              sizing: sizing,
              edgeLengths: lengths,
              edgeTags: tags,
              sheetId: sid,
              floorIndex: floor,
              projectName: 'P',
              sheetName: 'S',
              dateString: '2026-10-18',
              metersPerPixel: 0.02));
          final plot = planSheetPlot(
              net: net,
              sheetId: sid,
              floorIndex: floor,
              projectName: 'P',
              sheetName: 'S',
              dateString: '2026-10-18',
              metersPerPixel: 0.02);
          final dxf = networkToDxf(
              net: net,
              sizing: sizing,
              sheetId: sid,
              floorIndex: floor,
              metersPerPixel: 0.02,
              edgeLengths: lengths,
              edgeTags: tags,
              sheetPlot: plot);
          expect(_dxfTagLines(dxf), _pdfTagLines(pdf),
              reason: 'seed $i sheet $sid');
        }
      }
    });
  });

  // ── mech-drawing-props-2 ─────────────────────────────────────────────────
  group('mech-drawing-props-2 — an unconnected component stays on the sheet '
      'and keeps its glyph in the DXF', () {
    final net = Network(nodes: [
      _pn('a', 100, 100),
      _pn('b', 400, 100),
      _pn('p', 900, 700, component: NodeComponent.pump),
    ], edges: [
      _pe('e1', 'a', 'b', ServiceType.coldWater),
    ]);
    final sizing = {'e1': _sz('e1', ServiceType.coldWater, 50)};
    const nodeTags = {'p': 'P-01'};

    test('planFitBounds includes the orphan pump', () {
      final f = planFitBounds(net, 's1', 0, null);
      expect(f.maxX, 900);
      expect(f.maxY, 700);
    });

    test('the PDF prints the P-01 tag inside the page', () {
      final pdf = latin1.decode(planToPdf(
          net: net,
          sizing: sizing,
          edgeLengths: const {'e1': Length(6)},
          nodeTags: nodeTags,
          sheetId: 's1',
          floorIndex: 0,
          projectName: 'P',
          sheetName: 'S',
          dateString: '2026-10-18',
          metersPerPixel: 0.02));
      final m = RegExp(r'(-?[\d.]+) (-?[\d.]+) Tm \(P-01\) Tj').firstMatch(pdf);
      expect(m, isNotNull);
      final x = double.parse(m!.group(1)!), y = double.parse(m.group(2)!);
      expect(x, inInclusiveRange(0, PaperSize.a3Landscape.widthPt));
      expect(y, inInclusiveRange(0, PaperSize.a3Landscape.heightPt));
    });

    test('the DXF draws the orphan glyph on the neutral layer beside its tag',
        () {
      final dxf = networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's1',
          floorIndex: 0,
          metersPerPixel: 0.02,
          nodeTags: nodeTags);
      final ents = _dxfEntities(dxf);
      expect(ents.where((e) => e['8']?.first == kDxfLayerUnconnected),
          isNotEmpty);
      expect(dxf, contains(kDxfLayerUnconnected)); // declared in TABLES
      expect(ents.any((e) => e['0']!.first == 'TEXT' && e['1']?.first == 'P-01'),
          isTrue);
    });
  });

  // ── mech-drawing-props-3 ─────────────────────────────────────────────────
  group('mech-drawing-props-3 — a riser tie figure is never struck through by '
      'a parallel run', () {
    test('property: HW main 0.3–1.2 m either side of a CW riser (seeded)', () {
      const grid = ReferenceGrid(
        columns: [GridAxis('A', 100), GridAxis('B', 900)],
        rows: [GridAxis('1', 100), GridAxis('2', 700)],
      );
      // 0.02 m/px at 1 : 100 on paper = 0.2 paper-mm per px.
      const ptPerMm = 72 / 25.4;
      const k = 0.2 * ptPerMm;
      ({double x, double y}) map(double x, double y) =>
          (x: x * k, y: (1000 - y) * k);
      final rnd = math.Random(3030);
      var checked = 0;
      for (var i = 0; i < 80; i++) {
        final side = rnd.nextBool() ? 1.0 : -1.0;
        final dPx = (0.3 + rnd.nextDouble() * 0.9) / 0.02 * side;
        final net = Network(nodes: [
          _pn('r', 700, 300),
          _pn('r2', 700, 300, floor: 1),
          _pn('w', 300, 300),
          _pn('h1', 250, 300 + dPx),
          _pn('h2', 850, 300 + dPx),
        ], edges: [
          _pe('riser', 'r', 'r2', ServiceType.coldWater, kind: EdgeKind.riser),
          _pe('cw', 'r', 'w', ServiceType.coldWater),
          _pe('hw', 'h1', 'h2', ServiceType.hotWater),
        ]);
        final ann = layoutPlanAnnotations(
          net: net,
          sheetId: 's1',
          floorIndex: 0,
          map: map,
          unitsPerMm: ptPerMm,
          edgeLabels: const {},
          grid: grid,
          gridExtentPx: (minX: 100, minY: 100, maxX: 900, maxY: 700),
          metersPerPixel: 0.02,
        );
        for (final t in ann.ties) {
          checked++;
          final w = t.text.length * t.textSize * 0.55;
          final l = t.textX, b0 = t.textY, r = l + w, tp = b0 + t.textSize;
          for (final e in net.edges.where((e) => e.kind == EdgeKind.run)) {
            final a = net.nodeById(e.fromId)!, c = net.nodeById(e.toId)!;
            final pa = map(a.x, a.y), pc = map(c.x, c.y);
            expect(_segCrossesBox(pa.x, pa.y, pc.x, pc.y, l, b0, r, tp),
                isFalse,
                reason: 'seed $i: tie "${t.text}" crossed by ${e.id}');
          }
        }
      }
      expect(checked, greaterThan(0)); // the property is not vacuous
    });
  });

  // ── mech-drawing-props-4 ─────────────────────────────────────────────────
  group('mech-drawing-props-4 — runs never cross the north arrow or legend',
      () {
    test('property: plan widths 1700–1900 px with a 9-service legend', () {
      final chrome = DrawingChrome(
        drawingNumber: 'M-101',
        legendServices: ServiceType.values.take(9).toList(),
      );
      for (var w = 1700.0; w <= 1900; w += 25) {
        // A 38 m x 20 m-class CW ring with a tee 2.4 m from the NE corner.
        final net = Network(nodes: [
          _pn('a', 0, 0),
          _pn('b', w, 0),
          _pn('c', w, 1000),
          _pn('d', 0, 1000),
          _pn('t', w - 120, 0),
        ], edges: [
          _pe('ab1', 'a', 't', ServiceType.coldWater),
          _pe('ab2', 't', 'b', ServiceType.coldWater),
          _pe('bc', 'b', 'c', ServiceType.coldWater),
          _pe('cd', 'c', 'd', ServiceType.coldWater),
          _pe('da', 'd', 'a', ServiceType.coldWater),
        ]);
        final plot = planSheetPlot(
            net: net,
            sheetId: 's1',
            floorIndex: 0,
            projectName: 'P',
            sheetName: 'S',
            dateString: '2026-10-18',
            metersPerPixel: 0.02,
            chrome: chrome);
        expect(plot, isNotNull);
        // occupiedPx = 4 off-frame strips + title block + north + legend +
        // scale bar: every in-frame reservation must be clear of every run.
        final inFrame = plot!.occupiedPx.skip(4).toList();
        expect(inFrame.length, greaterThanOrEqualTo(4), reason: 'w $w');
        for (final e in net.edges) {
          final a = net.nodeById(e.fromId)!, c = net.nodeById(e.toId)!;
          for (final o in inFrame) {
            expect(
                _segCrossesBox(
                    a.x, a.y, c.x, c.y, o.minX, o.minY, o.maxX, o.maxY),
                isFalse,
                reason: 'w $w: ${e.id} crosses $o');
          }
        }
      }
    });
  });

  // ── mech-drawing-props-5 ─────────────────────────────────────────────────
  group('mech-drawing-props-5 — DXF flow chevrons are sized in paper units',
      () {
    List<double> chevronArms(double mpp) {
      // 30 m main + 1.0 m branch, both with a solved flow direction.
      final px30 = 30 / mpp, px1 = 1 / mpp;
      final net = Network(nodes: [
        _pn('a', 0, 0),
        _pn('b', px30, 0),
        _pn('c', px30, px1),
      ], edges: [
        _pe('main', 'a', 'b', ServiceType.coldWater),
        _pe('br', 'b', 'c', ServiceType.coldWater),
      ]);
      final sizing = {
        'main': _sz('main', ServiceType.coldWater, 50, flowFrom: 'a'),
        'br': _sz('br', ServiceType.coldWater, 25, flowFrom: 'b'),
      };
      final dxf = networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's1',
          floorIndex: 0,
          metersPerPixel: mpp);
      final layer = dxfLayerNameFor(ServiceType.coldWater);
      final lines = [
        for (final e in _dxfEntities(dxf))
          if (e['0']!.first == 'LINE' && e['8']?.first == layer)
            math.sqrt(math.pow(
                    double.parse(e['11']!.first) - double.parse(e['10']!.first),
                    2) +
                math.pow(
                    double.parse(e['21']!.first) - double.parse(e['20']!.first),
                    2)),
      ];
      // Drop the two run LINEs (30 000 mm and 1 000 mm): the rest are arms.
      return [for (final l in lines) if (l < 900) l];
    }

    test('one chevron (the 30 m main), arm = 1.25 x 5 pt of paper, at any '
        'calibration', () {
      // Extent 30 m x 1 m plots at 1 : 100 on A3 ⇒ u = 100 model mm / paper
      // mm. A chevron leg (tip→wing) is sqrt(1 + 0.75²) = 1.25 arms; the arm
      // is 5 pt = 5 × 25.4/72 paper mm ⇒ 1.25 × 5 × 25.4/72 × 100 mm.
      const expected = 1.25 * 5 * 25.4 / 72 * 100;
      for (final mpp in const [0.005, 0.02]) {
        final arms = chevronArms(mpp);
        expect(arms, hasLength(2), reason: 'mpp $mpp'); // 1 chevron only
        for (final a in arms) {
          expect(a, closeTo(expected, 0.5), reason: 'mpp $mpp');
        }
      }
    });
  });

  // ── riser-sheet findings (6/7/8) ─────────────────────────────────────────
  NetNode rn(String id, double x, int floor, {NodeRole role = NodeRole.main}) =>
      NetNode(
          id: id, sheetId: 's1', x: x, y: 0, floorIndex: floor, role: role);

  group('mech-drawing-props-7 — riser tags take their in-band default slot; '
      'no zero-length LINE', () {
    test('one CW stack G->L3: every tag at riser x + 6, no leader, no '
        'degenerate line', () {
      const b = BuildingLevels([
        Floor('G', Length(4)),
        Floor('L1', Length(4)),
        Floor('L2', Length(4)),
        Floor('L3', Length(4)),
      ]);
      final net = Network(nodes: [
        for (var f = 0; f < 4; f++) rn('n$f', 200, f),
      ], edges: [
        for (var f = 0; f < 3; f++)
          _pe('r$f', 'n$f', 'n${f + 1}', ServiceType.coldWater,
              kind: EdgeKind.riser),
      ]);
      final sheet = buildMechanicalRiserSld(
        network: net,
        building: b,
        sizing: {
          for (var f = 0; f < 3; f++)
            'r$f': _sz('r$f', ServiceType.coldWater, 50),
        },
        edgeLengths: {for (var f = 0; f < 3; f++) 'r$f': const Length(4)},
      );
      final lines = sheet.prims.whereType<SldLine>().toList();
      for (final l in lines) {
        expect((l.x2 - l.x1).abs() + (l.y2 - l.y1).abs(), greaterThan(0.5),
            reason: 'zero-length line at (${l.x1},${l.y1})');
      }
      final riserX = lines
          .firstWhere((l) =>
              l.weight == SldWeight.medium && (l.x1 - l.x2).abs() < 0.5)
          .x1;
      final tagLabels = sheet.prims
          .whereType<SldLabel>()
          .where((l) => l.text.contains('CW') && l.size == 8)
          .toList();
      expect(tagLabels, hasLength(6)); // 3 pipe tags + 3 riser ids
      for (final l in tagLabels) {
        expect(l.x, riserX + 6, reason: '"${l.text}" was displaced');
      }
    });
  });

  group('mech-drawing-props-8 — the riser legend keys only printed service '
      'codes', () {
    test('a CW stack + a supply-air run: SA is not keyed', () {
      final net = Network(nodes: [
        rn('a', 200, 0),
        rn('b', 200, 1),
        rn('d1', 300, 1),
        rn('d2', 500, 1),
      ], edges: [
        _pe('r', 'a', 'b', ServiceType.coldWater, kind: EdgeKind.riser),
        _pe('sa', 'd1', 'd2', ServiceType.duct),
      ]);
      final sheet = buildMechanicalRiserSld(
        network: net,
        building: const BuildingLevels(
            [Floor('G', Length(4)), Floor('L1', Length(4))]),
        sizing: {
          'r': _sz('r', ServiceType.coldWater, 50),
          'sa': _sz('sa', ServiceType.duct, 300),
        },
      );
      final codes = sheet.legend.map((e) => e.code).toList();
      expect(codes, contains('CW'));
      expect(codes, isNot(contains('SA')));
    });
  });

  group('mech-drawing-props-6 — no tag prints through the VTR roof stub', () {
    test('property: random vent/rainwater/CW riser sheets (seeded)', () {
      final rnd = math.Random(146);
      var stubs = 0;
      for (var i = 0; i < 120; i++) {
        final floors = 2 + rnd.nextInt(2);
        final top = floors - 1;
        final nodes = <NetNode>[];
        final edges = <NetEdge>[];
        final sizing = <String, EdgeSizing>{};
        final lengths = <String, Length>{};
        var k = 0;
        void edge(String a, String b, ServiceType s, EdgeKind kind) {
          final id = 'e${k++}';
          edges.add(_pe(id, a, b, s, kind: kind));
          sizing[id] = _sz(id, s, const <double>[32, 50, 100][rnd.nextInt(3)]);
          lengths[id] = Length(1 + rnd.nextDouble() * 6);
        }

        // A vent stack reaching the top floor (⇒ a VTR stub).
        final vx = 100.0 + rnd.nextInt(400);
        for (var f = 0; f < floors; f++) {
          nodes.add(rn('v$f', vx, f));
        }
        for (var f = 0; f < top; f++) {
          edge('v$f', 'v${f + 1}', ServiceType.vent, EdgeKind.riser);
        }
        // Top-floor runs of random services around it.
        for (var j = 0; j < 1 + rnd.nextInt(4); j++) {
          final s = [
            ServiceType.vent,
            ServiceType.rainwater,
            ServiceType.coldWater
          ][rnd.nextInt(3)];
          final x0 = vx - 150 + rnd.nextInt(300).toDouble();
          nodes.add(rn('a$j', x0, top));
          nodes.add(rn('b$j', x0 + 40 + rnd.nextInt(200).toDouble(), top));
          edge('a$j', 'b$j', s, EdgeKind.run);
        }
        final sheet = buildMechanicalRiserSld(
          network: Network(nodes: nodes, edges: edges),
          sizing: sizing,
          edgeLengths: lengths,
          building: BuildingLevels([
            for (var f = 0; f < floors; f++) Floor('F$f', const Length(4)),
          ]),
        );
        final labels = sheet.prims.whereType<SldLabel>().toList();
        final vtr = labels.where((l) => l.text == 'VTR');
        for (final v in vtr) {
          final sx = v.x - 6, stubTop = v.y - 6;
          final stub = sheet.prims.whereType<SldLine>().firstWhere(
              (l) => l.dashed && (l.x1 - sx).abs() < 0.01 &&
                  (l.y2 - stubTop).abs() < 0.01);
          stubs++;
          for (final l in labels) {
            if (identical(l, v)) continue;
            final w = l.text.length * l.size * kMechRiserLabelCharW;
            expect(
                _segCrossesBox(stub.x1, stub.y1, stub.x2, stub.y2, l.x,
                    l.y - l.size, l.x + w, l.y),
                isFalse,
                reason: 'seed $i: "${l.text}" crosses the VTR stub');
          }
        }
      }
      expect(stubs, greaterThan(0));
    });
  });
}
