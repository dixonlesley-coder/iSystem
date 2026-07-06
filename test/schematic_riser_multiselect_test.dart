/// D5 — the Riser Edit canvas gained the Layout marquee idiom: an empty-canvas
/// left-drag rubber-band-selects several placed risers, and a body drag on any
/// selected riser moves the WHOLE set horizontally in one undo step. This test
/// pins a deterministic (identity) edit viewport, marquees two risers, drags one
/// to move both, and checks one undo restores them.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart' show workspaceViewProvider, WorkspaceView;
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/schematic_view_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

class _FixedNetworkController extends NetworkController {
  _FixedNetworkController(this._fixed);
  final Network _fixed;
  @override
  DrawingState build() => DrawingState(network: _fixed);
}

// Two vertical risers (r1 at x=150, r2 at x=400), each spanning floor 0 -> 1.
// Under the identity edit viewport their legs sit at those x's between the floor
// band centres, so their on-screen positions are deterministic.
const _twoRisers = Network(
  nodes: [
    NetNode(id: 'r1lo', sheetId: 's1', x: 150, y: 0, floorIndex: 0),
    NetNode(id: 'r1hi', sheetId: 's1', x: 150, y: 0, floorIndex: 1),
    NetNode(id: 'r2lo', sheetId: 's1', x: 400, y: 0, floorIndex: 0),
    NetNode(id: 'r2hi', sheetId: 's1', x: 400, y: 0, floorIndex: 1),
  ],
  edges: [
    NetEdge(
      id: 'r1',
      fromId: 'r1lo',
      toId: 'r1hi',
      service: ServiceType.coldWater,
      kind: EdgeKind.riser,
    ),
    NetEdge(
      id: 'r2',
      fromId: 'r2lo',
      toId: 'r2hi',
      service: ServiceType.coldWater,
      kind: EdgeKind.riser,
    ),
  ],
);

void main() {
  testWidgets(
      'marquee selects both risers; a group drag moves both; one undo restores '
      'both', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          networkControllerProvider.overrideWith(
            () => _FixedNetworkController(_twoRisers),
          ),
        ],
        child: const MechXApp(),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    // Enter the Riser workspace in Edit mode with a pinned identity viewport
    // (world == canvas-local px) so the risers' screen positions are exact.
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
    container
        .read(schematicViewProvider.notifier)
        .setEditTransform(const ViewportTransform());
    container.read(schematicViewProvider.notifier).setMode(SchematicMode.edit);
    await tester.pump();

    final canvasRect = tester.getRect(find.byWidgetPredicate(
      (w) => w is Focus && w.focusNode?.debugLabel == 'elevation-canvas',
    ));
    Offset at(double x, double y) => canvasRect.topLeft + Offset(x, y);

    double xOf(String nodeId) => container
        .read(networkControllerProvider)
        .network
        .nodeById(nodeId)!
        .x;

    // ── Marquee across both riser legs (start on a blank spot) ────────────────
    final m = await tester.startGesture(at(10, 200));
    await tester.pump();
    await m.moveTo(at(500, 420));
    await tester.pump();
    await m.up();
    await tester.pump();

    expect(container.read(selectionProvider).edgeIds,
        containsAll(<String>{'r1', 'r2'}));

    // ── Group drag: grab riser r1's leg and pull +100px right ─────────────────
    final g = await tester.startGesture(at(150, 320));
    await tester.pump();
    await g.moveTo(at(250, 320));
    await tester.pump();
    await g.up();
    await tester.pump();

    // Both risers moved by the same delta (relative offset preserved).
    expect(xOf('r1lo'), 250);
    expect(xOf('r1hi'), 250);
    expect(xOf('r2lo'), 500);
    expect(xOf('r2hi'), 500);

    // ── One undo restores BOTH risers ────────────────────────────────────────
    container.read(historyProvider.notifier).undo();
    await tester.pump();
    expect(xOf('r1lo'), 150);
    expect(xOf('r2lo'), 400);
  });
}
