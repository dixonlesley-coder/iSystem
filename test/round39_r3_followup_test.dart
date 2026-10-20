// Round 39 r3 follow-up (2026-10-20) — the two residuals the r3 review left:
//
// 1. A position-only write (panel drag on the single-line, a board / load
//    placed or moved on the layout) runs on every drag frame. Phase
//    assignment reads currents and topology, never positions, so these
//    intents skip the two stamping solves and keep every way's
//    `assignedPhase` verbatim.
// 2. A value-identical MEP re-sync (the on-open sync of a saved project)
//    writes NOTHING, so an untouched legacy file is not re-stamped and does
//    not open dirty.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show Offset;
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/load_list.dart' show defaultMotorCosPhi;
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

ElectricalCircuit _amps(String id, double a) => ElectricalCircuit(
      id: id,
      name: id,
      loadKind: LoadKind.heating,
      loadW: 231 * a,
      cosPhi: 1,
      phases: 1,
      length: const Length(10),
    );

void main() {
  test('geometry-only writes keep every assignedPhase and change only position',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctl = c.read(electricalProjectProvider.notifier);
    ctl.setProject(ElectricalProject(panels: [
      ElectricalPanel(
          id: 'db',
          name: 'DB',
          x: 0,
          y: 0,
          circuits: [_amps('a', 30), _amps('b', 20), _amps('c', 20)]),
    ]));
    // A content edit stamps the solved lines onto the document.
    ctl.setCircuit('db', 'a', name: 'A');
    final stamped = {
      for (final w in c.read(electricalProjectProvider).panels.single.circuits)
        w.id: w.assignedPhase,
    };
    expect(stamped.values.whereType<PhaseLine>(), hasLength(3));

    ctl.setPanelPosition('db', 120, 80);
    ctl.movePanels({'db': const Offset(240, 160)});
    final after = c.read(electricalProjectProvider).panels.single;
    expect(after.x, 240);
    expect(after.y, 160);
    expect(
        {for (final w in after.circuits) w.id: w.assignedPhase}, stamped);
  });

  test('a value-identical MEP re-sync writes nothing', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctl = c.read(electricalProjectProvider.notifier);
    ctl.setProject(const ElectricalProject(
        panels: [ElectricalPanel(id: 'mdp', name: 'MDP')]));
    final pump = ElectricalCircuit(
      id: 'mep-pump',
      name: kSupplyPumpLoadName,
      loadKind: LoadKind.motor,
      loadW: 3000,
      cosPhi: defaultMotorCosPhi,
      length: kDefaultCircuitLength,
      sourceEquipmentId: 'pump',
      flaOverrideA: const Current(5),
    );
    ctl.syncMepEquipment([pump]);
    final once = c.read(electricalProjectProvider);
    ctl.syncMepEquipment([pump]);
    expect(identical(c.read(electricalProjectProvider), once), isTrue);
  });
}
