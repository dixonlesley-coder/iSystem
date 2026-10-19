/// ROUND 24 (2026-10-18) — the engine half of the round-24 review fixes, each
/// pinned by a hand-derived case (and a seeded property where the rule is
/// one):
///
///   bom      unmatched breakers that differ only in kA never merge
///   incomer  a saturated incomer says OVER RANGE on every printed surface
///   ltscale  the plan DXF dashes plot at the PDF's paper dash ($LTSCALE)
///   e-plan   an off-sheet feeder is drawn as a riser mark + listed
///   duct     a sized duct prints true-width double-line
///   overlap  an annotation that can only overprint is COUNTED + warned
///   e-label  electrical route figures sit along their route, clear of it
///   tt-rcd   TT feeder RCD type / sensitivity / life-safety follow the tree
///   met      a TN main earthing conductor follows the service PE uncapped
///   spd      the SPD distance is measured from the NEAREST upstream SPD
///   dxf      non-finite coords / polyface faces / truncation are honest
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/report/plan_annotation_layout.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuit _heater(String id, double w) => ElectricalCircuit(
      id: id,
      name: id,
      loadKind: LoadKind.heating,
      loadW: w,
      cosPhi: 1.0,
      phases: 3,
      length: const Length(5),
    );

ElectricalPanel _root(String id, List<ElectricalCircuit> c) =>
    ElectricalPanel(id: id, name: id, circuits: c);

ElectricalPanel _sub(String id, String fedBy, List<ElectricalCircuit> c,
        {bool essential = false}) =>
    ElectricalPanel(
      id: id,
      name: id,
      sourceType: PanelSource.feeder,
      fedByCircuitId: fedBy,
      essential: essential,
      circuits: c,
    );

ElectricalCircuit _feeder(String id, String to, double m,
        {bool lifeSafety = false}) =>
    ElectricalCircuit(
      id: id,
      name: 'to $to',
      loadKind: LoadKind.feeder,
      feedsPanelId: to,
      length: Length(m),
      lifeSafety: lifeSafety,
    );

ElectricalCircuitResult _way(ElectricalSystemResult s, String panel, String c) =>
    s.panels[panel]!.circuits.firstWhere((r) => r.circuitId == c);

