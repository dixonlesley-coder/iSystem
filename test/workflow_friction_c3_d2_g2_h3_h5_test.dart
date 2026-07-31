/// WORKFLOW-FRICTION-REVIEW batch — C3 (cross-sheet/inert edit guard), D2
/// (arrow-nudge coalescing), F3 (the tool cluster follows the DRAW section),
/// F4 (the export gate names the offending sheets), G2 (the duplicate water
/// warning), H3 (cancelled vs nothing-to-export) and H5 (the laid drainage
/// slope reaching the drawings).
///
/// Expected values are derived in the comment above each assertion, or read
/// back from the engine's own primitives where the test is orchestration-level.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/air_warnings_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/inspector_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/selection_scope.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/ui/canvas/canvas_tool_cluster.dart';
import 'package:mechx/ui/canvas/network_layer.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/plan_symbols.dart' show gravitySlopeLabel;
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

/// Capture a live [WidgetRef] against a minimal ProviderScope — the harness the
/// export tests use (the export helpers take a WidgetRef).
Future<WidgetRef> _refHarness(WidgetTester tester) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    ProviderScope(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Consumer(builder: (context, ref, _) {
          captured = ref;
          return const SizedBox.shrink();
        }),
      ),
    ),
  );
  await tester.pump();
  return captured;
}

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

