// Round 65 (elec-convergence-17-mep-board-3ph-under-1ph-root) — the MEP
// equipment board takes the SERVICE's system. On a 1-phase 230 V house
// (PLN 900 VA) the first drawn pump used to mint a 3-phase 400 V MEP board
// under the 1-phase root: a `feeder-phase-mismatch` ERROR (a 3-phase board
// cannot be fed from a single-phase one) no UI path could clear. The board
// is now 1-phase 230 V under a 1-phase root, and the 3-phase mint is kept
// under a 3-phase root (byte-identical).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

ElectricalCircuit _pump() => const ElectricalCircuit(
      id: 'mep-p1',
      name: 'Pump P-01',
      loadKind: LoadKind.pump,
      loadW: 420,
      phases: 1,
      flaOverrideA: Current(2.3),
      sourceEquipmentId: 'p1',
    );

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

ElectricalPanel _mep(ProviderContainer c) => c
    .read(electricalProjectProvider)
    .panels
    .firstWhere((p) => p.id == kMepEquipmentPanelId);

void main() {
  test('a 1-phase service gets a 1-phase MEP board, no mismatch error', () {
    final c = _c();
    final e = c.read(electricalProjectProvider.notifier);
    e.addPanel(
        name: 'MDP',
        system: ElectricalSystem.singlePhase,
        voltage: const Voltage(230));
    e.setSupplyCapacityVa(const ApparentPower(900));
    e.syncMepEquipment([_pump()]);
    final mep = _mep(c);
    expect(mep.system, ElectricalSystem.singlePhase);
    expect(mep.voltage.volts, 230);
    expect(mep.fedByCircuitId, kMepEquipmentFeederId);
    final codes = {
      for (final w in c.read(electricalResultProvider).warnings) w.code,
    };
    expect(codes, isNot(contains('feeder-phase-mismatch')));
    // A re-sync keeps the board's system.
    e.syncMepEquipment([_pump()]);
    expect(_mep(c).system, ElectricalSystem.singlePhase);
  });

  test('a 3-phase root keeps the 3-phase 400 V mint', () {
    final c = _c();
    final e = c.read(electricalProjectProvider.notifier);
    e.addPanel(name: 'MDP');
    e.syncMepEquipment([_pump()]);
    final mep = _mep(c);
    expect(mep.system, ElectricalSystem.threePhase);
    expect(mep.voltage.volts, 400);
  });

  test('an existing 3-phase MEP board under a 1-phase root is correctable',
      () {
    final c = _c();
    final e = c.read(electricalProjectProvider.notifier);
    e.addPanel(name: 'MDP');
    e.syncMepEquipment([_pump()]);
    final root = c
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id != kMepEquipmentPanelId);
    e.setPanelSystem(root.id, ElectricalSystem.singlePhase);
    expect(
        c.read(electricalResultProvider).warnings.map((w) => w.code),
        contains('feeder-phase-mismatch'));
    e.setPanelSystem(kMepEquipmentPanelId, ElectricalSystem.singlePhase);
    expect(
        c.read(electricalResultProvider).warnings.map((w) => w.code),
        isNot(contains('feeder-phase-mismatch')));
  });
}
