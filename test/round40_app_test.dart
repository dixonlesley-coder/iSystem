// Round 40 (2026-10-18) — electrical store regressions.
//
// 1. regression-parked-way-retyped-motor-kw-ignored — a PARKED MEP way
//    retyped through the inspector's Motor kW field sizes on the new machine
//    (the stale minted FLA is dropped), exactly like a hand-entered motor.
// 2. elec-props-6-mep-way-machine-fields-editable-then-silently-reverted —
//    an MEP-derived way's power / life-safety duty is refused (it follows
//    the drawn machine), so the live solve never diverges from a reopen.
// 3. elec-props-6-empty-mep-board-survives-last-way-delete — deleting the
//    MEP board's last way removes the empty board + its feeder, as a reopen
//    does.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/units.dart';

ElectricalCircuitResult _way(ProviderContainer c, String panel, String id) =>
    c
        .read(electricalResultProvider)
        .panels[panel]!
        .circuits
        .firstWhere((r) => r.circuitId == id);

// A parked 3 kW pump: minted input W 3529.4 and FLA 6.0 A, source removed.
const _parked = ElectricalCircuit(
  id: 'mep-n1',
  name: 'Pump P-01 (source removed)',
  loadKind: LoadKind.pump,
  loadW: 3529.4,
  motorKw: 3,
  cosPhi: 0.85,
  phases: 3,
  length: Length(10),
  flaOverrideA: Current(6.0),
);

