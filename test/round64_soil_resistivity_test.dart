/// Round 64 (elec-convergence-16-tt-soil-resistivity-unreachable-electrode-
/// never-designed) — the site soil resistivity is reachable from the app:
/// `setSoilResistivity` designs the earth electrode (rods in the Commercial
/// BOM) and turns the `tt-earth-fault-unchecked` advisory into the real
/// Ra x IΔn <= 50 V judge. One undo step; clearing hands it back.
///
/// First principles (Dwight single rod, IEEE 142): 3 m x 16 mm rod in
/// 100 ohm.m soil -> R1 = 100 / (2 pi 3) x (ln(8 x 3 / 0.016) - 1)
/// = 5.305 x (7.313 - 1) = 33.5 ohm, so at least ceil(33.5 / 5) = 7 rods
/// even with no mutual coupling; the BS 7430 count is the engine's own
/// `designElectrode` figure.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/commercial_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/electrode.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

ElectricalProject _tt() => const ElectricalProject(
  id: 'p',
  name: 'Farm',
  earthingSystem: EarthingSystem.tt,
  panels: [
    ElectricalPanel(
      id: 'MDP',
      name: 'MDP',
      system: ElectricalSystem.threePhase,
      voltage: Voltage(400),
      circuits: [
        ElectricalCircuit(
          id: 's',
          name: 'Sockets',
          loadKind: LoadKind.socket,
          loadW: 2000,
          length: Length(20),
        ),
        ElectricalCircuit(
          id: 'l',
          name: 'Lamp',
          loadKind: LoadKind.lighting,
          loadW: 800,
          length: Length(15),
        ),
      ],
    ),
  ],
);

double _rods(ProviderContainer c) => c
    .read(electricalBomProvider)
    .lines
    .where((l) => l.description.startsWith('Earth electrode rod'))
    .fold<double>(0, (s, l) => s + l.qty);

bool _unchecked(ProviderContainer c) => c
    .read(electricalAdvancedProvider)
    .warnings
    .any((w) => w.code == 'tt-earth-fault-unchecked');

void main() {
  test('R1 for a 3 m x 16 mm rod in 100 ohm.m soil is 33.5 ohm', () {
    expect(singleRodResistance(100, 3, 16), closeTo(33.49, 0.02));
  });

  test('soil resistivity designs the electrode, undo hands it back', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(electricalProjectProvider.notifier)..setProject(_tt());
    // Before: no electrode, no rods, only the advisory.
    expect(c.read(electricalAdvancedProvider).electrode, isNull);
    expect(_rods(c), 0);
    expect(_unchecked(c), isTrue);

    ctrl.setSoilResistivity(100);
    expect(c.read(electricalProjectProvider).soilResistivityOhmM, 100);
    final e = c.read(electricalAdvancedProvider).electrode;
    expect(e, isNotNull);
    final design = designElectrode(soilResistivityOhmM: 100);
    expect(e!.rodCount, design.rodCount);
    expect(e.rodCount, greaterThanOrEqualTo(7));
    expect(_rods(c), design.rodCount.toDouble());
    // The advisory gives way to the real judge.
    expect(_unchecked(c), isFalse);

    // One undo step.
    c.read(historyProvider.notifier).undo();
    expect(c.read(electricalProjectProvider).soilResistivityOhmM, isNull);
    expect(_rods(c), 0);

    // Non-finite refused; 0 / null clear.
    ctrl.setSoilResistivity(double.nan);
    expect(c.read(electricalProjectProvider).soilResistivityOhmM, isNull);
    ctrl.setSoilResistivity(250);
    expect(c.read(electricalProjectProvider).soilResistivityOhmM, 250);
    ctrl.setSoilResistivity(0);
    expect(c.read(electricalProjectProvider).soilResistivityOhmM, isNull);
  });
}
