// Round 51 — a duplicated floor and an offset run keep the source run's
// hand-picked size + pipe / duct material (plumbing-hvac-convergence finding).
//
// Before: `_appendFloorClones` and `offsetEdgeParallel` built a bare
// `NetEdge(service)`, so every copy reverted to the auto pick (DN15 for a lone
// outlet) and the service-default material — a 9-storey "draw one floor,
// duplicate to L2..L8" project issued different sizes / materials for identical
// floors. Both now go through the shared `_cloneEdge`.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/units.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  // One cold-water run on s1/floor 0 with a hand-picked DN50 + PPR PN16.
  (ProviderContainer, String) seed() {
    final c = makeContainer();
    final n = c.read(networkControllerProvider.notifier);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(100, 0));
    n.setTool(DrawTool.select);
    final id = c.read(networkControllerProvider).network.edges.single.id;
    n.setEdgeSizeOverride(id, Diameter.mm(50));
    n.setEdgePipeProduct(id, PipeProduct.pprPn16);
    return (c, id);
  }

  test('duplicateFloorToTargets keeps sizeOverride + pipeProduct on every copy',
      () {
    final (c, srcId) = seed();
    final n = c.read(networkControllerProvider.notifier);
    n.duplicateFloorToTargets(
      fromSheetId: 's1',
      fromFloor: 0,
      targets: const [(sheetId: 's2', floor: 1), (sheetId: 's3', floor: 2)],
    );
    final net = c.read(networkControllerProvider).network;
    final src = net.edgeById(srcId)!;
    final clones = [
      for (final e in net.edges)
        if (e.id != srcId) e,
    ];
    expect(clones, hasLength(2));
    final sizing = c.read(sizingProvider);
    for (final e in clones) {
      expect(e.sizeOverride, src.sizeOverride);
      expect(e.pipeProduct, PipeProduct.pprPn16);
      expect(e.ductProduct, src.ductProduct);
      // The override is honoured by the sizer, so the copy sizes exactly as
      // the source: DN50 (0.050 m) — never the auto pick.
      expect(sizing[e.id]?.diameter.meters, closeTo(0.050, 1e-12));
      expect(sizing[e.id]?.diameter.meters,
          closeTo(sizing[srcId]!.diameter.meters, 1e-12));
    }
  });

  test('a duct run duplicates with its duct material', () {
    final c = makeContainer();
    final n = c.read(networkControllerProvider.notifier);
    n.setService(ServiceType.duct);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(100, 0));
    n.setTool(DrawTool.select);
    final id = c.read(networkControllerProvider).network.edges.single.id;
    final product = DuctProduct.values.last;
    n.setEdgeDuctProduct(id, product);
    n.duplicateFloorToTargets(
        fromSheetId: 's1',
        fromFloor: 0,
        targets: const [(sheetId: 's2', floor: 1)]);
    final clone = c
        .read(networkControllerProvider)
        .network
        .edges
        .singleWhere((e) => e.id != id);
    expect(clone.ductProduct, product);
    expect(clone.service, ServiceType.duct);
  });

  test('offsetEdgeParallel keeps sizeOverride + pipeProduct', () {
    final (c, srcId) = seed();
    final n = c.read(networkControllerProvider.notifier);
    final newId = n.offsetEdgeParallel(srcId, 30, leftSide: true)!;
    final e = c.read(networkControllerProvider).network.edgeById(newId)!;
    expect(e.sizeOverride?.meters, closeTo(0.050, 1e-12));
    expect(e.pipeProduct, PipeProduct.pprPn16);
    expect(e.kind, EdgeKind.run);
  });

  // Seeded property: for random size / material picks, every duplicated run
  // carries the exact source triple (sizeOverride, pipeProduct, ductProduct).
  test('property: duplicate preserves every run field (seeded)', () {
    final rng = math.Random(51);
    for (var trial = 0; trial < 20; trial++) {
      final c = makeContainer();
      final n = c.read(networkControllerProvider.notifier);
      n.setTool(DrawTool.drawRun);
      final pts = 2 + rng.nextInt(4);
      for (var i = 0; i < pts; i++) {
        n.placeRunPoint('s1', 0, Offset(i * 100.0, rng.nextDouble() * 50));
      }
      n.setTool(DrawTool.select);
      final edges = c.read(networkControllerProvider).network.edges;
      for (final e in edges) {
        if (rng.nextBool()) {
          n.setEdgeSizeOverride(e.id, Diameter.mm(20.0 + 5 * rng.nextInt(10)));
        }
        if (rng.nextBool()) {
          n.setEdgePipeProduct(e.id,
              PipeProduct.values[rng.nextInt(PipeProduct.values.length)]);
        }
      }
      final before = c.read(networkControllerProvider).network.edges;
      n.duplicateFloorToTargets(
          fromSheetId: 's1',
          fromFloor: 0,
          targets: const [(sheetId: 's2', floor: 1)]);
      final after = c.read(networkControllerProvider).network.edges;
      final copies = after.skip(before.length).toList();
      expect(copies, hasLength(before.length));
      // Clones are appended in source-edge order.
      for (var i = 0; i < before.length; i++) {
        expect(copies[i].sizeOverride, before[i].sizeOverride);
        expect(copies[i].pipeProduct, before[i].pipeProduct);
        expect(copies[i].ductProduct, before[i].ductProduct);
        expect(copies[i].service, before[i].service);
      }
    }
  });

  // Round 51 r2 — `_appendFloorClones` now carries `e.kind` through
  // `_cloneEdge` (it used to force `EdgeKind.run`). Its edge filter admits
  // RUNS only, so a riser whose both ends sit on the source floor / sheet (a
  // riser clamped onto one floor) is still never cloned — the copy can never
  // turn into a riser, nor a riser into a run.
  test('duplicate floor clones runs only: a clamped riser is not copied', () {
    final c = makeContainer();
    final n = c.read(networkControllerProvider.notifier);
    NetNode node(String id, double x) =>
        NetNode(id: id, sheetId: 's1', x: x, y: 0, floorIndex: 0);
    n.loadNetwork(Network(nodes: [
      node('a', 0),
      node('b', 100),
      node('c', 200),
    ], edges: const [
      NetEdge(id: 'run', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      NetEdge(
          id: 'rsr',
          fromId: 'b',
          toId: 'c',
          service: ServiceType.coldWater,
          kind: EdgeKind.riser),
    ]));
    n.duplicateFloorToTargets(
      fromSheetId: 's1',
      fromFloor: 0,
      targets: const [(sheetId: 's2', floor: 1)],
    );
    final net = c.read(networkControllerProvider).network;
    final copies = [
      for (final e in net.edges)
        if (e.id != 'run' && e.id != 'rsr') e,
    ];
    expect(copies, hasLength(1));
    expect(copies.single.kind, EdgeKind.run);
  });
}
