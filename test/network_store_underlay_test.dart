import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx_engine/network/network.dart';

/// B12 store wiring: the underlay snap callback is applied BELOW node/tee snap
/// and ABOVE the grid — the same precedence position the magnetic grid occupies.
void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('a node candidate beats an underlay candidate at the drop', () {
    final c = makeContainer();
    final n = c.read(networkControllerProvider.notifier);
    // Seed a lone node at (50,50).
    n.loadNetwork(const Network(nodes: [
      NetNode(id: 'n0', sheetId: 's1', x: 50, y: 50, floorIndex: 0),
    ], edges: []));

    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0)); // pending start
    // Second click lands within snapRadius of n0, and the underlay near that
    // click would pull it to a DIFFERENT point (60,60). Node snap must win.
    n.placeRunPoint('s1', 0, const Offset(52, 50),
        snapRadius: 12,
        underlaySnap: (w) =>
            (w - const Offset(52, 50)).distance < 20 ? const Offset(60, 60) : null);

    final net = c.read(networkControllerProvider).network;
    expect(net.edges, hasLength(1));
    final e = net.edges.single;
    // The far endpoint is the EXISTING node, not the underlay point.
    expect(e.toId == 'n0' || e.fromId == 'n0', isTrue);
    // No node was created at the underlay point.
    expect(net.nodes.any((x) => x.x == 60 && x.y == 60), isFalse);
  });

  test('underlay snaps a free endpoint when no node/tee is in range', () {
    final c = makeContainer();
    final n = c.read(networkControllerProvider.notifier);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    // Far from anything; the underlay near the end click pulls it onto a wall.
    n.placeRunPoint('s1', 0, const Offset(200, 200),
        snapRadius: 12,
        underlaySnap: (w) =>
            (w - const Offset(200, 200)).distance < 5 ? const Offset(210, 205) : null);

    final net = c.read(networkControllerProvider).network;
    expect(net.edges, hasLength(1));
    // The end node sits on the underlay point.
    expect(net.nodes.any((x) => x.x == 210 && x.y == 205), isTrue);
  });

  test('no underlay callback ⇒ endpoint lands exactly at the click (unchanged)',
      () {
    final c = makeContainer();
    final n = c.read(networkControllerProvider.notifier);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(200, 200), snapRadius: 12);
    final net = c.read(networkControllerProvider).network;
    expect(net.nodes.any((x) => x.x == 200 && x.y == 200), isTrue);
  });
}
