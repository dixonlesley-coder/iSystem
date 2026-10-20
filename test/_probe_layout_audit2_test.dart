import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/ui/canvas/snapping.dart';
import 'package:mechx_engine/network/network.dart';

void main() {
  test('ortho first segment from near-node start', () {
    final c = ProviderContainer();
    final n = c.read(networkControllerProvider.notifier);
    n.loadNetwork(const Network(nodes: [
      NetNode(id: 'x', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
      NetNode(id: 'y', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
    ], edges: [NetEdge(id: 'e0', fromId: 'x', toId: 'y', service: ServiceType.coldWater)]));
    n.setService(ServiceType.coldWater);
    n.setTool(DrawTool.drawRun);
    const start = Offset(104, 107);
    n.placeRunPoint('s1', 0, start);
    final end = orthoSnap(start, const Offset(400, 110));
    n.placeRunPoint('s1', 0, end, ortho: true);
    final net = c.read(networkControllerProvider).network;
    for (final e in net.edges) {
      final a = net.nodeById(e.fromId)!, b = net.nodeById(e.toId)!;
      // ignore: avoid_print
      print('${e.id}: (${a.x},${a.y}) -> (${b.x},${b.y})');
    }
  });
}
