// Round 12 (2026-10-18) — the ui-journey findings, each pinned with the
// exact repro from the journey audit.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/ai_copilot_store.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/calibration_store.dart';
import 'package:mechx/store/command_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/snap_settings_store.dart';
import 'package:mechx/ui/electrical/panel_geometry.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_text_field.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
}

ProviderContainer _c(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(MechXApp)),
    listen: false);

Future<void> _ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

FocusNode _node(String label) => FocusManager.instance.rootScope.descendants
    .firstWhere((n) => n.debugLabel == label);

Future<ProviderContainer> _bootLayout(WidgetTester tester) async {
  setDesktopSurface(tester);
  await tester.pumpWidget(const ProviderScope(child: MechXApp()));
  await tester.pump();
  final c = _c(tester);
  seedDemoSheets(c);
  c.read(shellSectionProvider.notifier).set(ShellSection.design);
  c.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  return c;
}

void main() {
  setUpAll(_loadFonts);

  group('ui-journey-undo-redo-double-dispatch', () {
    testWidgets('one Ctrl+Z / Ctrl+Y = ONE step with the Layout canvas focused',
        (tester) async {
      final c = await _bootLayout(tester);
      final project = c.read(projectControllerProvider.notifier);
      project.setName('A');
      project.setName('B');
      project.setName('C');
      _node('canvas').requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'canvas');

      await _ctrl(tester, LogicalKeyboardKey.keyZ);
      expect(c.read(projectControllerProvider).name, 'B');
      await _ctrl(tester, LogicalKeyboardKey.keyY);
      expect(c.read(projectControllerProvider).name, 'C');
    });

    testWidgets('one Ctrl+Z = ONE step with the electrical canvas focused',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final c = _c(tester);
      c.read(shellSectionProvider.notifier).set(ShellSection.design);
      c.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final e = c.read(electricalProjectProvider.notifier);
      for (var i = 0; i < 3; i++) {
        e.addPanelAt(name: 'P$i', x: 100.0 * i, y: 400.0 * i);
      }
      await tester.pump();
      _node('electrical-canvas').requestFocus();
      await tester.pump();
      await _ctrl(tester, LogicalKeyboardKey.keyZ);
      expect(c.read(electricalProjectProvider).panels, hasLength(2));
    });
  });

  testWidgets(
      'ui-journey-esc-closes-sheet-and-cancels-canvas — Esc closes F1 only',
      (tester) async {
    final c = await _bootLayout(tester);
    c.read(measureModeProvider.notifier).set(true);
    _node('canvas').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pump();
    expect(c.read(shortcutsSheetOpenProvider), isTrue);
    // A bare tool key while the sheet is open never reaches the canvas.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(c.read(networkControllerProvider).tool, DrawTool.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(c.read(shortcutsSheetOpenProvider), isFalse);
    // The in-progress canvas mode survives the Esc that closed the sheet.
    expect(c.read(measureModeProvider), isTrue);
  });

  group('ui-journey-pending-field-edit-lost', () {
    Widget host(void Function(String) onCommitted) => MechXTheme(
          data: MechXThemeData.dark,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: MechXTextField(value: 'Level 2', onCommitted: onCommitted),
          ),
        );

    // Round 14 re-derivation (regression-commit-on-dispose-deactivated-ref):
    // the field no longer commits on TEARDOWN — its host's ref is already
    // deactivated by then (see audit_r14_app_test.dart). A bare unmount
    // therefore drops the edit; every navigation commits first instead.
    testWidgets('a bare unmount does not call the host back', (tester) async {
      String? committed;
      await tester.pumpWidget(host((v) => committed = v));
      await tester.enterText(find.byType(EditableText), 'Roof deck');
      await tester.pumpWidget(const SizedBox());
      expect(committed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('commitPendingEdit commits the focused field synchronously',
        (tester) async {
      String? committed;
      await tester.pumpWidget(host((v) => committed = v));
      await tester.enterText(find.byType(EditableText), 'Roof deck');
      MechXTextField.commitPendingEdit();
      expect(committed, 'Roof deck');
    });

    testWidgets('Ctrl+1 from the Projects page keeps the typed project name',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final c = _c(tester);
      c.read(projectControllerProvider.notifier).setName('Tower');
      c.read(shellSectionProvider.notifier).set(ShellSection.projects);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final field = find.byWidgetPredicate(
          (w) => w is MechXTextField && w.value == 'Tower');
      expect(field, findsOneWidget);
      await tester.enterText(
          find.descendant(of: field, matching: find.byType(EditableText)),
          'Menara Satu');
      await _ctrl(tester, LogicalKeyboardKey.digit1);
      await tester.pump();
      expect(c.read(projectControllerProvider).name, 'Menara Satu');
    });
  });

  testWidgets(
      'ui-journey-palette-tool-keeps-measure-mode — Tool: Select clears Measure',
      (tester) async {
    final c = await _bootLayout(tester);
    c.read(measureModeProvider.notifier).set(true);
    c.read(refLineModeProvider.notifier).set(true);
    await _ctrl(tester, LogicalKeyboardKey.keyK);
    expect(c.read(commandPaletteOpenProvider), isTrue);
    await tester.enterText(find.byType(EditableText).last, 'Tool: Select');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(c.read(networkControllerProvider).tool, DrawTool.select);
    expect(c.read(measureModeProvider), isFalse);
    expect(c.read(refLineModeProvider), isFalse);
  });

  testWidgets(
      'ui-journey-copilot-no-esc-focus-leak — Esc closes it; keys stay out of '
      'the canvas', (tester) async {
    final c = await _bootLayout(tester);
    _node('canvas').requestFocus();
    await tester.pump();
    c.read(copilotOpenProvider.notifier).open();
    await tester.pump();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('canvas'));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(c.read(networkControllerProvider).tool, DrawTool.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(c.read(copilotOpenProvider), isFalse);
  });

  test('ui-journey-new-project-keeps-session-state — applyDocument resets it',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(reportExportedProvider.notifier).markExported();
    c.read(calibrationControllerProvider.notifier).start();
    c.read(measureModeProvider.notifier).set(true);
    c.read(refLineModeProvider.notifier).set(true);
    expect(c.read(calibrationControllerProvider).isActive, isTrue);

    applyDocument(
        c.read,
        const ProjectDocument(
          projectName: 'Untitled project',
          floors: [Floor('G', Length(3.0))],
          calibrations: {},
          sheets: [],
          network: Network(nodes: [], edges: []),
        ));
    expect(c.read(reportExportedProvider), isFalse);
    expect(c.read(calibrationControllerProvider).isActive, isFalse);
    expect(c.read(measureModeProvider), isFalse);
    expect(c.read(refLineModeProvider), isFalse);
  });

  test('ui-journey-add-panel-overlaps — successive drops never overlap', () {
    var project = const ElectricalProject(id: 'p', name: 'P', panels: []);
    for (var i = 1; i <= 4; i++) {
      final r = computeSystem(const PuilProfile(), project);
      final slot = nextPanelDropSlot(project, r);
      project = ElectricalProject(id: 'p', name: 'P', panels: [
        ...project.panels,
        ElectricalPanel(
          id: 'SP$i',
          name: 'Sub-panel $i',
          x: slot.dx,
          y: slot.dy,
          circuits: const [
            ElectricalCircuit(
                id: 'c', name: 'L', loadKind: LoadKind.lighting, loadW: 500),
          ],
        ),
      ]);
    }
    final r = computeSystem(const PuilProfile(), project);
    final pos = resolvePanelPositions(project, r);
    final ids = pos.keys.toList();
    for (var a = 0; a < ids.length; a++) {
      for (var b = a + 1; b < ids.length; b++) {
        final ya = pos[ids[a]]!.dy, yb = pos[ids[b]]!.dy;
        final ha = panelFootprintLod(r.panels[ids[a]]!, PanelLod.schedule);
        final hb = panelFootprintLod(r.panels[ids[b]]!, PanelLod.schedule);
        // Vertical bands are disjoint ⇒ the cards cannot overlap.
        expect(ya + ha <= yb || yb + hb <= ya, isTrue,
            reason: '${ids[a]} vs ${ids[b]}');
      }
    }
  });

  test('ui-journey-autosized-plural — one run reads "1 run"', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(firstAutoSizeNudgeProvider.notifier).maybeFire(1);
    expect(c.read(statusMessageProvider),
        'Auto-sized 1 run · sizes shown on the plan');
  });

  test('mech-props-2 gravity loop — the closing pipe surfaces in Review', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    NetNode drain(String id, double x) => NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: 0,
        role: NodeRole.fixture,
        component: NodeComponent.roofDrain);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(
          nodes: [
            drain('C0', 0),
            drain('C1', 100),
            drain('C2', 200),
            const NetNode(id: 'out', sheetId: 's1', x: -100, y: 0, floorIndex: 0),
          ],
          edges: const [
            NetEdge(
                id: 'a', fromId: 'C0', toId: 'C1', service: ServiceType.rainwater),
            NetEdge(
                id: 'b', fromId: 'C1', toId: 'C2', service: ServiceType.rainwater),
            NetEdge(
                id: 'c', fromId: 'C2', toId: 'C0', service: ServiceType.rainwater),
            NetEdge(
                id: 'd', fromId: 'C0', toId: 'out', service: ServiceType.rainwater),
          ],
        ));
    final issue = c
        .read(designIssuesProvider)
        .firstWhere((i) => i.kind == 'loop-unbalanced');
    expect(issue.title, 'Gravity loop — closing pipe provisional');
    // Every drawn edge is sized (none silently dropped).
    expect(c.read(sizingProvider).keys.toSet(), {'a', 'b', 'c', 'd'});
  });
}
