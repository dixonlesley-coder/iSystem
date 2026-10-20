// Round 37 (2026-10-18) — app-side seed suite.
//
// regression-rekind-motor-to-spare-seeds-phantom-load: re-kinding a motor way
// to Spare / Capacitor / Feeder must never seed the motor's input W onto the
// way (a spare is zero-demand; a capacitor way reads loadW as kvar).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

ElectricalProject _project() => ElectricalProject(
      panels: [
        ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
          ElectricalCircuit(
              id: 'm',
              name: 'Chiller',
              loadKind: LoadKind.motor,
              motorKw: 30,
              loadW: 0,
              phases: 3,
              length: const Length(20)),
          ElectricalCircuit(
              id: 'l',
              name: 'Lighting',
              loadKind: LoadKind.lighting,
              loadW: 1000,
              cosPhi: 1,
              isLighting: true,
              length: const Length(20)),
        ]),
      ],
    );

ElectricalCircuit _way(ProviderContainer c, String id) => c
    .read(electricalProjectProvider)
    .panels
    .single
    .circuits
    .firstWhere((w) => w.id == id);

void main() {
  test('motor -> spare: a zero-demand spare, MDP demand is the 1 kW lighting',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(electricalProjectProvider.notifier)
      ..setProject(_project());
    ctrl.setCircuit('mdp', 'm', loadKind: LoadKind.spare);
    expect(_way(c, 'm').loadW, 0);
    expect(_way(c, 'm').motorKw, isNull);
    final r = c.read(electricalResultProvider).panels['mdp']!;
    // Only the 1000 W lighting way (demand factor 1) remains.
    expect(r.demandW, closeTo(1000, 1e-6));
    final spare = r.circuits.firstWhere((x) => x.circuitId == 'm');
    expect(spare.designCurrent.amperes, closeTo(0, 1e-9));
  });

  test('motor -> capacitor: no phantom 34 kvar bank (loadW stays 0)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(electricalProjectProvider.notifier)
      ..setProject(_project());
    ctrl.setCircuit('mdp', 'm', loadKind: LoadKind.capacitor);
    expect(_way(c, 'm').loadW, 0);
  });

  test('a typed W on the same edit still wins (spare with a reservation)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(electricalProjectProvider.notifier)
      ..setProject(_project());
    ctrl.setCircuit('mdp', 'm', loadKind: LoadKind.spare, loadW: 500);
    expect(_way(c, 'm').loadW, 500);
  });

  test('lighting -> spare zeroes the way like a new spare way', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(electricalProjectProvider.notifier)
      ..setProject(_project());
    ctrl.setCircuit('mdp', 'l', loadKind: LoadKind.spare);
    expect(_way(c, 'l').loadW, 0);
  });
}
