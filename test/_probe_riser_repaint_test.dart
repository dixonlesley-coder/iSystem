import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart' show workspaceViewProvider, WorkspaceView;
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/schematic_layout_store.dart';
import 'package:mechx/store/schematic_view_store.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx_engine/network/network.dart';
import 'test_util.dart';

class _Fixed extends NetworkController {
  _Fixed(this._fixed);
  final Network _fixed;
  @override
  DrawingState build() => DrawingState(network: _fixed);
}

const _net = Network(
  nodes: [
    NetNode(id: 'r1lo', sheetId: 's1', x: 150, y: 0, floorIndex: 0),
    NetNode(id: 'r1hi', sheetId: 's1', x: 150, y: 0, floorIndex: 1),
  ],
  edges: [
    NetEdge(id: 'r1', fromId: 'r1lo', toId: 'r1hi', service: ServiceType.coldWater, kind: EdgeKind.riser),
  ],
);

void main() {
  testWidgets('probe: edit riser drag repaints?', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(ProviderScope(overrides: [
      networkControllerProvider.overrideWith(() => _Fixed(_net)),
    ], child: const MechXApp()));
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(MechXApp)), listen: false);
    c.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
    c.read(schematicViewProvider.notifier).setEditTransform(const ViewportTransform());
    c.read(schematicViewProvider.notifier).setMode(SchematicMode.edit);
    await tester.pump();
    final canvasRect = tester.getRect(find.byWidgetPredicate(
        (w) => w is Focus && w.focusNode?.debugLabel == 'elevation-canvas'));
    Offset at(double x, double y) => canvasRect.topLeft + Offset(x, y);
    final cp = find.byWidgetPredicate((w) =>
        w is CustomPaint && w.painter?.runtimeType.toString() == '_EditSchematicPainter');
    expect(cp, findsOneWidget);
    final ro = tester.renderObject<RenderCustomPaint>(cp);
    // select first
    final g = await tester.startGesture(at(150, 320));
    await tester.pump();
    await g.up();
    await tester.pump();
    final before = (tester.widget<CustomPaint>(cp).painter)!;
    final g2 = await tester.startGesture(at(150, 320));
    await tester.pump();
    await g2.moveTo(at(260, 320));
    await tester.pump(Duration.zero, EnginePhase.layout);
    final after = (tester.widget<CustomPaint>(cp).painter)!;
    // ignore: avoid_print
    print('PROBE identical=${identical(before, after)} shouldRepaint=${after.shouldRepaint(before)}');
    // ignore: avoid_print
    print('PROBE override=${c.read(schematicLayoutProvider).schematicXOverrides} '
        'customPaintNeedsPaint=${ro.debugNeedsPaint}');
    RenderObject? p = ro;
    while (p != null && !p.isRepaintBoundary) { p = p.parent; }
    // ignore: avoid_print
    print('PROBE nearestBoundary=${p.runtimeType} needsPaint=${p?.debugNeedsPaint}');
    await tester.pump();
    await g2.up();
    await tester.pump();
  });
}
