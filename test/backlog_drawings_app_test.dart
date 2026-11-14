// Drawing backlog (2026-11-13) — app-side intents behind the drawing items.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx_engine/electrical/model.dart';

void main() {
  test('C-2 setPanelFloor sets / clears a board\'s riser floor, undoable', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final store = c.read(electricalProjectProvider.notifier);
    store.setProject(const ElectricalProject(
        id: 'p', name: 'p', panels: [ElectricalPanel(id: 'a', name: 'PP-Lt3')]));
    ElectricalPanel a() =>
        c.read(electricalProjectProvider).panels.firstWhere((p) => p.id == 'a');
    expect(a().floorIndex, isNull);
    store.setPanelFloor('a', 2);
    expect(a().floorIndex, 2);
    c.read(historyProvider.notifier).undo();
    expect(a().floorIndex, isNull);
    store.setPanelFloor('a', 4);
    store.setPanelFloor('a', null);
    expect(a().floorIndex, isNull);
    store.setPanelFloor('a', -1);
    expect(a().floorIndex, isNull);
  });
}
