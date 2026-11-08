// Round 14 (2026-10-18) — drafting-visual findings on the issued drawings:
//   2  a feeder never strikes through the sub-panel's header text;
//   3  services on one floor sit on separate riser LANES (no overdraw);
//   4  the pump-set FJ sits at the pump nozzle (pump > FJ > CV > GV);
//   5  the calibrated plan DXF carries an honest metric scale bar + the ISO
//      title block on the G-ANNO-* layers;
//   6  one title per drawing series (register == sheet);
//   7  one plotted scale for every plan of a set;
//   8  the DEVICE rule clears the bold GRUP heading.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_annotation_layout.dart' show PlanSheetPlot;
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

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

/// Helvetica-Bold advance widths (per 1000 em) for the upper-case letters
/// the GRUP head uses — the Adobe base-14 AFM figures.
const _boldWidth = {'G': 778, 'R': 722, 'U': 722, 'P': 667};

ElectricalProject _twoBoards() => const ElectricalProject(
      id: 'e',
      name: 'e',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'Main Distribution Panel',
          system: ElectricalSystem.threePhase,
          voltage: Voltage(400),
          circuits: [
            ElectricalCircuit(
              id: 'w1',
              name: 'Feeder LP',
              loadKind: LoadKind.feeder,
              length: Length(20),
              feedsPanelId: 'LP',
            ),
          ],
        ),
        ElectricalPanel(
          id: 'LP',
          name: 'Lighting Panel',
          tag: 'LP-1',
          system: ElectricalSystem.threePhase,
          voltage: Voltage(400),
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'w1',
          circuits: [
            ElectricalCircuit(
              id: 'l1',
              name: 'Lighting 1',
              loadKind: LoadKind.lighting,
              loadW: 1200,
              length: Length(15),
            ),
          ],
        ),
      ],
    );

