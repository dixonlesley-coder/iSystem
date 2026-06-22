import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx_engine/network/network.dart';

void main() {
  group('NetworkController', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('defaults: select tool, empty network', () {
      final c = makeContainer();
      final s = c.read(networkControllerProvider);
      expect(s.tool, DrawTool.select);
      expect(s.isDrawing, isFalse);
      expect(s.network.edges, isEmpty);
    });

    test('drawing a run: first point pends, second makes an edge + chains', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      expect(c.read(networkControllerProvider).pendingPoint, const Offset(0, 0));
      expect(c.read(networkControllerProvider).network.edges, isEmpty);

      n.placeRunPoint('s1', 0, const Offset(100, 0));
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 2);
      expect(net.edges.single.service, ServiceType.coldWater);
      expect(c.read(networkControllerProvider).pendingPoint, const Offset(100, 0));
    });

    test('chaining shares the joining node (polyline)', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      n.placeRunPoint('s1', 0, const Offset(200, 0));
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 3);
      expect(net.edges.length, 2);
    });

    test('snapping reuses a nearby node', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0)); // nodes a,b
      n.setTool(DrawTool.drawRun); // clear pending
      n.placeRunPoint('s1', 0, const Offset(2, 2)); // ≈ a
      n.placeRunPoint('s1', 0, const Offset(100, 2)); // ≈ b
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 2, reason: 'both endpoints snapped to a and b');
      expect(net.edges.length, 2);
    });

    test('riser adds a riser edge to the floor above', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRiser);
      n.placeRiser('s1', 0, const Offset(50, 50), 3);
      final net = c.read(networkControllerProvider).network;
      expect(net.edges.single.kind, EdgeKind.riser);
      final lower = net.nodeById(net.edges.single.fromId)!;
      final upper = net.nodeById(net.edges.single.toId)!;
      expect(lower.floorIndex, 0);
      expect(upper.floorIndex, 1);
    });

    test('riser is a no-op on the top floor', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRiser);
      n.placeRiser('s1', 2, const Offset(0, 0), 3); // floors 0..2
      expect(c.read(networkControllerProvider).network.edges, isEmpty);
    });

    test('undo / redo / clear', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.placeRunPoint('s1', 0, const Offset(100, 0));
      expect(n.canUndo, isTrue);
      n.undo();
      expect(c.read(networkControllerProvider).network.edges, isEmpty);
      n.redo();
      expect(c.read(networkControllerProvider).network.edges.length, 1);
      n.clear();
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
    });

    test('setService changes the active service and clears pending', () {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      n.placeRunPoint('s1', 0, const Offset(0, 0));
      n.setService(ServiceType.duct);
      expect(c.read(networkControllerProvider).service, ServiceType.duct);
      expect(c.read(networkControllerProvider).pendingPoint, isNull);
    });
  });

  testWidgets('draw palette renders; Run tool activates without error',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    expect(find.text('DRAW'), findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
    expect(find.text('Riser'), findsOneWidget);
    expect(find.text('Cold water'), findsOneWidget);

    await tester.ensureVisible(find.text('Run'));
    await tester.tap(find.text('Run'));
    await tester.pump();

    // drawing two points on the canvas must not throw
    await tester.tapAt(const Offset(330, 300));
    await tester.pump();
    await tester.tapAt(const Offset(400, 320));
    await tester.pump();
  });
}
