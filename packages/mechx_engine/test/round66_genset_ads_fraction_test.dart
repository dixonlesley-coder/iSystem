// Round 66 (regression-typed-genset-fraction-skips-genset-ads-judge) — a
// typed genset backup fraction below 100 % with NO board marked essential
// never silently drops the ads-disconnection-on-genset ERROR.
//
// The Round-56 mall (TN-S, 1600 kVA transformer, forced 200 kVA genset), the
// PP-ESS board NOT marked essential and named neutrally ('PP-2'), a 75 kW
// fire-pump way 60 m long.
//
// First principles (Round 56): the alternator sub-transient fault is
// Isc = S / (sqrt3 x 400 x Xd'') = 200e3 / (sqrt3 x 400 x 0.12) = 2405.6 A,
// a source impedance on the U0 loop 230 / 2405.6 = 0.0956 ohm against the
// transformer's 230 / 57 735 = 0.0040 ohm, so the 60 m way that passes ADS
// on the utility fails on the genset. With nothing designated the set can
// pick up ANY board, so the verdict is the same whatever fraction of demand
// it was typed to back: both 'f' and 'fp' fail at fraction 0.5 / 0.9 as at
// the untyped (whole-building) set, and a typed fraction < 1 also raises the
// INFO asking the engineer to mark the boards the set backs.
library;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _mall({double? fraction}) => ElectricalProject(
      id: 'm',
      name: 'Mall',
      earthingSystem: EarthingSystem.tnS,
      transformerKva: const ApparentPower(1600e3),
      sources: ElectricalSources(
          generator: GeneratorSource(
              kva: const ApparentPower(200e3), backupFraction: fraction)),
      panels: const [
        ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'f',
                  name: 'PP-2 feeder',
                  loadKind: LoadKind.feeder,
                  length: Length(50),
                  cableOverrideMm2: 150,
                  feedsPanelId: 'PP'),
            ]),
        ElectricalPanel(
            id: 'PP',
            name: 'PP-2',
            voltage: Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'fp',
                  name: 'Pump',
                  loadKind: LoadKind.pump,
                  motorKw: 75,
                  phases: 3,
                  length: Length(60)),
            ]),
      ],
    );

AdvancedStudy _study(ElectricalProject p) =>
    computeAdvancedStudy(_profile, p, computeSystem(_profile, p));

void main() {
  final whole = _study(_mall());

  test('untyped set: every board judged on the genset fault', () {
    expect(whole.gensetAdsFailedCircuitIds, isNotEmpty);
    expect(whole.gensetAdsFailedCircuitIds, contains('fp'));
    expect(whole.warnings.map((w) => w.code),
        isNot(contains('genset-backed-boards-undesignated')));
  });

  for (final fr in [1.0, 0.9, 0.5]) {
    test('typed fraction $fr: the same ADS-on-genset errors', () {
      final st = _study(_mall(fraction: fr));
      expect(st.gensetAdsFailedCircuitIds, whole.gensetAdsFailedCircuitIds);
      final errs = [
        for (final w in st.warnings)
          if (w.code == 'ads-disconnection-on-genset') w.circuitId,
      ];
      expect(errs.toSet(), whole.gensetAdsFailedCircuitIds);
      final infos = [
        for (final w in st.warnings)
          if (w.code == 'genset-backed-boards-undesignated') w,
      ];
      expect(infos, hasLength(fr < 1 ? 1 : 0));
      if (fr < 1) expect(infos.single.severity, WarningSeverity.info);
    });
  }
}
