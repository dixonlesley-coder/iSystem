/// D5 — the Riser Edit canvas gained the Layout marquee idiom: an empty-canvas
/// left-drag rubber-band-selects several placed risers, and a body drag on any
/// selected riser moves the WHOLE set horizontally. This test pins a
/// deterministic (identity) edit viewport, marquees two risers and drags one to
/// move both.
///
/// B3 RE-DERIVATION — the group drag used to write the elevation x onto the PLAN
/// nodes, so this test asserted `nodeById('r1lo').x == 250` and that ONE undo
/// restored 150. The gesture is a diagram declutter: it must not edit the
/// drawing (it silently relocated the riser away from its shaft on the plan and
/// in every plan export). The assertions are re-derived to the new contract:
/// every node's PLAN x is unchanged (150 / 400), the elevation-layout override
/// carries the moved positions (250 / 500 — the same +100 delta, relative offset
/// preserved), and NO undo step is recorded (the network never changed, so the
/// old snapshot was a phantom entry).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart' show workspaceViewProvider, WorkspaceView;
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/schematic_layout_store.dart';
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
      'marquee selects both risers; a group drag moves both on the DIAGRAM, '
      'leaving the plan geometry untouched', (tester) async {
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

    // The PLAN x (the drawn geometry) — must never move on this surface.
    double planX(String nodeId) => container
        .read(networkControllerProvider)
        .network
        .nodeById(nodeId)!
        .x;

    // The DIAGRAM x the elevation draws at (override, else the plan x).
    double diagramX(String nodeId) => container
        .read(schematicLayoutProvider)
        .xForId(nodeId, planX(nodeId));

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

    // Both risers moved by the same delta ON THE DIAGRAM (relative offset
    // preserved) — 150 -> 250 and 400 -> 500.
    expect(diagramX('r1lo'), 250);
    expect(diagramX('r1hi'), 250);
    expect(diagramX('r2lo'), 500);
    expect(diagramX('r2hi'), 500);

    // ── B3: the PLAN geometry is untouched, and nothing was recorded ─────────
    expect(planX('r1lo'), 150);
    expect(planX('r1hi'), 150);
    expect(planX('r2lo'), 400);
    expect(planX('r2hi'), 400);
    expect(container.read(historyProvider.notifier).canUndo, isFalse,
        reason: 'a diagram-only move must not push an undo entry');
  });
}
