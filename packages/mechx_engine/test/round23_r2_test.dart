// Round 23 r2 — reviewer follow-ups to the round-23 audit fix:
//
//   elec-drafting-2-5 (root)  every BreakerClass consumer is exhaustive: an
//                             ACB is never sized / timed as an MCB.
//   elec-drafting-2-3 parity  the electrical layout DXF stamps the PDF twin's
//                             snapped 1 : N (same fit, underlay frame + the
//                             real title block).
import 'dart:convert' show latin1;
import 'dart:typed_data';

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/enclosure.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

/// One 3φ resistive way of [w] watts on a single LV main board.
ElectricalProject _board(double w) =>
    ElectricalProject(id: 'b', name: 'B', panels: [
      ElectricalPanel(id: 'LVMDP', name: 'LVMDP', circuits: [
        ElectricalCircuit(
            id: 'h',
            name: 'Process load',
            loadKind: LoadKind.heating,
            loadW: w,
            cosPhi: 1.0,
            phases: 3,
            length: const Length(5)),
      ]),
    ]);

void main() {
  group('elec-drafting-2-5: ACB is its own class everywhere', () {
    test('deviceModules: an ACB frame >= the widest (1600 A) MCCB band', () {
      final acb = deviceModules(deviceClass: 'ACB', poles: 4, ratingA: 2500);
      final mccb1600 =
          deviceModules(deviceClass: 'MCCB', poles: 4, ratingA: 1600);
      // 330 mm / 18 mm = 18.3 ⇒ 19 modules; the >250 A MCCB band is
      // 140 mm / 18 = 7.8 ⇒ 8 modules; the MCB-by-poles path would be 4.
      expect(acb, (acbFrameWidthMm / dinModuleWidthMm).ceil());
      expect(acb, 19);
      expect(mccb1600, 8);
      expect(acb, greaterThanOrEqualTo(mccb1600));
      expect(acb, greaterThan(4)); // never the narrow MCB path
    });

    test('the ACB board enclosure is no smaller than a 1250 A MCCB board', () {
      // 1500 kW → 2165 A → ACB 2500 A; 700 kW → 1010 A → MCCB 1250 A.
      final acbR = computeSystem(_profile, _board(1500000));
      final mccbR = computeSystem(_profile, _board(700000));
      expect(
          acbR.panels['LVMDP']!.incomer.breaker.deviceClass, BreakerClass.acb);
      expect(mccbR.panels['LVMDP']!.incomer.breaker.deviceClass,
          BreakerClass.mccb);
      expect(estimatePanelModules(acbR.panels['LVMDP']!),
          greaterThanOrEqualTo(estimatePanelModules(mccbR.panels['LVMDP']!)));
      final a = computeAdvancedStudy(_profile, _board(1500000), acbR)
          .enclosure['LVMDP']!;
      final m = computeAdvancedStudy(_profile, _board(700000), mccbR)
          .enclosure['LVMDP']!;
      expect(a.modules, greaterThanOrEqualTo(m.modules));
      expect(a.widthMm, greaterThanOrEqualTo(m.widthMm));
    });

    test('switchgear loss: an ACB pole dissipates more than an MCCB pole', () {
      expect(acbLossPerPoleW, greaterThan(mccbLossPerPoleW));
    });

    test('arc-flash clearing time: MCB < MCCB <= ACB (never the MCB 0.05 s)',
        () {
      final mcb = arcFlashClearingTimeS(BreakerClass.mcb);
      final mccb = arcFlashClearingTimeS(BreakerClass.mccb);
      final acb = arcFlashClearingTimeS(BreakerClass.acb);
      expect(mcb, 0.05);
      expect(mccb, 0.2);
      expect(acb, greaterThanOrEqualTo(mccb));
      final r = computeSystem(_profile, _board(1500000));
      final af =
          computeAdvancedStudy(_profile, _board(1500000), r).arcFlash['LVMDP'];
      expect(af, isNotNull);
      expect(af!.clearingTimeS, acb);
    });

    test('BOM: an ACB line is an honest unmatched / substituted line', () {
      final r = computeSystem(_profile, _board(1500000));
      final bom = buildBom(r, parts: fullCatalog());
      final line = bom.lines.firstWhere((l) =>
          l.category == PartCategory.breaker &&
          l.description.startsWith('ACB 2500A'));
      // No catalogue ACB exists: either nothing reaches 2500 A (unmatched,
      // no SKU) or the matched part is flagged as a substitution — never a
      // silent clean match on an MCCB.
      expect(line.sku == null || line.deviceSubstituted, isTrue,
          reason: line.description);
      // The widest catalogue frame is below 2500 A ⇒ nothing covers it:
      // the line carries no SKU (unmatched), never a clean MCCB match.
      expect(line.sku, isNull);
      // Round 23 follow-up — the unmatched line is still PRICEABLE: an
      // `elec:breaker:<class>:<A>:<poles>P[:<kA>]` key (audit round 8: every
      // non-catalogue electrical line carries an `elec:` key).
      expect(line.priceKey, startsWith('${kElecPriceKeyPrefix}breaker:ACB:2500A:'));
      // The substitution branch is unreachable today: ACB starts above 1600 A
      // and the widest catalogue breaker is 800 A, so nothing ever matches.
      // Only an MCB carries a B/C/D curve — no ACB line names one.
      for (final l in bom.lines.where((l) =>
          l.category == PartCategory.breaker &&
          l.description.startsWith('ACB'))) {
        expect(l.description, isNot(contains('curve')), reason: l.description);
      }
    });
  });

  group("elec-drafting-2-3: the DXF stamps the PDF twin's 1 : N", () {
    const chrome = DrawingChrome(drawingNumber: 'E-101');
    const data = ElectricalPlanData(nodes: [
      ElectricalPlanNode(
          x: 100, y: 100, tag: 'LVMDP', kind: ElectricalPlanNodeKind.panel),
      ElectricalPlanNode(
          x: 600, y: 100, tag: 'PP-EM', kind: ElectricalPlanNodeKind.panel),
    ], routes: [
      ElectricalPlanRoute(x1: 100, y1: 100, x2: 600, y2: 100, label: '15.0 m'),
    ]);
    // A plan sheet far larger than the drawn content: the underlay frame
    // drives the PDF's fit, which the node-only DXF estimate cannot see.
    final underlay = RasterPlanUnderlay(
        rgbPixels: Uint8List.fromList([255, 255, 255]),
        pixelWidth: 1,
        pixelHeight: 1,
        sheetWidthPx: 4000,
        sheetHeightPx: 2800);

    String pdfScale({PlanUnderlay? u}) {
      final pdf = latin1.decode(electricalPlanToPdf(
          data: data,
          projectName: 'P',
          sheetName: 'Lantai Dasar',
          dateString: '2026-10-19',
          chrome: chrome,
          metersPerPixel: 0.03,
          underlay: u));
      return RegExp(r'1 : (\d+) @ A3').firstMatch(pdf)!.group(1)!;
    }

    for (final withUnderlay in [false, true]) {
      test('parity (${withUnderlay ? 'with' : 'no'} underlay)', () {
        final u = withUnderlay ? underlay : null;
        final n = electricalPlanPlottedScaleDenominator(
            data: data,
            projectName: 'P',
            sheetName: 'Lantai Dasar',
            dateString: '2026-10-19',
            chrome: chrome,
            metersPerPixel: 0.03,
            underlay: u);
        expect(n, isNotNull);
        expect('$n', pdfScale(u: u));
        final dxf = electricalPlanToDxf(
            data: data,
            projectName: 'P',
            sheetName: 'Lantai Dasar',
            chrome: chrome,
            metersPerPixel: 0.03,
            plottedScaleDenominator: n);
        expect(RegExp(r'1 : (\d+) @ A3').firstMatch(dxf)!.group(1), '$n');
      });
    }

    test('the underlay frame really moves the rung (the gap is real)', () {
      // 4000 px × 0.03 m/px = 120 m across the A3 sheet needs a coarser
      // rung than the 15 m route alone.
      expect(
          int.parse(pdfScale(u: underlay)), greaterThan(int.parse(pdfScale())));
    });

    test('uncalibrated: no denominator (the PDF prints NTS)', () {
      expect(
          electricalPlanPlottedScaleDenominator(
              data: data,
              projectName: 'P',
              sheetName: 'L',
              dateString: '2026-10-19',
              chrome: chrome),
          isNull);
    });
  });
}
