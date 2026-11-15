// Backlog D-4 (2026-11-13) — put an inline component ON a riser
// (`NetworkController.insertComponentOnRiser`), one undo step.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/units.dart';

void main() {
  // Three 4.0 m storeys; a cold-water riser from L3's ceiling main (11.7 m)
  // down to L1's (3.7 m), DN50 by hand, PPR PN16.
  ProviderContainer load() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier).setFloors([
      for (var i = 0; i < 3; i++) Floor('L${i + 1}', const Length(4.0)),
    ]);
    c.read(networkControllerProvider.notifier).loadNetwork(const Network(
      nodes: [
        NetNode(id: 'T', sheetId: 's2', x: 100, y: 50, floorIndex: 2),
        NetNode(id: 'B', sheetId: 's0', x: 100, y: 50, floorIndex: 0),
      ],
      edges: [
        NetEdge(
          id: 'r',
          fromId: 'T',
          toId: 'B',
          service: ServiceType.coldWater,
          kind: EdgeKind.riser,
          pipeProduct: PipeProduct.pprPn16,
          sizeOverride: Diameter(0.05),
        ),
      ],
    ));
    return c;
  }

  test('splits the riser into two riser segments that keep service / size / '
      'product; the PRV sits on the chosen floor at its ceiling', () {
    final c = load();
    final ctrl = c.read(networkControllerProvider.notifier);
    final id = ctrl.insertComponentOnRiser('r', NodeComponent.prv,
        floorIndex: 1, sheetId: 's1')!;
    final net = c.read(networkControllerProvider).network;
    final prv = net.nodeById(id)!;
    expect(prv.component, NodeComponent.prv);
    expect(prv.floorIndex, 1);
    expect(prv.sheetId, 's1');
    expect((prv.x, prv.y), (100.0, 50.0));
    final b = c.read(projectControllerProvider).building;
    // L2 ceiling 4.0 + 3.7 = 7.7 m — between the ends 11.7 and 3.7.
    expect(nodeElevation(prv, b).meters, closeTo(7.7, 1e-12));
    expect(net.edges.length, 2);
    for (final e in net.edges) {
      expect(e.kind, EdgeKind.riser);
      expect(e.service, ServiceType.coldWater);
      expect(e.pipeProduct, PipeProduct.pprPn16);
      expect(e.sizeOverride!.meters, 0.05);
    }
    expect({for (final e in net.edges) (e.fromId, e.toId)},
        {('T', id), (id, 'B')});
    // The two segments add up to the original riser: 4.0 + 4.0 = 8.0 m.
    double len(NetEdge e) =>
        riserElevationDelta(e, net.nodeById(e.fromId)!, net.nodeById(e.toId)!,
                b)
            .meters;
    expect(net.edges.map(len).fold<double>(0, (a, x) => a + x),
        closeTo(8.0, 1e-12));
    // One undo step restores the single riser.
    ctrl.undo();
    final back = c.read(networkControllerProvider).network;
    expect(back.edges.single.id, 'r');
    expect(back.nodes.length, 2);
  });

  test('at an end floor the station lands at that end (a 0 m segment), '
      'at the end node\'s own sheet', () {
    final c = load();
    final id = c
        .read(networkControllerProvider.notifier)
        .insertComponentOnRiser('r', NodeComponent.gateValve, floorIndex: 0)!;
    final net = c.read(networkControllerProvider).network;
    expect(net.nodeById(id)!.sheetId, 's0');
    expect(net.edges.length, 2);
  });

  test('refused (no change) off the riser span, on a run, with an elevation '
      'outside the span', () {
    final c = load();
    final ctrl = c.read(networkControllerProvider.notifier);
    expect(
        ctrl.insertComponentOnRiser('r', NodeComponent.prv, floorIndex: 3),
        isNull);
    expect(
        ctrl.insertComponentOnRiser('r', NodeComponent.prv,
            floorIndex: 1, elevation: const Length(12.5)),
        isNull);
    expect(
        ctrl.insertComponentOnRiser('missing', NodeComponent.prv,
            floorIndex: 1),
        isNull);
    expect(c.read(networkControllerProvider).network.edges.single.id, 'r');
    // An explicit elevation inside the span is honoured.
    final id = ctrl.insertComponentOnRiser('r', NodeComponent.prv,
        floorIndex: 1, elevation: const Length(5.0))!;
    final net = c.read(networkControllerProvider).network;
    expect(net.nodeById(id)!.elevation!.meters, 5.0);
  });
}
