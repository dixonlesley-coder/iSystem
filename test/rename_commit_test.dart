/// D1 — one gesture, one undo step: typing a PROJECT or FLOOR name used to push
/// one undo entry PER KEYSTROKE (`_snapshot()` on every `onChanged`), so
/// "Gedung BRI Cabang Jakarta" was 25 entries, evicting real drawing edits from
/// the 200-entry stacks. Both fields now commit on blur / Enter — the mechanism
/// `MechXTextField.onCommitted` already provided and other call sites used.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx/ui/widgets/mechx_text_field.dart';

import 'test_util.dart';

/// How many undo snapshots the project controller is holding.
int _undoDepth(ProviderContainer c) {
  var depth = 0;
  final ctrl = c.read(projectControllerProvider.notifier);
  while (ctrl.canUndo) {
    ctrl.undo();
    depth++;
  }
  return depth;
}

Future<ProviderContainer> _open(WidgetTester tester, String destination) async {
  setDesktopSurface(tester);
  await tester.pumpWidget(const ProviderScope(child: MechXApp()));
  await tester.pump();
  final c = ProviderScope.containerOf(
    tester.element(find.byType(MechXApp)),
    listen: false,
  );
  await tester.tap(find.descendant(
      of: find.byType(NavRail), matching: find.text(destination)));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('renaming the PROJECT is one undo step, committed on Enter',
      (tester) async {
    final c = await _open(tester, 'Projects');

    final field = find.byType(MechXTextField).first;
    final editor = find.descendant(of: field, matching: find.byType(EditableText));
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(editor, 'Gedung BRI');
    await tester.pump();

    // Nothing committed yet — the store still holds the old name and no undo
    // entry was pushed for the six intermediate keystrokes.
    expect(c.read(projectControllerProvider).name, 'Untitled project');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(c.read(projectControllerProvider).name, 'Gedung BRI');
    expect(_undoDepth(c), 1);
  });

  testWidgets('renaming a LEVEL is one undo step, committed on Enter',
      (tester) async {
    final c = await _open(tester, 'Building');

    // Cards render top-first: the first name field is the top level.
    final field = find.byType(MechXTextField).first;
    final editor = find.descendant(of: field, matching: find.byType(EditableText));
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(editor, 'Lantai Atap');
    await tester.pump();

    expect(c.read(projectControllerProvider).floors.last.name, 'Level 2');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(c.read(projectControllerProvider).floors.last.name, 'Lantai Atap');
    expect(_undoDepth(c), 1);
  });
}
