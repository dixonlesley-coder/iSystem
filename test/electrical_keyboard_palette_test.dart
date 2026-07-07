/// L1 — the electrical Loads palette had no keyboard path: Tab reached a card
/// (the shared MechXFocusRing lit up) but Enter/Space did nothing, since
/// adding a way was wired ONLY through the canvas drag-and-drop target. This
/// mirrors the mechanical SegmentPalette's proven `dropAtCentre` keyboard
/// pattern (see `keyboard_palette_activation_test.dart`) for the electrical
/// palette: a focused card + Enter adds the load to the selected panel (or
/// the project's first panel when nothing is selected).
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/ui/electrical/electrical_palette.dart';
import 'package:mechx/ui/widgets/palette_card.dart';

import 'test_util.dart';

/// Focuses the [Focus] node hosting the palette card whose label is [label],
/// then presses Enter — exercising the card's keyboard-activation path.
Future<void> _focusAndActivate(WidgetTester tester, String label) async {
  final card = find.ancestor(
    of: find.text(label),
    matching: find.byType(PaletteCard<PaletteLoad>),
  );
  expect(card, findsOneWidget);
  final focusNode = Focus.of(
    tester.element(find.descendant(of: card, matching: find.byType(Text)).first),
  );
  focusNode.requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
}

void main() {
  testWidgets(
      'Enter on a focused Loads-palette card adds a way to the first panel '
      'when none is selected', (tester) async {
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

    int circuitsOn(String panelId) => container
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == panelId)
        .circuits
        .length;
    final before = circuitsOn('mdp');
    expect(
      container.read(electricalInspectorTargetProvider),
      isNull,
      reason: 'nothing selected yet',
    );

    await _focusAndActivate(tester, 'Lighting');

    // 'mdp' is the sample project's FIRST panel, so with nothing selected the
    // way lands there.
    expect(circuitsOn('mdp'), before + 1,
        reason: 'Enter on a focused load card should add a way');
    expect(container.read(statusMessageProvider), contains('Lighting'));
    expect(container.read(statusMessageProvider), contains('Main Distribution Panel'));
  });

  testWidgets(
      'Enter on a focused Loads-palette card adds a way to the selected '
      'panel, not the first one', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // The unified Layout's Electrical layer: the palette (`ElectricalPalette`)
    // stays on screen regardless of selection there (unlike the standalone
    // workspace, whose inspector column swaps to an inline editor once a
    // panel is selected) — the scenario this test needs to exercise "add to
    // the selected panel while the palette is still visible".
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
    container
        .read(activeDisciplineProvider.notifier)
        .set(DisciplineLayer.electrical);
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();

    // Select the OTHER panel ('lp1') via the Layout electrical layer's marker
    // selection.
    container.read(electricalSelectionProvider.notifier).selectPanel('lp1');
    await tester.pump();

    int circuitsOn(String panelId) => container
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == panelId)
        .circuits
        .length;
    final beforeMdp = circuitsOn('mdp');
    final beforeLp1 = circuitsOn('lp1');

    await _focusAndActivate(tester, 'Lighting');

    expect(circuitsOn('lp1'), beforeLp1 + 1,
        reason: 'the selected panel should receive the new way');
    expect(circuitsOn('mdp'), beforeMdp,
        reason: 'the unselected panel should be untouched');
  });
}
