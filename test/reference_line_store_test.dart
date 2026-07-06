import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/reference_line_store.dart';

void main() {
  test('add ignores a zero-length span and stores real ones', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(referenceLinesProvider.notifier);
    r.add(sheetId: 's1', x1: 10, y1: 10, x2: 10, y2: 10);
    expect(c.read(referenceLinesProvider), isEmpty);
    r.add(sheetId: 's1', x1: 0, y1: 0, x2: 30, y2: 40);
    final list = c.read(referenceLinesProvider);
    expect(list, hasLength(1));
    expect(list.first.pixelLength, closeTo(50, 1e-9)); // 3-4-5
    expect(list.first.sheetId, 's1');
    expect(list.first.label, isNull);
  });

  test('add carries an optional label', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(referenceLinesProvider.notifier);
    r.add(sheetId: 's1', x1: 0, y1: 0, x2: 30, y2: 0, label: 'Shaft wall');
    expect(c.read(referenceLinesProvider).single.label, 'Shaft wall');
  });

  test('removeById and clear', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(referenceLinesProvider.notifier);
    r.add(sheetId: 's1', x1: 0, y1: 0, x2: 1, y2: 0);
    r.add(sheetId: 's1', x1: 0, y1: 0, x2: 2, y2: 0);
    final id0 = c.read(referenceLinesProvider).first.id;
    r.removeById(id0);
    expect(c.read(referenceLinesProvider), hasLength(1));
    expect(c.read(referenceLinesProvider).any((x) => x.id == id0), isFalse);
    r.clear();
    expect(c.read(referenceLinesProvider), isEmpty);
  });

  test('set() loads a list and fresh ids never collide with loaded ones', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(referenceLinesProvider.notifier);
    r.set(const [
      ReferenceLine(id: 'rl5', sheetId: 's1', x1: 0, y1: 0, x2: 1, y2: 1),
    ]);
    expect(c.read(referenceLinesProvider), hasLength(1));
    r.add(sheetId: 's1', x1: 0, y1: 0, x2: 2, y2: 0);
    final ids = c.read(referenceLinesProvider).map((x) => x.id).toSet();
    expect(ids, hasLength(2)); // no collision with the loaded 'rl5'
  });

  test('ReferenceLine.fromJson is tolerant (drops malformed, keeps a label)',
      () {
    expect(ReferenceLine.fromJson('nope'), isNull);
    expect(
        ReferenceLine.fromJson({'id': 'rl1', 'sheetId': 's1'}), isNull); // no coords
    final ok = ReferenceLine.fromJson({
      'id': 'rl1',
      'sheetId': 's1',
      'x1': 1,
      'y1': 2,
      'x2': 3,
      'y2': 4,
      'label': 'Corridor wall',
    });
    expect(ok, isNotNull);
    expect(ok!.label, 'Corridor wall');
    // Round-trip.
    expect(ReferenceLine.fromJson(ok.toJson())!.toJson(), ok.toJson());
    // Absent label ⇒ null, and the key is omitted from toJson.
    final noLabel = ReferenceLine.fromJson({
      'id': 'rl2',
      'sheetId': 's1',
      'x1': 0,
      'y1': 0,
      'x2': 1,
      'y2': 1,
    });
    expect(noLabel!.label, isNull);
    expect(noLabel.toJson().containsKey('label'), isFalse);
  });

  // ── B12: reference-line undo domain ────────────────────────────────────────

  test('reference-line add records on the global timeline and undoes/redoes',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(referenceLinesProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    expect(hist.canUndo, isFalse);
    r.add(sheetId: 's1', x1: 0, y1: 0, x2: 30, y2: 40);
    expect(c.read(referenceLinesProvider), hasLength(1));
    expect(hist.canUndo, isTrue);

    hist.undo();
    expect(c.read(referenceLinesProvider), isEmpty);
    hist.redo();
    expect(c.read(referenceLinesProvider), hasLength(1));
  });

  test('a degenerate (ignored) add records nothing — no phantom undo step', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(referenceLinesProvider.notifier);
    r.add(sheetId: 's1', x1: 5, y1: 5, x2: 5, y2: 5);
    expect(c.read(referenceLinesProvider), isEmpty);
    expect(c.read(historyProvider.notifier).canUndo, isFalse);
  });

  test('delete is undoable — Ctrl+Z restores the deleted reference line', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(referenceLinesProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    r.add(sheetId: 's1', x1: 0, y1: 0, x2: 30, y2: 40, label: 'Shaft wall');
    final id = c.read(referenceLinesProvider).single.id;

    r.removeById(id);
    expect(c.read(referenceLinesProvider), isEmpty);

    hist.undo();
    final restored = c.read(referenceLinesProvider).single;
    expect(restored.id, id);
    expect(restored.label, 'Shaft wall');
  });

  test('reference lines share the global timeline with other domains', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(referenceLinesProvider.notifier);
    final hist = c.read(historyProvider.notifier);

    r.add(sheetId: 's1', x1: 0, y1: 0, x2: 30, y2: 40);
    r.add(sheetId: 's1', x1: 0, y1: 0, x2: 10, y2: 0);

    hist.undo();
    expect(c.read(referenceLinesProvider), hasLength(1));
    hist.undo();
    expect(c.read(referenceLinesProvider), isEmpty);
  });

  test('load path (set) never records — no phantom undo across a project load',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final hist = c.read(historyProvider.notifier);

    // Mirror applyDocument: replace the list wholesale (the load path).
    c.read(referenceLinesProvider.notifier).set(const [
      ReferenceLine(id: 'rl5', sheetId: 's1', x1: 0, y1: 0, x2: 1, y2: 1),
    ]);

    expect(c.read(referenceLinesProvider), hasLength(1));
    expect(hist.canUndo, isFalse);
    expect(hist.canRedo, isFalse);
    expect(c.read(referenceLinesProvider.notifier).canUndo, isFalse);
  });

  test('set() clears the local undo/redo stacks (fresh baseline on load)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(referenceLinesProvider.notifier);

    r.add(sheetId: 's1', x1: 0, y1: 0, x2: 30, y2: 40);
    expect(r.canUndo, isTrue);

    r.set(const []);
    expect(r.canUndo, isFalse);
    expect(r.canRedo, isFalse);
  });
}
