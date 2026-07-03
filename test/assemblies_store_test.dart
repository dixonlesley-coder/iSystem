import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/assemblies_store.dart';
import 'package:mechx_engine/network/network.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  // A tiny 3-node / 2-edge cold-water network to capture from.
  const net = Network(
    nodes: [
      NetNode(
          id: 'n0',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture),
      NetNode(id: 'n1', sheetId: 's1', x: 30, y: 0, floorIndex: 0),
      NetNode(id: 'n2', sheetId: 's1', x: 60, y: 0, floorIndex: 0),
    ],
    edges: [
      NetEdge(id: 'e0', fromId: 'n0', toId: 'n1', service: ServiceType.coldWater),
      NetEdge(id: 'e1', fromId: 'n1', toId: 'n2', service: ServiceType.coldWater),
    ],
  );

  test('build() is empty by default', () {
    final c = makeContainer();
    expect(c.read(assembliesProvider), isEmpty);
  });

  test('saveSelection captures the selection into a named block', () {
    final c = makeContainer();
    final ctrl = c.read(assembliesProvider.notifier);
    final a = ctrl.saveSelection('WC group', net, {'n0', 'n1'}, {'e0'});
    expect(a, isNotNull);
    expect(c.read(assembliesProvider), hasLength(1));
    expect(a!.name, 'WC group');
    expect(a.nodes.map((n) => n.id).toSet(), {'n0', 'n1'});
    expect(a.edges.map((e) => e.id).toSet(), {'e0'});
  });

  test('a selected edge always pulls in both endpoints', () {
    final c = makeContainer();
    // Select only the edge; its endpoints n0/n1 are pulled into the block.
    final a = c
        .read(assembliesProvider.notifier)
        .saveSelection('run', net, const {}, {'e0'})!;
    expect(a.nodes.map((n) => n.id).toSet(), {'n0', 'n1'});
    expect(a.edges, hasLength(1));
  });

  test('blank name or an empty capture is a no-op', () {
    final c = makeContainer();
    final ctrl = c.read(assembliesProvider.notifier);
    expect(ctrl.saveSelection('   ', net, {'n0'}, const {}), isNull);
    expect(ctrl.saveSelection('x', net, const {}, const {}), isNull);
    expect(c.read(assembliesProvider), isEmpty);
  });

  test('two saves get unique ids', () {
    final c = makeContainer();
    final ctrl = c.read(assembliesProvider.notifier);
    final a = ctrl.saveSelection('a', net, {'n0'}, const {})!;
    final b = ctrl.saveSelection('b', net, {'n1'}, const {})!;
    expect(a.id, isNot(b.id));
    expect(c.read(assembliesProvider), hasLength(2));
  });

  test('remove drops the block by id', () {
    final c = makeContainer();
    final ctrl = c.read(assembliesProvider.notifier);
    final a = ctrl.saveSelection('a', net, {'n0'}, const {})!;
    ctrl.remove(a.id);
    expect(c.read(assembliesProvider), isEmpty);
    // Removing an unknown id is a no-op.
    ctrl.remove('nope');
    expect(c.read(assembliesProvider), isEmpty);
  });

  test('set replaces the list and advances the id counter past loaded ids', () {
    final c = makeContainer();
    final ctrl = c.read(assembliesProvider.notifier);
    ctrl.set(const [SavedAssembly(id: 'asm-5', name: 'loaded')]);
    expect(c.read(assembliesProvider), hasLength(1));
    final a = ctrl.saveSelection('new', net, {'n0'}, const {})!;
    // The next id never collides with the loaded 'asm-5'.
    expect(a.id, 'asm-6');
  });
}
