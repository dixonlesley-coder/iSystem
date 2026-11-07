// Round 67 (elec-convergence-19-genset-ads-skips-full-backup-boards) — a
// genset TYPED to back 100 % of demand judges earth-fault disconnection on
// EVERY board, whatever is marked essential.
//
// The probe: TN-S, a declared 1000 kVA transformer, an auto-sized genset.
// MDP feeds board E (one 3 kW lighting way) and board P (a 55 kW motor and
// a 150 kW three-phase heater, 20 m). The genset plant is the same set in
// every case below (gensetPlantVa), so its alternator sub-transient fault
//   Isc = S / (sqrt3 x 400 x Xd'') with Xd'' = 0.12
// and its U0-loop source impedance 230 / Isc are the same too. With nothing
// marked essential the set may pick up any board, so the ways on P that pass
// on the utility but fail on that fault raise ads-disconnection-on-genset.
// Marking E essential while TYPING 1.0 changes nothing physical: the set is
// still sized on max(1.0 x building, essential) and carries P — so the very
// same ways must fail. Only a typed fraction < 1 (here 0.5) narrows the
// judge to the essential sub-tree {E}, whose 3 kW lighting way passes.
library;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _hospital({required bool essentialE, double? fraction}) =>
    ElectricalProject(
      id: 'h',
      name: 'Hospital',
      earthingSystem: EarthingSystem.tnS,
      transformerKva: const ApparentPower(1000e3),
      sources: ElectricalSources(
          generator: GeneratorSource(backupFraction: fraction)),
      panels: [
        const ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'f1',
                  name: 'E feeder',
                  loadKind: LoadKind.feeder,
                  length: Length(20),
                  feedsPanelId: 'E'),
              ElectricalCircuit(
                  id: 'f2',
                  name: 'P feeder',
                  loadKind: LoadKind.feeder,
                  length: Length(20),
                  feedsPanelId: 'P'),
            ]),
        ElectricalPanel(
            id: 'E',
            name: 'Board E',
            voltage: const Voltage(400),
            essential: essentialE,
            circuits: const [
              ElectricalCircuit(
                  id: 'l',
                  name: 'Lighting',
                  loadKind: LoadKind.lighting,
                  loadW: 3000,
                  length: Length(20)),
            ]),
        const ElectricalPanel(
            id: 'P',
            name: 'Board P',
            voltage: Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'm',
                  name: 'Motor',
                  loadKind: LoadKind.motor,
                  motorKw: 55,
                  phases: 3,
                  length: Length(40)),
              ElectricalCircuit(
                  id: 'h',
                  name: 'Heater',
                  loadKind: LoadKind.heating,
                  loadW: 150000,
                  phases: 3,
                  length: Length(20)),
            ]),
      ],
    );

AdvancedStudy _study(ElectricalProject p) =>
    computeAdvancedStudy(_profile, p, computeSystem(_profile, p));

Set<String> _errs(AdvancedStudy st) => {
      for (final w in st.warnings)
        if (w.code == 'ads-disconnection-on-genset') w.circuitId!,
    };

void main() {
  final undesignated = _study(_hospital(essentialE: false));

  test('the undesignated set fails ADS on board P (non-vacuous)', () {
    expect(undesignated.gensetAdsFailedCircuitIds, isNotEmpty);
    expect(_errs(undesignated), undesignated.gensetAdsFailedCircuitIds);
    // Every failure is a way of board P (or P's feeder on the MDP).
    expect(undesignated.gensetAdsFailedCircuitIds.difference({'f2', 'm', 'h'}),
        isEmpty);
  });

  test('E essential + a TYPED 100 % set: the same failures as undesignated',
      () {
    final p = _hospital(essentialE: true, fraction: 1.0);
    expect(gensetBackedPanelIds(p), isNotEmpty);
    expect(effectiveGeneratorBackupFraction(p), 1.0);
    final st = _study(p);
    expect(
        st.gensetAdsFailedCircuitIds, undesignated.gensetAdsFailedCircuitIds);
    expect(_errs(st), undesignated.gensetAdsFailedCircuitIds);
  });

  for (final fr in [0.5, null]) {
    test('E essential + fraction $fr: only the essential sub-tree is judged',
        () {
      final st = _study(_hospital(essentialE: true, fraction: fr));
      // Board E's lighting way (and E's own feeder) pass on the genset.
      expect(st.gensetAdsFailedCircuitIds.difference({'l', 'f1'}), isEmpty);
    });
  }
}
