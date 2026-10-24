import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;

/// Round 45 (mech-convergence-1) — a node merge (drag-end snap, base-point
/// Move, base-point Copy) keeps the CONTENT-bearing node: dragging a pump or
/// a fixture onto a bare run end used to delete it (and with it its duty,
/// schedule row, electrical way or fixture load). Two content-bearing nodes
/// never join.
void main() {
  const cw = ServiceType.coldWater;

  ProviderContainer make() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  NetNode bare(String id, double x, double y) =>
      NetNode(id: id, sheetId: 's', x: x, y: y, floorIndex: 0);
  NetNode pump(String id, double x, double y) => NetNode(
      id: id,
      sheetId: 's',
      x: x,
      y: y,
      floorIndex: 0,
      role: NodeRole.plant,
      component: NodeComponent.pump,
      tagNo: 1);
  NetEdge run(String id, String a, String b) =>
      NetEdge(id: id, fromId: a, toId: b, service: cw);

  // a(0,0)-b(100,0) cold-water run; pump p(300,0) with run p-q to q(400,0).
  Network probe() => Network(
        nodes: [bare('a', 0, 0), bare('b', 100, 0), pump('p', 300, 0),
          bare('q', 400, 0)],
        edges: [run('e1', 'a', 'b'), run('e2', 'p', 'q')],
      );

  void expectPumpJoined(Network net, {required String pumpId}) {
    final p = net.nodeById(pumpId);
    expect(p, isNotNull, reason: 'the pump survives the merge');
    expect(p!.component, NodeComponent.pump);
    expect(p.role, NodeRole.plant);
    expect(p.tagNo, 1, reason: 'its tag (P-01) stays');
    expect((p.x, p.y), (100.0, 0.0), reason: 'at the run end');
    expect(net.nodeById('b'), isNull, reason: 'the bare junction is merged');
    // Both runs now meet AT the pump.
    expect(net.edgesAt(pumpId).length, 2);
    expect(net.nodes.where((n) => n.component == NodeComponent.pump),
        hasLength(1));
  }

  test('drag-end snap: the dragged pump survives on the run end', () {
    final c = make();
    final n = c.read(networkControllerProvider.notifier);
    n.loadNetwork(probe());
    n.pushUndoSnapshot();
    n.moveNode('p', 102, 0); // within the 10 px snap radius of b
    n.endNodeDragWithSnap('p', 10);
    expectPumpJoined(c.read(networkControllerProvider).network, pumpId: 'p');
  });

  test('base-point Move onto the run end: the pump survives', () {
    final c = make();
    final n = c.read(networkControllerProvider.notifier);
    n.loadNetwork(probe());
    expect(n.translateSelection({'p'}, const {}, const Offset(-200, 0)), isTrue);
    expectPumpJoined(c.read(networkControllerProvider).network, pumpId: 'p');
  });

  test('base-point Copy onto the run end: the COPIED pump survives', () {
    final c = make();
    final n = c.read(networkControllerProvider.notifier);
    n.loadNetwork(probe());
    final ids = n.copySelectionBy({'p', 'q'}, {'e2'}, const Offset(-200, 0));
    final net = c.read(networkControllerProvider).network;
    final copies = net.nodes
        .where((x) => ids.nodeIds.contains(x.id) && x.component != null)
        .toList();
    expect(copies, hasLength(1));
    expect(copies.single.component, NodeComponent.pump);
    expect((copies.single.x, copies.single.y), (100.0, 0.0));
    expect(net.nodeById('b'), isNull);
    expect(net.edgesAt(copies.single.id).length, 2);
    // The original pump is untouched.
    expect(net.nodeById('p')!.component, NodeComponent.pump);
  });

  test('a fixture dragged onto its own branch end keeps its load', () {
    final c = make();
    final n = c.read(networkControllerProvider.notifier);
    n.loadNetwork(Network(nodes: [
      bare('m', 0, 0),
      bare('j', 100, 0),
      const NetNode(
          id: 'wc',
          sheetId: 's',
          x: 100,
          y: 60,
          floorIndex: 0,
          role: NodeRole.fixture,
          fixture: PlumbingFixture.waterClosetFlushTank),
    ], edges: [
      run('e1', 'm', 'j'),
    ]));
    n.pushUndoSnapshot();
    n.moveNode('wc', 100, 4);
    n.endNodeDragWithSnap('wc', 10);
    final net = c.read(networkControllerProvider).network;
    final wc = net.nodeById('wc')!;
    expect(wc.fixture, PlumbingFixture.waterClosetFlushTank);
    expect(wc.role, NodeRole.fixture);
    expect(net.edgesAt('wc'), hasLength(1));
  });

  test('two content-bearing nodes never join (no silent delete)', () {
    final c = make();
    final n = c.read(networkControllerProvider.notifier);
    n.loadNetwork(Network(
      nodes: [pump('p1', 0, 0), bare('x', 0, 100), pump('p2', 300, 0)],
      edges: [run('e1', 'p1', 'x')],
    ));
    n.pushUndoSnapshot();
    n.moveNode('p2', 2, 0);
    n.endNodeDragWithSnap('p2', 10);
    final net = c.read(networkControllerProvider).network;
    expect(net.nodes.where((x) => x.component == NodeComponent.pump),
        hasLength(2));
  });

  test('seeded property: every drag-end merge conserves the content-bearing '
      'nodes', () {
    final rnd = math.Random(45);
    const comps = [
      NodeComponent.pump,
      NodeComponent.groundTank,
      NodeComponent.ahu,
      NodeComponent.supplyDiffuser,
      null,
    ];
    for (var t = 0; t < 40; t++) {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      final nodes = <NetNode>[];
      final edges = <NetEdge>[];
      for (var i = 0; i < 6; i++) {
        final comp = comps[rnd.nextInt(comps.length)];
        nodes.add(NetNode(
            id: 'n$i',
            sheetId: 's',
            x: 60.0 * i,
            y: 0,
            floorIndex: 0,
            role: comp?.role ?? NodeRole.main,
            component: comp));
        if (i > 0 && rnd.nextBool()) edges.add(run('e$i', 'n${i - 1}', 'n$i'));
      }
      n.loadNetwork(Network(nodes: nodes, edges: edges));
      final before = nodes.where(nodeCarriesContent).length;
      final a = rnd.nextInt(6);
      var b = rnd.nextInt(6);
      if (b == a) b = (a + 1) % 6;
      n.pushUndoSnapshot();
      n.moveNode('n$a', 60.0 * b + 1, 0);
      n.endNodeDragWithSnap('n$a', 10);
      final after = c
          .read(networkControllerProvider)
          .network
          .nodes
          .where(nodeCarriesContent)
          .length;
      expect(after, before, reason: 'trial $t: n$a onto n$b');
    }
  });
}
