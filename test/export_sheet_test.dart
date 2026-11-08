/// Work item 8 — the ONE Export sheet (Ctrl/Cmd+E): every opener lands on the
/// sheet with its own group pre-expanded (the top bar / Ctrl+E / Review +
/// Projects links on the default submittal opening, the Riser toolbar on
/// Drawings, the Electrical toolbar on Electrical), and the sheet's keyboard
/// contract (Esc closes, Up/Down/Enter move + toggle).
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/command_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/ui/electrical/electrical_view.dart';
import 'package:mechx/ui/schematic/schematic_view.dart';
import 'package:mechx/ui/shell/export_sheet.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
}

Future<ProviderContainer> _pumpApp(WidgetTester tester) async {
  setDesktopSurface(tester);
  await tester.pumpWidget(const ProviderScope(child: MechXApp()));
  await tester.pump();
  return ProviderScope.containerOf(
    tester.element(find.byType(MechXApp)),
    listen: false,
  );
}

Finder _inSheet(Finder f) =>
    find.descendant(of: find.byType(ExportSheetOverlay), matching: f);

void main() {
  setUpAll(_loadFonts);

  testWidgets('closed at rest: the overlay renders nothing', (tester) async {
    await _pumpApp(tester);
    expect(_inSheet(find.text('DRAWINGS (7)')), findsNothing);
  });

  testWidgets(
      'the top bar Export button opens the sheet on the default group: the '
      'submittal action, every group collapsed with its count', (tester) async {
    final c = await _pumpApp(tester);
    await tester.tap(find.text('Export').first);
    await tester.pump();
    expect(c.read(exportSheetProvider), ExportGroup.submittal);
    expect(_inSheet(find.text('Export submittal package...')), findsOneWidget);
    for (final g in const [
      'DRAWINGS (7)',
      'REPORTS (6)',
      'DATA (2)',
      'ELECTRICAL (12)',
      'COMMERCIAL (2)',
    ]) {
      expect(_inSheet(find.text(g)), findsOneWidget, reason: g);
    }
    // Collapsed: no row is in the tree.
    expect(_inSheet(find.text('Export drawing (DXF)')), findsNothing);
    expect(_inSheet(find.text('Panel schedules')), findsNothing);

    // A header tap expands its group.
    await tester.tap(_inSheet(find.text('REPORTS (6)')));
    await tester.pump();
    expect(_inSheet(find.text('Export calc report (MD)')), findsOneWidget);

    // Esc closes.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(c.read(exportSheetProvider), isNull);
  });

  testWidgets('Ctrl+E toggles the sheet', (tester) async {
    final c = await _pumpApp(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(c.read(exportSheetProvider), ExportGroup.submittal);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(c.read(exportSheetProvider), isNull);
  });

  testWidgets('the Riser toolbar Export opens the sheet with Drawings expanded',
      (tester) async {
    final c = await _pumpApp(tester);
    // The riser toolbar's filter + Export ride the Auto bar once a service
    // exists.
    c.read(networkControllerProvider.notifier).loadNetwork(const Network(
      nodes: [
        NetNode(id: 'lo', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
        NetNode(id: 'hi', sheetId: 's1', x: 200, y: 0, floorIndex: 1),
      ],
      edges: [
        NetEdge(
          id: 'r1',
          fromId: 'lo',
          toId: 'hi',
          service: ServiceType.coldWater,
          kind: EdgeKind.riser,
        ),
      ],
    ));
    c.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
    c.read(shellSectionProvider.notifier).set(ShellSection.design);
    await tester.pump();
    await tester.tap(find.descendant(
        of: find.byType(SchematicView), matching: find.text('Export')));
    await tester.pump();
    expect(c.read(exportSheetProvider), ExportGroup.drawings);
    // The old riser menu's four rows live here now.
    expect(_inSheet(find.text('Riser single-line')), findsNWidgets(2));
    expect(_inSheet(find.text('All systems (drawing set)')), findsNWidgets(2));
    // Other groups stay collapsed.
    expect(_inSheet(find.text('Panel schedules')), findsNothing);
  });

  testWidgets(
      'the Electrical toolbar Export opens the sheet with Electrical expanded',
      (tester) async {
    final c = await _pumpApp(tester);
    seedSampleElectrical(c);
    c.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    c.read(shellSectionProvider.notifier).set(ShellSection.design);
    await tester.pump();
    await tester.tap(find.descendant(
        of: find.byType(ElectricalView), matching: find.text('Export')));
    await tester.pump();
    expect(c.read(exportSheetProvider), ExportGroup.electrical);
    expect(_inSheet(find.text('Panel schedules')), findsOneWidget);
    expect(_inSheet(find.text('Layout plan (denah)')), findsNWidgets(2));
    expect(_inSheet(find.text('Export drawing (DXF)')), findsNothing);
  });

  testWidgets(
      'keyboard: Down moves from the submittal action to the first header, '
      'Enter toggles it open', (tester) async {
    final c = await _pumpApp(tester);
    c.read(exportSheetProvider.notifier).open();
    await tester.pump();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(_inSheet(find.text('Export drawing (DXF)')), findsOneWidget);
    // Still open — Enter on a header toggles, it never exports.
    expect(c.read(exportSheetProvider), ExportGroup.submittal);
  });
}
