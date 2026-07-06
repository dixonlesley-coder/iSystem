import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/app_settings.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_assets.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/data/recovery.dart' show appSupportDirOverride;
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/shell/project_io.dart';

/// Finding B1 (atomic saves + the save in-flight lock) and B9 (Save resets the
/// hoisted autosave mirror). Drives the REAL [saveProject] with a remembered
/// project path (so no OS dialog is involved) via `tester.runAsync` — the save
/// touches the real filesystem and hops through `Isolate.run`.
void main() {
  // These tests drive the real recovery writes (Save/New clear per-project
  // slots under the app-support dir). Isolate this file's app-support dir to a
  // unique temp path so the concurrently-run suite's other isolates don't race
  // on the shared tree (this file pumps a bare ProviderScope, not the full app,
  // so it doesn't get the setDesktopSurface isolation hook).
  setUpAll(() {
    appSupportDirOverride =
        Directory.systemTemp.createTempSync('mechx_project_io_test').path;
  });

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

  testWidgets('Save records the file in the machine-local MRU / last-open list',
      (tester) async {
    final ref = await pumpRef(tester);
    final path = tempTarget(tester);
    ref.read(currentProjectPathProvider.notifier).set(path);

    await tester.runAsync(() => saveProject(ref));

    final mru = ref.read(appSettingsProvider).mru;
    expect(mru, isNotEmpty);
    expect(mru.first.path, path);
    expect(ref.read(appSettingsProvider).lastOpenPath, path);
  });

  // The virgin RESET itself (what New applies): a drawn network + electrical is
  // wiped by applyDocument(virgin). A pure container test — no widget/dialog
  // machinery — so it's fast and can't race the loaded suite.
  test('A3: applyDocument(virgin) resets a drawn network to empty', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final net = c.read(networkControllerProvider.notifier);
    net.setTool(DrawTool.drawRun);
    net.placeRunPoint('s1', 0, const Offset(0, 0));
    net.placeRunPoint('s1', 0, const Offset(100, 0));
    expect(c.read(networkControllerProvider).network.nodes, isNotEmpty);

    applyDocument(
      c.read,
      const ProjectDocument(
        projectName: 'Untitled project',
        floors: [
          Floor('Ground', Length(4.0)),
          Floor('Level 1', Length(3.5)),
          Floor('Level 2', Length(3.5)),
        ],
        calibrations: {},
        sheets: [],
        network: Network(),
      ),
    );
    expect(c.read(networkControllerProvider).network.nodes, isEmpty);
    expect(c.read(projectControllerProvider).floors.length, 3);
  });

  testWidgets(
      'A3: New project forgets the file identity, resets the baseline, and '
      'preserves the app-level language (no spurious dirty)',
      timeout: const Timeout(Duration(seconds: 30)), (tester) async {
    late BuildContext ctx;
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      child: Consumer(builder: (c, r, _) {
        ctx = c;
        ref = r;
        return const SizedBox();
      }),
    ));

    // The engineer chose Bahasa at the app level; New must keep it. A named,
    // CLEAN project (no drawn work) so the dirty-guard trivially passes with no
    // discard dialog — the guard-when-dirty path is covered by the discard/quit
    // guard tests; here we verify New's identity/baseline/language handling.
    ref.read(localeProvider.notifier).set(AppLocale.id);
    ref.read(currentProjectPathProvider.notifier).set('/old.mechx');
    expect(isProjectDirty(ref.read), isFalse);

    // newProject touches the real filesystem (clearRecoverySlots) — drive it in
    // the real-async zone so those I/O futures actually complete.
    await tester.runAsync(() => newProject(ctx, ref));
    await tester.pump();

    expect(ref.read(networkControllerProvider).network.nodes, isEmpty); // virgin
    expect(ref.read(currentProjectPathProvider), isNull); // file forgotten
    expect(ref.read(lastSavedSignatureProvider), isNull); // baseline reset
    expect(ref.read(projectControllerProvider).floors.length, 3); // defaults
    expect(ref.read(localeProvider), AppLocale.id); // language preserved
    // A brand-new project is NOT dirty (matches virgin at the current language).
    expect(isProjectDirty(ref.read), isFalse);

    // Unmount so the transient status-message timer is disposed in-body.
    await tester.pumpWidget(const SizedBox());
  });

  // K2: opening a portable .mechx with an embedded plan must decode + rehydrate
  // off the UI thread (the exact freeze class Save's gatherSheetAssetsAsync
  // already fixed) — driven through the REAL openProjectPath, no OS dialog.
  testWidgets(
      'K2: opening a portable project with an embedded plan repoints the '
      'sheet to the extracted local file and clears the busy pill',
      (tester) async {
    final ref = await pumpRef(tester);
    final tmp = Directory.systemTemp.createTempSync('mechx_open_test');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // A source plan to embed, then delete — simulating opening the portable
    // file on a machine that never had the original PDF.
    final pdf = File('${tmp.path}/plan.pdf')..writeAsBytesSync([7, 7, 7, 7]);
    final doc = ProjectDocument(
      projectName: 'Portable',
      floors: const [Floor('Ground', Length(3.0))],
      calibrations: const {},
      sheets: [Sheet(id: 'a', name: 'p', pdfPath: pdf.path)],
      network: const Network(),
    );
    final portable =
        doc.withSheets(doc.sheets, assets: gatherSheetAssets(doc.sheets));
    final projectFile = File('${tmp.path}/project.mechx')
      ..writeAsStringSync(portable.encode());
    pdf.deleteSync();

    await tester.runAsync(
        () => openProjectPath(ref.context, ref, projectFile.path));
    await tester.pump();

    expect(ref.read(loadErrorProvider), isNull);
    expect(ref.read(currentProjectPathProvider), projectFile.path);
    final sheets = ref.read(sheetsControllerProvider).sheets;
    expect(sheets, hasLength(1));
    // Repointed to the extracted local file — the original path is gone.
    expect(sheets.single.pdfPath, isNot(pdf.path));
    final extracted = File(sheets.single.pdfPath!);
    expect(extracted.existsSync(), isTrue);
    expect(extracted.readAsBytesSync(), [7, 7, 7, 7]); // original bytes back
    // The busy pill (set for the duration of the async decode+rehydrate) is
    // cleared once Open completes.
    expect(ref.read(busyProvider), isNull);
  });
}
