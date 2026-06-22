import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/selection_store.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('starts empty', () {
    final c = makeContainer();
    expect(c.read(selectionProvider).isEmpty, isTrue);
  });

  test('selectNode / selectEdge are mutually exclusive; clear resets', () {
    final c = makeContainer();
    final s = c.read(selectionProvider.notifier);

    s.selectNode('n1');
    expect(c.read(selectionProvider).nodeId, 'n1');
    expect(c.read(selectionProvider).isNode, isTrue);
    expect(c.read(selectionProvider).isEdge, isFalse);

    s.selectEdge('e1');
    expect(c.read(selectionProvider).edgeId, 'e1');
    expect(c.read(selectionProvider).nodeId, isNull);
    expect(c.read(selectionProvider).isEdge, isTrue);

    s.clear();
    expect(c.read(selectionProvider).isEmpty, isTrue);
  });
}
