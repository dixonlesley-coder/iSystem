// Round 46 (2026-10-18) — mech-props-1-mep-sync-listener-writes-during-build.
//
// The MEP -> electrical feed listener used to write the electrical project
// SYNCHRONOUSLY. The feed is first recomputed inside ANOTHER provider's build
// (the Review fan-in reads the electrical result right after an equipment
// drop), so the synchronous `state =` raised Riverpod's "Providers are not
// allowed to modify other providers during their initialization" assertion on
// a cold provider graph — a build-order flake in every debug/test build. The
// write is now deferred to one microtask (the Round 32 rule), reading the
// LATEST feed so a burst of edits syncs once.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx_engine/network/network.dart';

void main() {
  group('mech-props-1-mep-sync-listener-writes-during-build', () {
    for (final component in [
      NodeComponent.ahu,
      NodeComponent.pump,
      NodeComponent.supplyDiffuser,
    ]) {
      test('cold graph: read electrical, drop a ${component.name}, read the '
          'Review fan-in synchronously — no write during a build; the MEP '
          'board syncs on the next microtask', () async {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.read(electricalProjectProvider);
        c
            .read(networkControllerProvider.notifier)
            .mergeOrAddComponent('s1', 0, const Offset(10, 10), component);
        // The verbatim repro: this read used to throw the Riverpod assertion.
        expect(() => c.read(designIssuesProvider), returnsNormally);
        await Future<void>.delayed(Duration.zero);
        // After the deferred sync the derived way is on the MEP board exactly
        // when the drawn machine carries an electrical load (an AHU / pump
        // does; a passive diffuser does not) — the same rule as before, only
        // one microtask later.
        final derived = c
            .read(electricalProjectProvider)
            .panels
            .expand((p) => p.circuits)
            .where((w) => w.sourceEquipmentId != null)
            .toList();
        expect(
          derived,
          component == NodeComponent.supplyDiffuser ? isEmpty : hasLength(1),
        );
      });
    }

    test('a burst of drops syncs ONCE on the latest feed (no intermediate '
        'write)', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(electricalProjectProvider);
      await Future<void>.delayed(Duration.zero);
      var writes = 0;
      c.listen(electricalProjectProvider, (_, _) => writes++);
      final n = c.read(networkControllerProvider.notifier);
      n.mergeOrAddComponent('s1', 0, const Offset(10, 10), NodeComponent.pump);
      c.read(designIssuesProvider);
      n.mergeOrAddComponent('s1', 0, const Offset(400, 10), NodeComponent.pump);
      c.read(designIssuesProvider);
      expect(writes, 0, reason: 'nothing is written synchronously');
      await Future<void>.delayed(Duration.zero);
      expect(writes, 1);
      final derived = c
          .read(electricalProjectProvider)
          .panels
          .expand((p) => p.circuits)
          .where((w) => w.sourceEquipmentId != null);
      expect(derived, hasLength(2));
    });
  });
}
