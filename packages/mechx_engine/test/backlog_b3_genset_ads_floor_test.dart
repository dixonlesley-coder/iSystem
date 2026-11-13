/// Backlog B-3 (2026-11-13) — THE GENSET RECOMMENDATION HOLDS DISCONNECTION.
///
/// An UNFORCED standby set was recommended on its running kVA and the
/// motor-start floor only, so the recommended set could fail
/// `ads-disconnection-on-genset` on its own (smaller) alternator fault (the
/// apartment's 50 kVA set did, on three ways, before its fire pump grew).
/// `computeSystem` now tries the ladder ratings above that recommendation,
/// each a full re-solve with its own T4 cable growth, and takes the first at
/// which no auto-sized way / feeder of a genset-backed board fails; the
/// result carries it (`gensetAdsFloorKva`) and every genset sizing reads it,
/// governed by `disconnection`. A forced nameplate is judged, never resized.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart'
    show ElectricalSystemResult;
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

/// MDP → (10 m feeder, cable fixed at 10 mm²) → essential PP-E carrying one
/// 15 kW lift 60 m away, on a standby set of [kva] (null ⇒ recommended).
ElectricalProject _lift({double? kva, bool fixLift = false}) =>
    ElectricalProject(
      id: 'p',
      name: 'p',
      sources: ElectricalSources(
          generator: GeneratorSource(
              kva: kva == null ? null : ApparentPower.kilovoltAmperes(kva))),
      panels: [
        const ElectricalPanel(
          id: 'mdp',
          name: 'MDP',
          system: ElectricalSystem.threePhase,
          voltage: Voltage(400),
          circuits: [
            ElectricalCircuit(
              id: 'f-e',
              name: 'Feeder E',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'e',
              length: Length(10),
              cableOverrideMm2: 10,
            ),
          ],
        ),
        ElectricalPanel(
          id: 'e',
          name: 'PP-E',
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f-e',
          essential: true,
          circuits: [
            ElectricalCircuit(
              id: 'lift',
              name: 'Lift',
              loadKind: LoadKind.motor,
              cosPhi: loadDefaults[LoadKind.motor]!.cosPhi,
              demandFactor: 1,
              motorKw: 15,
              phases: 3,
              phasesUserSet: true,
              length: const Length(60),
              cableOverrideMm2: fixLift ? 16 : null,
            ),
          ],
        ),
      ],
    );

({ElectricalSystemResult sys, AdvancedStudy adv}) _solve(ElectricalProject p) {
  final sys = computeSystem(_p, p, originFaultLevel: const Current(16000));
  return (sys: sys, adv: computeAdvancedStudy(_p, p, sys));
}

double _isc(double kva) => kva * 1000 / (math.sqrt(3) * 400 * 0.12);

void main() {
  // The lift: 15 kW / 0.88 ⇒ 28.9 A, a 32 A D-curve MCB (20 × In = 640 A
  // magnetic) ⇒ Zs_max = 0.95 × 230 / 640 = 0.341 Ω (IEC 60364-4-41, the
  // ADS limit `gensetAdsCheck` judges with).
  // Floors: running 21.31 kVA, the lift's DOL start floor 58.92 kVA ⇒ the
  // first ladder rung ≥ 58.92 is 65 kVA (governed by motor start).
  // Alternator fault S / (√3 × 400 × X''d 0.12): 65 kVA ⇒ 781.8 A, 82 kVA ⇒
  // 986.3 A, 100 kVA ⇒ 1202.8 A. On 65 / 82 kVA the lift fails even at the
  // T4 growth bound (35 mm²: on 82 kVA the hot loop is R 0.033 + feeder
  // 2 × 2.19 × 0.010 × 1.28 + lift (0.627 + 1.38) × 0.060 × 1.28 = 0.243,
  // X 0.232 + 0.011 ⇒ 0.344 Ω > 0.341), so the cable reverts. On 100 kVA
  // the source falls to R 0.027 / X 0.190 and 25 mm² (PE 16) holds:
  // R 0.027 + 0.056 + (0.87 + 1.38) × 0.060 × 1.28 = 0.256, X 0.201 ⇒
  // 0.325 Ω ≤ 0.341 ⇒ the recommendation is 100 kVA, governed by
  // disconnection.
  test('alternator faults by hand', () {
    expect(_isc(65), closeTo(781.8, 0.05));
    expect(_isc(82), closeTo(986.3, 0.05));
    expect(_isc(100), closeTo(1202.8, 0.05));
    expect(0.95 * 230 / (20 * 32), closeTo(0.341, 5e-4));
  });

  test('a forced 65 kVA (the running / start rating) fails on the lift', () {
    final r = _solve(_lift(kva: 65));
    expect(r.sys.gensetAdsFloorKva, isNull);
    expect(r.adv.gensetAdsFailedCircuitIds, {'lift'});
    expect(gensetFaultBasis(_lift(kva: 65), r.sys)!.iscA,
        closeTo(_isc(65), 1e-6));
  });

  test('the recommendation is 100 kVA, governed by disconnection', () {
    final p = _lift();
    final r = _solve(p);
    expect(r.sys.gensetAdsFloorKva, 100);
    expect(gensetPlantVa(p, r.sys), 100e3);
    final g = r.adv.powerOneLine!.gensetSizing!;
    expect(g.ratingKva.inKilovoltAmperes, 100);
    expect(g.governing, GensetSizingReason.disconnection);
    expect(g.floorsKva!.running, closeTo(21.31, 0.005));
    expect(g.floorsKva!.start, closeTo(58.92, 0.005));
    expect(g.floorsKva!.ads, 100);
    // Without the disconnection floor the same floors give 65 kVA.
    final noAds = sizeGenerator(gensetBackupDemandVa(p, r.sys),
        backupPower: gensetBackupDemandW(p, r.sys),
        minKvaForStart: gensetStartFloorFor(p, r.sys));
    expect(noAds.ratingKva.inKilovoltAmperes, 65);
    expect(noAds.governing, GensetSizingReason.motorStart);
    // On it the lift grows to 25 mm² and disconnects in time.
    final lift = r.sys.panels['e']!.circuits.single;
    expect(lift.cable.csaMm2, 25);
    expect(lift.cableRaisedForAds, isTrue);
    expect(r.adv.gensetAdsFailedCircuitIds, isEmpty);
    final fs = faultStudy(r.sys, p, _p,
        originFaultLevel: Current(gensetFaultBasis(p, r.sys)!.iscA));
    expect(fs.circuits['lift']!.zsOhm, closeTo(0.325, 0.002));
    // Every genset surface reads the 100 kVA set (BOM, one-line).
    expect(r.adv.bom.lines.any((l) => l.description.startsWith('Genset 100 kVA')),
        isTrue);
  });

  test('a user-fixed way is never what the recommendation grows for', () {
    // The lift's cable fixed by the engineer: it is not auto-sized, so the
    // set stays at its 65 kVA motor-start rating and the error stands.
    final r = _solve(_lift(fixLift: true));
    expect(r.sys.gensetAdsFloorKva, isNull);
    expect(r.adv.gensetAdsFailedCircuitIds, {'lift'});
    expect(r.adv.powerOneLine!.gensetSizing!.governing,
        GensetSizingReason.motorStart);
  });
}
