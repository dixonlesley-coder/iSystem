/// Theme B — the riser's CROSS-SURFACE contract.
///
/// A riser is the one element that lives on two floors and two surfaces, and
/// three defects made it lie on one surface about the other:
///
///   * B1 — the far-floor node was stamped with the SOURCE sheet's id, and every
///     canvas overlay filters on sheet AND floor, so the riser was INVISIBLE on
///     the floor above (branch off it there and you drew a disconnected island);
///   * B2 — a Riser -> Edit palette drop took the ELEVATION's world x with
///     `y = 0` as PLAN coordinates and fell back to the current sheet when the
///     target floor had no plan, minting a node invisible on every sheet forever
///     yet still sized into the BOM;
///   * B3 — dragging a riser sideways on the elevation (a diagram declutter)
///     wrote that x straight onto the PLAN nodes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/schematic_layout_store.dart';
import 'package:mechx/store/sheets_store.dart';

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('B1 — a riser lands on the DESTINATION floor\'s sheet', () {
    test('the far node carries the sheet mapped to the floor it reaches', () {
      final c = _container();
      // Two plans: s1 -> floor 0 (where the riser is drawn), s2 -> floor 1.
      c.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 's1', name: 'Ground'),
        Sheet(id: 's2', name: 'Level 1'),
      ]);
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRiser);

      final result = n.placeRiser('s1', 0, const Offset(50, 50), 3);
      expect(result, RiserPlacement.up);

      final net = c.read(networkControllerProvider).network;
      final edge = net.edges.single;
      final lower = net.nodeById(edge.fromId)!;
      final upper = net.nodeById(edge.toId)!;
      expect(lower.floorIndex, 0);
      expect(lower.sheetId, 's1');
      expect(upper.floorIndex, 1);
      // The point of B1: the upper node is on the FLOOR-ABOVE's plan, so the
      // engineer can see and branch off it there.
      expect(upper.sheetId, 's2');
    });

    test('a DOWNWARD riser from the top floor lands on the lower floor\'s sheet',
        () {
      final c = _container();
      c.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 's1', name: 'Ground'),
        Sheet(id: 's2', name: 'Level 1'),
        Sheet(id: 's3', name: 'Level 2'),
      ]);
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRiser);

      // Top floor of a 3-floor building: spans DOWN to floor 1 (sheet s2).
      final result = n.placeRiser('s3', 2, const Offset(0, 0), 3);
      expect(result, RiserPlacement.down);
      final net = c.read(networkControllerProvider).network;
      final edge = net.edges.single;
      final far = net.nodeById(edge.toId)!;
      expect(far.floorIndex, 1);
      expect(far.sheetId, 's2');
    });

    test('an UNMAPPED destination floor falls back to the source sheet '
        '(today\'s behaviour pinned)', () {
      final c = _container();
      // Only ONE sheet, mapped to floor 0 — floor 1 carries no plan.
      c.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 's1', name: 'Ground'),
      ]);
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRiser);
      n.placeRiser('s1', 0, const Offset(50, 50), 3);

      final net = c.read(networkControllerProvider).network;
      final upper = net.nodeById(net.edges.single.toId)!;
      expect(upper.floorIndex, 1);
      expect(upper.sheetId, 's1',
          reason: 'no plan on floor 1 — nowhere better to put it');
    });

    test('with NO sheets loaded at all the source sheet is kept (byte-identical '
        'to the pre-B1 behaviour)', () {
      final c = _container();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRiser);
      n.placeRiser('s1', 0, const Offset(50, 50), 3);
      final net = c.read(networkControllerProvider).network;
      for (final node in net.nodes) {
        expect(node.sheetId, 's1');
      }
    });

    test('placeRiserAt puts the UPPER node on the floor-above plan too', () {
      final c = _container();
      c.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 's1', name: 'Ground'),
        Sheet(id: 's2', name: 'Level 1'),
      ]);
      final n = c.read(networkControllerProvider.notifier);
      final levelCount = c.read(projectControllerProvider).building.levelCount;
      final id = n.placeRiserAt('s1', 0, 250, levelCount)!;
      final net = c.read(networkControllerProvider).network;
      final edge = net.edges.firstWhere((e) => e.id == id);
      expect(net.nodeById(edge.fromId)!.sheetId, 's1');
      expect(net.nodeById(edge.toId)!.sheetId, 's2');
    });
  });

  group('B3 — moveRiserHorizontal is DIAGRAM-ONLY', () {
    test('the plan x is UNCHANGED and the elevation override carries the move',
        () {
      final c = _container();
      final ctrl = c.read(networkControllerProvider.notifier);
      final levelCount = c.read(projectControllerProvider).building.levelCount;
      final id = ctrl.placeRiserAt('s1', 0, 250, levelCount)!;

      ctrl.moveRiserHorizontal(id, 900);

      final net = c.read(networkControllerProvider).network;
      final edge = net.edges.firstWhere((e) => e.id == id);
      final a = net.nodeById(edge.fromId)!;
      final b = net.nodeById(edge.toId)!;
      // PLAN geometry untouched — the riser is still in its shaft on the plan
      // and in every plan export.
      expect(a.x, 250);
      expect(b.x, 250);
      // The DIAGRAM position moved, for both endpoints.
      final layout = c.read(schematicLayoutProvider);
      expect(layout.schematicXOverrides[a.id], 900);
      expect(layout.schematicXOverrides[b.id], 900);
      expect(layout.xFor(a), 900);
      expect(layout.xFor(b), 900);
    });

    test('it records NO undo step (the network never changed)', () {
      final c = _container();
      final ctrl = c.read(networkControllerProvider.notifier);
      final levelCount = c.read(projectControllerProvider).building.levelCount;
      final id = ctrl.placeRiserAt('s1', 0, 250, levelCount)!;
      final before = c.read(networkControllerProvider).network;

      ctrl.moveRiserHorizontal(id, 900);

      expect(c.read(networkControllerProvider).network, same(before));
    });

    test('a non-riser / unknown edge id is a no-op', () {
      final c = _container();
      final ctrl = c.read(networkControllerProvider.notifier);
      ctrl.moveRiserHorizontal('nope', 10);
      expect(c.read(schematicLayoutProvider).isEmpty, isTrue);

      ctrl.setTool(DrawTool.drawRun);
      ctrl.placeRunPoint('s1', 0, const Offset(0, 0));
      ctrl.placeRunPoint('s1', 0, const Offset(100, 0));
      final run = c.read(networkControllerProvider).network.edges.single;
      ctrl.moveRiserHorizontal(run.id, 500);
      expect(c.read(schematicLayoutProvider).isEmpty, isTrue);
    });

    test('an unmoved node falls back to its plan x', () {
      final c = _container();
      final ctrl = c.read(networkControllerProvider.notifier);
      final levelCount = c.read(projectControllerProvider).building.levelCount;
      ctrl.placeRiserAt('s1', 0, 250, levelCount);
      final node = c.read(networkControllerProvider).network.nodes.first;
      expect(c.read(schematicLayoutProvider).xFor(node), 250);
    });
  });
}
