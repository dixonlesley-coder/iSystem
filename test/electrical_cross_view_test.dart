/// Cross-view navigation between the two electrical projections — the
/// standalone single-line canvas (`WorkspaceView.electrical`,
/// `electrical_view.dart`) and the unified Layout floor-plan's Electrical
/// layer (`WorkspaceView.plan` + `activeDisciplineProvider ==
/// DisciplineLayer.electrical`, `layout_canvas.dart`/`electrical_layer.dart`).
///
/// Two one-tap context-menu rows close the loop:
///  * from the single-line, a PLACED panel/circuit's right-click menu gains a
///    "Show on layout" row (`_showOnLayout` in `electrical_view.dart`) that
///    jumps to the target's sheet on the Layout canvas, makes Electrical the
///    active discipline layer, selects it in `electricalSelectionProvider`,
///    and switches `workspaceViewProvider` — mirroring the Review→Electrical
///    locate mechanism's own sheet-selection (`issues_card.dart`'s `locate()`
///    via `sheetsControllerProvider.notifier.selectSheetById`);
///  * from the Layout canvas, a panel/circuit's right-click menu gains a
///    "Show in single-line" row (`_showInSingleLine` in `layout_canvas.dart`)
///    that switches to the Electrical workspace and hands the panel (+
///    optional circuit) id to the EXISTING `electricalFocusProvider` locate
///    seam the single-line already consumes for the Review jump.
///
/// Both rows are offered only when the target actually carries a placement
/// (`ElectricalPanel.layoutPos` / `ElectricalCircuit.loadPos`) — an unplaced
/// element never shows a dead action.
library;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_focus_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart'
    show ElectricalCanvas, ElectricalCanvasState;
import 'package:mechx/ui/electrical/electrical_controls.dart'
    show ElectricalMenu;
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/model.dart';

import 'test_util.dart';

/// A single secondary-click (right-click) gesture at [at] — mirrors the
/// mechanical canvas's own right-click test idiom (`layout_canvas_test.dart`):
/// one explicit `startGesture` + `up()`, since `tapAt` only ever fires the
/// primary button.
Future<void> _rightClick(WidgetTester tester, Offset at) async {
  final g = await tester.startGesture(at, buttons: kSecondaryButton);
  await g.up();
}

void main() {
  testWidgets(
      "single-line: a PLACED panel's 'Show on layout' row jumps the sheet, "
      'makes Electrical the active layer, selects it, and switches to the '
      'Layout workspace', (tester) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Three demo sheets; s1 ('Ground Floor') stays the default current sheet
    // so landing on s2 ('First Floor') is a real jump, not a no-op.
    seedDemoSheets(container);
    expect(container.read(sheetsControllerProvider).current?.id, 's1');

    container
        .read(workspaceViewProvider.notifier)
        .set(WorkspaceView.electrical);
    container.read(electricalProjectProvider.notifier).setProject(
      const ElectricalProject(
        id: 'placed-panel',
        name: 'Placed panel project',
        panels: [
          ElectricalPanel(
            id: 'mdp',
            name: 'Main Panel',
            tag: 'MDP',
            x: 100,
            y: 100,
            layoutPos: LayoutPos(sheetId: 's2', floorIndex: 1, x: 40, y: 40),
          ),
        ],
      ),
    );
    await tester.pump();
    // Frame the board at the SUMMARY LOD — the header (tag/name `Text`
    // widgets a right-click can locate) renders only there; the default
    // fit-to-content zoom for a single panel lands in the board-SCHEDULE tier,
    // whose header is a canvas paint, not a findable `Text` (`collapseToSummary`
    // is the same public zoom hook I7's "collapse" affordance uses).
    tester
        .state<ElectricalCanvasState>(find.byType(ElectricalCanvas))
        .collapseToSummary('mdp');
    await tester.pump();

    // Right-click the panel's header (the tag text is unique on-screen).
    expect(find.text('MDP'), findsOneWidget);
    await _rightClick(tester, tester.getCenter(find.text('MDP')));
    await tester.pump();

    expect(find.text('Show on layout'), findsOneWidget);
    await tester.tap(find.text('Show on layout'));
    await tester.pump();

    expect(container.read(workspaceViewProvider), WorkspaceView.plan);
    expect(container.read(activeDisciplineProvider), DisciplineLayer.electrical);
    expect(
      container.read(electricalSelectionProvider),
      const ElectricalSelection.panel('mdp'),
    );
    expect(container.read(sheetsControllerProvider).current?.id, 's2');
  });

  testWidgets(
      "single-line: an UNPLACED panel's context menu has NO 'Show on layout' "
      'row', (tester) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container
        .read(workspaceViewProvider.notifier)
        .set(WorkspaceView.electrical);
    container.read(electricalProjectProvider.notifier).setProject(
      const ElectricalProject(
        id: 'unplaced-panel',
        name: 'Unplaced panel project',
        panels: [
          ElectricalPanel(
            id: 'sub',
            name: 'Sub-panel',
            tag: 'SP-1',
            x: 100,
            y: 100,
            // No layoutPos — never placed on the plan.
          ),
        ],
      ),
    );
    await tester.pump();
    tester
        .state<ElectricalCanvasState>(find.byType(ElectricalCanvas))
        .collapseToSummary('sub');
    await tester.pump();

    expect(find.text('SP-1'), findsOneWidget);
    await _rightClick(tester, tester.getCenter(find.text('SP-1')));
    await tester.pump();

    // The menu itself renders (Properties/Open/etc.), just never a dead
    // "Show on layout" action with nowhere to jump to.
    expect(find.byType(ElectricalMenu), findsOneWidget);
    expect(find.text('Show on layout'), findsNothing);
  });

  testWidgets(
      "Layout: a placed panel's 'Show in single-line' row switches the "
      'workspace and hands the focus store the panel id', (tester) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    // Layout defaults to WorkspaceView.plan already; make Electrical the
    // active (interactive) discipline layer so the marker's context menu is
    // reachable (a non-active layer is `IgnorePointer`-wrapped).
    container
        .read(activeDisciplineProvider.notifier)
        .set(DisciplineLayer.electrical);
    // No circuits on this board — the panel MARKER (tag/name only) is all
    // this test needs; a placed circuit's own load marker is exercised by
    // `electrical_layer_drop_test.dart` and isn't this row's concern.
    container.read(electricalProjectProvider.notifier).setProject(
      const ElectricalProject(
        id: 'layout-panel',
        name: 'Layout panel project',
        panels: [
          ElectricalPanel(
            id: 'mdp',
            name: 'Main Panel',
            tag: 'MDP',
            layoutPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 200, y: 200),
          ),
        ],
      ),
    );
    await tester.pump();
    // Let the discipline cross-fade to full opacity settle (mirrors the
    // Layout electrical-layer test harness).
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('MDP'), findsOneWidget);
    await _rightClick(tester, tester.getCenter(find.text('MDP')));
    await tester.pump();

    expect(find.text('Show in single-line'), findsOneWidget);
    await tester.tap(find.text('Show in single-line'));
    // Deliberately NO pump here yet — the standalone electrical workspace's
    // `ref.listen(electricalFocusProvider, ...)` consumes (and clears) the
    // request only once it mounts on a later frame; checking the raw store
    // state right after the tap catches it before that happens.
    expect(container.read(workspaceViewProvider), WorkspaceView.electrical);
    expect(container.read(electricalFocusProvider)?.panelId, 'mdp');

    await tester.pump();
  });
}
