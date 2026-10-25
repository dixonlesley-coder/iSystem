/// Riser drafting-feel batch (2026-10-20) — interaction + frame-cost contract
/// of the two Riser canvases (Auto diagram + Edit elevation).
///
/// * R1 — a pan / zoom frame on the Auto riser re-lays-out and repaints
///   NOTHING: the painter instance is reused under a RepaintBoundary and only
///   the Transform moves; the view-state watchers never hear about it.
/// * P1 — the inferred-riser hover hit test reads the painter's memoized list.
/// * K1 — the F1 sheet's canvas view keys work on both Riser canvases
///   (F / Ctrl +-0 / arrows / hold Space), Edit adds Ctrl+A + arrow nudge, and
///   the shared fit bump frames them.
/// * R2 — Delete removes EVERY selected riser in one undo step.
/// * R3 — a riser drag needs to clear the pan slop, is ONE undo step, and the
///   riser menu offers 'Reset position'.
/// * R4 — the Edit frame grows to hold a riser drawn past x = 1200.
/// * R6 — Edit riser tags never overprint each other; run tags hide below the
///   LOD scale.
/// * V1/V2 — programmatic viewport changes ease, chips route through
///   MechXMotion.resolve (reduced motion ⇒ instant).
/// * V3 — the legend / title block are flat drawing content, never glass.
/// * V4/V5 — honest cursors and the window / crossing marquee.
///
/// Pinned by identity / counts, never wall-clock.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart' show projectDirtyProvider;
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/schematic_layout_store.dart';
import 'package:mechx/store/schematic_view_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/ui/canvas/canvas_view.dart' show canvasFitRequestProvider;
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx/ui/schematic/schematic_view.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/glass_surface.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

// Default project = 3 levels; the Edit elevation's bands are 160 world px, so
// floor 0's centre is y 400, floor 1's 240, floor 2's 80.
NetNode _n(String id, double x, int floor,
        {NodeRole role = NodeRole.main, NodeComponent? component}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: floor,
        role: role,
        component: component);

NetEdge _riser(String id, String a, String b,
        {ServiceType s = ServiceType.coldWater}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: EdgeKind.riser);

NetEdge _run(String id, String a, String b,
        {ServiceType s = ServiceType.coldWater}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s);

/// Two cold-water risers fed from a source on the ground floor.
final _twoRisers = Network(nodes: [
  _n('src', 60, 0, role: NodeRole.plant, component: NodeComponent.groundTank),
  _n('r1lo', 200, 0),
  _n('r1hi', 200, 1),
  _n('r2lo', 500, 1),
  _n('r2hi', 500, 2),
  _n('fx', 520, 2, role: NodeRole.fixture),
], edges: [
  _run('m0', 'src', 'r1lo'),
  _riser('r1', 'r1lo', 'r1hi'),
  _run('m1', 'r1hi', 'r2lo'),
  _riser('r2', 'r2lo', 'r2hi'),
  _run('m2', 'r2hi', 'fx'),
]);

Widget _harness(ProviderContainer c, {bool disableAnimations = false}) =>
    UncontrolledProviderScope(
      container: c,
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(
                size: const Size(1200, 800),
                disableAnimations: disableAnimations),
            child: SizedBox(
              width: 1200,
              height: 800,
              child: Overlay(initialEntries: [
                OverlayEntry(builder: (_) => const SchematicView()),
              ]),
            ),
          ),
        ),
      ),
    );

Future<ProviderContainer> _pump(WidgetTester tester, Network net,
    {SchematicMode mode = SchematicMode.auto,
    bool disableAnimations = false}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  c.read(schematicViewProvider.notifier).setMode(mode);
  await tester.pumpWidget(_harness(c, disableAnimations: disableAnimations));
  await tester.pump();
  await tester.pump(); // the Edit canvas frames itself post-frame
  return c;
}

Finder get _autoPaint => find.byWidgetPredicate((w) =>
    w is CustomPaint &&
    w.painter?.runtimeType.toString() == '_AutoSchematicPainter');

Rect _editCanvasRect(WidgetTester tester) => tester.getRect(find.byWidgetPredicate(
    (w) => w is Focus && w.focusNode?.debugLabel == 'elevation-canvas'));