void main() {
  // ═══════════════════════════════════════════════════════════════════════════
  // C3 — the scope precondition (pure).
  // ═══════════════════════════════════════════════════════════════════════════
  group('C3 scopeSelection', () {
    // Two cold-water runs: `e1` on sheet s1, `e2` on sheet s2 — the exact
    // shape the finding describes (the selection outliving a sheet switch).
    const nodes = [
      NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
      NetNode(id: 'b', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
      NetNode(id: 'c', sheetId: 's2', x: 0, y: 0, floorIndex: 1),
      NetNode(id: 'd', sheetId: 's2', x: 100, y: 0, floorIndex: 1),
    ];
    const edges = [
      NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      NetEdge(id: 'e2', fromId: 'c', toId: 'd', service: ServiceType.duct),
    ];
    const net = Network(nodes: nodes, edges: edges);

    test('members on another sheet are excluded and counted', () {
      final scope = scopeSelection(
        net: net,
        nodeIds: {'a', 'c'},
        edgeIds: {'e1', 'e2'},
        sheetId: 's1',
      );
      expect(scope.nodeIds, {'a'});
      expect(scope.edgeIds, {'e1'});
      // One node (c) + one edge (e2) live on s2.
      expect(scope.excludedCount, 2);
      expect(scope.hasExcluded, isTrue);
    });

    test('members on an INERT (hidden / locked) service are excluded', () {
      final scope = scopeSelection(
        net: net,
        nodeIds: {'a'},
        edgeIds: {'e1'},
        sheetId: 's1',
        inertServices: const {ServiceType.coldWater},
      );
      // The run is inert, and node `a` is inert too — its ONLY incident edge is
      // the inert one (the `_nodeInert` rule the canvas hit-test uses).
      expect(scope.isEmpty, isTrue);
      expect(scope.excludedCount, 2);
    });

    test('a FREE (unwired) node is never inert — loose equipment survives', () {
      const free = NetNode(id: 'f', sheetId: 's1', x: 5, y: 5, floorIndex: 0);
      const withFree =
          Network(nodes: [...nodes, free], edges: edges);
      final scope = scopeSelection(
        net: withFree,
        nodeIds: {'f'},
        edgeIds: const {},
        sheetId: 's1',
        inertServices: const {ServiceType.coldWater, ServiceType.duct},
      );
      expect(scope.nodeIds, {'f'});
      expect(scope.excludedCount, 0);
    });

    test('everything on the current sheet with nothing inert is byte-identical',
        () {
      final scope = scopeSelection(
        net: net,
        nodeIds: {'a', 'b'},
        edgeIds: {'e1'},
        sheetId: 's1',
      );
      expect(scope.nodeIds, {'a', 'b'});
      expect(scope.edgeIds, {'e1'});
      expect(scope.hasExcluded, isFalse);
    });

    test('owningSheetIfElsewhere names the sheet only when it is another one',
        () {
      expect(
          owningSheetIfElsewhere(net, edgeId: 'e2', currentSheetId: 's1'), 's2');
      expect(owningSheetIfElsewhere(net, edgeId: 'e1', currentSheetId: 's1'),
          isNull);
      expect(
          owningSheetIfElsewhere(net, nodeId: 'c', currentSheetId: 's1'), 's2');
      // An id that no longer resolves never invents a sheet.
      expect(owningSheetIfElsewhere(net, nodeId: 'gone', currentSheetId: 's1'),
          isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // C3 (canvas half) — Delete never fires across sheets.
  // ═══════════════════════════════════════════════════════════════════════════
  testWidgets('C3: Delete leaves the off-sheet half of a selection alone',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final c = _containerOf(tester);
    seedDemoSheets(c);
    await tester.pump();

    final sheets = c.read(sheetsControllerProvider).sheets;
    expect(sheets.length, greaterThanOrEqualTo(2));
    final here = sheets.first.id;
    final elsewhere = sheets[1].id;

    // One run on the CURRENT sheet and one on another — both selected, the
    // state a sheet switch leaves behind.
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
          NetNode(id: 'a', sheetId: here, x: 10, y: 10, floorIndex: 0),
          NetNode(id: 'b', sheetId: here, x: 90, y: 10, floorIndex: 0),
          NetNode(id: 'c', sheetId: elsewhere, x: 10, y: 10, floorIndex: 1),
          NetNode(id: 'd', sheetId: elsewhere, x: 90, y: 10, floorIndex: 1),
        ], edges: const [
          NetEdge(
              id: 'here', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
          NetEdge(
              id: 'away', fromId: 'c', toId: 'd', service: ServiceType.coldWater),
        ]));
    c.read(sheetsControllerProvider.notifier).selectSheetById(here);
    c
        .read(selectionProvider.notifier)
        .setMulti(const {}, const {'here', 'away'});
    await tester.pump();

    // The canvas owns Delete; give it focus by tapping the canvas area first.
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();

    final ids =
        c.read(networkControllerProvider).network.edges.map((e) => e.id).toSet();
    // The current sheet's run is gone; the OTHER sheet's run survives — the
    // silent cross-sheet deletion the finding describes cannot happen.
    expect(ids.contains('away'), isTrue,
        reason: 'the off-sheet run must not be deleted');
    expect(ids.contains('here'), isFalse);
    // ...and the engineer is TOLD what was left alone.
    expect(c.read(statusMessageProvider), isNotNull);
    expect(c.read(statusMessageProvider), contains('not deleted'));
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // D2 — one undo step per arrow-nudge burst.
  // ═══════════════════════════════════════════════════════════════════════════
  testWidgets('D2: a burst of arrow nudges collapses into ONE undo step',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final c = _containerOf(tester);
    seedDemoSheets(c);
    await tester.pump();

    final ctrl = c.read(networkControllerProvider.notifier);
    final sheet = c.read(sheetsControllerProvider).current!;
    ctrl.addSegment(sheet.id, 0, const Offset(400, 400),
        service: ServiceType.coldWater);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(c.read(selectionProvider).nodeIds.length, 2);

    final before = {
      for (final n in c.read(networkControllerProvider).network.nodes)
        n.id: Offset(n.x, n.y),
    };

    // FIVE nudges inside the idle window — one burst.
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 40));
    }
    final moved = {
      for (final n in c.read(networkControllerProvider).network.nodes)
        n.id: Offset(n.x, n.y),
    };
    for (final id in before.keys) {
      expect(moved[id]!.dx, greaterThan(before[id]!.dx));
    }

    // ONE undo restores the whole burst (it used to take five).
    ctrl.undo();
    for (final n in c.read(networkControllerProvider).network.nodes) {
      expect(n.x, closeTo(before[n.id]!.dx, 1e-6));
      expect(n.y, closeTo(before[n.id]!.dy, 1e-6));
    }

    // Let the burst expire, then nudge again: a NEW step (not folded into the
    // expired one), so a later undo is still available for it.
    await tester.pump(const Duration(milliseconds: 900));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    ctrl.undo();
    for (final n in c.read(networkControllerProvider).network.nodes) {
      expect(n.x, closeTo(before[n.id]!.dx, 1e-6));
    }
    // Drain the pending burst timer so the test ends with no live timer.
    await tester.pump(const Duration(milliseconds: 900));
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // F3 — the tool cluster follows the DRAW section, not just the inspector.
  // ═══════════════════════════════════════════════════════════════════════════
  testWidgets('F3: the on-canvas tool cluster mounts once DRAW is collapsed',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final c = _containerOf(tester);
    seedDemoSheets(c);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Empty project: DRAW defaults EXPANDED (`defaultExpanded: !networkExists`)
    // and the inspector is open ⇒ the tools are reachable ⇒ no cluster.
    expect(c.read(inspectorCollapsedProvider), isFalse);
    expect(find.byType(CanvasToolCluster), findsNothing);

    // Draw one element: DRAW auto-collapses. Before F3 that left the everyday
    // Layout state with NO visible drawing tool at all.
    final sheet = c.read(sheetsControllerProvider).current!;
    c.read(networkControllerProvider.notifier).addSegment(
        sheet.id, 0, const Offset(400, 400),
        service: ServiceType.coldWater);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(c.read(inspectorCollapsedProvider), isFalse,
        reason: 'the inspector is still open — only DRAW collapsed');
    expect(find.byType(CanvasToolCluster), findsOneWidget);
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // G2 — one over-velocity clamped water run raises exactly ONE issue.
  // ═══════════════════════════════════════════════════════════════════════════
  group('G2 over-capacity dedupe', () {
    test('a clamped over-capacity downpipe raises ONE issue, not two', () {
      final c = _container();
      c.read(projectControllerProvider.notifier).setCalibration(
            's1',
            const ScaleCalibration(0.1),
          );
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();

      // A roof drain with a 5000 m2 catchment at the default 200 mm/hr and
      // C = 0.9 (rational method):
      //   Q = C * i * A / 3.6e6 = 0.9 * 200 * 5000 / 3.6e6 = 0.25 m3/s = 250 L/s
      // — far past the largest tabulated downpipe (DN200, 65 L/s), so the sizer
      // CLAMPS at DN200 and raises `EdgeSizing.overCapacity`. The clamped pipe
      // then runs at v = 0.25 / (pi * 0.1^2) = 7.96 m/s, over the 3,0 m/s drain
      // ceiling — which is the SAME physics, so it used to ALSO print a
      // `water-velocity:<id>` warning on the same edge (the G2 duplicate).
      const drain = NetNode(
        id: 'rd',
        sheetId: 's1',
        x: 0,
        y: 0,
        floorIndex: 0,
        role: NodeRole.fixture,
        roofAreaM2: 5000,
      );
      const outlet =
          NetNode(id: 'out', sheetId: 's1', x: 200, y: 0, floorIndex: 0);
      const pipe = NetEdge(
        id: 'dp',
        fromId: 'rd',
        toId: 'out',
        service: ServiceType.rainwater,
      );
      c.read(networkControllerProvider.notifier).loadNetwork(
          const Network(nodes: [drain, outlet], edges: [pipe]));

      // Read the flags back from the engine (orchestration-level test).
      final sizing = c.read(sizingProvider)['dp']!;
      expect(sizing.overCapacity, isTrue,
          reason: 'the fixture must actually clamp for this test to mean '
              'anything');
      expect(c.read(overCapacityEdgesProvider), contains('dp'));
      expect(sizing.velocity.metersPerSecond, greaterThan(3.0),
          reason: 'clamped ⇒ over the drain ceiling ⇒ the duplicate used to '
              'fire');

      final issues = c.read(designIssuesProvider);
      expect(issues.where((i) => i.kind == 'storm-over-capacity').length, 1);
      // The duplicate is gone: the over-capacity row owns this edge (it is the
      // one carrying the actionable "split the roof outlets" message).
      expect(issues.where((i) => i.kind == 'water-velocity:dp'), isEmpty);
      // Exactly ONE issue points at this edge at all.
      expect(issues.where((i) => i.locate?.edgeId == 'dp').length, 1);
    });

    test('an over-velocity run that is NOT clamped keeps its velocity warning',
        () {
      final c = _container();
      c.read(projectControllerProvider.notifier).setCalibration(
            's1',
            const ScaleCalibration(0.1),
          );
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      // Four flush-valve WCs on a hand-pinned DN10 run: the override bypasses
      // the size search, so nothing is clamped — the velocity warning is the
      // only honest surface and MUST survive the G2 guard.
      final nodes = <NetNode>[
        const NetNode(
            id: 'src',
            sheetId: 's1',
            x: 0,
            y: 0,
            floorIndex: 0,
            role: NodeRole.plant),
        for (var i = 0; i < 4; i++)
          NetNode(
            id: 'wc$i',
            sheetId: 's1',
            x: 100.0 * (i + 1),
            y: 0,
            floorIndex: 0,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushValve,
          ),
      ];
      final edges = <NetEdge>[
        const NetEdge(
          id: 'main',
          fromId: 'src',
          toId: 'wc0',
          service: ServiceType.coldWater,
          sizeOverride: Diameter(0.010),
        ),
        for (var i = 1; i < 4; i++)
          NetEdge(
            id: 'b$i',
            fromId: 'wc${i - 1}',
            toId: 'wc$i',
            service: ServiceType.coldWater,
          ),
      ];
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(Network(nodes: nodes, edges: edges));

      expect(c.read(overCapacityEdgesProvider).contains('main'), isFalse);
      expect(
          c
              .read(designIssuesProvider)
              .where((i) => i.kind == 'water-velocity:main'),
          hasLength(1));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // H3 / F4 — the export surface tells the truth.
  // ═══════════════════════════════════════════════════════════════════════════
  group('H3 / F4 export honesty', () {
    testWidgets('H3: an export with NO sheet raises a visible error (was a '
        'total no-op)', (tester) async {
      final ref = await _refHarness(tester);
      // No sheets imported ⇒ nothing to draw. The writer returns null
      // ("nothing to write"), which is NOT the silent cancel `false`.
      await exportDrawingDxf(ref);
      await tester.pump();
      final err = ref.read(loadErrorProvider);
      expect(err, isNotNull);
      expect(err, contains('Nothing to export'));
      expect(err, contains('import a plan first'));
    });

    testWidgets('F4: the zero-length gate NAMES the offending sheets',
        (tester) async {
      final ref = await _refHarness(tester);
      ref.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 's1', name: 'Ground Floor', sizePx: Size(1000, 800)),
        Sheet(id: 's2', name: 'Level 1', sizePx: Size(1000, 800)),
      ]);
      // A drawn (and therefore SIZED) run on the UNCALIBRATED sheet s2 ⇒
      // `edgeLength` returns 0 m ⇒ the export gate fires.
      ref.read(networkControllerProvider.notifier).loadNetwork(const Network(
            nodes: [
              NetNode(id: 'a', sheetId: 's2', x: 0, y: 0, floorIndex: 0),
              NetNode(
                  id: 'b',
                  sheetId: 's2',
                  x: 100,
                  y: 0,
                  floorIndex: 0,
                  role: NodeRole.fixture,
                  fixture: PlumbingFixture.lavatory),
            ],
            edges: [
              NetEdge(
                  id: 'r',
                  fromId: 'a',
                  toId: 'b',
                  service: ServiceType.coldWater),
            ],
          ));
      await tester.pump();
      expect(ref.read(zeroLengthSizedEdgeCountProvider), greaterThan(0));
      expect(ref.read(zeroLengthSheetIdsProvider), ['s2']);

      await exportDrawingDxf(ref);
      await tester.pump();
      final err = ref.read(loadErrorProvider)!;
      // Names the SHEET (not just a count), pluralizes honestly (no '(s)'),
      // and points at the locatable Design Issues surface.
      expect(err, contains('Level 1'));
      expect(err, contains('1 drawn element'));
      expect(err.contains('element(s)'), isFalse);
      expect(err, contains('Review > Design issues'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // H5 — the LAID drainage slope reaches the drawings + the canvas label.
  // ═══════════════════════════════════════════════════════════════════════════
  group('H5 drainage slope threading', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mechx_h5_'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    testWidgets('a non-default slope reaches the submittal DXF payload',
        (tester) async {
      final ref = await _refHarness(tester);
      ref.read(projectControllerProvider.notifier).setName('project');
      ref.read(projectControllerProvider.notifier).setCalibration(
            's1',
            const ScaleCalibration(0.05),
          );
      ref.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 's1', name: 'Ground Floor', sizePx: Size(1000, 800)),
      ]);
      // One DRAINAGE branch, whose size label carries the laid fall token.
      ref.read(networkControllerProvider.notifier).loadNetwork(const Network(
            nodes: [
              NetNode(id: 'wb', sheetId: 's1', x: 100, y: 100, floorIndex: 0,
                  role: NodeRole.fixture, fixture: PlumbingFixture.lavatory),
              NetNode(id: 'st', sheetId: 's1', x: 500, y: 100, floorIndex: 0),
            ],
            edges: [
              NetEdge(
                  id: 'br',
                  fromId: 'wb',
                  toId: 'st',
                  service: ServiceType.drainage),
            ],
          ));
      // 1:50 — twice the 1:100 default, so the token is unambiguous.
      ref.read(drainageSlopeProvider.notifier).set(0.02);
      await tester.pump();
      expect(gravitySlopeLabel(ref.read(drainageSlopeProvider)), '1:50');

      final wrote = await tester
          .runAsync(() => writeSubmittalPackageToDir(ref, dir.path));
      expect(wrote, isTrue);

      // The package now bundles several DXFs (riser SLD, electrical set); the
      // fall token rides the PLAN drawing(s). Assert across the whole set: the
      // issued sheets stamp the slope the SIZER used somewhere, and the
      // hard-coded 1:100 default appears NOWHERE — the finding's "the issued
      // sheet contradicts the signed report".
      final dxfs = [
        for (final f in dir.listSync().whereType<File>())
          if (f.path.endsWith('.dxf')) f.readAsStringSync(),
      ];
      expect(dxfs, isNotEmpty);
      expect(dxfs.any((d) => d.contains('1:50')), isTrue,
          reason: 'the plan DXF must stamp the real 1:50 fall');
      expect(dxfs.every((d) => !d.contains('1:100')), isTrue,
          reason: 'no issued DXF may stamp the stale 1:100 default');
    });

    testWidgets('the canvas label formatter re-paints on a slope change',
        (tester) async {
      // The plan label token comes from the painter's `drainageSlope`, which is
      // now fed by `drainageSlopeProvider`. Changing the provider must produce a
      // painter that reports it needs a repaint — i.e. the new fall reaches the
      // on-canvas label.
      final c = _container();
      c.read(projectControllerProvider.notifier).setCalibration(
            's1',
            const ScaleCalibration(0.05),
          );
      c.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 's1', name: 'Ground Floor', sizePx: Size(1000, 800)),
      ]);
      c.read(networkControllerProvider.notifier).loadNetwork(const Network(
            nodes: [
              NetNode(id: 'wb', sheetId: 's1', x: 100, y: 100, floorIndex: 0,
                  role: NodeRole.fixture, fixture: PlumbingFixture.lavatory),
              NetNode(id: 'st', sheetId: 's1', x: 500, y: 100, floorIndex: 0),
            ],
            edges: [
              NetEdge(
                  id: 'br',
                  fromId: 'wb',
                  toId: 'st',
                  service: ServiceType.drainage),
            ],
          ));

      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: NetworkLayer(sheetId: 's1', floorIndex: 0),
        ),
      ));
      await tester.pump();

      CustomPainter painterNow() => (tester.widget<CustomPaint>(
            find.descendant(
              of: find.byType(NetworkLayer),
              matching: find.byType(CustomPaint),
            ),
          ).painter)!;

      final before = painterNow();
      c.read(drainageSlopeProvider.notifier).set(0.02); // 1:50
      await tester.pump();
      final after = painterNow();

      expect(identical(before, after), isFalse);
      expect(after.shouldRepaint(before), isTrue,
          reason: 'the slope change must reach the plan label formatter');
    });
  });
}