void main() {
  // ── bom ───────────────────────────────────────────────────────────────────
  group('bom — an unmatched breaker keeps its kA through consolidation', () {
    // 700 kW heater, pf 1, 3φ 400 V: Ib = 700 000 / (√3·400) = 1010.4 A ⇒
    // the 1250 A rung — above every catalogue MCCB frame (none > 800 A), so
    // both incomers are UNMATCHED and differ only in specified kA.
    final project = ElectricalProject(id: 'b', name: 'B', panels: [
      _root('A', [_heater('ha', 700000)]),
      _root('B', [_heater('hb', 700000)]),
    ]);
    final sys = computeSystem(_p, project);

    test('the 1250 A incomer has no catalogue part', () {
      expect(700000 / (math.sqrt(3) * 400), closeTo(1010.4, 0.1));
      expect(sys.panels['A']!.incomer.breaker.ratingA.amperes, 1250);
      expect(matchBreakerSku(sys.panels['A']!.incomer.breaker, fullCatalog(),
              poles: 4),
          isNull);
    });

    for (final order in const [
      {'A': 50.0, 'B': 25.0},
      {'A': 25.0, 'B': 50.0},
    ]) {
      test('50 / 25 kA ⇒ two lines, each on its own key ($order)', () {
        final bom = buildBom(sys,
            parts: fullCatalog(), incomerKaByPanelId: order);
        final incomers = bom.lines
            .where((l) =>
                l.category == PartCategory.breaker &&
                l.description.contains('1250A') &&
                l.description.contains('incomer'))
            .toList();
        expect(incomers, hasLength(2));
        final keys = incomers.map((l) => l.priceKey).toSet();
        expect(keys, {
          'elec:breaker:MCCB:1250A:4P:50kA',
          'elec:breaker:MCCB:1250A:4P:25kA',
        });
        for (final l in incomers) {
          expect(l.qty, 1);
          // The line itself names the kA its key prices.
          final ka = l.priceKey!.split(':').last;
          expect(l.description, contains(' $ka'));
        }
      });
    }
  });

  // ── incomer ───────────────────────────────────────────────────────────────
  group('incomer — OVER RANGE on every printed surface', () {
    // 3000 kW, pf 1: Ib = 3 000 000 / (√3·400) = 4330.1 A > the 4000 A top
    // ACB frame ⇒ saturated.
    final project = ElectricalProject(
        id: 'o', name: 'O', panels: [_root('LVMDP', [_heater('h', 3000000)])]);
    final sys = computeSystem(_p, project);
    final inc = sys.panels['LVMDP']!.incomer;
    final needs = (3000000 / (math.sqrt(3) * 400)).toStringAsFixed(1);

    test('the shared suffix', () {
      expect(inc.overRange, isTrue);
      expect(incomerOverRangeSuffix(inc), ' OVER RANGE (needs ${needs}A)');
      expect(incomerOverRangeSuffix(inc, withNeeds: false), ' OVER RANGE');
      final ok = computeSystem(_p,
              ElectricalProject(id: 'k', name: 'K', panels: [
                _root('P', [_heater('h', 10000)])
              ]))
          .panels['P']!
          .incomer;
      expect(incomerOverRangeSuffix(ok), '');
    });

    test('equipment schedule + calc report + plan node say so', () {
      final rows = buildEquipmentScheduleRows(EquipmentScheduleData(
          projectName: 'O', date: 'd', electrical: sys));
      expect(rows.singleWhere((r) => r.category == EquipmentCategory.panel).size,
          contains('OVER RANGE (needs ${needs}A)'));
      final md = buildElectricalCalcReport(ElectricalCalcReportData(
        projectName: 'O',
        date: 'd',
        standardsName: 'PUIL',
        standardsRevision: '2011',
        project: project,
        result: sys,
      ));
      expect(md, contains('4000 A ACB 4P OVER RANGE (needs ${needs}A)'));
      final placed = ElectricalProject(id: 'o', name: 'O', panels: [
        ElectricalPanel(
          id: 'LVMDP',
          name: 'LVMDP',
          layoutPos: const LayoutPos(sheetId: 's', floorIndex: 0, x: 1, y: 1),
          circuits: [_heater('h', 3000000)],
        ),
      ]);
      final data = buildElectricalPlanData(
          project: placed,
          result: computeSystem(_p, placed),
          sheetId: 's',
          floorIndex: 0);
      expect(data.nodes.single.sub, '4000A 3ph OVER RANGE');
    });
  });

  // ── ltscale ───────────────────────────────────────────────────────────────
  group('ltscale — DXF dashes plot at the PDF paper dash', () {
    test('dash_model × LTSCALE / N = the 6 pt PDF dash (property)', () {
      final rnd = math.Random(24);
      for (var i = 0; i < 50; i++) {
        final n = [20, 50, 100, 200, 500, 1000][rnd.nextInt(6)].toDouble();
        final paperDashMm = kDxfLtypeDashUnits * dxfLtScaleFor(n) / n;
        expect(paperDashMm, closeTo(6 * 25.4 / 72, 1e-12));
        expect(paperDashMm, closeTo(serviceDashPatternPdf(ServiceType.vent)!
                .first *
            25.4 /
            72, 1e-12));
      }
    });

    test('the plan DXF header declares it', () {
      const net = Network(nodes: [
        NetNode(id: 'a', sheetId: 's', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's', x: 300, y: 0, floorIndex: 0),
      ], edges: [
        NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.returnAir),
      ]);
      const plot = PlanSheetPlot(scaleDenominator: 100);
      final dxf = networkToDxf(
          net: net,
          sizing: const {},
          sheetId: 's',
          floorIndex: 0,
          metersPerPixel: 0.02,
          sheetPlot: plot);
      final lines = dxf.split('\n').map((l) => l.trim()).toList();
      final i = lines.indexOf(r'$LTSCALE');
      expect(i, greaterThan(0));
      // 100 × 2.1167 / 12 = 17.6389.
      expect(double.parse(lines[i + 2]), closeTo(100 * 6 * 25.4 / 72 / 12, 1e-4));
    });
  });

  // ── e-plan ────────────────────────────────────────────────────────────────
  group('e-plan — an off-sheet feeder is drawn + listed', () {
    const building = BuildingLevels([
      Floor('Ground', Length(4.0)),
      Floor('Level 1', Length(3.5)),
    ]);
    const calib = {
      's0': ScaleCalibration(0.02),
      's1': ScaleCalibration(0.02),
    };
    const lp2Pos = LayoutPos(sheetId: 's1', floorIndex: 1, x: 100, y: 100);
    const mdpPos = LayoutPos(sheetId: 's0', floorIndex: 0, x: 100, y: 100);
    final project = ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          tag: 'MDP',
          layoutPos: mdpPos,
          circuits: [_feeder('f2', 'LP2', 10)]),
      const ElectricalPanel(
          id: 'LP2',
          name: 'LP-2',
          tag: 'LP-2',
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f2',
          layoutPos: lp2Pos,
          circuits: []),
    ]);
    final len = planLengthLabel(electricalCableLength(mdpPos, lp2Pos,
        calibrationBySheet: calib, building: building));

    test('the source sheet shows ke LP-2 (Level 1) going UP', () {
      final d = buildElectricalPlanData(
          project: project,
          sheetId: 's0',
          floorIndex: 0,
          calibrations: calib,
          building: building);
      final r = d.risers.single;
      expect(r.text, 'ke LP-2 (Level 1) - $len');
      expect(r.sense, 'UP');
      expect((r.x, r.y), (100.0, 100.0));
      expect(d.unplaced, contains('Feeder ke LP-2 (Level 1) - $len (lembar lain)'));
      final pdf = String.fromCharCodes(electricalPlanToPdf(
          data: d, projectName: 'P', sheetName: 's0', dateString: 'd'));
      expect(pdf, contains('UP ke LP-2 \\(Level 1\\)'));
      final dxf = electricalPlanToDxf(data: d, projectName: 'P', sheetName: 's0');
      expect(dxf, contains('UP ke LP-2 (Level 1)'));
    });

    test('the fed sheet shows dari MDP (Ground) going DN', () {
      final d = buildElectricalPlanData(
          project: project,
          sheetId: 's1',
          floorIndex: 1,
          calibrations: calib,
          building: building);
      expect(d.risers.single.text, 'dari MDP (Ground) - $len');
      expect(d.risers.single.sense, 'DN');
    });
  });

  // ── duct ──────────────────────────────────────────────────────────────────
  group('duct — true-width double line', () {
    test('the outline sits ±W/2 off the run (property)', () {
      final rnd = math.Random(7);
      for (var i = 0; i < 40; i++) {
        final ax = rnd.nextDouble() * 100, ay = rnd.nextDouble() * 100;
        final bx = ax + 1 + rnd.nextDouble() * 100;
        final by = ay + rnd.nextDouble() * 100 - 50;
        final half = 0.5 + rnd.nextDouble() * 10;
        final o = planDoubleLineOutline(ax, ay, bx, by, half);
        expect(o, hasLength(2));
        final len = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
        for (final s in o) {
          // Perpendicular distance from (s.x1,s.y1) to the run line = half,
          // and each outline is parallel to (and as long as) the run.
          final d = ((s.x1 - ax) * (by - ay) - (s.y1 - ay) * (bx - ax)).abs() /
              len;
          expect(d, closeTo(half, 1e-9));
          expect(s.x2 - s.x1, closeTo(bx - ax, 1e-9));
          expect(s.y2 - s.y1, closeTo(by - ay, 1e-9));
        }
      }
    });

    test('a 500x350 duct at 1:50 prints two LINEs 500 mm apart in the DXF', () {
      // 300 px × 0.02 m = 6 m run; W 500 mm ⇒ 500 / 50 = 10 mm on paper
      // ≥ 1 mm ⇒ double line, the outline 500 model-mm apart.
      const net = Network(nodes: [
        NetNode(id: 'a', sheetId: 's', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's', x: 300, y: 0, floorIndex: 0),
      ], edges: [
        NetEdge(id: 'd', fromId: 'a', toId: 'b', service: ServiceType.duct),
      ]);
      final sizing = {
        'd': EdgeSizing(
          edgeId: 'd',
          service: ServiceType.duct,
          flow: FlowRate.litersPerSecond(800),
          diameter: Diameter.mm(450),
          velocity: const Velocity(4),
          width: Length.mm(500),
          height: Length.mm(350),
        ),
      };
      expect(planDuctWidthM(sizing['d']), closeTo(0.5, 1e-12));
      final dxf = networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's',
          floorIndex: 0,
          metersPerPixel: 0.02,
          sheetPlot: const PlanSheetPlot(scaleDenominator: 50));
      final l = dxf.split('\n').map((s) => s.trim()).toList();
      final ys = <double>[];
      for (var i = 0; i + 1 < l.length; i++) {
        if (l[i] == '0' && l[i + 1] == 'LINE') {
          var j = i + 2;
          String? layer;
          double? y1;
          while (j + 1 < l.length && l[j] != '0') {
            if (l[j] == '8') layer = l[j + 1];
            if (l[j] == '20') y1 = double.parse(l[j + 1]);
            j += 2;
          }
          if (layer == dxfLayerNameFor(ServiceType.duct) && y1 != null) {
            ys.add(y1);
          }
        }
      }
      // Two outline lines (+ possibly a flow chevron — none: unoriented).
      expect(ys, hasLength(2));
      expect((ys[0] - ys[1]).abs(), closeTo(500, 1e-6));
    });

    test('an NTS DXF (no ladder scale) keeps one line, like the PDF (r2)', () {
      // 300 px × 2 m = 600 m: no A3 ladder scale fits ⇒ plotN null, u =
      // 600 000 / 80 / 2.5 = 3000; W 5000 mm ⇒ 1.67 paper-mm ≥ 1 would have
      // double-lined on the heuristic alone. The PDF has no pointsPerMeter
      // here (NTS) ⇒ single line, so the DXF twin must agree.
      const net = Network(nodes: [
        NetNode(id: 'a', sheetId: 's', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's', x: 300, y: 0, floorIndex: 0),
      ], edges: [
        NetEdge(id: 'd', fromId: 'a', toId: 'b', service: ServiceType.duct),
      ]);
      final sizing = {
        'd': EdgeSizing(
          edgeId: 'd',
          service: ServiceType.duct,
          flow: FlowRate.litersPerSecond(8000),
          diameter: Diameter.mm(2000),
          velocity: const Velocity(4),
          width: Length.mm(5000),
          height: Length.mm(350),
        ),
      };
      expect(a3PlottedScaleDenominatorFor(600000, 0), isNull);
      final dxf = networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's',
          floorIndex: 0,
          metersPerPixel: 2);
      final l = dxf.split('\n').map((s) => s.trim()).toList();
      var lines = 0;
      for (var i = 0; i + 1 < l.length; i++) {
        if (l[i] == '0' && l[i + 1] == 'LINE') {
          var j = i + 2;
          String? layer;
          while (j + 1 < l.length && l[j] != '0') {
            if (l[j] == '8') layer = l[j + 1];
            j += 2;
          }
          if (layer == dxfLayerNameFor(ServiceType.duct)) lines++;
        }
      }
      expect(lines, 1);
    });

    test('a pipe never double-lines', () {
      expect(
          planDuctWidthM(EdgeSizing(
            edgeId: 'p',
            service: ServiceType.coldWater,
            flow: FlowRate.litersPerSecond(1),
            diameter: Diameter.mm(50),
            velocity: const Velocity(1),
          )),
          isNull);
    });
  });

  // ── overlap ───────────────────────────────────────────────────────────────
  group('overlap — a label that can only overprint is counted', () {
    test('a clear sheet ⇒ 0; a fully occupied sheet ⇒ every label counted', () {
      final clear = PlanLabelLayout();
      placePlanLabel(
          ax: 0, ay: 0, bx: 100, by: 0, text: 'DN50', textSize: 2.5, layout: clear);
      expect(clear.unresolvedCount, 0);
      final jammed = PlanLabelLayout(boxes: [
        (minX: -1000.0, minY: -1000.0, maxX: 1000.0, maxY: 1000.0),
      ]);
      for (var i = 0; i < 3; i++) {
        placePlanLabel(
            ax: 0,
            ay: i * 5.0,
            bx: 100,
            by: i * 5.0,
            text: 'DN50',
            textSize: 2.5,
            layout: jammed);
      }
      expect(jammed.unresolvedCount, 3);
      expect(planOverlapWarning(0), isNull);
      expect(planOverlapWarning(3), startsWith('PERHATIAN: 3 label bertumpuk'));
    });
  });

  // ── e-label ───────────────────────────────────────────────────────────────
  group('e-label — route figures sit along their route, clear of it', () {
    test('a fan of home runs: every figure off its own line, none unresolved',
        () {
      // A panel at (0,0) and 7 loads 1.2 m apart at 1:100 (0.02 m/px ⇒ 60 px
      // ≈ in points via the identity map here).
      final nodes = <ElectricalPlanNode>[
        const ElectricalPlanNode(
            x: 0, y: 0, tag: 'LP-1', kind: ElectricalPlanNodeKind.panel),
        for (var i = 0; i < 7; i++)
          ElectricalPlanNode(
              x: 120 + i * 60.0,
              y: 200,
              tag: 'L$i',
              kind: ElectricalPlanNodeKind.load),
      ];
      final routes = <ElectricalPlanRoute>[
        for (var i = 0; i < 7; i++)
          ElectricalPlanRoute(
              x1: 0,
              y1: 0,
              x2: 120 + i * 60.0,
              y2: 200,
              label: '${(3.8 + 0.7 * i).toStringAsFixed(1)} m'),
      ];
      final data = ElectricalPlanData(nodes: nodes, routes: routes);
      final ann = layoutElectricalPlanAnnotations(data,
          map: (x, y) => (x: x, y: -y), sizes: kElectricalPlanPdfSizes);
      expect(ann.routeLabels, hasLength(7));
      expect(ann.overlapCount, 0);
      for (final e in ann.routeLabels.entries) {
        final r = routes[e.key];
        final ax = r.x1, ay = -r.y1, bx = r.x2, by = -r.y2;
        final len = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
        final p = e.value;
        // Rotated to its route (upright) …
        final bearing = math.atan2(by - ay, bx - ax) * 180 / math.pi;
        final up = bearing > 90 ? bearing - 180 : (bearing <= -90 ? bearing + 180 : bearing);
        if (p.leaderAnchor == null) {
          expect(p.angleDeg, closeTo(up, 1e-9));
          // … and its baseline sits OFF its own line (≥ half a text height).
          final l = p.lines.first;
          final d = ((l.x - ax) * (by - ay) - (l.y - ay) * (bx - ax)).abs() / len;
          expect(d, greaterThan(0.5 * kElectricalPlanPdfSizes.routeTextSize));
        }
      }
    });
  });

  // ── tt-rcd ────────────────────────────────────────────────────────────────
  group('tt-rcd — feeder RCDs follow the fed tree', () {
    ElectricalProject threeTier({bool lifeSafetyBoard = false}) =>
        ElectricalProject(
          id: 't',
          name: 'T',
          earthingSystem: EarthingSystem.tt,
          panels: [
            _root('MDP', [_feeder('mf', 'SDP', 30)]),
            _sub('SDP', 'mf', [
              const ElectricalCircuit(
                  id: 'ev',
                  name: 'EV',
                  loadKind: LoadKind.evCharger,
                  loadW: 11000,
                  phases: 3,
                  length: Length(10)),
              _feeder('sf', 'DB', 20),
            ]),
            _sub('DB', 'sf', [
              const ElectricalCircuit(
                  id: 'pump',
                  name: 'Pump',
                  loadKind: LoadKind.pump,
                  motorKw: 11,
                  phases: 3,
                  starterType: StarterType.vfd,
                  length: Length(10)),
            ]),
          ],
        );

    test('Type B on both feeders; 1000 mA above the 300 mA below', () {
      final sys = computeSystem(_p, threeTier());
      expect(_way(sys, 'SDP', 'ev').rcd.type, RcdType.b);
      expect(_way(sys, 'DB', 'pump').rcd.type, RcdType.b);
      final lower = _way(sys, 'SDP', 'sf').rcd;
      final upper = _way(sys, 'MDP', 'mf').rcd;
      expect(lower.type, RcdType.b);
      expect(upper.type, RcdType.b);
      expect(lower.ratingMa, 300);
      expect(upper.ratingMa, 1000);
      // ≥ 3 × IΔn discrimination at every level (300 ≥ 3 × 100 / 30 mA
      // finals; 1000 ≥ 3 × 300).
      expect(upper.ratingMa >= 3 * lower.ratingMa, isTrue);
      expect(upper.timeDelayed && lower.timeDelayed, isTrue);
      expect(upper.reason, contains('≥ 3 × the 300 mA'));
    });

    test('the sensitivity ladder', () {
      expect([for (var i = 0; i < 5; i++) ttFeederRcdMa(i)],
          [300, 1000, 3000, 10000, 10000]);
    });

    test('a feeder to a life-safety-only board takes no tripping RCD', () {
      final project = ElectricalProject(
        id: 'f',
        name: 'F',
        earthingSystem: EarthingSystem.tt,
        panels: [
          _root('MDP', [_feeder('pf', 'PFP', 30)]),
          _sub('PFP', 'pf', [
            const ElectricalCircuit(
                id: 'fp',
                name: 'Fire pump',
                loadKind: LoadKind.pump,
                motorKw: 30,
                phases: 3,
                lifeSafety: true,
                length: Length(10)),
            const ElectricalCircuit(
                id: 'jp',
                name: 'Jockey pump',
                loadKind: LoadKind.pump,
                motorKw: 1.5,
                phases: 3,
                lifeSafety: true,
                length: Length(10)),
          ]),
        ],
      );
      final sys = computeSystem(_p, project);
      final feeder = _way(sys, 'MDP', 'pf').rcd;
      expect(feeder.required, isFalse);
      expect(feeder.reason, contains('RCM'));
      final fault = faultStudy(sys, project, _p);
      final w = fault.warnings
          .where((w) => w.code == 'tt-no-earth-fault-protection')
          .toList();
      // No tripping RCD anywhere on the path (the two pumps + the feeder
      // itself, RCM only) ⇒ the honest 'no RCD' wording on all three.
      expect(w.map((x) => x.circuitId).toSet(), {'fp', 'jp', 'pf'});
      for (final x in w) {
        expect(x.message, contains('carries no RCD'));
      }
    });

    test('a life-safety way under a feeder RCD names that upstream device', () {
      final project = ElectricalProject(
        id: 'm',
        name: 'M',
        earthingSystem: EarthingSystem.tt,
        panels: [
          _root('MDP', [_feeder('mf', 'DB', 30)]),
          _sub('DB', 'mf', [
            const ElectricalCircuit(
                id: 'fp',
                name: 'Fire pump',
                loadKind: LoadKind.pump,
                motorKw: 15,
                phases: 3,
                lifeSafety: true,
                length: Length(10)),
            const ElectricalCircuit(
                id: 'lt',
                name: 'Lights',
                loadKind: LoadKind.lighting,
                isLighting: true,
                loadW: 2000,
                length: Length(10)),
          ]),
        ],
      );
      final sys = computeSystem(_p, project);
      expect(_way(sys, 'MDP', 'mf').rcd.required, isTrue);
      final fault = faultStudy(sys, project, _p);
      final w = fault.warnings
          .singleWhere((w) => w.code == 'tt-no-earth-fault-protection');
      expect(w.message, contains('upstream 300 mA RCD on MDP / to DB'));
      expect(w.message, isNot(contains('carries no RCD')));
    });

    test('a life-safety feeder still passes its Type B load upstream (r2)',
        () {
      // MDP --mf--> SDP --lf (life-safety, no RCD)--> DB [EV charger].
      final project = ElectricalProject(
        id: 'b',
        name: 'B',
        earthingSystem: EarthingSystem.tt,
        panels: [
          _root('MDP', [_feeder('mf', 'SDP', 30)]),
          _sub('SDP', 'mf', [
            const ElectricalCircuit(
                id: 'lt',
                name: 'Lights',
                loadKind: LoadKind.lighting,
                isLighting: true,
                loadW: 2000,
                length: Length(10)),
            _feeder('lf', 'DB', 20, lifeSafety: true),
          ]),
          _sub('DB', 'lf', [
            const ElectricalCircuit(
                id: 'ev',
                name: 'EV',
                loadKind: LoadKind.evCharger,
                loadW: 11000,
                phases: 3,
                length: Length(10)),
          ]),
        ],
      );
      final sys = computeSystem(_p, project);
      expect(_way(sys, 'SDP', 'lf').rcd.required, isFalse);
      final upper = _way(sys, 'MDP', 'mf').rcd;
      // A Type A device here would be blinded by the EV's DC fault current.
      expect(upper.type, RcdType.b);
      // The life-safety feeder carries no RCD ⇒ no discrimination level.
      expect(upper.ratingMa, 300);
    });

    test('TN projects are untouched', () {
      final tn = ElectricalProject(
        id: 't',
        name: 'T',
        panels: threeTier().panels,
      );
      final sys = computeSystem(_p, tn);
      expect(_way(sys, 'MDP', 'mf').rcd.required, isFalse);
    });
  });

  // ── met ───────────────────────────────────────────────────────────────────
  group('met — TN main earthing follows the service PE uncapped', () {
    test('ladder arithmetic', () {
      expect(tnMainEarthingConductorMm2(_p, 10), 16); // floor
      expect(tnMainEarthingConductorMm2(_p, 120), 120); // > the old 50 cap
      // 2 × 150 = 300 mm² equivalent (parallel runs each carry a PE).
      expect(tnMainEarthingConductorMm2(_p, 150, runsPerPhase: 2), 300);
      // The TT electrode conductor keeps the 16..50 clamp.
      expect(_p.mainEarthingConductorMm2(120), 50);
    });

    test('a 150 kW TN-C-S service: MET = PE of its main cable (> 50)', () {
      final project = ElectricalProject(
          id: 'm', name: 'M', panels: [_root('MDP', [_heater('h', 150000)])]);
      final sys = computeSystem(_p, project);
      // Ib = 150 000 / (√3·400) = 216.5 A on the incomer rating.
      final ib = Current(150000 / (math.sqrt(3) * 400));
      final inc = sys.panels['MDP']!.incomer.breaker.ratingA;
      final cable = sizeCable(_p,
          designCurrent: ib,
          breakerRating: inc,
          deratingFactor: 1,
          minSectionMm2: 4);
      final pe = _p.peConductorSizeMm2(cable.csaMm2);
      expect(pe, greaterThan(50));
      expect(sys.earthing.mainEarthingConductorMm2,
          tnMainEarthingConductorMm2(_p, pe,
              runsPerPhase: cable.runsPerPhase ?? 1));
    });
  });

  // ── spd ───────────────────────────────────────────────────────────────────
  group('spd — distance from the nearest upstream SPD', () {
    test('MDP → SDP 50 m → DB 3 m: SDP recommended, DB covered by it', () {
      final project = ElectricalProject(id: 's', name: 'S', panels: [
        _root('MDP', [_feeder('a', 'SDP', 50)]),
        _sub('SDP', 'a', [
          _heater('h1', 5000),
          _feeder('b', 'DB', 3),
        ]),
        _sub('DB', 'b', [_heater('h2', 5000)]),
      ]);
      final sys = computeSystem(_p, project);
      final adv = computeAdvancedStudy(_p, project, sys);
      expect(adv.spd['SDP']!.recommended, isTrue);
      expect(adv.spd['DB']!.recommended, isFalse);
      expect(adv.spd['DB']!.note, contains('of the nearest upstream SPD'));
    });
  });

  // ── dxf ───────────────────────────────────────────────────────────────────
  group('dxf — honest parse', () {
    String line(double x1, double y1, Object x2, double y2) =>
        '0\nLINE\n8\n0\n10\n$x1\n20\n$y1\n11\n$x2\n21\n$y2\n';
    String wrap(String body, {String blocks = ''}) =>
        '${blocks.isEmpty ? '' : '0\nSECTION\n2\nBLOCKS\n${blocks}0\nENDSEC\n'}'
        '0\nSECTION\n2\nENTITIES\n${body}0\nENDSEC\n0\nEOF\n';

    test('a 1e999 / NaN coordinate never collapses the bounds', () {
      for (final bad in ['1e999', 'NaN', '-1e999']) {
        final d = parseDxf(wrap(line(0, 0, 40000, 0) +
            line(0, 0, 0, 20000) +
            line(0, 0, bad, 5)))!;
        expect(d.bounds.isUsable, isTrue, reason: bad);
        expect(d.bounds.width, 40000);
        expect(d.bounds.height, 20000);
        expect(d.polylines, hasLength(2), reason: bad);
      }
    });

    test('a polyface mesh adds no plan points (no lines to the origin)', () {
      const poly = '0\nPOLYLINE\n8\n0\n66\n1\n70\n64\n'
          '0\nVERTEX\n8\n0\n10\n700000\n20\n9200000\n70\n192\n'
          '0\nVERTEX\n8\n0\n10\n700050\n20\n9200030\n70\n192\n'
          '0\nVERTEX\n8\n0\n10\n0\n20\n0\n70\n128\n71\n1\n72\n2\n73\n1\n'
          '0\nSEQEND\n';
      final d = parseDxf(wrap(line(700000, 9200000, 700050, 9200000) + poly))!;
      expect(d.bounds.minX, 700000);
      expect(d.bounds.minY, 9200000);
      expect(d.polylines, hasLength(1));
    });

    test('a budget-truncated plan is flagged and its bounds stay complete',
        () {
      final chair = StringBuffer('0\nBLOCK\n8\n0\n2\nCHAIR\n10\n0\n20\n0\n');
      for (var i = 0; i < 50; i++) {
        chair.write(line(i.toDouble(), 0, i.toDouble(), 10));
      }
      chair.write('0\nENDBLK\n');
      // 100 × 100 MINSERT of a 50-line block = 500 000 primitives > the
      // 400 000 cap, then the building wall at x = -50 000.
      const minsert =
          '0\nINSERT\n8\n0\n2\nCHAIR\n10\n0\n20\n0\n70\n100\n71\n100\n44\n100\n45\n100\n';
      final d = parseDxf(wrap(minsert + line(-50000, 0, 0, 0),
          blocks: chair.toString()))!;
      expect(d.truncated, isTrue);
      expect(d.polylines.length, 400000);
      expect(d.bounds.minX, -50000);
      final small = parseDxf(wrap(line(0, 0, 10, 10)))!;
      expect(small.truncated, isFalse);
    });

    test('truncated only when an INSERT is actually refused (r2)', () {
      const tick = '0\nBLOCK\n8\n0\n2\nTICK\n10\n0\n20\n0\n'
          '0\nLINE\n8\n0\n10\n0\n20\n0\n11\n1\n21\n1\n0\nENDBLK\n';
      // 10 × (100 × 100) MINSERTs = exactly maxInserts instances, none refused.
      const m = '0\nINSERT\n8\n0\n2\nTICK\n10\n0\n20\n0\n'
          '70\n100\n71\n100\n44\n2\n45\n2\n';
      final exact = parseDxf(wrap(m * 10, blocks: tick))!;
      expect(exact.polylines, hasLength(100000));
      expect(exact.truncated, isFalse);
      // One more INSERT is refused ⇒ flagged.
      const one = '0\nINSERT\n8\n0\n2\nTICK\n10\n500\n20\n500\n';
      expect(parseDxf(wrap(m * 10 + one, blocks: tick))!.truncated, isTrue);

      // A block nested past the depth limit drops its geometry ⇒ flagged.
      final chain = StringBuffer();
      for (var i = 0; i < 10; i++) {
        chain.write('0\nBLOCK\n8\n0\n2\nB$i\n10\n0\n20\n0\n');
        chain.write(i == 9
            ? line(0, 0, 5, 5)
            : '0\nINSERT\n8\n0\n2\nB${i + 1}\n10\n0\n20\n0\n');
        chain.write('0\nENDBLK\n');
      }
      final deep = parseDxf(wrap(
          '0\nINSERT\n8\n0\n2\nB0\n10\n0\n20\n0\n${line(0, 0, 100, 100)}',
          blocks: chain.toString()))!;
      expect(deep.truncated, isTrue);
    });

    test('a frame change is detected', () {
      const a = DxfBounds(0, 0, 40000, 20000);
      expect(a.differsFrom(const DxfBounds(0, 0, 40000, 20000)), isFalse);
      expect(a.differsFrom(const DxfBounds(0, 0, 48000, 20000)), isTrue);
    });
  });
}