void main() {
  group('2 — the feeder enters the sub-panel without striking its header', () {
    test('no horizontal feeder segment crosses a panel title label', () {
      final project = _twoBoards();
      final sys = computeSystem(_p, project);
      final s = buildElectricalSld(project: project, result: sys);
      final feeders = s.prims.whereType<SldLine>().where((l) =>
          l.weight == SldWeight.medium && (l.y1 - l.y2).abs() < 1e-9);
      expect(feeders, isNotEmpty);
      final titles = s.prims
          .whereType<SldLabel>()
          .where((t) => t.text.startsWith('Lighting Panel'));
      expect(titles, isNotEmpty);
      for (final t in titles) {
        final w = t.text.length * t.size * 0.6;
        for (final f in feeders) {
          final crossesX = math.max(f.x1, f.x2) > t.x &&
              math.min(f.x1, f.x2) < t.x + w;
          // The cap height above the baseline + the descender band below it.
          final crossesY = f.y1 > t.y - t.size && f.y1 <= t.y + 3;
          expect(crossesX && crossesY, isFalse,
              reason: 'feeder at y ${f.y1} strikes "${t.text}"');
        }
      }
    });
  });

  group('3 — one LANE per service on the combined riser sheet', () {
    Network net() => const Network(nodes: [
          NetNode(id: 'cw0', sheetId: 's', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'cw1', sheetId: 's', x: 0, y: 0, floorIndex: 1),
          NetNode(id: 'cwb', sheetId: 's', x: 300, y: 0, floorIndex: 1),
          NetNode(id: 'hw0', sheetId: 's', x: 100, y: 0, floorIndex: 0),
          NetNode(id: 'hw1', sheetId: 's', x: 100, y: 0, floorIndex: 1),
          NetNode(id: 'hwb', sheetId: 's', x: 250, y: 0, floorIndex: 1),
        ], edges: [
          NetEdge(
              id: 'cr',
              fromId: 'cw0',
              toId: 'cw1',
              service: ServiceType.coldWater,
              kind: EdgeKind.riser),
          NetEdge(
              id: 'cb',
              fromId: 'cw1',
              toId: 'cwb',
              service: ServiceType.coldWater),
          NetEdge(
              id: 'hr',
              fromId: 'hw0',
              toId: 'hw1',
              service: ServiceType.hotWater,
              kind: EdgeKind.riser),
          NetEdge(
              id: 'hb',
              fromId: 'hw1',
              toId: 'hwb',
              service: ServiceType.hotWater),
        ]);

    test('CW and HW branches on one floor never share a y', () {
      final lanes = riserServiceLanes(net());
      // CW sits on the band centre (lane 0), HW one pitch above it.
      expect(lanes['cwb'], isNull);
      expect(lanes['hwb'], riserServiceLane(ServiceType.hotWater));
      expect(riserServiceLane(ServiceType.hotWater),
          isNot(riserServiceLane(ServiceType.coldWater)));
      // A single-service focus keeps every node on the centre.
      expect(riserServiceLanes(net(), focus: ServiceType.hotWater), isEmpty);
      final s = buildMechanicalRiserSld(network: net());
      final horiz = s.prims
          .whereType<SldLine>()
          .where((l) => (l.y1 - l.y2).abs() < 1e-9 && l.layer != null)
          .toList();
      // No two different-layer horizontal segments overlap collinearly.
      for (var i = 0; i < horiz.length; i++) {
        for (var j = i + 1; j < horiz.length; j++) {
          final a = horiz[i], b = horiz[j];
          if (a.layer == b.layer || (a.y1 - b.y1).abs() > 1e-6) continue;
          final overlap = math.min(math.max(a.x1, a.x2), math.max(b.x1, b.x2)) -
              math.max(math.min(a.x1, a.x2), math.min(b.x1, b.x2));
          expect(overlap, lessThanOrEqualTo(1e-6),
              reason: '${a.layer} over ${b.layer} at y ${a.y1}');
        }
      }
    });
  });

  group('4 — the pump-set flexible joint sits at the pump nozzle', () {
    test('suction STR > FJ > pump, discharge pump > FJ > CV > GV', () {
      final tokens = [for (final (t, _) in kPumpSetValveTrain) t];
      final pump = tokens.indexOf('PUMP');
      expect(tokens.sublist(pump - 2, pump), ['STR', 'FJ']);
      expect(tokens.sublist(pump + 1), ['FJ', 'CV', 'GV']);
    });
  });

  group('5 — the calibrated plan DXF scale bar + title block', () {
    const net = Network(nodes: [
      NetNode(id: 'a', sheetId: 's', x: 0, y: 0, floorIndex: 0),
      NetNode(id: 'b', sheetId: 's', x: 200, y: 0, floorIndex: 0),
      NetNode(id: 'c', sheetId: 's', x: 200, y: 150, floorIndex: 0),
    ], edges: [
      NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      NetEdge(id: 'e2', fromId: 'b', toId: 'c', service: ServiceType.coldWater),
    ]);
    const chrome = DrawingChrome(
      drawingNumber: 'M-101',
      revisionNumber: 'Rev. 0',
      sheetIndex: 1,
      sheetTotal: 1,
      legendServices: [ServiceType.coldWater],
      drawingTitle: 'PLAN - Ground',
    );

    test('the bar is a real-metre rung with figures, beside 1 : N', () {
      for (final mpp in [0.02, 0.05, 0.1]) {
        final dxf = networkToDxf(
          net: net,
          sizing: const {},
          sheetId: 's',
          floorIndex: 0,
          metersPerPixel: mpp,
          chrome: chrome,
          projectName: 'Menara',
        );
        final ents = _dxfEntities(dxf);
        // The plotted scale this extent snaps to on A3 (the PDF's rule).
        final n = a3PlottedScaleDenominatorFor(200 * mpp * 1000, 150 * mpp * 1000)!;
        final scaleText = [
          for (final e in ents)
            if (e['0']!.first == 'TEXT' && e['8']?.first == kDxfLayerScale)
              e['1']!.first,
        ];
        expect(scaleText, contains('1 : $n'), reason: 'mpp $mpp');
        final endFig = scaleText.firstWhere(
            (t) => t.endsWith(' m') && !t.contains('/'),
            orElse: () => '');
        final metres = scaleText
            .where((t) => t.endsWith(' m'))
            .map((t) => double.parse(t.substring(0, t.length - 2)))
            .reduce(math.max);
        expect(endFig, isNotEmpty);
        // The bar's drawn length (model mm) equals its printed metres × 1000.
        final barLines = [
          for (final e in ents)
            if (e['0']!.first == 'LINE' && e['8']?.first == kDxfLayerScale)
              (
                double.parse(e['10']!.first),
                double.parse(e['11']!.first),
                double.parse(e['20']!.first),
                double.parse(e['21']!.first),
              ),
        ];
        final longest = barLines
            .where((l) => (l.$3 - l.$4).abs() < 1e-9)
            .map((l) => (l.$2 - l.$1).abs())
            .reduce(math.max);
        expect(longest, closeTo(metres * 1000, 1e-6), reason: 'mpp $mpp');
        // ... and it is a ladder rung (1, 2, 5, 10, 20, 50, 100 m).
        expect(const [1.0, 2, 5, 10, 20, 50, 100], contains(metres));
        // The ISO title block rides G-ANNO-TTLB with the project + title.
        final ttlb = [
          for (final e in ents)
            if (e['0']!.first == 'TEXT' && e['8']?.first == kDxfLayerFrame)
              e['1']!.first,
        ];
        expect(ttlb, containsAll(['PROJECT', 'Menara', 'TITLE', 'PLAN - Ground',
            'SCALE', '1 : $n', 'DRAWN', 'CHECKED', 'APPROVED']));
        // No legacy unprefixed chrome layers.
        for (final e in ents) {
          expect(const {'title', 'legend', 'scale', 'north'}
              .contains(e['8']?.first), isFalse);
        }
      }
    });
  });

  group('6 — one title per drawing series', () {
    test('register titles are distinct, ASCII, and carry the sheet name', () {
      final titles = {
        for (final s in DrawingSeries.values)
          s: drawingSeriesTitle(s, sheetName: 'Lantai 1'),
      };
      expect(titles.values.toSet().length, DrawingSeries.values.length);
      for (final t in titles.values) {
        expect(t.codeUnits.every((c) => c >= 0x20 && c < 0x7f), isTrue);
      }
      expect(titles[DrawingSeries.mechanicalPlan], 'PLAN - Lantai 1');
      expect(drawingSeriesTitle(DrawingSeries.electricalOverview),
          isNot(drawingSeriesTitle(DrawingSeries.electricalDetail)));
    });
  });

  group('7 — one plotted scale for a whole set', () {
    test('a minimum denominator lifts a sparse sheet to the shared 1 : N', () {
      const sparse = Network(nodes: [
        NetNode(id: 'a', sheetId: 's', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's', x: 100, y: 0, floorIndex: 0),
      ], edges: [
        NetEdge(
            id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      ]);
      PlanSheetPlot? plot({int? min}) => planSheetPlot(
            net: sparse,
            sheetId: 's',
            floorIndex: 0,
            projectName: 'p',
            sheetName: 's',
            dateString: '2026-10-18',
            metersPerPixel: 0.02,
            minScaleDenominator: min,
          );
      final natural = plot()!.scaleDenominator;
      final shared = plot(min: 100)!.scaleDenominator;
      expect(natural, lessThan(100));
      expect(shared, 100);
      // Snapped to a ladder rung >= the floor, never below.
      final snap = snapPlottedScale(
          rawScale: 10,
          metersPerPixel: 0.02,
          hasContent: true,
          paperLabel: 'A3',
          minDenominator: 100);
      expect(snap.scaleRow, '1 : 100 @ A3');
      // Property: the floor never draws a sheet LARGER than its own fit.
      for (final min in [20, 50, 100, 200]) {
        final n = plot(min: min)!.scaleDenominator;
        expect(n, greaterThanOrEqualTo(math.max(min, natural)));
      }
    });
  });

  group('8 — the DEVICE rule clears the GRUP heading', () {
    test('bold 7-pt GRUP ends left of the first ruled vertical', () {
      final project = _twoBoards();
      final sys = computeSystem(_p, project);
      final s = buildElectricalSld(
          project: project, result: sys, onlyPanelId: 'LP');
      final head =
          s.prims.whereType<SldLabel>().firstWhere((t) => t.text == 'GRUP');
      final width = 'GRUP'
              .split('')
              .fold<int>(0, (a, c) => a + _boldWidth[c]!) /
          1000 *
          head.size;
      // 2.889 em × 7 pt = 20.2.
      expect(width, closeTo(20.223, 1e-3));
      // The first vertical rule to the right of the GRUP head.
      final rules = s.prims
          .whereType<SldLine>()
          .where((l) => (l.x1 - l.x2).abs() < 1e-9 && l.x1 > head.x)
          .map((l) => l.x1)
          .toList()
        ..sort();
      expect(rules, isNotEmpty);
      expect(head.x + width, lessThan(rules.first),
          reason: 'GRUP ends at ${head.x + width}, rule at ${rules.first}');
    });
  });
}
