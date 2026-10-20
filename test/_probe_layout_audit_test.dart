import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/canvas_view.dart';
import 'package:mechx/ui/canvas/text_entry_guard.dart';
import 'package:mechx_engine/network/network.dart';
import 'test_util.dart';

ProviderContainer _c(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(MechXApp)), listen: false);

String _pf() => FocusManager.instance.primaryFocus?.toString() ?? 'null';

void main() {
  testWidgets('probe focus + draw keys', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final c = _c(tester);
    seedDemoSheets(c);
    await tester.pump(const Duration(milliseconds: 300));
    final here = c.read(sheetsControllerProvider).current!.id;
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
          NetNode(id: 'a', sheetId: here, x: 10, y: 10, floorIndex: 0),
          NetNode(id: 'b', sheetId: here, x: 90, y: 10, floorIndex: 0),
        ], edges: const [
          NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
        ]));
    await tester.pump(const Duration(milliseconds: 300));
    c.read(projectControllerProvider.notifier).setCalibration(here, const ScaleCalibration(0.01));
    await tester.pump();
    final canvasRect = tester.getRect(find.byType(CanvasView).first);
    // ignore: avoid_print
    print('initial focus: ${_pf()}');
    // Blur everything (what an inspector field commit does).
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    print('after unfocus: ${_pf()}');
    // click empty canvas
    await tester.tapAt(canvasRect.center + const Offset(200, 150), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
    print('after canvas click: ${_pf()}');
    c.read(selectionProvider.notifier).setMulti(const {}, const {'e1'});
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    print('edges after Delete: ${c.read(networkControllerProvider).network.edges.length}');

    // Drawing: arm run tool, place points by tapping
    c.read(networkControllerProvider.notifier).setTool(DrawTool.drawRun);
    await tester.pump(const Duration(milliseconds: 100));
    final p0 = canvasRect.center;
    await tester.tapAt(p0, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(p0 + const Offset(100, 0), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(p0 + const Offset(100, 80), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 100));
    final n1 = c.read(networkControllerProvider).network.edges.length;
    print('svc before typing: ${c.read(networkControllerProvider).service}');
    for (final k in [LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit0]) { await tester.sendKeyEvent(k); }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    print('after typing 3000+Enter: svc=${c.read(networkControllerProvider).service} edges=${c.read(networkControllerProvider).network.edges.length}');
    print('drawing: edges=$n1 textFocused=${isTextEntryFocused()} focus=${_pf()}');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    print('after Ctrl+Z mid-run: edges=${c.read(networkControllerProvider).network.edges.length} pending=${c.read(networkControllerProvider).pendingPoint}');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    print('after Enter mid-run: pending=${c.read(networkControllerProvider).pendingPoint} tool=${c.read(networkControllerProvider).tool}');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.pump();
    print('after O mid-run: ortho toggled? (check) ');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    print('after Backspace: edges=${c.read(networkControllerProvider).network.edges.length}');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 100));
    print('after Esc: pending=${c.read(networkControllerProvider).pendingPoint} tool=${c.read(networkControllerProvider).tool} focus=${_pf()}');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 100));
    print('after Esc2: tool=${c.read(networkControllerProvider).tool} focus=${_pf()}');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 100));
    print('after Enter idle (tool armed programmatically): tool=${c.read(networkControllerProvider).tool}');
    await tester.pump(const Duration(seconds: 4));
  });
}
