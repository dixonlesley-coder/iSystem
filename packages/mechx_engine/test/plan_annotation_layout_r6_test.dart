// R6 — the plan sheet reads like a drafted AutoCAD sheet in BOTH formats:
// one annotation layout (`layoutPlanAnnotations`) sized in PAPER millimetres
// makes the PDF and the DXF choose the same line split and the same slot;
// point tags never float unattributed; a tag may sit past a free run end; the
// setting-out grid is a soft obstacle no leader runs along; UP/DN marks take
// a clear quadrant; coincident risers print one tag. Expected values are
// hand-derived from the placer's own metric (width = chars × size × 0.55,
// height = size, beside offset 0.7 × size, line pitch 1.3 × size).
import 'dart:convert';
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/plan_annotation_layout.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/report/riser_tags.dart' show elementTags;
import 'package:mechx_engine/sizing/network_sizing.dart' show SizingContext;
import 'package:test/test.dart';

import '../tool/generate_export_samples.dart'
    show
        buildNetwork,
        sizeNetwork,
        calibrations,
        building,
        elevationLabels,
        referenceGrid,
        planSheetChrome,
        projectName,
        dateString;

/// One drawn tag line: its text (normalised to the DXF's ASCII), rotation and
/// baseline-start anchor.
typedef _Line = ({String text, double angle, double x, double y});

