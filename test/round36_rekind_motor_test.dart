// Round 36 (2026-10-18) — elec-props-4-stale-motorkw-after-rekind.
//
// Re-kinding a hand-entered motor way to HVAC drops the (now hidden) motor
// power, so the starter, the PF study and the genset dip size on the same
// 5 kW the schedule does — never a stale 30 kW.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/units.dart';

ElectricalProject _project({double loadW = 0}) => ElectricalProject(
      sources: const ElectricalSources(generator: GeneratorSource()),
      panels: [
        ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
          ElectricalCircuit(
              id: 'c',
              name: 'Chiller',
              loadKind: LoadKind.motor,
              motorKw: 30,
              loadW: loadW,
              phases: 3,
              starterType: StarterType.dol,
              length: const Length(20)),
        ]),
      ],
    );

ElectricalCircuit _way(ProviderContainer c) => c
    .read(electricalProjectProvider)
    .panels
    .single
    .circuits
    .single;

void main() {
  test('motor 30 kW -> hvac, then loadW 5000: motorKw cleared; starter, PF '
      'and dip all on 5 kW', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(electricalProjectProvider.notifier)
      ..setProject(_project());
    ctrl.setCircuit('mdp', 'c', loadKind: LoadKind.hvac);
    expect(_way(c).motorKw, isNull);
    // No W on the way yet: the motor's electrical input seeds it
    // (30 000 / 0.88 = 34 091 W) so the load survives the re-kind.
    expect(_way(c).loadW, closeTo(30000 / kAssumedMotorEfficiency, 1e-6));
    ctrl.setCircuit('mdp', 'c', loadW: 5000);
    final study = c.read(electricalAdvancedProvider);
    expect(study.controlAssemblies['c']!.motor!.kw, closeTo(5, 1e-9));
    expect(study.powerFactor.totalKw, closeTo(5, 1e-9));
    expect(
        gensetStartMotors(c.read(electricalProjectProvider))
            .single
            .shaftPower
            .inKiloWatts,
        closeTo(5, 1e-9));
  });

  test('a way that already carries W keeps it on the re-kind', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(electricalProjectProvider.notifier)
      ..setProject(_project(loadW: 4000));
    ctrl.setCircuit('mdp', 'c', loadKind: LoadKind.hvac);
    expect(_way(c).motorKw, isNull);
    expect(_way(c).loadW, 4000);
  });

  test('re-kinding motor -> pump keeps the motor power', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(electricalProjectProvider.notifier)
      ..setProject(_project());
    ctrl.setCircuit('mdp', 'c', loadKind: LoadKind.pump);
    expect(_way(c).motorKw, 30);
  });
}