void main() {
  group('regression-parked-way-retyped-motor-kw-ignored', () {
    test('retyping a parked pump to 15 kW sizes it as a 15 kW pump', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctl = c.read(electricalProjectProvider.notifier);
      ctl.setProject(const ElectricalProject(panels: [
        ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
          _parked,
          // The same machine typed by hand: the reference sizing.
          ElectricalCircuit(
            id: 'hand',
            name: 'Hand pump',
            loadKind: LoadKind.pump,
            motorKw: 15,
            cosPhi: 0.85,
            phases: 3,
            length: Length(10),
          ),
        ]),
      ]));
      ctl.setCircuit('mdp', 'mep-n1', motorKw: 15);
      final way = c
          .read(electricalProjectProvider)
          .panels
          .single
          .circuits
          .firstWhere((w) => w.id == 'mep-n1');
      expect(way.flaOverrideA, isNull);
      expect(way.loadW, closeTo(15000 / kAssumedMotorEfficiency, 1e-6));
      // Ib = (15 / 0.88) kW / (sqrt(3) * 400 * 0.85) = 28.9 A -> MCB 32 A.
      final ib = 15000 / kAssumedMotorEfficiency / (math.sqrt(3) * 400 * 0.85);
      expect(ib, closeTo(28.9, 0.05));
      final r = _way(c, 'mdp', 'mep-n1');
      final hand = _way(c, 'mdp', 'hand');
      expect(r.runCurrentA.amperes, closeTo(ib, 0.1));
      expect(r.breaker.ratingA.amperes, 32);
      expect(r.breaker.ratingA.amperes, hand.breaker.ratingA.amperes);
      expect(r.cable.csaMm2, hand.cable.csaMm2);
    });

    test('merging a 4 kW hand motor into the parked pump keeps both machines',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctl = c.read(electricalProjectProvider.notifier);
      ctl.setProject(const ElectricalProject(panels: [
        ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
          _parked,
          ElectricalCircuit(
            id: 'm4',
            name: 'Motor 4 kW',
            loadKind: LoadKind.motor,
            motorKw: 4,
            cosPhi: 0.85,
            phases: 3,
            length: Length(10),
          ),
        ]),
      ]));
      ctl.mergeCircuit('mdp', 'm4', 'mep-n1');
      // (3 + 4) kW / 0.88 / (sqrt(3) * 400 * 0.85) = 13.5 A (was 6.0 A).
      final ib = 7000 / kAssumedMotorEfficiency / (math.sqrt(3) * 400 * 0.85);
      expect(ib, closeTo(13.5, 0.05));
      expect(_way(c, 'mdp', 'mep-n1').runCurrentA.amperes, closeTo(ib, 0.1));
    });
  });

  group('elec-props-6-mep-way-machine-fields-editable-then-silently-reverted',
      () {
    ElectricalCircuit derived() => const ElectricalCircuit(
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

    for (final edit in <String, void Function(ElectricalProjectController)>{
      'motorKw': (ctl) =>
          ctl.setCircuit(kMepEquipmentPanelId, 'mep-n0', motorKw: 4),
      'loadW': (ctl) =>
          ctl.setCircuit(kMepEquipmentPanelId, 'mep-n0', loadW: 4000),
      'clearMotorKw': (ctl) =>
          ctl.setCircuit(kMepEquipmentPanelId, 'mep-n0', clearMotorKw: true),
      'lifeSafety': (ctl) =>
          ctl.setCircuit(kMepEquipmentPanelId, 'mep-n0', lifeSafety: true),
    }.entries) {
      test('a typed ${edit.key} on a derived way is refused — the solve and '
          'the document stay the drawn machine\'s', () {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        final ctl = c.read(electricalProjectProvider.notifier);
        ctl.setProject(const ElectricalProject(
            panels: [ElectricalPanel(id: 'mdp', name: 'MDP')]));
        ctl.syncMepEquipment([derived()]);
        final before = c.read(electricalProjectProvider);
        final ibBefore =
            _way(c, kMepEquipmentPanelId, 'mep-n0').runCurrentA.amperes;
        edit.value(ctl);
        expect(identical(c.read(electricalProjectProvider), before), isTrue);
        expect(_way(c, kMepEquipmentPanelId, 'mep-n0').runCurrentA.amperes,
            ibBefore);
      });
    }

    test('a non-machine edit (cable family) on a derived way still applies',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctl = c.read(electricalProjectProvider.notifier);
      ctl.setProject(const ElectricalProject(
          panels: [ElectricalPanel(id: 'mdp', name: 'MDP')]));
      ctl.syncMepEquipment([derived()]);
      ctl.setCircuit(kMepEquipmentPanelId, 'mep-n0', cableType: 'NYY');
      final w = c
          .read(electricalProjectProvider)
          .panels
          .firstWhere((p) => p.id == kMepEquipmentPanelId)
          .circuits
          .single;
      expect(w.cableType, 'NYY');
    });
  });

  group('elec-props-6-empty-mep-board-survives-last-way-delete', () {
    test('deleting the parked last way removes the board + its feeder, as a '
        'resync does', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctl = c.read(electricalProjectProvider.notifier);
      ctl.setProject(const ElectricalProject(
          panels: [ElectricalPanel(id: 'mdp', name: 'MDP')]));
      ctl.syncMepEquipment([
        const ElectricalCircuit(
          id: 'mep-n0',
          name: 'Supply / booster pump',
          loadKind: LoadKind.pump,
          loadW: 3529.4,
          motorKw: 3,
          cosPhi: 0.85,
          phases: 3,
          length: kDefaultCircuitLength,
          sourceEquipmentId: 'n0',
          flaOverrideA: Current(6.0),
        ),
      ]);
      // A real edit makes the way non-pristine, so removal PARKS it.
      ctl.setCircuit(kMepEquipmentPanelId, 'mep-n0', phases: 1);
      ctl.syncMepEquipment(const []);
      expect(
          c
              .read(electricalProjectProvider)
              .panels
              .firstWhere((p) => p.id == kMepEquipmentPanelId)
              .circuits
              .single
              .sourceEquipmentId,
          isNull);
      ctl.deleteCircuit(kMepEquipmentPanelId, 'mep-n0');
      final live = c.read(electricalProjectProvider);
      expect(live.panels.map((p) => p.id), ['mdp']);
      expect(live.panels.single.circuits, isEmpty,
          reason: 'the feeder to the removed board is swept');
      // The same document a resync (reopen) gives.
      ctl.syncMepEquipment(const []);
      expect(c.read(electricalProjectProvider).panels.map((p) => p.id),
          ['mdp']);
      expect(c.read(electricalProjectProvider).panels.single.circuits,
          isEmpty);
    });
  });
}
