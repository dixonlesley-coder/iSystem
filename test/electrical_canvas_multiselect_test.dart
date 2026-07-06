/// D2 — the electrical single-line canvas gained multi-select parity with the
/// mechanical Layout canvas: an empty-canvas left-drag draws a marquee that
/// rubber-band-selects panels, the arrow keys nudge the whole selection by one
/// grid step, and a single Ctrl+Z restores every moved panel together. This
/// test marquees both sample panels, nudges them, and asserts ONE undo restores
/// both.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      'a marquee selects both panels, an arrow key nudges them together, and '
      'one undo restores both', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();

    final state = tester.state<ElectricalCanvasState>(
      find.byType(ElectricalCanvas),
    );

    // The two sample boards start auto-laid (null x/y).
    List<double?> xsFor(String id) {
      final p = container
          .read(electricalProjectProvider)
          .panels
          .firstWhere((p) => p.id == id);
      return [p.x, p.y];
    }

    expect(xsFor('mdp'), [null, null]);
    expect(xsFor('lp1'), [null, null]);

    // Marquee across the whole canvas — start in the (blank) top-left corner so
    // the drag begins a marquee rather than grabbing a panel, then sweep to the
    // opposite corner so the box crosses every panel.
    final canvasRect = tester.getRect(find.byType(ElectricalCanvas));
    final gesture = await tester.startGesture(canvasRect.topLeft + const Offset(4, 4));
    await tester.pump();
    await gesture.moveTo(canvasRect.center);
    await tester.pump();
    await gesture.moveTo(canvasRect.bottomRight - const Offset(4, 4));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // Both boards are now in the multi-selection.
    expect(state.selectedPanelIds, containsAll(<String>{'mdp', 'lp1'}));

    // Nudge the whole selection one grid step right via the canvas's own key
    // handler (the same path the app drives).
    final focusWidget = tester
        .widgetList<Focus>(find.descendant(
          of: find.byType(ElectricalCanvas),
          matching: find.byType(Focus),
        ))
        .firstWhere((f) => f.onKeyEvent != null);
    focusWidget.onKeyEvent!(
      focusWidget.focusNode!,
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowRight,
        logicalKey: LogicalKeyboardKey.arrowRight,
        timeStamp: Duration.zero,
      ),
    );
    await tester.pump();

    // Both panels now carry a concrete position (the resolved spot + one step).
    final mdpNudged = xsFor('mdp');
    final lp1Nudged = xsFor('lp1');
    expect(mdpNudged[0], isNotNull);
    expect(lp1Nudged[0], isNotNull);

    // ONE undo restores BOTH boards to their original auto-laid state.
    container.read(historyProvider.notifier).undo();
    await tester.pump();
    expect(xsFor('mdp'), [null, null]);
    expect(xsFor('lp1'), [null, null]);
  });
}
