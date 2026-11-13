// Backlog E-4 (2026-11-13) — the genset block-load (step) check (apartment
// backlog f). On ATS transfer the standby set picks up what it backs (the
// essential boards' simultaneous non-motor demand plus their running motors,
// `gensetBackupDemandW`) in ONE step; it is judged against the allowable
// first step `kGensetFirstStepFraction` (0.6, `// VERIFY` ISO 8528-5 class
// G2) x the rated kW (kVA x 0.8). Exceeded => an INFO recommending staged
// pick-up; the rating is never changed.
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart' show WarningSeverity;
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

ElectricalProject _project({ApparentPower? forced}) => ElectricalProject(
      id: 'p',
      name: 'Step',
      sources: ElectricalSources(generator: GeneratorSource(kva: forced)),
      panels: const [
        ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
          ElectricalCircuit(
              id: 'f', name: 'Feeder PP-E', feedsPanelId: 'ppe'),
        ]),
        ElectricalPanel(
            id: 'ppe',
            name: 'PP-E',
            essential: true,
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f',
            circuits: [
              ElectricalCircuit(
                  id: 'l',
                  name: 'Emergency lighting',
                  loadKind: LoadKind.lighting,
                  isLighting: true,
                  loadW: 30000,
                  cosPhi: 0.9,
                  length: Length(20)),
              ElectricalCircuit(
                  id: 'h',
                  name: 'Heaters',
                  loadKind: LoadKind.heating,
                  loadW: 30000,
                  cosPhi: 1.0,
                  length: Length(20)),
            ]),
      ],
    );

void main() {
  test('the pure check: 0.6 x rated kVA x 0.8', () {
    final st = gensetStepLoadCheck(
        ratedKva: ApparentPower.kilovoltAmperes(100),
        stepW: const Power(50000))!;
    expect(st.ratedKw, 80);
    expect(st.allowableKw, closeTo(48, 1e-9));
    expect(st.stepKw, 50);
    expect(st.exceeded, isTrue);
    expect(
        gensetStepLoadCheck(
                ratedKva: ApparentPower.kilovoltAmperes(100),
                stepW: const Power(48000))!
            .exceeded,
        isFalse);
    expect(
        gensetStepLoadCheck(
            ratedKva: const ApparentPower(0), stepW: const Power(1)),
        isNull);
  });

  test('a typed 100 kVA set picking up 60 kW in one step: INFO, staged '
      'pick-up; the rating is unchanged', () {
    const profile = PuilProfile();
    final project = _project(forced: ApparentPower.kilovoltAmperes(100));
    final sys = computeSystem(profile, project);
    final adv = computeAdvancedStudy(profile, project, sys);
    final st = adv.powerOneLine!.gensetStepLoad!;
    // PP-E: 30 000 + 30 000 = 60 000 W = 60 kW in one step; 100 kVA x 0.8
    // = 80 kW rated, 0.6 x 80 = 48 kW allowable => exceeded.
    expect(st.stepKw, closeTo(60, 1e-6));
    expect(st.allowableKw, closeTo(48, 1e-9));
    expect(st.exceeded, isTrue);
    final w = adv.warnings
        .where((w) => w.code == 'genset-step-load-staged')
        .single;
    expect(w.severity, WarningSeverity.info);
    expect(w.message, contains('60.0 kW in one step'));
    expect(w.message, contains('48.0 kW'));
    // Judge-only: the typed set stays 100 kVA.
    expect(adv.powerOneLine!.gensetSizing!.ratingKva.inKilovoltAmperes, 100);
    expect(adv.verifyItems, contains(gensetStepLoadVerifyItem));
    // The calc report's genset section states it.
    final md = buildElectricalCalcReport(ElectricalCalcReportData(
      projectName: 'Step',
      date: '2026-11-13',
      standardsName: 'PUIL',
      standardsRevision: '2011',
      project: project,
      result: sys,
      powerOneLine: adv.powerOneLine,
    ));
    expect(
        md,
        contains('Genset step load on transfer: 60.0 kW in one step vs the '
            'allowable first step 48.0 kW (60 % of 80.0 kW rated) — above '
            'it: stage the pick-up'));
  });

  test('an unforced set is never resized by the check', () {
    const profile = PuilProfile();
    final project = _project();
    final sys = computeSystem(profile, project);
    final adv = computeAdvancedStudy(profile, project, sys);
    final st = adv.powerOneLine!.gensetStepLoad!;
    final kva = adv.powerOneLine!.gensetSizing!.ratingKva.inKilovoltAmperes;
    expect(st.ratedKw, closeTo(kva * kGeneratorPf, 1e-9));
    expect(st.exceeded, st.stepKw > 0.6 * kva * 0.8 + 1e-9);
  });
}
