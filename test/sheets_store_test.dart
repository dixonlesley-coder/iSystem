import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/viewport.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  /// A1: production launches EMPTY; the placeholder sheets are a test/golden
  /// seed only. Tests below that navigate/map sheets seed them explicitly.
  ProviderContainer makeSeededContainer() {
    final c = makeContainer();
    c.read(sheetsControllerProvider.notifier).loadDemoSheets();
    return c;
  }

  test('starts EMPTY — no placeholder sheets on first launch (A1)', () {
    final c = makeContainer();
    final s = c.read(sheetsControllerProvider);
    expect(s.isEmpty, isTrue);
    expect(s.sheets, isEmpty);
    expect(s.current, isNull);
  });

  test('loadDemoSheets seeds the demo project, first selected', () {
    final c = makeSeededContainer();
    final s = c.read(sheetsControllerProvider);
    expect(s.sheets.length, 3);
    expect(s.sheets, kDemoSheets);
    expect(s.currentIndex, 0);
    expect(s.current?.name, 'Ground Floor');
  });

  test('selectSheet changes the current sheet', () {
    final c = makeSeededContainer();
    c.read(sheetsControllerProvider.notifier).selectSheet(2);
    expect(c.read(sheetsControllerProvider).current?.id, 's3');
  });

  test('selectSheet ignores out-of-range indices', () {
    final c = makeSeededContainer();
    c.read(sheetsControllerProvider.notifier).selectSheet(99);
    expect(c.read(sheetsControllerProvider).currentIndex, 0);
  });

  test('viewport persists per sheet and restores; others stay unframed', () {
    final c = makeSeededContainer();
    final ctrl = c.read(sheetsControllerProvider.notifier);
    const vt = ViewportTransform(scale: 2.5, offset: Offset(12, 34));
    ctrl.setViewport('s2', vt);
    expect(c.read(sheetsControllerProvider).viewportFor('s2'), vt);
    expect(c.read(sheetsControllerProvider).viewportFor('s1'), isNull);
  });

  test('loadSheets replaces and resets selection + viewports', () {
    final c = makeSeededContainer();
    final ctrl = c.read(sheetsControllerProvider.notifier);
    ctrl.setViewport('s1', const ViewportTransform(scale: 3));
    ctrl.loadSheets(const [Sheet(id: 'x', name: 'X')]);
    final s = c.read(sheetsControllerProvider);
    expect(s.sheets.single.id, 'x');
    expect(s.currentIndex, 0);
    expect(s.viewportFor('s1'), isNull);
  });

  test('floorFor: positional default, explicit override, clamped', () {
    final c = makeSeededContainer();
    final ctrl = c.read(sheetsControllerProvider.notifier);
    // 3 demo sheets s1,s2,s3 → positional floors 0,1,2 within a 3-floor model.
    var s = c.read(sheetsControllerProvider);
    expect(s.floorFor('s1', 3), 0);
    expect(s.floorFor('s2', 3), 1);
    expect(s.floorFor('s3', 3), 2);
    // explicit override
    ctrl.setSheetFloor('s3', 0);
    s = c.read(sheetsControllerProvider);
    expect(s.floorFor('s3', 3), 0);
    // clamped to the building's level count
    expect(s.floorFor('s2', 1), 0); // positional 1 → clamp to 0 when 1 level
  });

  test('setSheetFloor is undoable via the global history timeline', () {
    final c = makeSeededContainer();
    final sheets = c.read(sheetsControllerProvider.notifier);
    final history = c.read(historyProvider.notifier);

    // s3's positional default is floor 2; override it to 0.
    sheets.setSheetFloor('s3', 0);
    expect(c.read(sheetsControllerProvider).floorFor('s3', 3), 0);
    expect(history.canUndo, isTrue);

    // Undo on the global timeline reverts the mapping to its positional default.
    history.undo();
    expect(c.read(sheetsControllerProvider).floorFor('s3', 3), 2);

    // Redo restores the override.
    history.redo();
    expect(c.read(sheetsControllerProvider).floorFor('s3', 3), 0);
  });

  test('loadSheets clears the sheet-floor undo stack', () {
    final c = makeSeededContainer();
    final sheets = c.read(sheetsControllerProvider.notifier);

    sheets.setSheetFloor('s3', 0);
    expect(sheets.canUndo, isTrue);

    // A loaded document is a fresh baseline — the local mapping history is
    // cleared so an undo can't reach back into the previous document.
    sheets.loadSheets(const [Sheet(id: 'x', name: 'X')]);
    expect(sheets.canUndo, isFalse);
  });
}
