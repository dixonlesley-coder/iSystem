/// G3 — the commit-on-blur / -submit mode of [MechXTextField] and the electrical
/// inputs built on it. In the default (live) mode every keystroke propagates;
/// in commit mode the edit is deferred to blur / Enter (Esc cancels), so a
/// rename is ONE undo step and a partially-typed number never commits an
/// intermediate value.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/electrical/electrical_controls.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_text_field.dart';

import 'test_util.dart';

/// The minimal ancestry a bespoke MechX control needs (mirrors
/// stepped_value_field_test's `_host`).
Widget _host(Widget child) => MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 260, child: child),
          ),
        ),
      ),
    );

void main() {
  group('MechXTextField default (live) mode is unchanged', () {
    testWidgets('onChanged still fires per edit; no onCommitted needed',
        (tester) async {
      setDesktopSurface(tester);
      final changes = <String>[];
      await tester.pumpWidget(_host(MechXTextField(
        value: 'a',
        onChanged: changes.add,
      )));
      await tester.enterText(find.byType(EditableText), 'ab');
      await tester.pump();
      // Live mode propagates immediately (no blur needed).
      expect(changes, ['ab']);
    });
  });

  group('MechXTextField live-mode onSubmitted (I3 — Enter fires an action)', () {
    testWidgets('Enter fires onSubmitted while onChanged stays live; blur does '
        'NOT fire it', (tester) async {
      setDesktopSurface(tester);
      final changes = <String>[];
      var submits = 0;
      await tester.pumpWidget(_host(MechXTextField(
        value: '',
        onChanged: changes.add,
        onSubmitted: () => submits++,
      )));

      // onChanged still propagates per keystroke (live mode is preserved).
      await tester.enterText(find.byType(EditableText), '3000');
      await tester.pump();
      expect(changes.last, '3000');
      expect(submits, 0);

      // Enter fires the action exactly once.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(submits, 1);

      // A blur (e.g. clicking Cancel) must NOT fire the action — only Enter does.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(submits, 1);
    });
  });

  group('MechXTextField commit-on-blur mode', () {
    testWidgets('coalesces several edits into ONE commit on blur (a rename is '
        'not one undo step per character)', (tester) async {
      setDesktopSurface(tester);
      var value = 'orig';
      final commits = <String>[];
      await tester.pumpWidget(_host(StatefulBuilder(
        builder: (context, setState) => MechXTextField(
          value: value,
          onCommitted: (v) {
            commits.add(v);
            setState(() => value = v);
          },
        ),
      )));

      // Three successive edits — none commit while the field holds focus.
      await tester.enterText(find.byType(EditableText), 'A');
      await tester.enterText(find.byType(EditableText), 'AB');
      await tester.enterText(find.byType(EditableText), 'ABC');
      await tester.pump();
      expect(commits, isEmpty);

      // Blur → exactly ONE commit, carrying the final text.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(commits, ['ABC']);
      // The field now displays the committed value.
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'ABC',
      );
    });

    testWidgets('Enter (submit) commits once; a subsequent blur does not '
        're-commit', (tester) async {
      setDesktopSurface(tester);
      var value = 'orig';
      final commits = <String>[];
      await tester.pumpWidget(_host(StatefulBuilder(
        builder: (context, setState) => MechXTextField(
          value: value,
          onCommitted: (v) {
            commits.add(v);
            setState(() => value = v);
          },
        ),
      )));

      await tester.enterText(find.byType(EditableText), 'done');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(commits, ['done']);

      // The Enter unfocused the field; the focus-loss must not commit again.
      await tester.pump();
      expect(commits, ['done']);
    });

    testWidgets('Esc cancels the pending edit and re-displays the value',
        (tester) async {
      setDesktopSurface(tester);
      const value = 'keep';
      final commits = <String>[];
      await tester.pumpWidget(_host(MechXTextField(
        value: value,
        onCommitted: commits.add,
      )));

      await tester.enterText(find.byType(EditableText), 'scrap');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(commits, isEmpty); // nothing committed
      // The canonical value is restored.
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'keep',
      );
    });

    testWidgets('an unedited blur is a no-op (no spurious commit)',
        (tester) async {
      setDesktopSurface(tester);
      final commits = <String>[];
      await tester.pumpWidget(_host(MechXTextField(
        value: 'x',
        onCommitted: commits.add,
      )));
      // Focus without typing, then blur.
      tester.widget<EditableText>(find.byType(EditableText)).focusNode
          .requestFocus();
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(commits, isEmpty);
    });
  });

  group('ElectricalNumInput commit-on-blur (no transient parse mis-size)', () {
    testWidgets('typing "0.85" never commits an intermediate "0"; commits 0.85 '
        'once on blur', (tester) async {
      setDesktopSurface(tester);
      var value = 20.0;
      final commits = <double>[];
      await tester.pumpWidget(_host(StatefulBuilder(
        builder: (context, setState) => ElectricalNumInput(
          value: value,
          onChanged: (v) {
            commits.add(v);
            setState(() => value = v);
          },
        ),
      )));

      // Type the value one prefix at a time — the OLD per-keystroke path would
      // have committed 0 (re-sizing the whole system) on the first char.
      await tester.enterText(find.byType(EditableText), '0');
      await tester.enterText(find.byType(EditableText), '0.8');
      await tester.enterText(find.byType(EditableText), '0.85');
      await tester.pump();
      expect(commits, isEmpty);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(commits, [0.85]);
    });

    testWidgets('an unchanged numeric value does not commit on blur',
        (tester) async {
      setDesktopSurface(tester);
      final commits = <double>[];
      await tester.pumpWidget(_host(ElectricalNumInput(
        value: 12,
        onChanged: commits.add,
      )));
      tester.widget<EditableText>(find.byType(EditableText)).focusNode
          .requestFocus();
      await tester.pump();
      // Re-type the same value, then blur — no-op guard suppresses the commit.
      await tester.enterText(find.byType(EditableText), '12');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(commits, isEmpty);
    });
  });
}
