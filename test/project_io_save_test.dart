import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/ui/shell/project_io.dart';

/// Finding B1 (atomic saves + the save in-flight lock) and B9 (Save resets the
/// hoisted autosave mirror). Drives the REAL [saveProject] with a remembered
/// project path (so no OS dialog is involved) via `tester.runAsync` — the save
/// touches the real filesystem and hops through `Isolate.run`.
void main() {
  /// Pumps a minimal ProviderScope and hands back a live [WidgetRef].
  Future<WidgetRef> pumpRef(WidgetTester tester) async {
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (context, r, _) {
            ref = r;
            return const SizedBox();
          },
        ),
      ),
    );
    return ref;
  }

  String tempTarget(WidgetTester tester) {
    final dir = Directory.systemTemp.createTempSync('mechx_save_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    return '${dir.path}/project.mechx';
  }

  testWidgets(
      'Save writes atomically in place: the displaced previous file survives '
      'as .bak, no .tmp is left, and the baseline/mirror/dirty state resets',
      (tester) async {
    final ref = await pumpRef(tester);
    final path = tempTarget(tester);

    // A remembered home file ⇒ Ctrl+S saves in place, no dialog.
    ref.read(currentProjectPathProvider.notifier).set(path);
    // Seed a stale mirror to prove Save resets it (B9): dirty work after this
    // save must get a FRESH recovery snapshot on the next autosave tick.
    ref.read(autosaveMirrorProvider.notifier).set('stale-mirror');
    ref.read(projectDirtyProvider.notifier).set(true);

    await tester.runAsync(() => saveProject(ref));
    expect(File(path).existsSync(), isTrue);
    // First save displaced nothing — no .bak yet.
    expect(File('$path.bak').existsSync(), isFalse);
    final firstContent = File(path).readAsStringSync();
    // The write is a decodable document.
    expect(ProjectDocument.decode(firstContent), isNotNull);

    // Change the work, save again: the previous save is DISPLACED to .bak
    // (never truncate-overwritten), and the temp file was renamed into place.
    final net = ref.read(networkControllerProvider.notifier);
    net.setTool(DrawTool.drawRun);
    net.placeRunPoint('s1', 0, const Offset(0, 0));
    net.placeRunPoint('s1', 0, const Offset(100, 0));
    await tester.runAsync(() => saveProject(ref));

    expect(File(path).readAsStringSync(), isNot(firstContent));
    expect(File('$path.bak').existsSync(), isTrue);
    expect(File('$path.bak').readAsStringSync(), firstContent);
    expect(File('$path.tmp').existsSync(), isFalse);

    // Save recorded the clean baseline, cleared the dirty flag, and reset the
    // autosave mirror (so the next divergence re-snapshots).
    expect(ref.read(lastSavedSignatureProvider), isNotNull);
    expect(ref.read(projectDirtyProvider), isFalse);
    expect(ref.read(autosaveMirrorProvider), isNull);
    expect(isProjectDirty(ref.read), isFalse);
  });

  testWidgets('a second Ctrl+S during a running save is a no-op (in-flight lock)',
      (tester) async {
    final ref = await pumpRef(tester);
    final path = tempTarget(tester);
    ref.read(currentProjectPathProvider.notifier).set(path);

    await tester.runAsync(() async {
      // The first call takes the lock synchronously (before its first await);
      // the second enters while it holds it and must return without writing.
      final first = saveProject(ref);
      final second = saveProject(ref);
      await Future.wait([first, second]);
    });

    expect(File(path).existsSync(), isTrue);
    // Had the second call also run, it would have displaced the first write
    // to `.bak`; the lock makes it a no-op instead.
    expect(File('$path.bak').existsSync(), isFalse);
  });
}
