// Round 74 (2026-10-18) — elec-convergence-25-rekind-keeps-old-kind-cosphi-
// demand-factor.
//
// Re-kinding a way re-derives the new kind's default cos φ and demand factor
// unless the engineer typed them. A socket (cos 0.9, df 0.7) re-kinded to
// heating (cos 1.0, df 1.0) used to keep 0.9 / 0.7, so the board demand and
// every feeder above it ran 30 % low.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

ElectricalProject _project() => ElectricalProject(panels: [
      ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
        ElectricalCircuit(
            id: 'f',
            name: 'Feeder DB',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'db',
            phases: 3,
            length: const Length(20)),
      ]),
      const ElectricalPanel(id: 'db', name: 'DB', circuits: []),
    ]);

void main() {
  ElectricalCircuit way(ProviderContainer c, String id) => c
      .read(electricalProjectProvider)
      .panels
      .firstWhere((p) => p.id == 'db')
      .circuits
      .firstWhere((w) => w.id == id);

  test('socket -> heating takes heating cos 1.0 / df 1.0; demand and feeder '
      'Ib follow', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(electricalProjectProvider.notifier)
      ..setProject(_project());
    final id = ctrl.addCircuit('db', kind: LoadKind.socket);
    ctrl.setCircuit('db', id, loadW: 9000, phases: 3);
    ctrl.setCircuit('db', id, loadKind: LoadKind.heating);
    final w = way(c, id);
    expect(w.loadKind, LoadKind.heating);
    expect(w.cosPhi, loadDefaults[LoadKind.heating]!.cosPhi); // 1.0
    expect(w.demandFactor, loadDefaults[LoadKind.heating]!.demandFactor); // 1
    expect(w.cosPhiUserSet, isFalse);
    expect(w.demandFactorUserSet, isFalse);
    final r = c.read(electricalResultProvider);
    // 9000 W × df 1.0 — the full resistive load reaches the board.
    expect(r.panels['db']!.demandW, closeTo(9000, 1e-6));
    // Feeder Ib = P / (√3 · 400 · cos φ 1.0) = 9000 / 692.8 = 12.99 A.
    final feeder =
        r.panels['mdp']!.circuits.firstWhere((x) => x.circuitId == 'f');
    expect(feeder.designCurrent.amperes,
        closeTo(9000 / (math.sqrt(3) * 400 * 1.0), 0.06));
  });

  test('a TYPED cos φ / demand factor survives the re-kind', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(electricalProjectProvider.notifier)
      ..setProject(_project());
    final id = ctrl.addCircuit('db', kind: LoadKind.socket);
    ctrl.setCircuit('db', id, cosPhi: 0.95, demandFactor: 0.8);
    ctrl.setCircuit('db', id, loadKind: LoadKind.heating);
    final w = way(c, id);
    expect(w.cosPhi, 0.95);
    expect(w.demandFactor, 0.8);
  });

  test('socket -> pump / hvac take their own kind defaults', () {
    for (final kind in [LoadKind.pump, LoadKind.motor, LoadKind.hvac]) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier)
        ..setProject(_project());
      final id = ctrl.addCircuit('db', kind: LoadKind.socket);
      ctrl.setCircuit('db', id, loadKind: kind);
      final w = way(c, id);
      expect(w.cosPhi, loadDefaults[kind]!.cosPhi, reason: '$kind');
      expect(w.demandFactor, loadDefaults[kind]!.demandFactor,
          reason: '$kind');
    }
  });
}
