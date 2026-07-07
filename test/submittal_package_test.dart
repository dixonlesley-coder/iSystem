/// J2 — the one-folder submittal package must bundle EVERY sheet's annotated
/// plan (PDF + DXF), not just whichever sheet happened to be active, with the
/// Daftar Gambar (N21) front-matter cover listing one row per bundled sheet.
///
/// Drives [writeSubmittalPackageToDir] directly (the file-writing pass factored
/// out of the private `_writeSubmittalPackage`) so the test can supply an
/// explicit temp directory instead of the headless-incompatible
/// `FilePicker.getDirectoryPath` OS dialog.
///
/// The write pass does REAL `dart:io` file I/O (`File.writeAsBytes`/
/// `writeAsString`), so it must run inside [WidgetTester.runAsync] — plain
/// `testWidgets` code runs in a fake-async zone that never lets genuine OS I/O
/// callbacks complete, which would otherwise hang the test forever.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';

void main() {
  /// Pump a minimal ProviderScope and capture a live [WidgetRef] — the same
  /// harness `export_wiring_test.dart` / `project_panel_test.dart` use, since
  /// the export helpers take a WidgetRef.
  Future<WidgetRef> harness(WidgetTester tester) async {
    late WidgetRef capturedRef;
    await tester.pumpWidget(
      ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Consumer(builder: (context, ref, _) {
            capturedRef = ref;
            return const SizedBox.shrink();
          }),
        ),
      ),
    );
    await tester.pump();
    return capturedRef;
  }

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mechx_submittal_'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  testWidgets(
      'bundles EVERY sheet\'s plan PDF + DXF (3-sheet fixture), not just the '
      'active one', (tester) async {
    final ref = await harness(tester);
    ref.read(projectControllerProvider.notifier).setName('project');
    // A 3-floor, 3-sheet placeholder fixture (no pdfPath/dxfPath ⇒ no
    // underlay to render — an empty network is enough to exercise the loop).
    ref.read(sheetsControllerProvider.notifier).loadSheets(const [
      Sheet(id: 's1', name: 'Ground Floor', sizePx: Size(1000, 800)),
      Sheet(id: 's2', name: 'Level 1', sizePx: Size(1000, 800)),
      Sheet(id: 's3', name: 'Roof Plan', sizePx: Size(1000, 800)),
    ]);

    final wrote =
        await tester.runAsync(() => writeSubmittalPackageToDir(ref, dir.path));
    expect(wrote, isTrue);

    final files = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList();

    final planPdfs = files.where((f) => RegExp(r'^project-plan-\d+-.*\.pdf$')
        .hasMatch(f));
    final planDxfs = files.where((f) => RegExp(r'^project-plan-\d+-.*\.dxf$')
        .hasMatch(f));
    // 3 sheets ⇒ 3 plan PDFs + 3 plan DXFs, one pair per rail position.
    expect(planPdfs, hasLength(3));
    expect(planDxfs, hasLength(3));
    for (final name in ['Ground Floor', 'Level 1', 'Roof Plan']) {
      expect(files.any((f) => f.contains(name) && f.endsWith('.pdf')), isTrue,
          reason: 'expected a plan PDF naming "$name" among $files');
    }

    // The Daftar Gambar cover sheet is written too.
    expect(files.contains('project-00-cover-sheets.pdf'), isTrue);
  });

  testWidgets('an empty sheet rail writes no plan PDF/DXF (no-op loop)',
      (tester) async {
    final ref = await harness(tester);
    // Default state: no sheets loaded.
    final wrote =
        await tester.runAsync(() => writeSubmittalPackageToDir(ref, dir.path));
    expect(wrote, isTrue);

    final files = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList();
    expect(files.where((f) => f.contains('plan-')), isEmpty);
  });

  testWidgets('the busy pill is set during the per-sheet loop and cleared '
      'after', (tester) async {
    final ref = await harness(tester);
    ref.read(sheetsControllerProvider.notifier).loadSheets(const [
      Sheet(id: 's1', name: 'Ground Floor', sizePx: Size(1000, 800)),
      Sheet(id: 's2', name: 'Level 1', sizePx: Size(1000, 800)),
    ]);
    expect(ref.read(busyProvider), isNull);

    await tester.runAsync(() => writeSubmittalPackageToDir(ref, dir.path));

    // Cleared once the write completes (never left stuck).
    expect(ref.read(busyProvider), isNull);
  });
}
