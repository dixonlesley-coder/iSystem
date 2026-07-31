/// J1 — the electrical single-line canvas is no longer the one workspace that
/// forgets where you were.
///
/// Its viewport, the one-shot initial-fit flag and the canvas selection used to
/// live in widget `State`, which the shell destroys on every workspace / tab
/// hop: coming back re-fitted from scratch and dropped the selection mid-task.
/// They now live in the transient `electricalCanvasViewProvider` (the
/// `schematic_view_store` idiom — session-only, never `.mechx`-persisted), and
/// the canvas re-seeds from it in `initState`.
///
/// Also covers the D2-parity fix: an arrow-nudge BURST is ONE undo step.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_canvas_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart';

import 'test_util.dart';

/// Drive one key straight through the canvas's own `Focus.onKeyEvent` — the
/// same path the app uses (and the path the D2 multi-select test uses).
void _sendKey(WidgetTester tester, LogicalKeyboardKey key,
    {PhysicalKeyboardKey physical = PhysicalKeyboardKey.arrowRight}) {
  final focusWidget = tester
      .widgetList<Focus>(find.descendant(
        of: find.byType(ElectricalCanvas),
        matching: find.byType(Focus),
      ))
      .firstWhere((f) => f.onKeyEvent != null);
  focusWidget.onKeyEvent!(
    focusWidget.focusNode!,
    KeyDownEvent(
      physicalKey: physical,
      logicalKey: key,
      timeStamp: Duration.zero,
    ),
  );
}

ProviderContainer _containerOf(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

void main() {
  testWidgets(
      'a workspace hop and back restores the electrical canvas zoom AND '
      'selection (they live in the transient store, not widget State)',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = _containerOf(tester);
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();
    // The one-shot initial fit lands in a post-frame callback.
    await tester.pump();

    final state =
        tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));

    // Zoom in twice and select a board — an ordinary "I was working here".
    state.zoomIn();
    state.zoomIn();
    await tester.pump();
    state.focusIssue('lp1');
    await tester.pump();

    final zoomed = state.transform;
    expect(state.selectedPanelIds, {'lp1'});
    // The transient store learned both.
    final stored = container.read(electricalCanvasViewProvider);
    expect(stored.transform, zoomed);
    expect(stored.didInitialFit, isTrue);
    expect(stored.selectedPanels, {'lp1'});

    // Hop to another workspace — the canvas widget is destroyed…
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
    await tester.pump();
    expect(find.byType(ElectricalCanvas), findsNothing);

    // …and back. The rebuilt canvas re-seeds from the store: same viewport,
    // same selection, and NO re-fit (the one-shot stays consumed).
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    await tester.pump();
    await tester.pump();

    final restored =
        tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));
    expect(restored.transform, zoomed,
        reason: 'the viewport must survive a workspace hop');
    expect(restored.selectedPanelIds, {'lp1'},
        reason: 'the selection must survive a workspace hop');
  });

  testWidgets(
      'the one-shot initial fit is consumed once per SESSION, so a hop back '
      'does not re-frame the canvas', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = _containerOf(tester);
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();
    await tester.pump();

    expect(container.read(electricalCanvasViewProvider).didInitialFit, isTrue);
    final fitted = container.read(electricalCanvasViewProvider).transform;
    expect(fitted, isNotNull);

    // Pan somewhere deliberately far from the fit framing.
    final state =
        tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));
    state.centreOn(const Offset(4000, 4000));
    await tester.pump();
    final panned = state.transform;
    expect(panned, isNot(fitted));

    // Hop away and back — the canvas must NOT silently re-fit over the user's
    // own framing.
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
    await tester.pump();
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    await tester.pump();
    await tester.pump();

    expect(
      tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas)).transform,
      panned,
    );
  });

  testWidgets(
      'D2 parity — a BURST of arrow nudges is ONE undo step (was one per key)',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = _containerOf(tester);
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();
    await tester.pump();

    List<double?> posOf(String id) {
      final p = container
          .read(electricalProjectProvider)
          .panels
          .firstWhere((p) => p.id == id);
      return [p.x, p.y];
    }

    // The sample boards start auto-laid (null x/y) — the honest "untouched".
    expect(posOf('mdp'), [null, null]);

    final state =
        tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));
    state.focusIssue('mdp');
    await tester.pump();
    expect(state.selectedPanelIds, {'mdp'});

    // FIVE nudges in quick succession (inside the 800 ms burst window).
    for (var i = 0; i < 5; i++) {
      _sendKey(tester, LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    final nudged = posOf('mdp');
    expect(nudged[0], isNotNull);

    // ONE undo puts it back where it started — not five.
    container.read(historyProvider.notifier).undo();
    await tester.pump();
    expect(posOf('mdp'), [null, null],
        reason: 'a whole nudge burst must collapse into a single undo step');
  });

  testWidgets(
      'a nudge burst CLOSES on the idle window, so a later nudge is its own '
      'undo step', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = _containerOf(tester);
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();
    await tester.pump();

    double? xOf(String id) => container
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == id)
        .x;

    final state =
        tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));
    state.focusIssue('mdp');
    await tester.pump();

    _sendKey(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final afterFirst = xOf('mdp');
    expect(afterFirst, isNotNull);

    // Let the burst lapse, then nudge again — a SECOND undo step.
    await tester.pump(const Duration(milliseconds: 900));
    _sendKey(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(xOf('mdp'), isNot(afterFirst));

    // The first undo rewinds only the SECOND burst.
    container.read(historyProvider.notifier).undo();
    await tester.pump();
    expect(xOf('mdp'), afterFirst);
    // The second undo rewinds the first.
    container.read(historyProvider.notifier).undo();
    await tester.pump();
    expect(xOf('mdp'), isNull);
  });
}
