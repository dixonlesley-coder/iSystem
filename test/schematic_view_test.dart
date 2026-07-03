/// Widget tests for SchematicView.
///
/// Harness: ProviderScope + MechXTheme + Directionality + MediaQuery
/// (no MaterialApp — the app uses WidgetsApp only).
///
/// Tests are intentionally light: they assert the widget builds without
/// throwing and renders the expected empty/non-empty states.  Pixel positions
/// are NOT asserted.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx/ui/schematic/schematic_view.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/network/network.dart';

// ---------------------------------------------------------------------------
// Minimal notifier override — always returns the supplied network.
// ---------------------------------------------------------------------------

class _FixedNetworkController extends NetworkController {
  _FixedNetworkController(this._fixed);

  final Network _fixed;

  @override
  DrawingState build() => DrawingState(network: _fixed);
}

// ---------------------------------------------------------------------------
// A small two-floor demo network used by several tests.
// ---------------------------------------------------------------------------

const _demoNetwork = Network(
  nodes: [
    NetNode(id: 'n0', sheetId: 's1', x: 100, y: 200, floorIndex: 0),
    NetNode(id: 'n1', sheetId: 's1', x: 300, y: 200, floorIndex: 0),
    NetNode(id: 'n2', sheetId: 's1', x: 200, y: 200, floorIndex: 0),
    NetNode(id: 'n3', sheetId: 's1', x: 200, y: 100, floorIndex: 1),
  ],
  edges: [
    NetEdge(
      id: 'e0',
      fromId: 'n0',
      toId: 'n1',
      service: ServiceType.coldWater,
    ),
    NetEdge(
      id: 'e1',
      fromId: 'n2',
      toId: 'n3',
      service: ServiceType.coldWater,
      kind: EdgeKind.riser,
    ),
  ],
);

List<Override> _demoOverrides() => [
      networkControllerProvider.overrideWith(
        () => _FixedNetworkController(_demoNetwork),
      ),
    ];

// ---------------------------------------------------------------------------
// Test harness helper
// ---------------------------------------------------------------------------

