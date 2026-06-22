import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/viewport.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('starts with demo sheets, first selected', () {
    final c = makeContainer();
    final s = c.read(sheetsControllerProvider);
    expect(s.sheets.length, 3);
    expect(s.currentIndex, 0);
    expect(s.current?.name, 'Ground Floor');
  });

  test('selectSheet changes the current sheet', () {
    final c = makeContainer();
    c.read(sheetsControllerProvider.notifier).selectSheet(2);
    expect(c.read(sheetsControllerProvider).current?.id, 's3');
  });

  test('selectSheet ignores out-of-range indices', () {
    final c = makeContainer();
    c.read(sheetsControllerProvider.notifier).selectSheet(99);
    expect(c.read(sheetsControllerProvider).currentIndex, 0);
  });

  test('viewport persists per sheet and restores; others stay unframed', () {
    final c = makeContainer();
    final ctrl = c.read(sheetsControllerProvider.notifier);
    const vt = ViewportTransform(scale: 2.5, offset: Offset(12, 34));
    ctrl.setViewport('s2', vt);
    expect(c.read(sheetsControllerProvider).viewportFor('s2'), vt);
    expect(c.read(sheetsControllerProvider).viewportFor('s1'), isNull);
  });

  test('loadSheets replaces and resets selection + viewports', () {
    final c = makeContainer();
    final ctrl = c.read(sheetsControllerProvider.notifier);
    ctrl.setViewport('s1', const ViewportTransform(scale: 3));
    ctrl.loadSheets(const [Sheet(id: 'x', name: 'X')]);
    final s = c.read(sheetsControllerProvider);
    expect(s.sheets.single.id, 'x');
    expect(s.currentIndex, 0);
    expect(s.viewportFor('s1'), isNull);
  });
}
