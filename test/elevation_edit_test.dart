/// Tests for the editable VERTICAL (elevation) view — placing, repositioning,
/// and sizing risers — and the §10 geometry-is-truth invariant that a riser's
/// length is the floor-to-floor elevation delta, never a pixel distance.
///
/// The store intents (placeRiserAt / moveRiserHorizontal) are tested directly
/// against the engine's `edgeLength` + the live `sizingProvider`; the widget is
/// driven through its Auto/Edit modes + the palette drag/drop and right-click.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/schematic_layout_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/ui/schematic/schematic_view.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

/// The default project has 3 floors (4.0 / 3.5 / 3.5 m): ceiling-main elevation
/// of floor 0 = 0 + 4.0 - 0.3 = 3.7 m; of floor 1 = 4.0 + 3.5 - 0.3 = 7.2 m.
/// A riser between the ceiling mains of floor 0 → 1 is therefore 3.5 m long.
const double _floor0CeilingMainElevation = 3.7;
const double _floor1CeilingMainElevation = 7.2;
const double _riser0to1LengthM =
    _floor1CeilingMainElevation - _floor0CeilingMainElevation; // 3.5

void main() {
  group('placeRiserAt (store intent)', () {
    test('adds a riser edge spanning two adjacent floors', () {
      final c = _container();
      final ctrl = c.read(networkControllerProvider.notifier);
      final levelCount = c.read(projectControllerProvider).building.levelCount;

      final id = ctrl.placeRiserAt('s1', 0, 250, levelCount,
          service: ServiceType.coldWater);

      expect(id, isNotNull);
      final net = c.read(networkControllerProvider).network;
      final edge = net.edges.firstWhere((e) => e.id == id);
      expect(edge.kind, EdgeKind.riser);
      final a = net.nodeById(edge.fromId)!;
      final b = net.nodeById(edge.toId)!;
      // Spans floor 0 → 1, both at the same horizontal x.
      expect({a.floorIndex, b.floorIndex}, {0, 1});
      expect(a.x, 250);
      expect(b.x, 250);
    });

    test('no-op when there is no floor above (top floor)', () {
      final c = _container();
      final ctrl = c.read(networkControllerProvider.notifier);
      final levelCount = c.read(projectControllerProvider).building.levelCount;

      final id = ctrl.placeRiserAt('s1', levelCount - 1, 100, levelCount);
      expect(id, isNull);
      expect(c.read(networkControllerProvider).network.edges, isEmpty);
    });

    test('records one undo step', () {
      final c = _container();
      final ctrl = c.read(networkControllerProvider.notifier);
      final levelCount = c.read(projectControllerProvider).building.levelCount;
      ctrl.placeRiserAt('s1', 0, 250, levelCount);
      expect(c.read(networkControllerProvider).network.edges.length, 1);
      ctrl.undo();
      expect(c.read(networkControllerProvider).network.edges, isEmpty);
    });
  });

  group('geometry-is-truth: riser length = elevation delta', () {
    test('edgeLength equals the floor-to-floor ceiling-main delta', () {
      final c = _container();
      final ctrl = c.read(networkControllerProvider.notifier);
      final building = c.read(projectControllerProvider).building;

      final id = ctrl.placeRiserAt('s1', 0, 250, building.levelCount);
      final net = c.read(networkControllerProvider).network;
      final edge = net.edges.firstWhere((e) => e.id == id);

      final len = edgeLength(
        edge,
        net,
        calibrationBySheet: const {},
        building: building,
      );
      expect(len.meters, closeTo(_riser0to1LengthM, 1e-9));
    });

    test('sized riser length (sizingProvider + edgeLength) = elevation delta',
        () {
      final c = _container();
      final ctrl = c.read(networkControllerProvider.notifier);
      final building = c.read(projectControllerProvider).building;

      final id = ctrl.placeRiserAt('s1', 0, 250, building.levelCount,
          service: ServiceType.coldWater)!;

      // The edge is sized (it carries the default leaf demand on its branch).
      final sizing = c.read(sizingProvider);
      expect(sizing.containsKey(id), isTrue);

      final net = c.read(networkControllerProvider).network;
      final edge = net.edges.firstWhere((e) => e.id == id);
      final len = edgeLength(edge, net,
          calibrationBySheet: const {}, building: building);
      expect(len.meters, closeTo(_riser0to1LengthM, 1e-9));
    });

    // B3 RE-DERIVATION — this test used to PIN the defect: it asserted that
    // dragging a riser sideways on the ELEVATION wrote that x onto the plan
    // nodes (`a.x == 900`, `b.x == 900`). That gesture is a diagram declutter;
    // writing it onto the plan silently relocated the riser away from its shaft
    // on the plan canvas and in every plan export, with nothing on the elevation
    // to show it. The contract is now the opposite — the PLAN x is UNCHANGED
    // (still 250, the placement x) and the move lands in the transient
    // elevation-layout override, which only the Riser -> Edit view reads. The
    // length invariant this test also guards is untouched (and is now
    // structurally guaranteed: no node coordinate moves at all).
    test('horizontal moveRiserHorizontal moves the DIAGRAM, not the plan — and '
        'never changes the riser length', () {
      final c = _container();
      final ctrl = c.read(networkControllerProvider.notifier);
      final building = c.read(projectControllerProvider).building;

      final id = ctrl.placeRiserAt('s1', 0, 250, building.levelCount)!;
      Network net = c.read(networkControllerProvider).network;
      NetEdge edge = net.edges.firstWhere((e) => e.id == id);
      final before = edgeLength(edge, net,
          calibrationBySheet: const {}, building: building);

      // Drag the riser hard to the right on the elevation.
      ctrl.moveRiserHorizontal(id, 900);

      net = c.read(networkControllerProvider).network;
      edge = net.edges.firstWhere((e) => e.id == id);
      final a = net.nodeById(edge.fromId)!;
      final b = net.nodeById(edge.toId)!;
      // PLAN geometry untouched — floors AND x.
      expect(a.x, 250);
      expect(b.x, 250);
      expect({a.floorIndex, b.floorIndex}, {0, 1});
      // The DIAGRAM position carries the move (both endpoints of the riser).
      final layout = c.read(schematicLayoutProvider);
      expect(layout.xFor(a), 900);
      expect(layout.xFor(b), 900);

      final after = edgeLength(edge, net,
          calibrationBySheet: const {}, building: building);
      expect(after.meters, closeTo(before.meters, 1e-9));
      expect(after.meters, closeTo(_riser0to1LengthM, 1e-9));
    });

    test('moveRiserHorizontal ignores a non-riser edge id', () {
      final c = _container();
      final ctrl = c.read(networkControllerProvider.notifier);
      // No edges yet — a bogus id is a no-op (does not throw).
      ctrl.moveRiserHorizontal('nope', 10);
      expect(c.read(networkControllerProvider).network.edges, isEmpty);
    });
  });

  group('sizing a riser via setEdgeSizeOverride', () {
    test('the override changes the sized diameter', () {
      final c = _container();
      final ctrl = c.read(networkControllerProvider.notifier);
      final building = c.read(projectControllerProvider).building;

      final id = ctrl.placeRiserAt('s1', 0, 250, building.levelCount,
          service: ServiceType.coldWater)!;
      final autoDia =
          c.read(sizingProvider)[id]!.diameter.inMillimeters;

      // Force DN100 — well above the auto cold-water size for one leaf demand.
      ctrl.setEdgeSizeOverride(id, Diameter.mm(100));
      final overriddenDia =
          c.read(sizingProvider)[id]!.diameter.inMillimeters;

      expect(overriddenDia, closeTo(100, 0.5));
      expect(overriddenDia, isNot(closeTo(autoDia, 0.5)));
    });
  });

  // ── Widget tests ────────────────────────────────────────────────────────────

  // The real app mounts SchematicView under a WidgetsApp (which supplies an
  // Overlay that Draggable + the right-click context-menu require). Mirror that
  // with an explicit Overlay so the test tree matches production.
  Widget harness(Widget child, {List<Override> overrides = const []}) =>
      ProviderScope(
        overrides: overrides,
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: const MediaQueryData(size: Size(1280, 832)),
              child: SizedBox(
                width: 1280,
                height: 832,
                child: Overlay(
                  initialEntries: [
                    OverlayEntry(builder: (_) => child),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  group('SchematicView widget', () {
    testWidgets('Auto mode shows the empty-state text with no network',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(harness(const SchematicView()));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('No network drawn'), findsOneWidget);
    });

    testWidgets('switching to Edit mode reveals the riser palette',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(harness(const SchematicView()));
      await tester.pump();

      // The palette ("Riser" card) is not present in Auto mode.
      expect(find.text('Riser'), findsNothing);

      await tester.tap(find.text('Edit'));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // The palette card + the service picker label appear.
      expect(find.text('Riser'), findsWidgets);
      expect(find.text('Riser service'), findsOneWidget);
    });

    testWidgets('Edit mode renders an interactive CustomPaint over a network',
        (tester) async {
      setDesktopSurface(tester);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Seed a riser through the store so the edit canvas has something to draw.
      final levelCount =
          container.read(projectControllerProvider).building.levelCount;
      container
          .read(networkControllerProvider.notifier)
          .placeRiserAt('s1', 0, 250, levelCount);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MechXTheme(
            data: MechXThemeData.dark,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: MediaQuery(
                data: const MediaQueryData(size: Size(1280, 832)),
                child: SizedBox(
                  width: 1280,
                  height: 832,
                  child: Overlay(
                    initialEntries: [
                      OverlayEntry(builder: (_) => const SchematicView()),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Edit'));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(CustomPaint), findsWidgets);
      // The seeded riser still spans floor 0 → 1.
      final net = container.read(networkControllerProvider).network;
      expect(net.edges.where((e) => e.kind == EdgeKind.riser), hasLength(1));
    });
  });
}