/// Wraps [child] in the minimal tree required by [SchematicView]:
///   ProviderScope → MechXTheme → Directionality → MediaQuery → SizedBox
Widget _harness(Widget child, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(800, 600)),
            child: SizedBox(width: 800, height: 600, child: child),
          ),
        ),
      ),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('SchematicView — empty network', () {
    testWidgets('builds without throwing and shows the empty-state text',
        (tester) async {
      await tester.pumpWidget(_harness(const SchematicView()));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('No network drawn'), findsOneWidget);
    });
  });

  group('SchematicView — demo network', () {
    testWidgets('renders without throwing with a two-floor network',
        (tester) async {
      await tester.pumpWidget(
        _harness(const SchematicView(), overrides: _demoOverrides()),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      // Empty-state placeholder must NOT appear when there are nodes.
      expect(find.text('No network drawn'), findsNothing);
    });

    testWidgets('a CustomPaint is present when the network is non-empty',
        (tester) async {
      await tester.pumpWidget(
        _harness(const SchematicView(), overrides: _demoOverrides()),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('Auto legend lists every service present in the demo network',
        (tester) async {
      await tester.pumpWidget(
        _harness(const SchematicView(), overrides: _demoOverrides()),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      // The legend is now DRAWING CHROME — OFF by default on the live canvas
      // (it rides the export). So only the toolbar toggle button shows 'Legend'
      // and 'Cold water' (the chip), with no legend card yet.
      expect(find.text('Legend'), findsOneWidget);
      expect(find.text('Cold water'), findsOneWidget);

      // Tapping the toggle previews the legend overlay on the canvas.
      await tester.tap(find.text('Legend'));
      await tester.pump();

      // Now 'Legend' appears twice (toolbar button + legend card header).
      expect(find.text('Legend'), findsNWidgets(2));
      // Pipe tags are CustomPaint-only, so a found 'CW' Text widget proves the
      // legend (the only place 'CW' is a Flutter Text) rendered, and the full
      // serviceLabel row confirms the service is listed by name.
      expect(find.text('CW'), findsWidgets);
      // 'Cold water' appears in the toolbar service chip AND the legend row.
      expect(find.text('Cold water'), findsNWidgets(2));
    });
  });

  group('SchematicView — legend on empty network', () {
    testWidgets('legend overlay is unreachable for an empty network',
        (tester) async {
      await tester.pumpWidget(_harness(const SchematicView()));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // The Auto view early-returns the empty-state text before the legend
      // Stack, so no legend service row renders.
      expect(find.text('No network drawn'), findsOneWidget);
      expect(find.text('Cold water'), findsNothing);
    });
  });

  group('SchematicView — F9 honest feed note', () {
    Network riserNetwork({required bool roofTank}) => Network(
          nodes: [
            const NetNode(id: 'lo', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
            NetNode(
              id: 'hi',
              sheetId: 's1',
              x: 200,
              y: 0,
              floorIndex: 1,
              component: roofTank ? NodeComponent.roofTank : null,
            ),
          ],
          edges: const [
            NetEdge(
              id: 'r1',
              fromId: 'lo',
              toId: 'hi',
              service: ServiceType.coldWater,
              kind: EdgeKind.riser,
            ),
          ],
        );

    testWidgets(
        "the Notes card claims '(roof tank)' only when a roofTank exists",
        (tester) async {
      // Tankless downfeed network (the default feed strategy is downfeed):
      // the feed line must NOT assert a roof tank.
      await tester.pumpWidget(_harness(const SchematicView(), overrides: [
        networkControllerProvider.overrideWith(
          () => _FixedNetworkController(riserNetwork(roofTank: false)),
        ),
      ]));
      await tester.pump();
      expect(find.text('Feed: gravity downfeed'), findsOneWidget);
      expect(find.textContaining('(roof tank)'), findsNothing);
    });

    testWidgets("with a real roofTank node the '(roof tank)' suffix returns",
        (tester) async {
      await tester.pumpWidget(_harness(const SchematicView(), overrides: [
        networkControllerProvider.overrideWith(
          () => _FixedNetworkController(riserNetwork(roofTank: true)),
        ),
      ]));
      await tester.pump();
      expect(find.text('Feed: gravity downfeed (roof tank)'), findsOneWidget);
    });
  });

  group('SchematicView — F3 Edit-mode undo contract', () {
    // The two-floor riser the pointer tests grab: vertical leg at world
    // x = 200 spanning floors 0-1.
    const riserNet = Network(
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
    );

    /// Global screen point on the riser's vertical leg, derived from the Edit
    /// canvas's own fit transform (contentSize = 1200 x 160·levels, padding 40
    /// — `_EditElevation`'s documented geometry; default building = 3 levels).
    Offset riserPoint(WidgetTester tester) {
      final clipBox = tester.renderObject<RenderBox>(find.descendant(
          of: find.byType(SchematicView), matching: find.byType(ClipRect)));
      final vt =
          ViewportTransform.fit(const Size(1200, 480), clipBox.size, padding: 40);
      // Floor band centres (floor 0 at the bottom): floor 0 → y 400, floor 1 →
      // y 240; the leg's midpoint is (200, 320) in world px.
      return clipBox.localToGlobal(vt.worldToScreen(const Offset(200, 320)));
    }

    // Edit mode hosts Draggable palette cards, which need an Overlay ancestor
    // (WidgetsApp provides one in the real shell); a roomier surface keeps the
    // toolbar + palette from overflowing the test viewport.
    Widget editHarness() => ProviderScope(
          child: MechXTheme(
            data: MechXThemeData.dark,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: MediaQuery(
                data: const MediaQueryData(size: Size(1200, 800)),
                child: SizedBox(
                  width: 1200,
                  height: 800,
                  child: Overlay(
                    initialEntries: [
                      OverlayEntry(
                        builder: (_) => const SchematicView(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets(
        'select-to-inspect pushes NO undo step and keeps redo; the first drag '
        'movement records exactly one', (tester) async {
      await tester.pumpWidget(editHarness());
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(SchematicView)),
        listen: false,
      );
      final net = container.read(networkControllerProvider.notifier);
      final history = container.read(historyProvider.notifier);
      net.loadNetwork(riserNet);

      // Enter Edit mode and let the canvas fit itself.
      await tester.tap(find.text('Edit'));
      await tester.pump();
      await tester.pump();

      // Prime a redo entry: place a second riser, then undo it.
      net.placeRiserAt('s1', 0, 500, 3, service: ServiceType.coldWater);
      expect(history.canUndo, isTrue);
      history.undo();
      expect(history.canUndo, isFalse);
      expect(history.canRedo, isTrue);

      // CLICK (down + up, no movement) on the riser: selection follows, but
      // no phantom undo step is pushed and the redo stack survives (F3).
      final point = riserPoint(tester);
      final click = await tester.startGesture(point);
      await click.up();
      await tester.pump();
      expect(container.read(selectionProvider).edgeId, 'r1');
      expect(history.canUndo, isFalse);
      expect(history.canRedo, isTrue);

      // DRAG: the first real movement records exactly ONE undo step for the
      // whole move (and, as any new edit, clears redo).
      final drag = await tester.startGesture(point);
      await drag.moveBy(const Offset(40, 0));
      await drag.moveBy(const Offset(40, 0));
      await drag.up();
      await tester.pump();

      final movedX = container
          .read(networkControllerProvider)
          .network
          .nodeById('lo')!
          .x;
      expect(movedX, isNot(200));
      expect(history.canUndo, isTrue);
      expect(history.canRedo, isFalse);

      // One undo restores the pre-drag position (single step per drag).
      history.undo();
      expect(
        container.read(networkControllerProvider).network.nodeById('lo')!.x,
        200,
      );
      expect(history.canUndo, isFalse);
    });
  });
}
