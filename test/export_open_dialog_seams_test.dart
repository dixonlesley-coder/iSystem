/// WORKFLOW-FRICTION I1 + I5 — the two file-dialog seams and the human import
/// failure message.
///
/// I1: 14 raw `FilePicker.saveFile` sites bypassed the remember-last-folder
/// wrapper, so a revision re-navigated the OS picker for every artifact. The
/// save side now routes through the ONE `pickExportSave` seam and the open /
/// import side through its new sibling `pickOpenPaths`. The OS dialogs
/// themselves can't run headless, so these tests pin the parts that CAN be
/// driven: that no raw picker call survives in the export surfaces (a source
/// assertion — the seam is only uniform if nothing bypasses it), and the
/// directory-memory logic behind `pickOpenPaths`.
///
/// I5: the pure import-failure mapping — a human message per file TYPE with the
/// raw exception text preserved in a parenthetical, and the old generic wording
/// kept for an error whose cause the app cannot know.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/app_settings.dart';
import 'package:mechx/store/app_state.dart' show AppLocale;
import 'package:mechx/ui/shell/project_io.dart';
import 'package:mechx/ui/strings/app_strings.dart';

void main() {
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

  group('I1 — every save dialog routes through the one pickExportSave seam', () {
    // The seam is only uniform if nothing bypasses it: a source assertion is
    // the honest check here, since the OS picker cannot be driven headless.
    const surfaces = [
      'lib/ui/electrical/electrical_export.dart',
      'lib/ui/schematic/schematic_export.dart',
      'lib/ui/commercial/commercial_hub.dart',
      'lib/ui/shell/project_io.dart',
    ];
    for (final path in surfaces) {
      test('$path has no raw FilePicker.saveFile call', () {
        final src = File(path).readAsStringSync();
        expect(src.contains('FilePicker.saveFile'), isFalse,
            reason: '$path must save through pickExportSave (I1)');
      });
    }

    test('the open/import surfaces have no raw FilePicker.pickFiles call '
        'outside the pickOpenPaths seam itself', () {
      final src = File('lib/ui/shell/project_io.dart').readAsStringSync();
      // Exactly ONE occurrence — the one inside `pickOpenPaths`.
      expect('FilePicker.pickFiles'.allMatches(src).length, 1);
    });
  });

  group('I1 — the open/import dialogs remember where you were', () {
    testWidgets('with no memory at all the dialog starts at the OS default',
        (tester) async {
      final ref = await harness(tester);
      expect(openDialogInitialDirectory(ref), isNull);
    });

    testWidgets(
        'it falls back to the folder of the last project opened/saved on this '
        'machine (cross-session continuity without a new settings field)',
        (tester) async {
      final ref = await harness(tester);
      final sep = Platform.pathSeparator;
      ref
          .read(appSettingsProvider.notifier)
          .recordRecent('${sep}proyek${sep}BRI${sep}gedung.mechx', 'gedung');
      expect(openDialogInitialDirectory(ref), '${sep}proyek${sep}BRI');
    });

    testWidgets(
        'this session\'s last picked folder WINS over the persisted fallback',
        (tester) async {
      final ref = await harness(tester);
      final sep = Platform.pathSeparator;
      ref
          .read(appSettingsProvider.notifier)
          .recordRecent('${sep}proyek${sep}BRI${sep}gedung.mechx', 'gedung');
      ref
          .read(lastOpenDirProvider.notifier)
          .rememberFile('${sep}denah${sep}lantai-2.dxf');
      expect(openDialogInitialDirectory(ref), '${sep}denah');
    });

    testWidgets('a bare filename (no directory part) keeps the prior memory',
        (tester) async {
      final ref = await harness(tester);
      final ctrl = ref.read(lastOpenDirProvider.notifier);
      ctrl.rememberFile('/denah/lantai-1.dxf');
      ctrl.rememberFile('lantai-2.dxf');
      expect(ref.read(lastOpenDirProvider), '/denah');
    });

    test('both path separators are tolerated (a Windows FilePicker path may '
        'use "/")', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(lastOpenDirProvider.notifier)
          .rememberFile(r'C:\Users\andi\Denah\lantai-3.dwg');
      expect(container.read(lastOpenDirProvider), r'C:\Users\andi\Denah');
      container
          .read(lastOpenDirProvider.notifier)
          .rememberFile('C:/Users/andi/Proyek/plan.pdf');
      expect(container.read(lastOpenDirProvider), 'C:/Users/andi/Proyek');
    });
  });

  group('I5 — an import failure speaks human, keeping the raw detail', () {
    const en = MechXStringsData(AppLocale.en);
    const id = MechXStringsData(AppLocale.id);

    test('a DXF parse failure names the DWG-mistaken-for-DXF cause + action',
        () {
      final msg = importFailureMessage(en,
          what: 'DXF',
          error: const FormatException('Unexpected group code at line 3'));
      expect(msg, contains("isn't a readable DXF"));
      expect(msg, contains('is it a DWG?'));
      // The raw text is preserved, not swallowed.
      expect(msg, contains('Unexpected group code at line 3'));
      expect(msg, isNot(contains('FormatException:')));
    });

    test('a DWG failure points at the converter / a CAD-side DXF export', () {
      final msg = importFailureMessage(en,
          what: 'DWG',
          error: StateError('ODA File Converter not found'));
      expect(msg, contains('ODA File Converter'));
      expect(msg, contains('could not be converted'));
      expect(msg, contains('ODA File Converter not found'));
    });

    test('a PDF failure names the damaged / locked / not-a-drawing causes', () {
      final msg = importFailureMessage(en,
          what: 'PDF', error: StateError('PDF "x.pdf" has no pages.'));
      expect(msg, contains('could not be read'));
      expect(msg, contains('password-protected'));
      expect(msg, contains('has no pages'));
    });

    test('an error the app cannot diagnose keeps the old generic wording (it '
        'never asserts a cause it does not know)', () {
      final msg = importFailureMessage(en,
          what: 'DXF',
          error: const FileSystemException('No such file', '/gone.dxf'));
      expect(msg, startsWith('Could not import DXF: '));
      expect(msg, contains('No such file'));
      expect(msg, isNot(contains('is it a DWG?')));
    });

    test('every mapped message is localized (ID is not the EN literal)', () {
      for (final what in ['DXF', 'DWG', 'PDF']) {
        final e = importFailureMessage(en,
            what: what, error: const FormatException('boom'));
        final i = importFailureMessage(id,
            what: what, error: const FormatException('boom'));
        expect(i, isNot(equals(e)), reason: '$what must translate');
        // The raw detail survives translation.
        expect(i, contains('boom'));
      }
      expect(
          importFailureMessage(id,
              what: 'DXF', error: const FormatException('boom')),
          contains('DWG'));
    });
  });
}