void main() {
  group('PDF == DXF label parity over the harness fixture (R6)', () {
    final net = buildNetwork();
    final sizing = sizeNetwork(net);
    final lengths = {
      for (final e in net.edges)
        e.id: edgeLength(e, net,
            calibrationBySheet: calibrations, building: building),
    };
    final tags = elementTags(net);
    final nodeTags = equipmentNodeTags(net);
    final slope = const SizingContext().drainageSlope;

    for (final (sid, floor, title) in [
      ('s0', 0, 'GROUND FLOOR - PLUMBING & RISERS'),
      ('s1', 1, 'LANTAI 1 - PLUMBING & HVAC'),
    ]) {
      final chrome = planSheetChrome(net, sid, floor, floor + 1, title);
      final pdf = latin1.decode(planToPdf(
        net: net,
        sizing: sizing,
        edgeLengths: lengths,
        edgeElevationLabels: elevationLabels(net),
        grid: referenceGrid,
        edgeTags: tags,
        nodeTags: nodeTags,
        gravitySlope: slope,
        sheetId: sid,
        floorIndex: floor,
        projectName: projectName,
        sheetName: title,
        dateString: dateString,
        metersPerPixel: 0.02,
        chrome: chrome,
      ));
      final plot = planSheetPlot(
        net: net,
        sheetId: sid,
        floorIndex: floor,
        projectName: projectName,
        sheetName: title,
        dateString: dateString,
        metersPerPixel: 0.02,
        grid: referenceGrid,
        chrome: chrome,
      );
      final dxf = networkToDxf(
        net: net,
        sizing: sizing,
        sheetId: sid,
        floorIndex: floor,
        metersPerPixel: 0.02,
        edgeLengths: lengths,
        edgeElevationLabels: elevationLabels(net),
        grid: referenceGrid,
        edgeTags: tags,
        nodeTags: nodeTags,
        gravitySlope: slope,
        chrome: chrome,
        sheetPlot: plot,
      );

      // PDF tags: every rotated (`Tm`) text line, in emission order.
      final pdfLines = <_Line>[
        for (final m in RegExp(r'(-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) '
                r'(-?[\d.]+) (-?[\d.]+) Tm \((.*?)\) Tj')
            .allMatches(pdf))
          (
            text: m.group(7)!.replaceAll('·', '-').replaceAll('Ø', '%%c'),
            angle: math.atan2(
                    double.parse(m.group(2)!), double.parse(m.group(1)!)) *
                180 /
                math.pi,
            x: double.parse(m.group(5)!),
            y: double.parse(m.group(6)!),
          ),
      ];
      // DXF tags: every ANNO-layer TEXT that carries a rotation (the UP/DN
      // marks carry none — the PDF prints those with `Td`).
      final ents = _dxfEntities(dxf);
      final dxfLines = <_Line>[
        for (final e in ents)
          if (e['0']!.first == 'TEXT' &&
              e['8']?.first == kDxfLayerAnno &&
              e['50'] != null)
            (
              text: e['1']!.first,
              angle: double.parse(e['50']!.first),
              x: double.parse(e['10']!.first),
              y: double.parse(e['20']!.first),
            ),
      ];

      test('$sid: identical line splits, in the same order', () {
        expect(pdfLines, isNotEmpty);
        expect(dxfLines.map((l) => l.text).toList(),
            pdfLines.map((l) => l.text).toList());
        // The fixture exercises BOTH forms, so the parity is not vacuous: at
        // least one tag is split to two lines and at least one is not.
        final composed = <String>{
          for (final e in net.edges)
            if (tags[e.id] != null) tags[e.id]!,
        };
        final lineTexts = pdfLines.map((l) => l.text).toSet();
        expect(
            lineTexts.any((t) =>
                composed.any((c) => t.startsWith(c)) && !t.contains(' m')),
            isTrue,
            reason: 'a two-line tag (identity line alone)');
        expect(lineTexts.any((t) => t.contains(' - ') && t.contains(' m')),
            isTrue);
      });

      test('$sid: identical rotations and slot geometry (a similarity)', () {
        // The DXF is the PDF scaled by k = model mm per PDF point at 1 : N:
        // k = N × 25.4 / 72 (both y-up), so every anchor offset from the
        // first tag's anchor matches after scaling.
        final k = plot!.scaleDenominator * kPlanPaperMmPerPt;
        expect(dxfLines.length, pdfLines.length);
        for (var i = 0; i < pdfLines.length; i++) {
          expect(dxfLines[i].angle, closeTo(pdfLines[i].angle, 0.1),
              reason: pdfLines[i].text);
          // PDF anchors are printed to 0.01 pt ⇒ a ±0.02 pt × k tolerance.
          final dxP = (pdfLines[i].x - pdfLines[0].x) * k;
          final dyP = (pdfLines[i].y - pdfLines[0].y) * k;
          expect(dxfLines[i].x - dxfLines[0].x, closeTo(dxP, 0.03 * k),
              reason: pdfLines[i].text);
          expect(dxfLines[i].y - dxfLines[0].y, closeTo(dyP, 0.03 * k),
              reason: pdfLines[i].text);
        }
      });

      test('$sid: identical leaders', () {
        final pdfLeaders = '0.30 0.30 0.30 RG 0.5 w'.allMatches(pdf).length;
        final dxfLeaders = ents
            .where((e) =>
                e['0']!.first == 'LINE' && e['8']?.first == kDxfLayerAnno)
            .length;
        expect(dxfLeaders, pdfLeaders);
      });
    }
  });

  group('point-feature attribution (R6)', () {
    test('a tag that cannot hug its marker is leadered FROM the marker', () {
      // Marker at the origin; the pseudo-run starts 8 right of it. A box
      // covers everything left of x = 40, so every hugging slot (near edge 8
      // from the marker) is blocked. The R5 placer then took the 7/8 station
      // of the pseudo-run (centre 8 + 0.875 × 84.15 = 81.6) — a tag ~40 right
      // of its marker with NO leader. Now any leaderless slot must keep its
      // near edge within 1.5 × 9 = 13.5 of the marker, so it escapes on a
      // leader that starts AT the marker.
      const text = 'V-R1 · DN32 - 4 m'; // 17 chars ⇒ w = 84.15
      final layout = PlanLabelLayout(boxes: [
        (minX: -200, minY: -200, maxX: 40, maxY: 200),
      ]);
      final p = placePlanLabel(
        ax: 8,
        ay: 0,
        bx: 8 + text.length * 9 * 0.55,
        by: 0,
        text: text,
        splitLines: const ['V-R1 · DN32', '4 m'],
        textSize: 9,
        layout: layout,
        anchorPoint: (x: 0, y: 0),
      );
      expect(p.leaderAnchor, isNotNull);
      expect(p.leaderAnchor!.x, 0);
      expect(p.leaderAnchor!.y, 0);
    });

    test('every harness riser / equipment tag is leadered or attached', () {
      final net = buildNetwork();
      final lengths = {
        for (final e in net.edges)
          e.id: edgeLength(e, net,
              calibrationBySheet: calibrations, building: building),
      };
      final tags = elementTags(net);
      for (final (sid, floor) in [('s0', 0), ('s1', 1)]) {
        final labels = <String, PlanEdgeLabelText>{
          for (final e in net.edges)
            if (tags[e.id] != null)
              e.id: (
                text: composePlanEdgeLabel(
                    tag: tags[e.id], length: planLengthLabel(lengths[e.id]!))!,
                split: null,
              ),
        };
        const u = 1 / kPlanPaperMmPerPt; // points
        final ann = layoutPlanAnnotations(
          net: net,
          sheetId: sid,
          floorIndex: floor,
          map: (x, y) => (x: x * 1.4, y: -y * 1.4),
          unitsPerMm: u,
          edgeLabels: labels,
          nodeTags: equipmentNodeTags(net),
          grid: referenceGrid,
          gridExtentPx: (minX: 0, minY: 0, maxX: 1100, maxY: 700),
          metersPerPixel: 0.02,
        );
        const ts = 9.0;
        for (final l in ann.labels) {
          if (l.kind == PlanLabelKind.run) continue;
          final p = l.placement;
          if (p.leaderAnchor != null) continue;
          // Attached: the marker lies within 1.5 × 9 of the tag rectangle.
          final node = l.kind == PlanLabelKind.equipment
              ? net.nodeById(l.id)!
              : () {
                  final e = net.edges.firstWhere((e) => e.id == l.id);
                  final a = net.nodeById(e.fromId)!;
                  return a.sheetId == sid && a.floorIndex == floor
                      ? a
                      : net.nodeById(e.toId)!;
                }();
          final mx = node.x * 1.4, my = -node.y * 1.4;
          var minX = double.infinity, maxX = -double.infinity;
          var minY = double.infinity, maxY = -double.infinity;
          for (final line in p.lines) {
            minX = math.min(minX, line.x);
            maxX = math.max(maxX, line.x + line.text.length * ts * 0.55);
            minY = math.min(minY, line.y);
            maxY = math.max(maxY, line.y + ts);
          }
          final dx = math.max(0, math.max(minX - mx, mx - maxX));
          final dy = math.max(0, math.max(minY - my, my - maxY));
          expect(math.sqrt(dx * dx + dy * dy),
              lessThanOrEqualTo(kPlanAnchorAttachFactor * ts + 1e-6),
              reason: '${l.id} floats unattributed');
        }
      }
    });
  });

  group('beyond-the-run-end stations (R6)', () {
    // Run 'a' (0,0)→(40,0) boxed in above and below (a narrow wedge): no slot
    // beside it is clear.
    List<LabelBox> wedge() => [
          (minX: -100, minY: 1, maxX: 40, maxY: 100),
          (minX: -100, minY: -100, maxX: 40, maxY: -1),
        ];

    test('a tag sits just past a FREE run end, in line with the run', () {
      final layout = PlanLabelLayout(boxes: wedge())..addRun('a', 0, 0, 40, 0);
      final p = placePlanLabel(
          ax: 0,
          ay: 0,
          bx: 40,
          by: 0,
          text: 'DN15',
          textSize: 9,
          layout: layout,
          ownRunId: 'a');
      // halfW = 4 × 9 × 0.55 / 2 = 9.9; centre = 40 + 9.9 + 0.5 × 9 = 54.4,
      // centred on the axis (v −4.5..4.5) ⇒ baseline start (44.5, −4.5).
      expect(p.leaderAnchor, isNull);
      expect(p.x, closeTo(44.5, 1e-9));
      expect(p.y, closeTo(-4.5, 1e-9));
    });

    test('never past an end where another run continues', () {
      final layout = PlanLabelLayout(boxes: wedge())
        ..addRun('a', 0, 0, 40, 0)
        ..addRun('z', 40, 0, 40, -80); // a tee / elbow at the b end
      final p = placePlanLabel(
          ax: 0,
          ay: 0,
          bx: 40,
          by: 0,
          text: 'DN15',
          textSize: 9,
          layout: layout,
          ownRunId: 'a');
      // The b end is taken and the a end is boxed in ⇒ it escapes (leader).
      expect(p.leaderAnchor, isNotNull);
      expect(p.x, lessThan(40));
    });
  });

  group('setting-out grid lines are soft obstacles (R6)', () {
    test('a tag slides along its run off a grid line', () {
      // Run (0,0)→(100,0); a column grid line crosses it at x = 50. The
      // midpoint slots (u ±9.9 about x = 50) straddle the line; the quarter
      // station x = 25 is clear ⇒ (25 − 9.9, 6.3) = (15.1, 6.3), no leader.
      final layout = PlanLabelLayout()
        ..addRun('a', 0, 0, 100, 0)
        ..addGridLine(50, -100, 50, 100);
      final p = placePlanLabel(
          ax: 0,
          ay: 0,
          bx: 100,
          by: 0,
          text: 'DN50',
          textSize: 9,
          layout: layout,
          ownRunId: 'a');
      expect(p.leaderAnchor, isNull);
      expect(p.x, closeTo(15.1, 1e-9));
      expect(p.y, closeTo(6.3, 1e-9));
    });

    test('but still crosses one when no clear slot exists', () {
      // Grid lines through every station of the run: the first beside slot
      // (midpoint, upper) is taken rather than escaping on a leader.
      final layout = PlanLabelLayout()..addRun('a', 0, 0, 100, 0);
      for (final x in [12.5, 25.0, 37.5, 50.0, 62.5, 75.0, 87.5]) {
        layout.addGridLine(x, -100, x, 100);
      }
      final p = placePlanLabel(
          ax: 0,
          ay: 0,
          bx: 100,
          by: 0,
          text: 'DN50',
          textSize: 9,
          layout: layout,
          ownRunId: 'a');
      expect(p.leaderAnchor, isNull);
      expect(p.x, closeTo(40.1, 1e-9));
    });

    test('a leader never runs coincident with a grid line', () {
      // Both beside rows blocked (the R5 "preferred cap" setup): the escape
      // row d = 18 is clear at every station with an equal 16.65 leader, so
      // the midpoint wins — unless its perpendicular leader would run ALONG
      // the grid line x = 50. Then the next station in preference order, the
      // quarter point x = 25, carries the leader.
      final layout = PlanLabelLayout(boxes: [
        (minX: -50, minY: 0.5, maxX: 150, maxY: 16),
        (minX: -50, minY: -16, maxX: 150, maxY: -0.5),
      ])
        ..addGridLine(50, -100, 50, 100);
      final p = placePlanLabel(
          ax: 0,
          ay: 0,
          bx: 100,
          by: 0,
          text: 'DN80',
          textSize: 9,
          layout: layout);
      expect(p.leaderAnchor, isNotNull);
      expect(p.leaderAnchor!.x, closeTo(25, 1e-9));
      expect(p.leaderEnd!.x, closeTo(25, 1e-9));
    });
  });

  group('UP/DN marks + coincident risers (R6)', () {
    // In points (unitsPerMm = 72 / 25.4), identity sheet-px map: the marker
    // 'r' at (100, 100); a run leaves it to the RIGHT; a riser rises to the
    // floor above.
    Network riserNet({bool twin = false}) => Network(nodes: [
          const NetNode(id: 'r', sheetId: 's', x: 100, y: 100, floorIndex: 0),
          const NetNode(id: 'e', sheetId: 's', x: 200, y: 100, floorIndex: 0),
          const NetNode(id: 'up', sheetId: 's', x: 100, y: 100, floorIndex: 1),
        ], edges: [
          const NetEdge(
              id: 'run',
              fromId: 'r',
              toId: 'e',
              service: ServiceType.coldWater),
          const NetEdge(
              id: 'ris',
              fromId: 'r',
              toId: 'up',
              service: ServiceType.coldWater,
              kind: EdgeKind.riser),
          if (twin)
            const NetEdge(
                id: 'ris2',
                fromId: 'r',
                toId: 'up',
                service: ServiceType.coldWater,
                kind: EdgeKind.riser),
        ]);
    PlanAnnotations lay(Network net) => layoutPlanAnnotations(
          net: net,
          sheetId: 's',
          floorIndex: 0,
          map: (x, y) => (x: x, y: y),
          unitsPerMm: 1 / kPlanPaperMmPerPt,
          edgeLabels: const {
            'ris': (text: 'CW-R1 · DN32 - 4 m', split: null),
            'ris2': (text: 'CW-R1 · DN32 - 4 m', split: null),
          },
        );

    test('the mark takes a quadrant clear of the run leaving the marker', () {
      final ann = lay(riserNet());
      expect(ann.upDown, hasLength(1));
      final m = ann.upDown.single;
      expect(m.text, 'UP');
      // Lower-right (the long-standing slot) and upper-right both sit within
      // 0.7 × 9 of the run along y = 100, so the first well-clear quadrant is
      // lower-LEFT: x = 100 − 8 − 2 × 9 × 0.55 = 82.1, baseline 100 − 8 = 92.
      expect(m.x, closeTo(82.1, 1e-9));
      expect(m.y, closeTo(92, 1e-9));
    });

    test('two coincident risers print ONE tag and ONE mark', () {
      final ann = lay(riserNet(twin: true));
      expect(ann.upDown, hasLength(1));
      expect(
          ann.labels.where((l) => l.kind == PlanLabelKind.riser), hasLength(1));
    });

    test('harness: no UP/DN mark overprints a run', () {
      final net = buildNetwork();
      for (final (sid, floor) in [('s0', 0), ('s1', 1)]) {
        PlanAnnotations? ann;
        ann = layoutPlanAnnotations(
          net: net,
          sheetId: sid,
          floorIndex: floor,
          map: (x, y) => (x: x * 1.4, y: -y * 1.4),
          unitsPerMm: 1 / kPlanPaperMmPerPt,
          edgeLabels: const {},
          grid: referenceGrid,
          gridExtentPx: (minX: 0, minY: 0, maxX: 1100, maxY: 700),
        );
        final probe = PlanLabelLayout();
        for (final e in net.edges) {
          if (e.kind != EdgeKind.run) continue;
          final a = net.nodeById(e.fromId)!, c = net.nodeById(e.toId)!;
          if (a.sheetId != sid || a.floorIndex != floor) continue;
          probe.addRun(e.id, a.x * 1.4, -a.y * 1.4, c.x * 1.4, -c.y * 1.4);
        }
        for (final m in ann.upDown) {
          final box = (
            minX: m.x,
            minY: m.y,
            maxX: m.x + m.text.length * m.textSize * 0.55,
            maxY: m.y + m.textSize,
          );
          expect(probe.hitsRun(box), isFalse,
              reason: '$sid ${m.text} at (${m.x}, ${m.y})');
        }
      }
    });
  });
}

/// The DXF ENTITIES as group-code maps (code → values), in file order.
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
