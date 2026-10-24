// Round 38 (2026-10-18) — the electrical store's two silent-data defects:
//
//  * elec-ui-drawings-1 — 'Feed from' the board that ALREADY feeds the
//    target stripped the existing feeder way (its typed 85 m / NYY) and wrote
//    a fresh 10 m default, silently. Connecting the current parent now KEEPS
//    the existing way (a pure no-op with no undo entry; the Feed-from chooser
//    marks it '(current)').
//  * elec-ui-drawings-4 — duplicating a panel left a target-less
//    'Feeder to X' way that was sized, scheduled and bought; a copied feeder
//    is now a spare way.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

void main() {
  ProviderContainer seeded() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    return c;
  }

  ElectricalCircuit feeder(ProviderContainer c) => c
      .read(electricalProjectProvider)
      .panels
      .firstWhere((p) => p.id == 'mdp')
      .circuits
      .firstWhere((w) => w.feedsPanelId == 'lp1');

  test('re-connecting the CURRENT parent keeps the typed feeder verbatim',
      () {
    final c = seeded();
    final ctrl = c.read(electricalProjectProvider.notifier);
    ctrl.setCircuit('mdp', 'mdp-f1',
        length: const Length(85), cableType: 'NYY');
    final before = feeder(c);
    expect(before.length.meters, 85);

    final projectBefore = c.read(electricalProjectProvider);
    final r = ctrl.connectFeeder('mdp', 'lp1');
    expect(r.connected, isTrue);
    expect(r.reparentedFromLabel, isNull);
    // A pure no-op: the very same project object (nothing committed).
    expect(identical(c.read(electricalProjectProvider), projectBefore), isTrue);

    final after = feeder(c);
    expect(after.id, before.id);
    expect(after.length.meters, 85);
    expect(after.cableType, 'NYY');
    // Idempotent: a second attempt changes nothing either.
    ctrl.connectFeeder('mdp', 'lp1');
    expect(feeder(c).id, before.id);
  });

  test('a genuine re-parent is still allowed', () {
    final c = seeded();
    final ctrl = c.read(electricalProjectProvider.notifier);
    ctrl.duplicatePanel('mdp');
    final copyId = c.read(electricalProjectProvider).panels.last.id;
    expect(ctrl.feederRefusalReason(copyId, 'lp1'), isNull);
  });

  test('a duplicated panel carries no target-less feeder: the copy is a '
      'spare way, never scheduled as "Feeder to LP-1"', () {
    final c = seeded();
    final ctrl = c.read(electricalProjectProvider.notifier);
    final srcFeeders = c
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == 'mdp')
        .circuits
        .where((w) => w.isFeeder)
        .length;
    expect(srcFeeders, greaterThan(0));
    ctrl.duplicatePanel('mdp');
    final copy = c.read(electricalProjectProvider).panels.last;
    expect(copy.circuits.where((w) => w.isFeeder), isEmpty);
    expect(copy.circuits.where((w) => w.loadKind == LoadKind.spare).length,
        greaterThanOrEqualTo(srcFeeders));
    final warnings = c.read(electricalResultProvider).warnings;
    expect(warnings.where((w) => w.code == 'feeder-without-target'), isEmpty);
  });
}
