import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/ui/canvas/edge_context_menu.dart';
import 'package:mechx/ui/canvas/selection_overlay.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

/// The B18/B19/B20/B22/B26/B27/B28 edit-time UX suite: the
/// [NetworkSelectionOverlay] is pumped in isolation on an IDENTITY viewport
/// (no registered sheet transform) so a world coordinate maps 1:1 to a screen
/// tap — mirroring `layer_lock_filter_test.dart`. The [MediaQueryData] size
/// MATCHES `setDesktopSurface`'s real physical view (1280x832) so the
/// context-menu clamping math positions rows within the true viewport (a
/// smaller declared size than the real view mis-clamps a tall scrollable menu
/// off-screen). An [Overlay] ancestor is added (missing from that harness)
/// since these tests also drive the root-overlay context menus.
Widget _host(ProviderContainer c, Widget child) => UncontrolledProviderScope(
      container: c,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(1280, 832)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MechXTheme(
            data: MechXThemeData.dark,
            child: Overlay(initialEntries: [
              OverlayEntry(
                builder: (_) => Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: 600, height: 400, child: child),
                ),
              ),
            ]),
          ),
        ),
      ),
    );

ProviderContainer _boot() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

const _cw = ServiceType.coldWater;

void main() {
  group('B18 trim/extend', () {
    testWidgets(
        'context-menu Trim/Extend arms a pick; clicking the boundary trims '
        'to the intersection', (tester) async {
      setDesktopSurface(tester);
      final c = _boot();
      final ctrl = c.read(networkControllerProvider.notifier);
      // A horizontal run a->m short of a vertical boundary q0-q1 at x=300.
      ctrl.loadNetwork(const Network(nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 50, y: 100, floorIndex: 0),
        NetNode(id: 'm', sheetId: 's1', x: 250, y: 100, floorIndex: 0),
        NetNode(id: 'q0', sheetId: 's1', x: 300, y: 50, floorIndex: 0),
        NetNode(id: 'q1', sheetId: 's1', x: 300, y: 150, floorIndex: 0),
      ], edges: [
        NetEdge(id: 'e1', fromId: 'a', toId: 'm', service: _cw),
        NetEdge(id: 'b1', fromId: 'q0', toId: 'q1', service: _cw),
      ]));

      await tester.pumpWidget(
          _host(c, const NetworkSelectionOverlay(sheetId: 's1', floorIndex: 0)));
      await tester.pump();

      c.read(selectionProvider.notifier).selectEdge('e1');
      await tester.pump();

      // Right-click along the run's body, nearer the 'm' end (250,100) than
      // 'a' (50,100) — but clear of the node's own 13px hit radius, so this
      // hits the RUN (opening the edge menu), not the node.
      final rc = await tester.startGesture(const Offset(220, 100),
          buttons: kSecondaryButton);
      await rc.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Trim/Extend to...'), findsOneWidget);
      await tester.tap(find.text('Trim/Extend to...'));
      await tester.pump();

      expect(c.read(trimExtendArmedProvider), const TrimExtendTarget('e1', 'm'));

      // Click the boundary run at its midpoint (300,100).
      await tester.tapAt(const Offset(300, 100));
      await tester.pump();

      expect(c.read(trimExtendArmedProvider), isNull, reason: 'a pick disarms');
      final net = c.read(networkControllerProvider).network;
      final m = net.nodeById('m')!;
      expect(m.x, closeTo(300, 0.01));
      expect(m.y, closeTo(100, 0.01));
      expect(net.edges.length, 3, reason: 'the boundary is teed at the join');
    });

    testWidgets(
        'a refused pick (parallel boundary) leaves the network untouched and '
        'shows a status toast', (tester) async {
      setDesktopSurface(tester);
      final c = _boot();
      final ctrl = c.read(networkControllerProvider.notifier);
      // e1 (a->m) and the parallel boundary p0-p1 never cross.
      ctrl.loadNetwork(const Network(nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 50, y: 100, floorIndex: 0),
        NetNode(id: 'm', sheetId: 's1', x: 250, y: 100, floorIndex: 0),
        NetNode(id: 'p0', sheetId: 's1', x: 50, y: 140, floorIndex: 0),
        NetNode(id: 'p1', sheetId: 's1', x: 300, y: 140, floorIndex: 0),
      ], edges: [
        NetEdge(id: 'e1', fromId: 'a', toId: 'm', service: _cw),
        NetEdge(id: 'b1', fromId: 'p0', toId: 'p1', service: _cw),
      ]));

      await tester.pumpWidget(
          _host(c, const NetworkSelectionOverlay(sheetId: 's1', floorIndex: 0)));
      await tester.pump();

      // Arm directly (the context-menu row's arming action is covered above).
      c
          .read(trimExtendArmedProvider.notifier)
          .arm(const TrimExtendTarget('e1', 'm'));
      await tester.pump();
      expect(c.read(statusMessageProvider), isNull);

      await tester.tapAt(const Offset(150, 140)); // on the parallel boundary
      await tester.pump();

      expect(c.read(trimExtendArmedProvider), isNull,
          reason: 'a pick disarms even on refusal');
      expect(c.read(statusMessageProvider), isNotNull);
      final m = c.read(networkControllerProvider).network.nodeById('m')!;
      expect(m.x, 250, reason: 'nothing moved on a refused pick');
      // The toast schedules a real self-clearing Timer — settle it so the
      // test doesn't end with a pending timer.
      c.read(statusMessageProvider.notifier).clear();
      expect(m.y, 100);
    });
  });

  group('free run endpoint stretches (extend/trim) instead of pulling', () {
    // A horizontal run a(50,100)->m(250,100); 'm' is the free end (degree-1
    // bare main). Dragging its on-node grip must MOVE 'm' (extend/trim the run),
    // NOT pull a new mainline out (which would keep 'm' put and add a node+edge).
    ProviderContainer bootFreeEnd() {
      final c = _boot();
      c.read(networkControllerProvider.notifier).loadNetwork(const Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 50, y: 100, floorIndex: 0),
          NetNode(id: 'm', sheetId: 's1', x: 250, y: 100, floorIndex: 0),
        ],
        edges: [
          NetEdge(id: 'e1', fromId: 'a', toId: 'm', service: _cw),
        ],
      ));
      return c;
    }

    testWidgets('dragging the free end AWAY extends the run (no new edge)',
        (tester) async {
      setDesktopSurface(tester);
      final c = bootFreeEnd();
      // Select 'm' so the on-node grip is mounted at the endpoint.
      c.read(selectionProvider.notifier).selectNode('m');
      await tester.pumpWidget(
          _host(c, const NetworkSelectionOverlay(sheetId: 's1', floorIndex: 0)));
      await tester.pump();

      // Grab the endpoint (250,100) and drag it out along the run's axis. (The
      // exact px lands short of the raw offset by the gesture pan-slop, so assert
      // direction + magnitude, not an exact coordinate.)
      await tester.dragFrom(const Offset(250, 100), const Offset(100, 0));
      await tester.pump();

      final net = c.read(networkControllerProvider).network;
      expect(net.edges.length, 1, reason: 'stretch must not spawn a new run');
      expect(net.nodes.length, 2, reason: 'no new junction node');
      final m = net.nodeById('m')!;
      expect(m.x, greaterThan(300), reason: 'the endpoint itself moved OUT');
      expect(m.y, closeTo(100, 0.5), reason: 'ortho keeps the run straight');
    });

    testWidgets('dragging the free end BACK trims the run', (tester) async {
      setDesktopSurface(tester);
      final c = bootFreeEnd();
      c.read(selectionProvider.notifier).selectNode('m');
      await tester.pumpWidget(
          _host(c, const NetworkSelectionOverlay(sheetId: 's1', floorIndex: 0)));
      await tester.pump();

      await tester.dragFrom(const Offset(250, 100), const Offset(-90, 0));
      await tester.pump();

      final net = c.read(networkControllerProvider).network;
      expect(net.edges.length, 1);
      final m = net.nodeById('m')!;
      expect(m.x, lessThan(220), reason: 'the run trimmed shorter');
      expect(m.x, greaterThan(60), reason: 'but the endpoint did not merge onto a');
      expect(m.y, closeTo(100, 0.5));
    });

    testWidgets('a lone dropped fitting (degree 0) still PULLS a new run',
        (tester) async {
      setDesktopSurface(tester);
      final c = _boot();
      // A bare main junction with no incident edges — the bootstrap pull point.
      c.read(networkControllerProvider.notifier).loadNetwork(const Network(
        nodes: [NetNode(id: 'f', sheetId: 's1', x: 100, y: 100, floorIndex: 0)],
      ));
      c.read(selectionProvider.notifier).selectNode('f');
      await tester.pumpWidget(
          _host(c, const NetworkSelectionOverlay(sheetId: 's1', floorIndex: 0)));
      await tester.pump();

      await tester.dragFrom(const Offset(100, 100), const Offset(120, 0));
      await tester.pump();

      final net = c.read(networkControllerProvider).network;
      expect(net.edges.length, 1, reason: 'a degree-0 grip still pulls a run');
      final f = net.nodeById('f')!;
      expect(f.x, closeTo(100, 0.5), reason: 'the source node stays put');
    });
  });

  group('B26 window vs crossing marquee', () {
    ProviderContainer bootMarqueeNet() {
      final c = _boot();
      final ctrl = c.read(networkControllerProvider.notifier);
      // 'enclosed' sits fully inside the (0,0)-(200,200) probe rect; 'partial'
      // has only ONE endpoint inside it.
      ctrl.loadNetwork(const Network(nodes: [
        NetNode(id: 'n1', sheetId: 's1', x: 50, y: 50, floorIndex: 0),
        NetNode(id: 'n2', sheetId: 's1', x: 150, y: 50, floorIndex: 0),
        NetNode(id: 'n3', sheetId: 's1', x: 150, y: 150, floorIndex: 0),
        NetNode(id: 'n4', sheetId: 's1', x: 250, y: 150, floorIndex: 0),
      ], edges: [
        NetEdge(id: 'enclosed', fromId: 'n1', toId: 'n2', service: _cw),
        NetEdge(id: 'partial', fromId: 'n3', toId: 'n4', service: _cw),
      ]));
      return c;
    }

    testWidgets('left-to-right (window): only the fully-enclosed run/nodes',
        (tester) async {
      setDesktopSurface(tester);
      final c = bootMarqueeNet();
      await tester.pumpWidget(
          _host(c, const NetworkSelectionOverlay(sheetId: 's1', floorIndex: 0)));
      await tester.pump();

      await tester.dragFrom(const Offset(0, 0), const Offset(200, 200));
      await tester.pump();

      final sel = c.read(selectionProvider);
      expect(sel.nodeIds, {'n1', 'n2', 'n3'});
      expect(sel.edgeIds, {'enclosed'},
          reason: 'partial only has n3 inside — excluded by a window');
    });

    testWidgets('right-to-left (crossing): also the merely-touched run',
        (tester) async {
      setDesktopSurface(tester);
      final c = bootMarqueeNet();
      await tester.pumpWidget(
          _host(c, const NetworkSelectionOverlay(sheetId: 's1', floorIndex: 0)));
      await tester.pump();

      await tester.dragFrom(const Offset(200, 200), const Offset(-200, -200));
      await tester.pump();

      final sel = c.read(selectionProvider);
      expect(sel.nodeIds, {'n1', 'n2', 'n3'});
      expect(sel.edgeIds, {'enclosed', 'partial'},
          reason: 'a crossing selects a run it merely touches');
    });
  });

  group('B27 match properties', () {
    testWidgets(
        'the brush applies the source run\'s size override + material to a '
        'clicked run of the same discipline family', (tester) async {
      setDesktopSurface(tester);
      final c = _boot();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(Network(nodes: const [
        NetNode(id: 'sa', sheetId: 's1', x: 50, y: 50, floorIndex: 0),
        NetNode(id: 'sb', sheetId: 's1', x: 150, y: 50, floorIndex: 0),
        NetNode(id: 'ta', sheetId: 's1', x: 50, y: 150, floorIndex: 0),
        NetNode(id: 'tb', sheetId: 's1', x: 150, y: 150, floorIndex: 0),
      ], edges: [
        NetEdge(
          id: 'src',
          fromId: 'sa',
          toId: 'sb',
          service: _cw,
          sizeOverride: Diameter.mm(50),
          pipeProduct: PipeProduct.pprPn16,
        ),
        const NetEdge(id: 'tgt', fromId: 'ta', toId: 'tb', service: _cw),
      ]));

      await tester.pumpWidget(
          _host(c, const NetworkSelectionOverlay(sheetId: 's1', floorIndex: 0)));
      await tester.pump();

      // Right-click the source run (midpoint 100,50) → 'Match properties'.
      final rc = await tester.startGesture(const Offset(100, 50),
          buttons: kSecondaryButton);
      await rc.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Match properties'), findsOneWidget);
      // The size-ladder-heavy menu scrolls; bring the row into view first.
      await tester.ensureVisible(find.text('Match properties'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Match properties'));
      await tester.pump();

      expect(c.read(matchPropertiesArmedProvider)?.sourceEdgeId, 'src');

      // Click the target run at its midpoint (100,150). The brush differs in
      // size AND material AND service, but the whole application must land as
      // ONE undo step (historyProvider is a monotone counter, +1 per commit).
      final beforeSteps = c.read(historyProvider);
      await tester.tapAt(const Offset(100, 150));
      await tester.pump();

      final tgt = c.read(networkControllerProvider).network.edgeById('tgt')!;
      expect(tgt.sizeOverride?.inMillimeters, closeTo(50, 0.01));
      expect(tgt.pipeProduct, PipeProduct.pprPn16);
      expect(c.read(historyProvider) - beforeSteps, 1,
          reason: 'match-properties must be one undo step, not three');
      // A brush, not a one-shot pick: it stays armed for the next click.
      expect(c.read(matchPropertiesArmedProvider), isNotNull);
    });
  });

  group('B28 hover measurement chip', () {
    testWidgets('appears after the wait window on a hovered elevation node',
        (tester) async {
      setDesktopSurface(tester);
      final c = _boot();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(const Network(nodes: [
        NetNode(id: 'n', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
      ]));

      await tester.pumpWidget(
          _host(c, const NetworkSelectionOverlay(sheetId: 's1', floorIndex: 0)));
      await tester.pump();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(const Offset(100, 100));
      await tester.pump();

      // Short of the ~500ms wait: still hidden.
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('FFL'), findsNothing);

      // Past the wait window: the chip is up.
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('FFL'), findsOneWidget);
    });

    testWidgets('suppressed while a canvas gesture is live', (tester) async {
      setDesktopSurface(tester);
      final c = _boot();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.loadNetwork(const Network(nodes: [
        NetNode(id: 'n', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
      ]));

      await tester.pumpWidget(
          _host(c, const NetworkSelectionOverlay(sheetId: 's1', floorIndex: 0)));
      await tester.pump();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(const Offset(100, 100));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('FFL'), findsOneWidget);

      // A live gesture elsewhere on the overlay suppresses it.
      c.read(canvasGestureActiveProvider.notifier).set(true);
      await tester.pump();
      expect(find.textContaining('FFL'), findsNothing);
    });
  });
}
