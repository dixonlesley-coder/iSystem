import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/recovery.dart' show appSupportDirOverride;
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/shell/project_io.dart';
import 'package:mechx/ui/strings/app_strings.dart';

/// F9 (WORKFLOW-FRICTION) — saving as `Gedung-BRI.mechx` left every title
/// block, report head and window title reading "Untitled project": Save seeded
/// the dialog FROM the name but never adopted the chosen filename back.
///
/// F10 — a template that seeds 12 floors then forces an import of 3 plans left
/// floors 4-12 planless with no word said, and never pointed at the Building
/// page where assign / duplicate live.
void main() {
  setUpAll(() {
    appSupportDirOverride =
        Directory.systemTemp.createTempSync('mechx_io_naming_test').path;
  });

  test('the file stem is the project name (F9, pure)', () {
    expect(projectNameFromPath(r'C:\Users\eng\Gedung-BRI.mechx'), 'Gedung-BRI');
    expect(projectNameFromPath('/home/eng/Gedung BRI.MECHX'), 'Gedung BRI');
    // No extension, mixed separators, and surrounding space all behave.
    expect(projectNameFromPath('/home/eng/tower'), 'tower');
    expect(projectNameFromPath('/home/eng/  spaced  .mechx'), 'spaced');
  });

  testWidgets('the first save adopts the stem; a named project keeps its name',
      (tester) async {
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      child: Consumer(builder: (context, r, _) {
        ref = r;
        return const SizedBox();
      }),
    ));
    final read = ref.read;

    // A virgin project carries the default name — the ONLY case that adopts.
    expect(read(projectControllerProvider).name, kDefaultProjectName);
    adoptFileStemAsProjectName(read, '/tmp/Gedung-BRI.mechx');
    expect(read(projectControllerProvider).name, 'Gedung-BRI');
    // It is an ordinary undo step (part of the save the engineer performed).
    expect(read(historyProvider.notifier).canUndo, isTrue);

    // A second save to another file does NOT rename a project the engineer
    // (or this adoption) has already named.
    adoptFileStemAsProjectName(read, '/tmp/copy-for-client.mechx');
    expect(read(projectControllerProvider).name, 'Gedung-BRI');
  });

  testWidgets('an empty stem is never adopted', (tester) async {
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      child: Consumer(builder: (context, r, _) {
        ref = r;
        return const SizedBox();
      }),
    ));
    adoptFileStemAsProjectName(ref.read, '/tmp/.mechx');
    expect(ref.read(projectControllerProvider).name, kDefaultProjectName);
    expect(ref.read(historyProvider.notifier).canUndo, isFalse);
  });

  test('the template shortfall names the gap and points at Building (F10)', () {
    const en = MechXStringsData(AppLocale.en);
    // 12 floors, 3 plans, forced by the template flow ⇒ the shortfall message.
    final short = importStatusMessage(en,
        imported: 3,
        totalSheets: 3,
        floors: 12,
        fromTemplate: true,
        added: false);
    expect(short, contains('12 floors'));
    expect(short, contains('3 plans'));
    expect(short, contains('Building page'));

    // Enough plans ⇒ the plain confirmation, unchanged.
    expect(
        importStatusMessage(en,
            imported: 3,
            totalSheets: 3,
            floors: 3,
            fromTemplate: true,
            added: false),
        '3 sheets imported');
    // A NORMAL import into a tall building is a deliberate one-at-a-time
    // workflow — it keeps its plain count and is never nagged.
    expect(
        importStatusMessage(en,
            imported: 1,
            totalSheets: 1,
            floors: 12,
            fromTemplate: false,
            added: true),
        '1 sheet added');
    // And it localizes (the ID table carries the same placeholders).
    const id = MechXStringsData(AppLocale.id);
    final shortId = importStatusMessage(id,
        imported: 3,
        totalSheets: 3,
        floors: 12,
        fromTemplate: true,
        added: false);
    expect(shortId, contains('12 lantai'));
    expect(shortId, contains('Bangunan'));
  });
}
