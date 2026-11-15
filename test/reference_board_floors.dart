// Drawing backlog C-2 — the reference fixtures' boards stand on their own
// floors in the electrical riser. Shared by the `reference_*_app_test.dart`
// suites and the drawing-set generator; runs the REAL store intent
// (`ElectricalProjectController.setPanelFloor`), the one the Panel
// inspector's 'Riser floor' field drives.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx/store/electrical_store.dart';

/// The floor a reference board stands on: a floor board `PP-Lt N` / `PP-L N`
/// on floor N-1 (0 = lowest, the fixtures' 'Lantai 1'); every other board
/// (LVMDP, PP-E, the MEP equipment board, a shophouse unit / house board) on
/// the ground floor (index 0 in every fixture).
int referenceBoardFloor(String name) {
  final m = RegExp(r'^PP-L(?:t)?\s*(\d+)$').firstMatch(name.trim());
  return m == null ? 0 : int.parse(m.group(1)!) - 1;
}

/// Sets [referenceBoardFloor] on every board of the loaded project.
void setReferenceBoardFloors(ProviderContainer c) {
  final store = c.read(electricalProjectProvider.notifier);
  for (final p in c.read(electricalProjectProvider).panels) {
    store.setPanelFloor(p.id, referenceBoardFloor(p.name));
  }
}
