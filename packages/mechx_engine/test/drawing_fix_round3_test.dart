// Drawing review — fix round 3 (2026-11-13): S1–S6 and O1–O3 of the second
// full review (`docs/DRAWING-REVIEW-RECORD.md`), one focused check each, on
// the shared pure layer the PDF and the DXF both draw from.
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/genset_backup.dart'
    show essentialDemandVa, gensetBackupDemandVa;
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/electrical_pagination.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_detail.dart';
import 'package:mechx_engine/report/plan_detail_sheet.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/apartment.dart' as apt;
import 'reference/house.dart' as house;
import 'reference/reference_building.dart';
import 'reference/tower.dart' as tower;

ElectricalSystemResult _solve(ReferenceBuilding b) {
  final fault = estimatedServiceFaultLevelA(b.electrical) ??
      const Current(defaultLvUtilityFaultKa * 1000);
  return computeSystem(const PuilProfile(), b.electrical,
      calibrationBySheet: b.calibrations,
      building: b.building,
      originFaultLevel: fault,
      busbarClearingTimeS: 0.1,
      phaseReassignThresholdA: 1.0);
}

List<SldLabel> _labels(SldSheet s) => s.prims.whereType<SldLabel>().toList();

void main() {
  final tw = tower.buildTower();
  final twSys = _solve(tw);
  final twAdv = computeAdvancedStudy(const PuilProfile(), tw.electrical, twSys);

  group('S1 power one-line captions never run into the next symbol', () {
    test('the MV utility caption wraps inside its column', () {
      final sheet = buildPowerOneLineSheet(twAdv.powerOneLine!);
      final gen = sheet.prims.whereType<SldCircle>().toList();
      expect(gen, isNotEmpty);
      final texts = _labels(sheet).map((l) => l.text).toList();
      final head = texts.indexWhere((t) => t.startsWith('MV supply'));
      expect(head, greaterThanOrEqualTo(0));
      // Wrapped: the device's closing bracket is on a later line.
      expect(texts[head], isNot(endsWith(')')), reason: '$texts');
      expect(texts.skip(head + 1).first, endsWith(')'));
      for (final l in _labels(sheet)) {
        final x1 = l.x + helveticaTextWidth(l.text, l.size);
        for (final c in gen) {
          final vertical = l.y > c.cy - c.r - l.size && l.y < c.cy + c.r + 2;
          final horizontal = l.x < c.cx + c.r && x1 > c.cx - c.r;
          final ownLetter = l.text == 'G';
          expect(!ownLetter && vertical && horizontal, isFalse,
              reason: '"${l.text}" touches a symbol');
        }
      }
    });

    test('wrapPowerOneLineCaption keeps every line within the width', () {
      const t = 'MV supply 20 kV + MV main (MV CB + relay, CT 60/5 A)';
      final lines = wrapPowerOneLineCaption(t, 7, 160);
      expect(lines.join(' '), t);
      for (final l in lines) {
        expect(helveticaTextWidth(l, 7), lessThanOrEqualTo(160));
      }
      expect(wrapPowerOneLineCaption('400 V', 7, 160), ['400 V']);
    });
  });

  group('S2 the essential bus prints the essential board demand', () {
    test('tower: demand = the PP-E figure E-301 prints, basis named', () {
      final bus =
          twAdv.powerOneLine!.nodes.singleWhere((n) => n.id == 'ess-bus');
      final ess = essentialDemandVa(tw.electrical, twSys) / 1000;
      final basis = gensetBackupDemandVa(tw.electrical, twSys).inKilovoltAmperes;
      String one(double v) => v == v.roundToDouble()
          ? v.toInt().toString()
          : v.toStringAsFixed(1);
      expect(bus.sub, startsWith('demand ${one(ess)} kVA'));
      // The board line E-301 prints for PP-E carries the SAME kVA.
      final ppE =
          twSys.panels.values.singleWhere((p) => p.name == 'PP-E');
      expect(one(ppE.demandVaOrEstimate() / 1000), one(ess));
      if (one(ess) != one(basis)) {
        expect(bus.sub, contains('genset basis'));
      }
    });

    test('without the essential demand the legacy basis text stands', () {
      final l = buildPowerOneLine(
          const ElectricalSources(
              generator: GeneratorSource(backupFraction: 0.45)),
          demand: const ApparentPower(100000),
          backupDemand: const ApparentPower(45000));
      expect(l.nodes.singleWhere((n) => n.id == 'ess-bus').sub, '45 kVA');
      final l2 = buildPowerOneLine(
          const ElectricalSources(
              generator: GeneratorSource(backupFraction: 0.45)),
          demand: const ApparentPower(100000),
          backupDemand: const ApparentPower(45000),
          essentialDemand: const ApparentPower(43200));
      expect(l2.nodes.singleWhere((n) => n.id == 'ess-bus').sub,
          'demand 43.2 kVA · genset basis 45 kVA');
    });
  });

  group('S3 an SLD legend keys only what is drawn', () {
    test('house: a red supply warning is not an essential supply', () {
      final h = house.buildHouse();
      final r = _solve(h);
      final ov = buildElectricalOverview(
          project: h.electrical, result: r, sourceChain: true);
      final rs = buildElectricalRiser(
          project: h.electrical,
          result: r,
          building: h.building,
          sourceChain: true);
      for (final s in [ov, rs]) {
        expect(s.legend.map((e) => e.code), isNot(contains('Essential')));
      }
    });

    test('tower: an essential board keys Essential', () {
      final ov = buildElectricalOverview(
          project: tw.electrical, result: twSys, sourceChain: true);
      expect(ov.legend.map((e) => e.code), contains('Essential'));
    });
  });

  group('S4 an off-sheet feeder carries its tag at the DARI mark', () {
    test('apartment: LVMDP > PP-E prints cable · device · length', () {
      final a = apt.buildApartment();
      final r = _solve(a);
      // The page plan hands PP-E's feed to another sheet: its DARI mark.
      final ppE = a.electrical.panels.singleWhere((p) => p.name == 'PP-E');
      final sheet = buildElectricalRiser(
          project: a.electrical,
          result: r,
          building: a.building,
          offPageFeedNotes: {ppE.id: 'LVMDP'});
      final all = _labels(sheet).map((l) => l.text).toList();
      final i = all.indexOf('LVMDP > PP-E');
      expect(i, greaterThanOrEqualTo(0), reason: '$all');
      final tag = all.skip(i + 1).take(2).join(' · ');
      expect(tag, contains('MCB'));
      expect(tag, matches(RegExp(r'\d+(\.\d+)? m')));
    });
  });

  group('S5/S6 key circles keep clear of measured text', () {
    test('a key beside a WC tag clears its real (Helvetica) width', () {
      final layout = PlanLabelLayout();
      // A fixture code at 9 pt: 'WC' is 1.666 em = 15.0 wide.
      final wc = placePlanLabel(
          ax: 100,
          ay: 100,
          bx: 110,
          by: 100,
          text: 'WC',
          textSize: 9,
          layout: layout,
          anchorPoint: (x: 100, y: 100));
      final x0 = wc.lines.first.x, y0 = wc.lines.first.y;
      final x1 = x0 + helveticaTextWidth('WC', 9);
      final keys = PlanKeyRegistry();
      final k = placePlanLabel(
          ax: x1 + 2,
          ay: y0 + 3,
          bx: x1 + 6,
          by: y0 + 3,
          text: 'CW-R1 · DN25',
          textSize: 9,
          layout: layout,
          keys: keys,
          keyOnly: true);
      final c = k.keyCircle!;
      // Nearest point of the WC glyph box (baseline - 0.2 em .. cap height).
      final nx = c.x.clamp(x0, x1), ny = c.y.clamp(y0 - 1.8, y0 + 6.5);
      final d = ((c.x - nx) * (c.x - nx) + (c.y - ny) * (c.y - ny));
      expect(d, greaterThan(c.r * c.r), reason: 'circle clear of the WC');
    });
  });

  group('O1 a TIPIKAL detail sheet prints no single floor', () {
    test('level codes read Ln; the CL datum note is replaced', () {
      expect(planTypicalTag('CW-L7 · DN15 - 4.1 m'), 'CW-Ln · DN15 - 4.1 m');
      expect(planTypicalTag('CW-R1 · DN50'), 'CW-R1 · DN50');
      expect(planTypicalTag('D-GF · DN100'), 'D-Ln · DN100');
      final notes = planTypicalDetailNotes([
        'WC Water closet',
        "CL = pipe centreline above this floor's FFL (Lantai 7 FFL +24.00)",
      ]);
      expect(notes, ['WC Water closet', kPlanTypicalDetailNote]);
      expect(notes.join(' '), isNot(contains('FFL +')));
    });
  });

  group('O2 a plant item prints its duty', () {
    test('a pump prints Q · H · kW; a tank with no capacity stays omitted',
        () {
      const pump = NetNode(
          id: 'p',
          sheetId: 's',
          x: 0,
          y: 0,
          floorIndex: 0,
          component: NodeComponent.pump);
      expect(
          equipmentDetail(pump,
              motor: const Power(18500),
              flow: FlowRate.litersPerSecond(10.8),
              head: const Head(122.1)),
          'Q 10.8 L/s · H 122.1 m · 18.5 kW');
      expect(
          equipmentDetail(pump,
              motor: const Power(370),
              flow: FlowRate.litersPerSecond(0.02),
              head: const Head(0.03)),
          'Q 0.02 L/s · H 0.03 m · 0.37 kW');
      expect(equipmentDetail(pump, motor: const Power(2200)), '2.2 kW');
      const tank = NetNode(
          id: 't',
          sheetId: 's',
          x: 0,
          y: 0,
          floorIndex: 0,
          component: NodeComponent.groundTank);
      // The issued sheet prints the schedule's '-' for it
      // (`issuedRiserEquipmentDetailsProvider`); the engine never invents one.
      expect(equipmentDetail(tank), isNull);
    });
  });

  group('O3 the genset transfer switch and filled E-301 pages', () {
    test('one arrangement: E-301 draws the ATS E-501 draws', () {
      final arr = serviceArrangementOf(tw.electrical, twSys);
      expect(arr.transfer, isNotNull);
      expect(arr.transfer!.boards, contains('PP-E'));
      final ats = twAdv.powerOneLine!.nodes
          .singleWhere((n) => n.kind == PowerNodeKind.ats);
      expect(ats.label, arr.transfer!.label);
      final ov = buildElectricalOverview(
          project: tw.electrical, result: twSys, sourceChain: true);
      final t = _labels(ov).map((l) => l.text).toList();
      expect(t, contains(arr.transfer!.label));
      expect(t.any((x) => x.contains('${arr.transfer!.label} ke PP-E')),
          isTrue);
      expect(ov.legend.map((e) => e.code), contains(arr.transfer!.label));
    });

    test('no genset, no transfer switch', () {
      final h = house.buildHouse();
      expect(serviceArrangementOf(h.electrical, _solve(h)).transfer, isNull);
    });

    test('tower E-301: no chunk page but the last under half full', () {
      final pages = paginatedElectricalOverviewSheets(
          project: tw.electrical,
          result: twSys,
          chrome: const DrawingChrome(),
          projectName: 'Menara Contoh 30');
      int boards(SldSheet s) =>
          _labels(s).where((l) => RegExp(r'^\d+A \dP · ').hasMatch(l.text))
              .length;
      final chunk = [
        for (final p in pages)
          if (_labels(p).any((l) => l.text.startsWith('LANJUT: '))) p,
      ];
      if (chunk.length < 2) return;
      final counts = chunk.map(boards).toList();
      final full = counts.reduce((a, b) => a > b ? a : b);
      for (var i = 0; i < counts.length - 1; i++) {
        expect(2 * counts[i], greaterThanOrEqualTo(full),
            reason: 'chunk page ${i + 1}: $counts');
      }
    });
  });

  group('detail sheets keep every stack tag (fix round 3)', () {
    test('a cut stub in detail A never takes the stack node detail B owns',
        () {
      final a = apt.buildApartment();
      final net = a.network;
      final tags = elementTags(net, building: a.building);
      PlanDetailCallout c(String l, double x0, double y0, double x1,
              double y1) =>
          PlanDetailCallout(
              letter: l,
              rectPx: (minX: x0, minY: y0, maxX: x1, maxY: y1),
              sheetRef: 'M-501');
      // The apartment's typical-floor clusters (the drain stacks D-R1 at
      // (425, 650) in B, D-R2 at (600, 675) in C; A's clip reaches both).
      final p = planDetailSheetPlot(
          net: net,
          sizing: const {},
          edgeLengths: const <String, Length>{},
          sheetId: apt.kAptSheets[11],
          floorIndex: 11,
          metersPerPixel: 0.01,
          details: [
            c('A', 480, 570, 580, 670),
            c('B', 321.25, 580, 435, 660),
            c('C', 590, 665, 670, 778.75),
          ],
          areaMm: (minX: 0, minY: 0, maxX: 380, maxY: 250),
          edgeTags: tags);
      final printed = {
        for (final e in p.net.edges)
          if (e.kind == EdgeKind.riser && !p.unlabelledIds.contains(e.id))
            p.edgeTags[e.id],
      };
      expect(printed, containsAll(['D-R1', 'D-R2', 'V-R1', 'V-R2']));
    });
  });

  group('detail scale bar fits its frame (fix round 3)', () {
    test('a capped bar takes the longest round length that fits', () {
      // 1:50: the 30 mm rule picks 2 m = 40 mm; capped at 17 mm it takes
      // 0.5 m = 10 mm (1 m = 20 mm does not fit).
      expect(planDetailScaleBarLength(50), 40);
      expect(planDetailScaleBarLength(50, maxLenMm: 17), 10);
      expect(planDetailScaleBarLength(50, maxLenMm: 60), 40);
    });
  });
}
