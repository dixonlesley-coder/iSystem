import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/network/network.dart';

/// C5 — a destructive cascade must state its collateral. Removing a sheet
/// prunes every element drawn on it; the store now RETURNS that count so the
/// status pill can name it (and the whole cascade stays one undo step, which is
/// what lets the pill honestly offer Ctrl+Z).
///
/// F6 — the annotation `add`s return the new id so the drawing gesture can
/// select what was just drawn.
void main() {
  ProviderContainer make() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  void seedSheets(ProviderContainer c) =>
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();

  group('C5: removeSheet reports its collateral', () {
    test('an empty sheet prunes nothing', () {
      final c = make();
      seedSheets(c);
      expect(
          c.read(sheetsControllerProvider.notifier).removeSheet('s2'), 0);
    });

    test('an unknown sheet is a no-op reporting 0', () {
      final c = make();
      seedSheets(c);
      expect(c.read(sheetsControllerProvider.notifier).removeSheet('nope'), 0);
      expect(c.read(sheetsControllerProvider).sheets, hasLength(3));
    });

    test('a drawn sheet reports every node AND edge that went with it', () {
      final c = make();
      seedSheets(c);
      final n = c.read(networkControllerProvider.notifier);
      n.setService(ServiceType.coldWater);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s2', 1, const Offset(0, 0));
      n.placeRunPoint('s2', 1, const Offset(100, 0));
      n.placeRunPoint('s2', 1, const Offset(200, 0));
      n.setTool(DrawTool.select);
      final net = c.read(networkControllerProvider).network;
      final onS2 = net.nodes.where((x) => x.sheetId == 's2').length;
      expect(onS2, 3);
      expect(net.edges, hasLength(2));

      final pruned =
          c.read(sheetsControllerProvider.notifier).removeSheet('s2');
      // 3 nodes + the 2 runs joining them.
      expect(pruned, 5);
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
      expect(c.read(networkControllerProvider).network.edges, isEmpty);
    });

    test('the pruned work comes back with ONE undo (so the pill may say so)',
        () {
      final c = make();
      seedSheets(c);
      final n = c.read(networkControllerProvider.notifier);
      n.setService(ServiceType.coldWater);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s2', 1, const Offset(0, 0));
      n.placeRunPoint('s2', 1, const Offset(100, 0));
      n.setTool(DrawTool.select);
      expect(c.read(sheetsControllerProvider.notifier).removeSheet('s2'), 3);
      c.read(historyProvider.notifier).undo();
      expect(c.read(sheetsControllerProvider).sheets, hasLength(3));
      expect(c.read(networkControllerProvider).network.nodes, hasLength(2));
      expect(c.read(networkControllerProvider).network.edges, hasLength(1));
    });
  });

  group('F6: a drawn annotation can be selected because add returns its id', () {
    test('room add returns the new id; a degenerate box returns null', () {
      final c = make();
      final rooms = c.read(roomAreasProvider.notifier);
      final id = rooms.add(
          sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 150);
      expect(id, isNotNull);
      expect(c.read(roomAreasProvider).single.id, id);
      expect(
          rooms.add(sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 1, by: 1),
          isNull);
      expect(c.read(roomAreasProvider), hasLength(1));
    });

    test('tank add returns the new id; a degenerate box returns null', () {
      final c = make();
      final tanks = c.read(tankAreasProvider.notifier);
      final id = tanks.add(
          sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 200, by: 150);
      expect(id, isNotNull);
      expect(c.read(tankAreasProvider).single.id, id);
      expect(
          tanks.add(sheetId: 's1', floorIndex: 0, ax: 5, ay: 5, bx: 6, by: 6),
          isNull);
      expect(c.read(tankAreasProvider), hasLength(1));
    });
  });
}
