// Round 42 (2026-10-18) — the electrical store's kind / starter / motor
// provenance.
//
//  * regression-mep-kind-lock-traps-spare-rekinded-machine — a derived way
//    whose kind was left at Spare (re-kinded while parked, or saved by an
//    r40 build) is migrated back to its drawn machine's kind on the next
//    sync, and re-kinding it back to the mint's kind is never refused.
//  * elec-ui-journey-3-starter-survives-rekind-unclearable — a re-kind to a
//    starter-less kind drops the starter.
//  * elec-ui-journey-3-rekind-to-motor-shows-zero-kw — a W-sized way
//    re-kinded onto a motor carries its load as shaft kW.
//  * elec-props-8-star-delta-on-single-phase-way — a star-delta starter on a
//    single-phase way is refused.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
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

// 15 kW shaft / 0.88 = 17 045.5 W.
const double _pumpW = 15000 / 0.88;

ElectricalCircuit _way(ProviderContainer c, String id) => c
    .read(electricalProjectProvider)
    .panels
    .expand((p) => p.circuits)
    .firstWhere((w) => w.id == id);

void main() {
  group('regression-mep-kind-lock-traps-spare-rekinded-machine', () {
    test('parked, re-kinded to Spare, re-adopted: the pump demand returns',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctl = c.read(electricalProjectProvider.notifier);
      ctl.setProject(const ElectricalProject(
          panels: [ElectricalPanel(id: 'mdp', name: 'MDP')]));
      ctl.syncMepEquipment([_derived]);
      expect(c.read(electricalResultProvider).supply.demandW,
          closeTo(_pumpW, 1));
      // An edit makes the way the engineer's (parked, not dropped).
      ctl.setCircuit(kMepEquipmentPanelId, 'mep-n0',
          length: const Length(25));
      ctl.syncMepEquipment(const []);
      final parked = _way(c, 'mep-n0');
      expect(parked.sourceEquipmentId, isNull);
      // A parked way is the engineer's: the re-kind is allowed.
      ctl.setCircuit(kMepEquipmentPanelId, 'mep-n0',
          loadKind: LoadKind.spare);
      expect(_way(c, 'mep-n0').loadKind, LoadKind.spare);
      // The pump is redrawn: the drawn machine owns its kind again.
      ctl.syncMepEquipment([_derived]);
      final back = _way(c, 'mep-n0');
      expect(back.sourceEquipmentId, 'n0');
      expect(back.loadKind, LoadKind.pump);
      expect(back.loadKindUserSet, isFalse);
      expect(back.length.meters, 25); // the hand edit survives
      expect(c.read(electricalResultProvider).supply.demandW,
          closeTo(_pumpW, 1));
    });

    test('an r40-saved Spare derived way migrates back on the first sync',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctl = c.read(electricalProjectProvider.notifier);
      ctl.setProject(ElectricalProject(panels: [
        const ElectricalPanel(id: 'mdp', name: 'MDP'),
        ElectricalPanel(id: kMepEquipmentPanelId, name: 'MEP', circuits: [
          _derived.copyWith(
              loadKind: LoadKind.spare, loadW: 0, loadKindUserSet: true),
        ]),
      ]));
      ctl.syncMepEquipment([_derived]);
      expect(_way(c, 'mep-n0').loadKind, LoadKind.pump);
      expect(c.read(electricalResultProvider).supply.demandW,
          closeTo(_pumpW, 1));
    });

    test('safety net: re-kinding a stuck derived way to its mint kind is '
        'accepted; any other kind stays refused', () {
      final c = ProviderContainer(overrides: [
        mepAutoFeedCircuitsProvider.overrideWithValue(const [_derived]),
      ]);
      addTearDown(c.dispose);
      final ctl = c.read(electricalProjectProvider.notifier);
      ctl.setProject(ElectricalProject(panels: [
        ElectricalPanel(id: kMepEquipmentPanelId, name: 'MEP', circuits: [
          _derived.copyWith(
              loadKind: LoadKind.spare, loadW: 0, loadKindUserSet: true),
        ]),
      ]));
      ctl.setCircuit(kMepEquipmentPanelId, 'mep-n0',
          loadKind: LoadKind.heating);
      expect(_way(c, 'mep-n0').loadKind, LoadKind.spare);
      ctl.setCircuit(kMepEquipmentPanelId, 'mep-n0', loadKind: LoadKind.pump);
      expect(_way(c, 'mep-n0').loadKind, LoadKind.pump);
    });
  });

  group('starter + motor provenance on a re-kind', () {
    ProviderContainer board(ElectricalCircuit way,
        {ElectricalSystem system = ElectricalSystem.threePhase}) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(electricalProjectProvider.notifier).setProject(ElectricalProject(
          panels: [
            ElectricalPanel(
                id: 'mdp',
                name: 'MDP',
                system: system,
                voltage: Voltage(
                    system == ElectricalSystem.threePhase ? 400 : 230),
                circuits: [way]),
          ]));
      return c;
    }

    test('a star-delta motor re-kinded to Heating drops its starter', () {
      final c = board(const ElectricalCircuit(
        id: 'm',
        name: 'M',
        loadKind: LoadKind.motor,
        motorKw: 11,
        phases: 3,
        starterType: StarterType.starDelta,
        length: Length(10),
      ));
      c
          .read(electricalProjectProvider.notifier)
          .setCircuit('mdp', 'm', loadKind: LoadKind.heating);
      final w = _way(c, 'm');
      expect(w.loadKind, LoadKind.heating);
      expect(w.starterType, isNull);
      // 11 kW / 0.88 = 12 500 W seeded (Round 36).
      expect(w.loadW, closeTo(12500, 1e-6));
    });

    test('a starter survives a re-kind to HVAC (it still sizes there)', () {
      final c = board(const ElectricalCircuit(
        id: 'm',
        name: 'M',
        loadKind: LoadKind.motor,
        motorKw: 11,
        phases: 3,
        starterType: StarterType.dol,
        length: Length(10),
      ));
      c
          .read(electricalProjectProvider.notifier)
          .setCircuit('mdp', 'm', loadKind: LoadKind.hvac);
      expect(_way(c, 'm').starterType, StarterType.dol);
    });

    test('General 7500 W re-kinded to Motor: 6.6 kW shaft, the same Ib as a '
        'hand 6.6 kW motor', () {
      final c = board(const ElectricalCircuit(
        id: 'g',
        name: 'G',
        loadKind: LoadKind.general,
        loadW: 7500,
        cosPhi: 0.85,
        phases: 3,
        length: Length(10),
      ));
      c
          .read(electricalProjectProvider.notifier)
          .setCircuit('mdp', 'g', loadKind: LoadKind.motor);
      final w = _way(c, 'g');
      // 7500 W × 0.88 / 1000 = 6.6 kW shaft; the W is cleared.
      expect(w.motorKw, closeTo(6.6, 1e-9));
      expect(w.loadW, 0);
      final ib = c
          .read(electricalResultProvider)
          .panels['mdp']!
          .circuits
          .single
          .runCurrentA
          .amperes;
      final hand = board(const ElectricalCircuit(
        id: 'h',
        name: 'H',
        loadKind: LoadKind.motor,
        motorKw: 6.6,
        cosPhi: 0.85,
        phases: 3,
        length: Length(10),
      ));
      final ibHand = hand
          .read(electricalResultProvider)
          .panels['mdp']!
          .circuits
          .single
          .runCurrentA
          .amperes;
      expect(ib, ibHand);
    });

    test('a star-delta starter on a single-phase way is refused', () {
      final c = board(const ElectricalCircuit(
        id: 'jp',
        name: 'JP',
        loadKind: LoadKind.pump,
        motorKw: 2.2,
        phases: 1,
        length: Length(10),
      ));
      final ctl = c.read(electricalProjectProvider.notifier);
      ctl.setCircuit('mdp', 'jp', starterType: StarterType.starDelta);
      expect(_way(c, 'jp').starterType, isNull);
      ctl.setCircuit('mdp', 'jp', starterType: StarterType.dol);
      expect(_way(c, 'jp').starterType, StarterType.dol);
    });
  });
}
