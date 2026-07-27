/// Host wiring for the electrical inspector/menu contract this wave landed
/// (`electrical_inspector.dart`'s `ElectricalCircuitInspector` +
/// `ElectricalPanelInspector` optional params): the two INLINE editor call
/// sites in `app_shell.dart`'s shared `buildElectricalInlineEditor` — used by
/// both the standalone electrical workspace and the unified Layout
/// electrical-layer column — now resolve the run-length basis + placement
/// caption from the live §10 geometry, and drive Feed-from / Apply-template /
/// Pin-phases / Remove-from-layout through the live providers with a status
/// toast. Also covers the canvas's OWN right-click panel menu, which gained
/// the same Feed-from + Pin-phases rows (`electrical_view.dart`'s
/// `_buildPanelMenu`).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/electrical/electrical_controls.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      "a circuit's placed load shows 'from layout' in the inline inspector, "
      'and Remove-from-layout un-places it (one undo restores)',
      (tester) async {
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
    // s1 -> 'Ground Floor' sheet at building floor 0 ('Ground').
    seedDemoSheets(container);
    container
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.01));

    final ctrl = container.read(electricalProjectProvider.notifier);
    ctrl.setProject(const ElectricalProject(
      id: 'placed',
      name: 'Placed project',
      panels: [
        ElectricalPanel(
          id: 'mdp',
          name: 'MDP',
          tag: 'MDP',
          layoutPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0),
          circuits: [
            ElectricalCircuit(
              id: 'c1',
              name: 'Socket run',
              loadKind: LoadKind.socket,
              loadW: 2000,
              cosPhi: 0.9,
              length: Length(90), // a deliberately long manual fallback
              loadPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 300, y: 0),
            ),
          ],
        ),
      ],
    ));
    await tester.pump();

    container
        .read(electricalInspectorTargetProvider.notifier)
        .editCircuit('mdp', 'c1');
    await tester.pump();

    // The Length row reads the resolved geo basis, and the Placement row
    // names the sheet + floor the same way the sheet rail does. (Matched with
    // the leading 'm —' so this can't collide with the "From layout — remove
    // from layout to edit" hint or the "Remove from layout" button, both of
    // which also contain the bare substring "from layout".)
    expect(find.textContaining('m — from layout'), findsOneWidget);
    expect(find.textContaining('Placed — Sheet 1 · Ground'), findsOneWidget);

    await tester.ensureVisible(find.text('Remove from layout'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from layout'));
    await tester.pump();

    final unplaced = container
        .read(electricalProjectProvider)
        .panels
        .single
        .circuits
        .single;
    expect(unplaced.loadPos, isNull);
    expect(
      find.text('Removed from layout — manual length applies.'),
      findsOneWidget,
    );
    // The manual fallback now governs, so the row reads "manual" not "from
    // layout".
    expect(find.textContaining('manual'), findsWidgets);

    // ONE undo restores the placement.
    container.read(historyProvider.notifier).undo();
    await tester.pump();
    final restored = container
        .read(electricalProjectProvider)
        .panels
        .single
        .circuits
        .single;
    expect(restored.loadPos, isNotNull);
  });

  testWidgets(
      "the panel inspector's Feed-from chooser excludes cycle-forming "
      'candidates, and re-feeding an already-fed board toasts the "(was …)" '
      'move', (tester) async {
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
    final ctrl = container.read(electricalProjectProvider.notifier);

    final rootId = ctrl.addPanelAt(name: 'Root', tag: 'ROOT', x: 0, y: 0);
    final midId = ctrl.addPanelAt(name: 'Mid', tag: 'MID', x: 100, y: 0);
    final leafId = ctrl.addPanelAt(name: 'Leaf', tag: 'LEAF', x: 200, y: 0);
    final otherId = ctrl.addPanelAt(name: 'Other', tag: 'OTHER', x: 300, y: 0);
    final oldSrcId =
        ctrl.addPanelAt(name: 'Old source', tag: 'OLDSRC', x: 400, y: 0);
    // root -> mid -> leaf (a chain); oldSrc -> other (separately).
    ctrl.connectFeeder(rootId, midId);
    ctrl.connectFeeder(midId, leafId);
    ctrl.connectFeeder(oldSrcId, otherId);
    await tester.pump();

    // ROOT's own candidates must exclude MID and LEAF — both already
    // downstream of root, so reconnecting either would close a feeder loop.
    // Scoped to the chooser card itself: the single-line canvas behind the
    // inspector also labels every panel by its tag (MID/LEAF/OTHER/OLDSRC),
    // so a bare `find.text` would find those canvas labels too.
    container
        .read(electricalInspectorTargetProvider.notifier)
        .editPanel(rootId);
    await tester.pump();
    await tester.tap(find.text('Feed from…'));
    await tester.pumpAndSettle();

    final rootChooser = find.byType(ElectricalChooserCard);
    expect(rootChooser, findsOneWidget);
    expect(find.descendant(of: rootChooser, matching: find.text('MID')),
        findsNothing);
    expect(find.descendant(of: rootChooser, matching: find.text('LEAF')),
        findsNothing);
    expect(find.descendant(of: rootChooser, matching: find.text('OTHER')),
        findsOneWidget);
    expect(find.descendant(of: rootChooser, matching: find.text('OLDSRC')),
        findsOneWidget);

    // OTHER's chooser marks its current feeder OLDSRC as "(current)"; picking
    // ROOT instead re-parents it and toasts the board it moved from.
    container
        .read(electricalInspectorTargetProvider.notifier)
        .editPanel(otherId);
    await tester.pump();
    await tester.tap(find.text('Feed from…'));
    await tester.pumpAndSettle();
    final otherChooser = find.byType(ElectricalChooserCard);
    expect(
      find.descendant(
          of: otherChooser, matching: find.text('OLDSRC (current)')),
      findsOneWidget,
    );

    await tester.tap(
        find.descendant(of: otherChooser, matching: find.text('ROOT')));
    await tester.pump();

    final rootPanel = container
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == rootId);
    expect(rootPanel.circuits.any((c) => c.feedsPanelId == otherId), isTrue);
    expect(
      find.text('Fed from ROOT (was OLDSRC).'),
      findsOneWidget,
    );
  });

  testWidgets(
      'Apply template populates an empty board in one undo step',
      (tester) async {
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
    final ctrl = container.read(electricalProjectProvider.notifier);
    final panelId = ctrl.addPanelAt(name: 'Sub-panel', tag: 'SP-1', x: 0, y: 0);
    await tester.pump();

    container
        .read(electricalInspectorTargetProvider.notifier)
        .editPanel(panelId);
    await tester.pump();

    expect(
      container
          .read(electricalProjectProvider)
          .panels
          .firstWhere((p) => p.id == panelId)
          .circuits,
      isEmpty,
    );

    await tester.ensureVisible(find.text('Apply template…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply template…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lighting panel'));
    await tester.pumpAndSettle();

    final populated = container
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == panelId);
    expect(populated.circuits, isNotEmpty);
    expect(
      find.text('Applied the Lighting panel template.'),
      findsOneWidget,
    );

    // ONE undo restores the empty board.
    container.read(historyProvider.notifier).undo();
    await tester.pump();
    final restored = container
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == panelId);
    expect(restored.circuits, isEmpty);
  });

  testWidgets(
      'Pin phases writes phaseOverride for single-phase ways only',
      (tester) async {
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
    final ctrl = container.read(electricalProjectProvider.notifier);
    ctrl.setProject(const ElectricalProject(
      id: 'phases',
      name: 'Phase test',
      panels: [
        ElectricalPanel(
          id: 'mdp',
          name: 'MDP',
          tag: 'MDP',
          circuits: [
            ElectricalCircuit(
              id: 'c1',
              name: 'Light A',
              loadKind: LoadKind.lighting,
              isLighting: true,
              loadW: 500,
              phases: 1,
            ),
            ElectricalCircuit(
              id: 'c2',
              name: 'Light B',
              loadKind: LoadKind.lighting,
              isLighting: true,
              loadW: 500,
              phases: 1,
            ),
            ElectricalCircuit(
              id: 'c3',
              name: 'Light C',
              loadKind: LoadKind.lighting,
              isLighting: true,
              loadW: 500,
              phases: 1,
            ),
            ElectricalCircuit(
              id: 'c4',
              name: 'Chiller',
              loadKind: LoadKind.hvac,
              loadW: 18000,
              phases: 3,
            ),
          ],
        ),
      ],
    ));
    await tester.pump();

    container
        .read(electricalInspectorTargetProvider.notifier)
        .editPanel('mdp');
    await tester.pump();

    await tester.ensureVisible(find.text('Pin phases'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin phases'));
    await tester.pump();

    final panel = container.read(electricalProjectProvider).panels.single;
    for (final id in ['c1', 'c2', 'c3']) {
      expect(
        panel.circuits.firstWhere((c) => c.id == id).phaseOverride,
        isNotNull,
        reason: '$id is single-phase and should be pinned',
      );
    }
    expect(
      panel.circuits.firstWhere((c) => c.id == 'c4').phaseOverride,
      isNull,
      reason: 'c4 is three-phase — pinning a line is meaningless for it',
    );
    expect(find.textContaining('Phases pinned for 3 ways'), findsOneWidget);
  });
}
