// Backlog E-3 (2026-11-13) — the MV-side device of the service transformer
// (tower backlog d): from the transformer rating and the 20 kV MV voltage,
// I = S / (sqrt3 x 20 000), then an HV HRC fuse from the named 20 kV
// transformer-fuse table (`// VERIFY`, up to 1250 kVA), else an MV circuit
// breaker with relay on the next standard CT >= 1.25 x I. Report-only: no LV
// figure reads it.
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/tower.dart';

void main() {
  group('mvTransformerProtection (pure)', () {
    test('a fused unit: 630 kVA -> I = 630 000 / (sqrt3 x 20 000) = 18.19 A '
        '-> HV HRC fuse 40 A', () {
      final p = mvTransformerProtection(630)!;
      expect(p.flcA, closeTo(18.187, 1e-3));
      expect(p.fused, isTrue);
      expect(p.fuseA, 40);
      expect(p.device, 'HV HRC fuse 40 A');
    });

    test('the table limit: 1250 kVA (36.08 A) -> 80 A; a rating between rows '
        'takes the row above', () {
      expect(mvTransformerProtection(1250)!.fuseA, 80);
      expect(mvTransformerProtection(25)!.fuseA, 6.3);
      // Every table row is ~2.2 x its own full-load current (>= 1.4 x).
      for (final r in kMvTransformerFuseTable20kV) {
        final i = mvTransformerProtection(r.kva)!.flcA;
        expect(r.fuseA / i, greaterThanOrEqualTo(1.4), reason: '${r.kva}');
      }
    });

    test('above the table: 1600 kVA -> 46.19 A -> MV CB + relay, CT >= '
        '1.25 x 46.19 = 57.74 A -> 60/5 A', () {
      final p = mvTransformerProtection(1600)!;
      // 1 600 000 / (1.7320508 x 20 000) = 46.188 A.
      expect(p.flcA, closeTo(46.188, 1e-3));
      expect(p.fused, isFalse);
      expect(p.ctPrimaryA, 60);
      expect(p.device, 'MV CB + relay, CT 60/5 A');
      // 2500 kVA: 72.17 A x 1.25 = 90.21 -> CT 100.
      expect(mvTransformerProtection(2500)!.ctPrimaryA, 100);
      expect(mvTransformerProtection(0), isNull);
    });

    test('the table is surfaced in the PUIL verify checklist', () {
      expect(
          const PuilProfile()
              .verifyChecklist
              .any((v) => v.value.toString().contains('MV transformer '
                  'protection at 20 kV')),
          isTrue);
    });
  });

  group('tower (declared 1600 kVA)', () {
    final tower = buildTower();
    final project = tower.electrical;
    final sys = computeSystem(
      const PuilProfile(),
      project,
      calibrationBySheet: tower.calibrations,
      building: tower.building,
      originFaultLevel: estimatedServiceFaultLevelA(project) ??
          const Current(defaultLvUtilityFaultKa * 1000),
      busbarClearingTimeS: 0.1,
      phaseReassignThresholdA: 1.0,
    );
    final adv = computeAdvancedStudy(const PuilProfile(), project, sys);

    test('MV full-load current 46.19 A; MV CB + relay on a 60/5 A CT', () {
      final mv = serviceMvProtection(project, sys)!;
      expect(mv.kva, 1600);
      expect(mv.units, 1);
      expect(mv.flcA, closeTo(46.19, 0.005));
      expect(mv.device, 'MV CB + relay, CT 60/5 A');
      expect(mv.summary, contains('46.19 A'));
      // The study's own primary FLC agrees (rounded to 0.1 A).
      expect(adv.supply.primaryFlc!.amperes, closeTo(46.2, 1e-9));
    });

    test('E-501 prints it beside the MV main', () {
      final head = adv.powerOneLine!.nodes.firstWhere((n) => n.id == 'utility');
      expect(head.sub, 'MV supply 20 kV + MV main (MV CB + relay, CT 60/5 A)');
    });

    test('the calc report supply section states it', () {
      final md = buildElectricalCalcReport(ElectricalCalcReportData(
        projectName: 'Tower',
        date: '2026-11-13',
        standardsName: 'PUIL',
        standardsRevision: '2011',
        project: project,
        result: sys,
      ));
      expect(
          md,
          contains('- MV transformer protection: MV transformer feeder '
              '(1600 kVA): I = 1600 kVA / (sqrt3 x 20 kV) = 46.19 A'));
      expect(md, contains('MV CB + relay, CT 60/5 A'));
    });

    test('E-301 prints it beside the MV main', () {
      final sheet = buildElectricalOverview(
          project: project, result: sys, sourceChain: true);
      final texts = [
        for (final p in sheet.prims)
          if (p is SldLabel) p.text,
      ];
      expect(texts, contains('MV CB + relay, CT 60/5 A'));
    });
  });

}
