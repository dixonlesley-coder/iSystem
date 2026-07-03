/// B4 — the electrical single-line canvas's key handler must never apply a
/// destructive shortcut while the user is typing in a text field: a Backspace
/// or Delete inside an inspector/drawer field belongs to the FIELD, not the
/// drawing. The canvas guards every shortcut behind `isTextEntryFocused()`
/// (shared with the Layout canvas), so these tests drive the REAL handler —
/// through the canvas's own `Focus.onKeyEvent` — in both states: with a text
/// field focused (ignored, drawing untouched) and without (Delete removes the
/// selected panel).
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/canvas/text_entry_guard.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      'Delete typed into a text field never mutates the drawing; the same key '
      'deletes the selected panel once the field is released', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container
        .read(workspaceViewProvider.notifier)
        .set(WorkspaceView.electrical);
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();

    bool hasMdp() => container
        .read(electricalProjectProvider)
        .panels
        .any((p) => p.id == 'mdp');

    // Select the MDP by tapping its summary card (the card registers both tap
    // and double-tap, so advance past the double-tap window for the single
    // tap to resolve).
    await tester.tap(find.text('Main Distribution Panel'));
    await tester.pump(const Duration(milliseconds: 400));

    // Open the Service & Earthing drawer (its numeric fields are real
    // EditableTexts) and focus one — the typing state under test.
    final serviceButton = find.text('Service & Earthing');
    await tester.ensureVisible(serviceButton);
    await tester.pump();
    await tester.tap(serviceButton);
    await tester.pump();
    // Focus the field programmatically — a hit-test tap can miss when the
    // drawer field sits off the test viewport; what matters here is only that
    // a text field HOLDS focus, which is exactly the guard's condition.
    tester.widget<EditableText>(find.byType(EditableText).first)
        .focusNode
        .requestFocus();
    await tester.pump();
    expect(isTextEntryFocused(), isTrue);

    // The canvas's own key handler (the root Focus of ElectricalCanvas).
    final focusWidget = tester
        .widgetList<Focus>(find.descendant(
          of: find.byType(ElectricalCanvas),
          matching: find.byType(Focus),
        ))
        .firstWhere((f) => f.onKeyEvent != null);
    KeyEventResult sendDelete() => focusWidget.onKeyEvent!(
          focusWidget.focusNode!,
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.delete,
            logicalKey: LogicalKeyboardKey.delete,
            timeStamp: Duration.zero,
          ),
        );

    // While typing: the shortcut is IGNORED and the selected panel survives.
    expect(sendDelete(), KeyEventResult.ignored);
    expect(hasMdp(), isTrue);

    // Release the field: the very same key now performs the canvas action on
    // the still-selected panel.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(isTextEntryFocused(), isFalse);
    expect(sendDelete(), KeyEventResult.handled);
    await tester.pump();
    expect(hasMdp(), isFalse);
  });
}
