// Round 41 (2026-10-18) — regression-rekind-bypasses-mep-machine-lock.
//
// Re-kinding an MEP-derived way (Spare / Capacitor / any other kind) is
// refused: the drawn machine owns its kind, so the live solve and the next
// sync / reopen never diverge (a Spare re-kind zeroed the pump's W live and
// the next sync restored it; a Capacitor re-kind read the pump's W as kvar
// and dropped its demand for good).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

const _derived = ElectricalCircuit(
  id: 'mep-n0',
  name: 'Supply / booster pump',
  loadKind: LoadKind.pump,
  loadW: 17045.5,
  motorKw: 15,
  cosPhi: 0.85,
  phases: 3,
  length: kDefaultCircuitLength,
  sourceEquipmentId: 'n0',
);

void main() {
  for (final kind in LoadKind.values.where((k) => k != LoadKind.pump)) {
    test('re-kinding a derived way to ${kind.name} is refused', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctl = c.read(electricalProjectProvider.notifier);
      ctl.setProject(const ElectricalProject(
          panels: [ElectricalPanel(id: 'mdp', name: 'MDP')]));
      ctl.syncMepEquipment([_derived]);
      final before = c.read(electricalProjectProvider);
      final demandBefore = c.read(electricalResultProvider).supply.demandW;
      ctl.setCircuit(kMepEquipmentPanelId, 'mep-n0', loadKind: kind);
      expect(identical(c.read(electricalProjectProvider), before), isTrue);
      expect(c.read(electricalResultProvider).supply.demandW, demandBefore);
      // The live solve equals a re-sync (what a reopen re-derives).
      ctl.syncMepEquipment([_derived]);
      expect(c.read(electricalResultProvider).supply.demandW, demandBefore);
    });
  }

  test('re-stating the CURRENT kind is not refused (provenance only)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctl = c.read(electricalProjectProvider.notifier);
    ctl.setProject(const ElectricalProject(
        panels: [ElectricalPanel(id: 'mdp', name: 'MDP')]));
    ctl.syncMepEquipment([_derived]);
    ctl.setCircuit(kMepEquipmentPanelId, 'mep-n0', loadKind: LoadKind.pump);
    final way = c
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == kMepEquipmentPanelId)
        .circuits
        .firstWhere((w) => w.id == 'mep-n0');
    expect(way.loadKindUserSet, isTrue);
    expect(way.loadKind, LoadKind.pump);
  });

  test('a hand-entered way may still be re-kinded', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctl = c.read(electricalProjectProvider.notifier);
    ctl.setProject(const ElectricalProject(panels: [
      ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
        ElectricalCircuit(
            id: 'h',
            name: 'Hand pump',
            loadKind: LoadKind.pump,
            motorKw: 4,
            phases: 3,
            length: Length(10)),
      ]),
    ]));
    ctl.setCircuit('mdp', 'h', loadKind: LoadKind.spare);
    final way = c
        .read(electricalProjectProvider)
        .panels
        .single
        .circuits
        .single;
    expect(way.loadKind, LoadKind.spare);
  });
}