/// Global position of the world point [world] on the Edit elevation.
Offset _editGlobal(WidgetTester tester, ProviderContainer c, Offset world) =>
    _editCanvasRect(tester).topLeft +
    c.read(schematicEditViewportProvider)!.worldToScreen(world);

double _diagramX(ProviderContainer c, String nodeId) {
  final n = c.read(networkControllerProvider).network.nodeById(nodeId)!;
  return c.read(schematicLayoutProvider).xFor(n);
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key,
    {bool ctrl = false}) async {
  if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  group('R1 / P1 — Auto riser frame cost', () {
    testWidgets(
        'N wheel + pan frames: zero diagram repaints, the SAME painter, and '
        'no view-state notification', (tester) async {
      final c = await _pump(tester, _twoRisers);
      final painter = tester.widget<CustomPaint>(_autoPaint).painter;
      final paints = debugAutoRiserPaintCount;
      final tags = c.read(riserTagsProvider(null));
      var viewStateNotifications = 0;
      c.listen(schematicViewProvider, (_, _) => viewStateNotifications++);

      final centre = tester.getCenter(_autoPaint);
      final mouse = TestPointer(7, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(centre));
      for (var i = 0; i < 10; i++) {
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, -40)));
        await tester.pump();
      }
      final pan = await tester.startGesture(centre,
          kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
      for (var i = 0; i < 5; i++) {
        await pan.moveBy(const Offset(12, 7));
        await tester.pump();
      }
      await pan.up();
      await tester.pump();

      final vt = c.read(schematicAutoViewportProvider);
      expect(vt, isNotNull);
      expect(vt!.scale, greaterThan(1.0), reason: 'the wheel zoomed in');
      expect(debugAutoRiserPaintCount, paints,
          reason: 'a pan / zoom frame must not repaint the diagram');
      expect(identical(tester.widget<CustomPaint>(_autoPaint).painter, painter),
          isTrue,
          reason: 'the painter (and its memoized layout) is reused');
      expect(viewStateNotifications, 0);
      expect(identical(c.read(riserTagsProvider(null)), tags), isTrue);
    });

    testWidgets('with Infer risers on, hovering never repaints and reads the '
        'memoized inferred list', (tester) async {
      // Two cold-water nodes stacked on floors 0 / 1 with NO drawn riser.
      final net = Network(nodes: [
        _n('a', 100, 0),
        _n('b', 300, 0),
        _n('c', 100, 1),
        _n('d', 300, 1),
      ], edges: [
        _run('ab', 'a', 'b'),
        _run('cd', 'c', 'd'),
      ]);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(schematicViewProvider.notifier).setInferRisers(true);
      c.read(networkControllerProvider.notifier).loadNetwork(net);
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_harness(c));
      await tester.pump();

      final paint = tester.widget<CustomPaint>(_autoPaint);
      final size = tester.getSize(_autoPaint);
      final first = autoSchematicInferredRisers(paint.painter, size)!;
      expect(first, isNotEmpty);
      final paints = debugAutoRiserPaintCount;
      final mouse = TestPointer(8, PointerDeviceKind.mouse);
      final rect = tester.getRect(_autoPaint);
      for (var i = 0; i < 12; i++) {
        await tester.sendEventToBinding(
            mouse.hover(rect.topLeft + Offset(40.0 + i * 60, 300)));
        await tester.pump();
      }
      expect(debugAutoRiserPaintCount, paints);
      expect(
          identical(
              autoSchematicInferredRisers(
                  tester.widget<CustomPaint>(_autoPaint).painter, size),
              first),
          isTrue,
          reason: 'P1: one inferred list per (inputs, size)');
    });
  });

  group('R5 — tall buildings lay out at a legible band height', () {
    testWidgets('a short building keeps the identity framing; a 30-storey one '
        'lays out taller than the window and Fit frames it', (tester) async {
      final c = await _pump(tester, _twoRisers);
      final canvas = tester.getSize(find.byWidgetPredicate((w) =>
          w is Focus && w.focusNode?.debugLabel == 'riser-auto-canvas'));
      expect(tester.getSize(_autoPaint), canvas,
          reason: 'world == viewport: the at-rest render is unchanged');
      expect(c.read(schematicAutoViewportProvider), isNull);

      c.read(projectControllerProvider.notifier).setFloors([
        for (var i = 0; i < 30; i++) Floor('L$i', const Length(3.5)),
      ]);
      await tester.pump();
      final world = tester.getSize(_autoPaint);
      expect(world.height, greaterThanOrEqualTo(30 * kAutoRiserMinBandWorldH));
      // Zoom in, then F frames the whole (taller) world inside the window.
      await _key(tester, LogicalKeyboardKey.equal, ctrl: true);
      await tester.pumpAndSettle();
      await _key(tester, LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      final vt = c.read(schematicAutoViewportProvider)!;
      expect(world.height * vt.scale, lessThanOrEqualTo(800));
    });
  });

  group('K1 / V1 — Auto riser view keys', () {
    testWidgets('Ctrl+= zooms 1.2x about the centre (eased), F fits, an arrow '
        'pans 64 px, the shared fit bump frames it', (tester) async {
      final c = await _pump(tester, _twoRisers);
      await tester.tap(_autoPaint);
      await tester.pump();

      await _key(tester, LogicalKeyboardKey.equal, ctrl: true);
      // V1: eased — mid-flight the scale is between the two framings.
      await tester.pump(const Duration(milliseconds: 60));
      final mid = c.read(schematicAutoViewportProvider)!.scale;
      expect(mid, greaterThan(1.0));
      expect(mid, lessThan(1.2));
      await tester.pumpAndSettle();
      expect(c.read(schematicAutoViewportProvider)!.scale, closeTo(1.2, 1e-9));

      await _key(tester, LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(c.read(schematicAutoViewportProvider), const ViewportTransform());

      await _key(tester, LogicalKeyboardKey.arrowLeft);
      expect(c.read(schematicAutoViewportProvider)!.offset, const Offset(64, 0));

      c.read(canvasFitRequestProvider.notifier).request();
      await tester.pumpAndSettle();
      expect(c.read(schematicAutoViewportProvider), const ViewportTransform());
    });

    testWidgets('V1: with reduced motion a zoom button applies at once',
        (tester) async {
      final c = await _pump(tester, _twoRisers, disableAnimations: true);
      await tester.tap(find.text('+'));
      await tester.pump();
      expect(c.read(schematicAutoViewportProvider)!.scale, closeTo(1.2, 1e-9));
    });
  });

  group('K1 / R2 — Riser Edit keyboard', () {
    testWidgets('Ctrl+A selects every riser; Delete removes them ALL (one undo '
        'step) and prunes their bare endpoints', (tester) async {
      final net = Network(nodes: [
        _n('a0', 200, 0),
        _n('a1', 200, 1),
        _n('b0', 500, 0),
        _n('b1', 500, 1),
      ], edges: [
        _riser('ra', 'a0', 'a1'),
        _riser('rb', 'b0', 'b1'),
      ]);
      final c = await _pump(tester, net, mode: SchematicMode.edit);
      await _key(tester, LogicalKeyboardKey.keyA, ctrl: true);
      expect(c.read(selectionProvider).edgeIds, {'ra', 'rb'});

      await _key(tester, LogicalKeyboardKey.delete);
      final after = c.read(networkControllerProvider).network;
      expect(after.edges, isEmpty, reason: 'R2: both risers deleted');
      expect(after.nodes, isEmpty, reason: 'orphaned riser ends pruned');

      c.read(historyProvider.notifier).undo();
      final restored = c.read(networkControllerProvider).network;
      expect(restored.edges.map((e) => e.id).toSet(), {'ra', 'rb'},
          reason: 'one undo restores the whole delete');
      expect(restored.nodes, hasLength(4));
    });

    testWidgets('an arrow NUDGES the selected risers on the diagram (one undo '
        'step each); with nothing selected it pans', (tester) async {
      final c = await _pump(tester, _twoRisers, mode: SchematicMode.edit);
      final scale = c.read(schematicEditViewportProvider)!.scale;
      await _key(tester, LogicalKeyboardKey.keyA, ctrl: true);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(_diagramX(c, 'r1lo'), closeTo(200 + 8 / scale, 1e-9));
      expect(_diagramX(c, 'r1hi'), closeTo(200 + 8 / scale, 1e-9));
      expect(_diagramX(c, 'r2lo'), closeTo(500 + 8 / scale, 1e-9));
      expect(c.read(networkControllerProvider).network.nodeById('r1lo')!.x, 200,
          reason: 'the plan never moves');
      c.read(historyProvider.notifier).undo();
      expect(_diagramX(c, 'r1lo'), 200);

      await _key(tester, LogicalKeyboardKey.escape); // clear the selection
      final before = c.read(schematicEditViewportProvider)!;
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(c.read(schematicEditViewportProvider),
          before.panned(const Offset(-64, 0)));
      expect(c.read(schematicLayoutProvider).isEmpty, isTrue);
    });

    testWidgets('hold Space + left-drag pans (no marquee, no selection change); '
        'Ctrl+0 is 100 %; the fit bump re-frames', (tester) async {
      final c = await _pump(tester, _twoRisers, mode: SchematicMode.edit);
      final before = c.read(schematicEditViewportProvider)!;
      final blank = _editGlobal(tester, c, const Offset(900, 60));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      final g = await tester.startGesture(blank, kind: PointerDeviceKind.mouse);
      await g.moveBy(const Offset(50, 30));
      await tester.pump();
      await g.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(c.read(schematicEditViewportProvider),
          before.panned(const Offset(50, 30)));
      expect(c.read(selectionProvider).hasSelection, isFalse);

      await _key(tester, LogicalKeyboardKey.digit0, ctrl: true);
      await tester.pumpAndSettle();
      expect(c.read(schematicEditViewportProvider)!.scale, 1.0);

      c.read(canvasFitRequestProvider.notifier).request();
      await tester.pumpAndSettle();
      expect(c.read(schematicEditViewportProvider)!.scale,
          closeTo(before.scale, 1e-9));
    });
  });

  group('R3 — riser drag: slop, undo, reset', () {
    testWidgets('a 1 px jitter never moves the riser; a real drag is ONE undo '
        'step; the menu resets it (undoable too)', (tester) async {
      final c = await _pump(tester, _twoRisers, mode: SchematicMode.edit);
      final leg = _editGlobal(tester, c, const Offset(200, 320));
      final history = c.read(historyProvider.notifier);

      final jitter = await tester.startGesture(leg, kind: PointerDeviceKind.mouse);
      await jitter.moveBy(const Offset(1, 0));
      await tester.pump();
      await jitter.up();
      await tester.pump();
      expect(c.read(selectionProvider).edgeIds, {'r1'});
      expect(c.read(schematicLayoutProvider).isEmpty, isTrue,
          reason: 'below the pan slop a press is a click');
      expect(history.canUndo, isFalse);

      final drag = await tester.startGesture(leg, kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 6; i++) {
        await drag.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      await drag.up();
      await tester.pump();
      final scale = c.read(schematicEditViewportProvider)!.scale;
      expect(_diagramX(c, 'r1lo'), closeTo(200 + 60 / scale, 1e-6),
          reason: 'measured from the press — crossing the slop never jumps');
      expect(history.canUndo, isTrue);

      // Right-click the moved riser: 'Reset position' returns it to plan x.
      final moved = _editGlobal(tester, c, Offset(_diagramX(c, 'r1lo'), 320));
      await tester.tapAt(moved,
          buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.tap(find.text('Reset position'));
      await tester.pump();
      expect(_diagramX(c, 'r1lo'), 200);
      // Undo the reset (back to the dragged x), then undo the drag.
      history.undo();
      expect(_diagramX(c, 'r1lo'), closeTo(200 + 60 / scale, 1e-6));
      history.undo();
      expect(_diagramX(c, 'r1lo'), 200);
      expect(history.canUndo, isFalse);
    });

    testWidgets("'Reset position' is offered only for a moved riser",
        (tester) async {
      final c = await _pump(tester, _twoRisers, mode: SchematicMode.edit);
      await tester.tapAt(_editGlobal(tester, c, const Offset(200, 320)),
          buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(find.text('Reset position'), findsNothing);
      expect(find.text('Delete riser'), findsOneWidget);
    });
  });

  group('R4 — the Edit frame holds every riser', () {
    testWidgets('a riser drawn at plan x 2400 sits inside Fit and the floor '
        'lines', (tester) async {
      final net = Network(nodes: [
        _n('a0', 200, 0),
        _n('a1', 200, 1),
        _n('far0', 2400, 0),
        _n('far1', 2400, 1),
      ], edges: [
        _riser('ra', 'a0', 'a1'),
        _riser('rf', 'far0', 'far1'),
      ]);
      final c = await _pump(tester, net, mode: SchematicMode.edit);
      final canvas = _editCanvasRect(tester);
      final x = c
          .read(schematicEditViewportProvider)!
          .worldToScreen(const Offset(2400, 320))
          .dx;
      expect(x, greaterThan(0));
      expect(x, lessThan(canvas.width), reason: 'R4: inside the fitted frame');
    });
  });

  group('R6 — Edit labels', () {
    testWidgets('two risers side by side: their tags never overprint, none is '
        'dropped', (tester) async {
      final net = Network(nodes: [
        _n('a0', 200, 0),
        _n('a1', 200, 1),
        _n('b0', 204, 0),
        _n('b1', 204, 1),
        _n('c0', 208, 0),
        _n('c1', 208, 1),
      ], edges: [
        _riser('ra', 'a0', 'a1'),
        _riser('rb', 'b0', 'b1'),
        _riser('rc', 'c0', 'c1'),
      ]);
      await _pump(tester, net, mode: SchematicMode.edit);
      final tags = [
        for (final t in debugEditTagRects)
          if (t.riser) t.rect,
      ];
      expect(tags, hasLength(3));
      for (var i = 0; i < tags.length; i++) {
        for (var j = i + 1; j < tags.length; j++) {
          expect(tags[i].overlaps(tags[j]), isFalse,
              reason: 'tag $i vs $j overprint');
        }
      }
    });

    testWidgets('run tags hide below the LOD scale, riser tags never do',
        (tester) async {
      final c = await _pump(tester, _twoRisers, mode: SchematicMode.edit);
      c
          .read(schematicEditViewportProvider.notifier)
          .set(const ViewportTransform(scale: 1));
      await tester.pump();
      expect(debugEditTagRects.where((t) => !t.riser), isNotEmpty);
      c
          .read(schematicEditViewportProvider.notifier)
          .set(const ViewportTransform(scale: kEditRunLabelMinScale * 0.8));
      await tester.pump();
      expect(debugEditTagRects.where((t) => !t.riser), isEmpty);
      expect(debugEditTagRects.where((t) => t.riser), hasLength(2));
    });
  });

  group('V5 — window vs crossing marquee', () {
    final net = Network(nodes: [
      _n('a0', 100, 0),
      _n('a1', 100, 1),
    ], edges: [
      _riser('ra', 'a0', 'a1'),
    ]);
    // Identity worldOf: the leg runs (100, 240) .. (100, 400).
    Offset worldOf(NetNode n) => Offset(n.x, n.floorIndex == 0 ? 400 : 240);

    test('a window needs the whole leg; a crossing only a touch', () {
      const touching = Rect.fromLTRB(50, 300, 150, 500);
      const enclosing = Rect.fromLTRB(50, 200, 150, 500);
      expect(riserIdsInScreenRect(net, touching, window: true, worldOf: worldOf),
          isEmpty);
      expect(
          riserIdsInScreenRect(net, enclosing, window: true, worldOf: worldOf),
          {'ra'});
      expect(
          riserIdsInScreenRect(net, touching, window: false, worldOf: worldOf),
          {'ra'});
    });

    testWidgets('a left-to-right drag that only touches selects nothing; the '
        'same box right-to-left selects', (tester) async {
      final c = await _pump(tester, _twoRisers, mode: SchematicMode.edit);
      c
          .read(schematicEditViewportProvider.notifier)
          .set(const ViewportTransform());
      await tester.pump();
      final o = _editCanvasRect(tester).topLeft;
      // Riser r1's leg: x 200, y 240 .. 400 (identity view).
      Future<void> band(Offset a, Offset b) async {
        final g = await tester.startGesture(o + a, kind: PointerDeviceKind.mouse);
        await g.moveTo(o + b);
        await tester.pump();
        await g.up();
        await tester.pump();
      }

      await band(const Offset(150, 300), const Offset(260, 460));
      expect(c.read(selectionProvider).edgeIds, isEmpty);
      await band(const Offset(260, 460), const Offset(150, 300));
      expect(c.read(selectionProvider).edgeIds, {'r1'});
    });
  });

  group('V2 / V3 / V4 — motion gate, flat annotations, cursors', () {
    testWidgets('V2: with reduced motion the Riser toolbar chips are instant',
        (tester) async {
      await _pump(tester, _twoRisers, disableAnimations: true);
      // The riser-owned chips (a service filter chip and the checkbox toggle):
      // the NEAREST animated wrapper of each label is the chip's own.
      Duration nearest<T extends ImplicitlyAnimatedWidget>(String label) =>
          tester
              .widget<T>(find
                  .ancestor(of: find.text(label).first, matching: find.byType(T))
                  .first)
              .duration;
      expect(nearest<AnimatedContainer>('Cold water'), Duration.zero);
      expect(nearest<AnimatedDefaultTextStyle>('Cold water'), Duration.zero);
      expect(nearest<AnimatedContainer>('Infer risers'), Duration.zero);
    });

    testWidgets('V3: the legend and title block are not Liquid Glass',
        (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(schematicViewProvider.notifier)
        ..setShowLegend(true)
        ..setShowTitleBlock(true);
      c.read(networkControllerProvider.notifier).loadNetwork(_twoRisers);
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_harness(c));
      await tester.pump();
      for (final text in ['FITTINGS', 'Untitled project']) {
        expect(find.text(text), findsOneWidget);
        expect(
            find.ancestor(
                of: find.text(text), matching: find.byType(GlassSurface)),
            findsNothing,
            reason: '$text sits on drawing content (golden rule 8)');
      }
    });

    testWidgets('V4: move cursor over a riser, basic on blank canvas, grab '
        'while Space is held', (tester) async {
      final c = await _pump(tester, _twoRisers, mode: SchematicMode.edit);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: _editGlobal(tester, c, const Offset(900, 60)));
      await tester.pump();
      MouseCursor cursor() =>
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1)!;
      expect(cursor(), SystemMouseCursors.basic);
      await mouse.moveTo(_editGlobal(tester, c, const Offset(200, 320)));
      await tester.pump();
      expect(cursor(), SystemMouseCursors.resizeLeftRight);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(cursor(), SystemMouseCursors.grab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await mouse.removePointer();
    });
  });

  group('R3 — the riser-layout undo domain', () {
    test('a gesture that ends where it began records nothing; a real one is '
        'one step that never dirties the project; a document reset clears it',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final layout = c.read(schematicLayoutProvider.notifier);
      final history = c.read(historyProvider.notifier);

      layout.beginGesture();
      layout.setNodesX({'a': 10});
      layout.setNodesX({'a': 0});
      layout.clearNodes(['a']);
      layout.endGesture();
      expect(history.canUndo, isFalse, reason: 'a net no-op is not an entry');

      layout.beginGesture();
      layout.setNodesX({'a': 10, 'b': 10});
      layout.setNodesX({'a': 30, 'b': 30});
      layout.endGesture();
      expect(history.canUndo, isTrue);
      expect(c.read(projectDirtyProvider), isFalse);
      history.undo();
      expect(c.read(schematicLayoutProvider).isEmpty, isTrue);
      history.redo();
      expect(c.read(schematicLayoutProvider).schematicXOverrides,
          {'a': 30.0, 'b': 30.0});

      // An unchanged reset is not an entry either.
      layout.resetNodes(['zzz']);
      layout.resetNodes(['a', 'b']);
      expect(c.read(schematicLayoutProvider).isEmpty, isTrue);
      expect(layout.canUndo, isTrue);

      history.reset();
      expect(layout.canUndo, isFalse);
      expect(layout.canRedo, isFalse);
    });
  });
}
