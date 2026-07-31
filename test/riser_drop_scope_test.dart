/// B2 — the Riser -> Edit palette drop.
///
/// A drop used to take the ELEVATION diagram's world x with `y = 0` as the
/// riser's PLAN coordinates, and `_sheetIdForFloor` fell back to the CURRENT
/// sheet when the target floor carried no plan — producing a node whose sheetId
/// mapped to floor 0 while its floorIndex said 1: invisible on every sheet
/// forever, yet still sized into the BOM. Now an unmapped floor REFUSES the drop
/// (with a status message naming the level to assign a plan to) and a mapped one
/// places the riser at that SHEET'S CENTRE and says so.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart' show statusMessageProvider;
import 'package:mechx/store/electrical_store.dart'
    show WorkspaceView, workspaceViewProvider;
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/schematic_view_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

/// The palette's riser card (a `Draggable<_RiserDragData>` — the type argument
/// is private, so match on the runtime type name).
final _riserCard = find.byWidgetPredicate(
    (w) => w.runtimeType.toString().startsWith('Draggable<'));

/// Open the Riser workspace in EDIT mode with an identity viewport, so the
/// elevation's world px equal canvas-local px and the band a drop lands on is
/// exact. Bands are 160 world px tall with floor 0 at the BOTTOM, so on a
/// 3-level building local y = 400 is floor 0 and y = 240 is floor 1.
Future<ProviderContainer> _openRiserEdit(WidgetTester tester,
    {List<Sheet> sheets = const []}) async {
  setDesktopSurface(tester);
  await tester.pumpWidget(const ProviderScope(child: MechXApp()));
  await tester.pump();
  final c = ProviderScope.containerOf(
    tester.element(find.byType(MechXApp)),
    listen: false,
  );
  if (sheets.isNotEmpty) {
    c.read(sheetsControllerProvider.notifier).loadSheets(sheets);
  }
  c.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
  c.read(schematicViewProvider.notifier).setEditTransform(
        const ViewportTransform(),
      );
  c.read(schematicViewProvider.notifier).setMode(SchematicMode.edit);
  await tester.pump();
  return c;
}

/// Drag the riser palette card onto the elevation canvas at canvas-local
/// ([x], [y]) and release.
Future<void> _dropRiserAt(WidgetTester tester, double x, double y) async {
  final canvasRect = tester.getRect(find.byWidgetPredicate(
    (w) => w is Focus && w.focusNode?.debugLabel == 'elevation-canvas',
  ));
  final target = canvasRect.topLeft + Offset(x, y);
  final gesture = await tester.startGesture(tester.getCenter(_riserCard.first));
  await tester.pump(const Duration(milliseconds: 50));
  await gesture.moveTo(target);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('B2 — a drop onto a level with NO plan is refused, with a status '
      'message naming the level', (tester) async {
    // No sheets at all: every level is unmapped.
    final c = await _openRiserEdit(tester);
    expect(c.read(networkControllerProvider).network.edges, isEmpty);

    await _dropRiserAt(tester, 300, 400); // floor 0's band

    expect(c.read(networkControllerProvider).network.edges, isEmpty,
        reason: 'no plan on the target level ⇒ nothing is drawn');
    expect(c.read(networkControllerProvider).network.nodes, isEmpty);
    expect(c.read(statusMessageProvider), 'Assign a plan to Ground first');
  });

  testWidgets('B2 — a drop onto a mapped level places the riser at that '
      'sheet\'s CENTRE and says so', (tester) async {
    final c = await _openRiserEdit(tester, sheets: const [
      Sheet(id: 's1', name: 'Ground Floor', sizePx: Size(1684, 1190)),
      Sheet(id: 's2', name: 'First Floor', sizePx: Size(1684, 1190)),
      Sheet(id: 's3', name: 'Roof Plan', sizePx: Size(1190, 1684)),
    ]);

    // The first solve also fires the one-shot "Auto-sized N runs" pill, which
    // lands on the same transient channel a frame later — so collect every
    // status the drop produces rather than reading the last one.
    final statuses = <String>[];
    final sub = c.listen<String?>(statusMessageProvider, (_, next) {
      if (next != null) statuses.add(next);
    });
    addTearDown(sub.close);

    await _dropRiserAt(tester, 300, 400); // floor 0's band → sheet s1

    final net = c.read(networkControllerProvider).network;
    expect(net.edges, hasLength(1));
    final edge = net.edges.single;
    expect(edge.kind, EdgeKind.riser);
    final lower = net.nodeById(edge.fromId)!;
    final upper = net.nodeById(edge.toId)!;

    // The BASE sits at the centre of the ground-floor plan — a real, findable
    // plan coordinate — not at the elevation's cursor x with y pinned to 0.
    expect(lower.sheetId, 's1');
    expect(lower.floorIndex, 0);
    expect(lower.x, 1684 / 2);
    expect(lower.y, 1190 / 2);

    // B1: the far end lands on the FLOOR-ABOVE's plan, so it is visible there.
    expect(upper.sheetId, 's2');
    expect(upper.floorIndex, 1);

    expect(statuses,
        contains('Riser on Ground — placed at the centre of Ground Floor'));
  });
}
