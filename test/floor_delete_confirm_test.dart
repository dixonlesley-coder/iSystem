/// C2 — deleting a level is honest about the work it takes with it.
///
/// Two halves, both defective before:
///   (a) `remapNodesForFloorChange` shifted only nodes ABOVE the removed floor,
///       so nodes ON it kept their index while the floor above slid DOWN into
///       that slot — two floors' drawn work silently FUSED at the wrong
///       elevation, in range so no orphan check fired and nothing warned. The
///       honest semantics: that work is DELETED with the floor it lived on, in
///       the SAME single structural undo step as the floor removal.
///   (b) the Building page's `×` fired straight into `removeFloor` with no
///       count and no confirm. It now counts the level's drawn elements and
///       asks first (a level with nothing drawn on it still goes straight away).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

/// A 3-floor network: one run on floor 0, one run on floor 1, and a riser
/// spanning 1 -> 2.
const _net = Network(
  nodes: [
    NetNode(id: 'a0', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
    NetNode(id: 'b0', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
    NetNode(id: 'a1', sheetId: 's2', x: 0, y: 0, floorIndex: 1),
    NetNode(id: 'b1', sheetId: 's2', x: 100, y: 0, floorIndex: 1),
    NetNode(id: 'a2', sheetId: 's3', x: 0, y: 0, floorIndex: 2),
  ],
  edges: [
    NetEdge(id: 'e0', fromId: 'a0', toId: 'b0', service: ServiceType.coldWater),
    NetEdge(id: 'e1', fromId: 'a1', toId: 'b1', service: ServiceType.coldWater),
    NetEdge(
      id: 'r1',
      fromId: 'b1',
      toId: 'a2',
      service: ServiceType.coldWater,
      kind: EdgeKind.riser,
    ),
  ],
);

void main() {
  group('C2 (a) — the removed floor\'s work goes with it', () {
    test('elementsOnFloor counts the nodes plus every edge touching them', () {
      final c = _container();
      c.read(networkControllerProvider.notifier).loadNetwork(_net);
      // Floor 0: 2 nodes + 1 run.
      expect(c.read(networkControllerProvider.notifier).elementsOnFloor(0), 3);
      // Floor 1: 2 nodes + its run + the riser leaving it.
      expect(c.read(networkControllerProvider.notifier).elementsOnFloor(1), 4);
      // Floor 2: 1 node + the riser arriving.
      expect(c.read(networkControllerProvider.notifier).elementsOnFloor(2), 2);
    });

    test('elementsOnFloor is 0 for a level with nothing drawn on it', () {
      final c = _container();
      expect(c.read(networkControllerProvider.notifier).elementsOnFloor(1), 0);
    });

    test('removing a MIDDLE floor deletes its work and never fuses it onto the '
        'floor above', () {
      final c = _container();
      final proj = c.read(projectControllerProvider.notifier);
      proj.setFloors(const [
        Floor('F0', Length(4.0)),
        Floor('F1', Length(3.0)),
        Floor('F2', Length(3.0)),
      ]);
      c.read(networkControllerProvider.notifier).loadNetwork(_net);

      proj.removeFloor(1);

      final net = c.read(networkControllerProvider).network;
      // F1's nodes are gone…
      expect(net.nodeById('a1'), isNull);
      expect(net.nodeById('b1'), isNull);
      // …with every edge that touched them (its run AND the riser leg).
      expect(net.edges.map((e) => e.id), ['e0']);
      // F0's work is untouched; F2's node slid down one index to keep its own
      // physical slab — and did NOT inherit F1's drawing.
      expect(net.nodeById('a0')!.floorIndex, 0);
      expect(net.nodeById('a2')!.floorIndex, 1);
      final building = c.read(projectControllerProvider).building;
      expect(building.floors[net.nodeById('a2')!.floorIndex].name, 'F2');
    });

    test('the floor removal and the deletion are ONE undo step', () {
      final c = _container();
      final proj = c.read(projectControllerProvider.notifier);
      proj.setFloors(const [
        Floor('F0', Length(4.0)),
        Floor('F1', Length(3.0)),
        Floor('F2', Length(3.0)),
      ]);
      c.read(networkControllerProvider.notifier).loadNetwork(_net);

      proj.removeFloor(1);
      expect(c.read(projectControllerProvider).floors.length, 2);
      expect(c.read(networkControllerProvider).network.nodes, hasLength(3));

      c.read(historyProvider.notifier).undo();

      // BOTH halves come back together — never the torn state.
      expect(c.read(projectControllerProvider).floors.length, 3);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes, hasLength(5));
      expect(net.edges, hasLength(3));
      expect(net.nodeById('a1')!.floorIndex, 1);
      expect(net.nodeById('a2')!.floorIndex, 2);
    });

    test('an empty network is still a byte-identical no-op remap', () {
      final c = _container();
      final proj = c.read(projectControllerProvider.notifier);
      final before = c.read(networkControllerProvider).network;
      proj.removeFloor(1);
      expect(c.read(networkControllerProvider).network, same(before));
    });
  });

  group('C2 (b) — the Building page confirms before it deletes', () {
    Future<ProviderContainer> openBuilding(WidgetTester tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final c = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      await tester.pump();
      await tester.tap(find.descendant(
          of: find.byType(NavRail), matching: find.text('Building')));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('a level carrying drawn work asks first, naming the count',
        (tester) async {
      final c = await openBuilding(tester);
      c.read(networkControllerProvider.notifier).loadNetwork(_net);
      await tester.pump();

      // Cards render top-first, so the LAST '×' is the ground floor's (floor 0,
      // which carries 2 nodes + 1 run = 3 elements).
      await tester.tap(find.text('×').last);
      await tester.pumpAndSettle();

      expect(find.text('Delete Ground?'), findsOneWidget);
      expect(
          find.text('Ground carries 3 drawn elements — deleting the level '
              'deletes them too.'),
          findsOneWidget);
      // Nothing has happened yet.
      expect(c.read(projectControllerProvider).floors.length, 3);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(c.read(projectControllerProvider).floors.length, 3);
      expect(c.read(networkControllerProvider).network.nodes, hasLength(5));
    });

    testWidgets('confirming deletes the level AND its work', (tester) async {
      final c = await openBuilding(tester);
      c.read(networkControllerProvider.notifier).loadNetwork(_net);
      await tester.pump();

      await tester.tap(find.text('×').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete level'));
      await tester.pumpAndSettle();

      expect(c.read(projectControllerProvider).floors.length, 2);
      final net = c.read(networkControllerProvider).network;
      expect(net.nodeById('a0'), isNull);
      expect(net.nodeById('b0'), isNull);
      expect(net.edges.any((e) => e.id == 'e0'), isFalse);
    });

    testWidgets('a level with NOTHING drawn on it is removed straight away',
        (tester) async {
      final c = await openBuilding(tester);
      expect(c.read(projectControllerProvider).floors.length, 3);

      // The top card is Level 2 — an empty level, so no dialog.
      await tester.tap(find.text('×').first);
      await tester.pumpAndSettle();

      expect(find.text('Delete Level 2?'), findsNothing);
      expect(c.read(projectControllerProvider).floors.length, 2);
    });
  });
}
