import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/recovery.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';

/// Finding F2 — the signature-based dirty check that guards Open / Import / quit
/// against silently destroying unsaved work, plus the autosave loop's promotion
/// from "drawn-network-only" to "anything that diverges from the clean baseline".
void main() {
  group('isProjectDirty (guard-time truth table)', () {
    test('a virgin launch is NOT dirty', () {
      // Nothing drawn, no save/open yet — matches the untouched default (even
      // though the electrical store seeds a sample board), so the guard must let
      // Open/Import/quit through without a confirm dialog.
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(isProjectDirty(c.read), isFalse);
    });

    test('drawing a run makes it dirty', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0)); // one edge, two nodes
      expect(c.read(networkControllerProvider).network.nodes, isNotEmpty);
      expect(isProjectDirty(c.read), isTrue);
    });

    test('an electrical-only edit (no drawn network) makes it dirty', () {
      // The old network.nodes.isEmpty gate would have called this clean; the
      // signature check correctly sees the diverged electrical sub-model.
      // (A fresh project's electrical model is now EMPTY — the sample board is
      // an explicit action — so the divergence is a user panel add.)
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(electricalProjectProvider.notifier).addPanel(name: 'LP-1');
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
      expect(isProjectDirty(c.read), isTrue);
    });

    test('capturing the current encode as the saved baseline clears dirty', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      expect(isProjectDirty(c.read), isTrue);

      // Simulate a successful Save: the live encode becomes the clean baseline.
      c
          .read(lastSavedSignatureProvider.notifier)
          .set(buildDocument(c.read).encode());
      expect(isProjectDirty(c.read), isFalse);

      // A further edit diverges from that baseline again.
      n.placeRunPoint('s1', 0, const Offset(200, 0));
      expect(isProjectDirty(c.read), isTrue);
    });
  });

  group('startAutosave recovery (no phantom, but electrical-only recovered)', () {
    late String path;
    setUp(() {
      path = '${Directory.systemTemp.path}/mechx_recovery.mechx';
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    });
    tearDown(() {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    });

    test('a virgin project writes no recovery (no phantom)', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final timer =
          startAutosave(c, interval: const Duration(milliseconds: 10));
      addTearDown(timer.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(await readRecovery(path: path), isNull);
      expect(c.read(projectDirtyProvider), isFalse);
    });

    test('an electrical-only project (no drawn nodes) IS recovered', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(electricalProjectProvider.notifier).addPanel(name: 'LP-1');
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
      final timer =
          startAutosave(c, interval: const Duration(milliseconds: 10));
      addTearDown(timer.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final recovered = await readRecovery(path: path);
      expect(recovered, isNotNull);
      expect(c.read(projectDirtyProvider), isTrue);
    });

    test(
        'B9: dirty-again-after-Save re-snapshots even a previously-MIRRORED '
        'state (the hoisted mirror is reset by Save)', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final net = c.read(networkControllerProvider.notifier);
      final timer =
          startAutosave(c, interval: const Duration(milliseconds: 10));
      addTearDown(timer.cancel);

      // State A: one run drawn; a tick mirrors it to recovery.
      net.setTool(DrawTool.drawRun);
      net.placeRunPoint('s1', 0, const Offset(0, 0));
      net.placeRunPoint('s1', 0, const Offset(100, 0));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(await readRecovery(path: path), isNotNull);
      expect(c.read(autosaveMirrorProvider), isNotNull);

      // Draw on to state B, then "Save" at B — exactly what saveProject does:
      // baseline = B, recovery cleared, dirty lowered, MIRROR RESET.
      net.placeRunPoint('s1', 0, const Offset(200, 0));
      c
          .read(lastSavedSignatureProvider.notifier)
          .set(buildDocument(c.read).encode());
      c.read(autosaveMirrorProvider.notifier).clear();
      c.read(projectDirtyProvider.notifier).set(false);
      await clearRecovery(path: path);
      // Clean at B: ticks write nothing (the no-phantom invariant holds).
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(await readRecovery(path: path), isNull);

      // Undo back toward the previously-mirrored state A: dirty vs baseline B.
      // Because Save reset the hoisted mirror, the next tick re-writes the
      // snapshot — the old closure-held `lastWritten` still equalled A's
      // encode and would have SKIPPED it (dirty work, zero snapshot).
      c.read(historyProvider.notifier).undo();
      expect(isProjectDirty(c.read), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(await readRecovery(path: path), isNotNull);
    });
  });
}
