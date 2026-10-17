import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;

import '../data/autosave.dart' show ProviderReader;
import 'annotation_store.dart';
import 'electrical_store.dart';
import 'network_store.dart';
import 'project_store.dart';
import 'reference_line_store.dart';

/// The floor index a piece of FLOOR-PLACED work (a drawn node, a room, a tank,
/// a measurement, an electrical placement) moves to after the building floor
/// STACK changed — the ONE rule every floor-frozen record follows, so the
/// network and the annotations / electrical placements can never drift apart
/// (a room left on floor 0 while the AC node inside it moved to floor 2 stops
/// containing it, and the AC circuit silently falls back to its default load).
///
/// [levelCount] is the NEW floor count. When [insertedCount] floors were
/// INSERTED at [insertedIndex] (basements at 0), work at/above that slot shifts
/// UP by [insertedCount] first. When the floor at [removedIndex] was DELETED,
/// work ON it has no home — null is returned (the caller deletes it, exactly as
/// `NetworkController.remapNodesForFloorChange` deletes nodes there) — and work
/// above it drops one index so it keeps its own physical floor. The result is
/// finally clamped into `[0, levelCount)` (a wholesale shrink drops work above
/// the new top onto it).
int? shiftFloorIndex(
  int floor, {
  required int levelCount,
  int? removedIndex,
  int? insertedIndex,
  int insertedCount = 0,
}) {
  if (removedIndex != null && floor == removedIndex) return null;
  var fi = floor;
  if (insertedIndex != null && insertedCount > 0 && fi >= insertedIndex) {
    fi += insertedCount;
  }
  if (removedIndex != null && fi > removedIndex) fi -= 1;
  final maxIndex = levelCount < 1 ? 0 : levelCount - 1;
  if (fi < 0) fi = 0;
  if (fi > maxIndex) fi = maxIndex;
  return fi;
}

/// The floor index work on a sheet moves to when that sheet's effective floor
/// moved by [delta] (a sheet→floor re-mapping, or a positional shift after a
/// sibling sheet was removed) — mirrors `NetworkController.remapSheetFloor`:
/// shift, then clamp into `[0, levelCount)`.
int shiftSheetFloorIndex(int floor, int delta, {required int levelCount}) {
  final maxIndex = levelCount < 1 ? 0 : levelCount - 1;
  var fi = floor + delta;
  if (fi < 0) fi = 0;
  if (fi > maxIndex) fi = maxIndex;
  return fi;
}

/// Apply a floor mapping to every annotation list (rooms, tanks, measurements)
/// and every electrical placement (panel `layoutPos` + circuit `loadPos`),
/// WITHOUT recording undo — the compound structural edit that calls this has
/// already captured all of them in its ONE [UndoDomain.structural] snapshot.
///
/// [map] receives a record's (sheetId, floorIndex) and returns its new floor,
/// or null when the record has no home any more (its floor was deleted): an
/// annotation is then DELETED (like the drawn nodes on that floor) and an
/// electrical placement is UN-PLACED (the panel / load is a model row, not a
/// drawing — it drops to the unplaced tray and its cable falls back to the
/// manual length rather than vanishing from the design). Records [map] leaves
/// unchanged are kept by identity, so a no-op mapping is byte-identical.
void remapFloorPlacedWork(
  ProviderReader read,
  int? Function(String sheetId, int floorIndex) map,
) {
  // Rooms.
  final rooms = read(roomAreasProvider);
  var roomsChanged = false;
  final nextRooms = <RoomArea>[];
  for (final r in rooms) {
    final fi = map(r.sheetId, r.floorIndex);
    if (fi == null) {
      roomsChanged = true;
    } else if (fi != r.floorIndex) {
      roomsChanged = true;
      nextRooms.add(r.withFloorIndex(fi));
    } else {
      nextRooms.add(r);
    }
  }
  if (roomsChanged) read(roomAreasProvider.notifier).set(nextRooms);

  // Tanks.
  final tanks = read(tankAreasProvider);
  var tanksChanged = false;
  final nextTanks = <TankArea>[];
  for (final t in tanks) {
    final fi = map(t.sheetId, t.floorIndex);
    if (fi == null) {
      tanksChanged = true;
    } else if (fi != t.floorIndex) {
      tanksChanged = true;
      nextTanks.add(t.withFloorIndex(fi));
    } else {
      nextTanks.add(t);
    }
  }
  if (tanksChanged) read(tankAreasProvider.notifier).set(nextTanks);

  // Measurements.
  final measurements = read(measurementsProvider);
  var measurementsChanged = false;
  final nextMeasurements = <Measurement>[];
  for (final m in measurements) {
    final fi = map(m.sheetId, m.floorIndex);
    if (fi == null) {
      measurementsChanged = true;
    } else if (fi != m.floorIndex) {
      measurementsChanged = true;
      nextMeasurements.add(m.withFloorIndex(fi));
    } else {
      nextMeasurements.add(m);
    }
  }
  if (measurementsChanged) {
    read(measurementsProvider.notifier).set(nextMeasurements);
  }

  // Electrical placements.
  read(electricalProjectProvider.notifier).remapLayoutPositions((LayoutPos p) {
    final fi = map(p.sheetId, p.floorIndex);
    if (fi == null) return null;
    return fi == p.floorIndex ? p : p.copyWith(floorIndex: fi);
  });
}

/// Drop everything keyed to a GONE sheet ([isGone] true for its id) — the
/// rooms, tanks, measurements and traced reference lines drawn on it, its
/// calibration (+ stale flag) — and un-place any electrical panel / load placed
/// on it, WITHOUT recording undo (the caller's structural snapshot holds the
/// pre-change state). A gone sheet's leftovers used to survive: an orphan room
/// still fed the equipment schedule, and a re-import with the same filename
/// (`stem#i` ids repeat) silently inherited the old scale and annotations.
void pruneWorkOnSheets(
  ProviderReader read,
  bool Function(String sheetId) isGone,
) {
  remapFloorPlacedWork(read, (sheetId, fi) => isGone(sheetId) ? null : fi);
  final lines = read(referenceLinesProvider);
  if (lines.any((l) => isGone(l.sheetId))) {
    read(referenceLinesProvider.notifier).restoreState([
      for (final l in lines)
        if (!isGone(l.sheetId)) l,
    ]);
  }
  read(projectControllerProvider.notifier).dropCalibrationsWhere(isGone);
}

/// The sheet ids that still carry STATE — a calibration, a drawn node, an
/// annotation, a reference line or an electrical placement — even when no
/// live sheet uses them. A freshly-added sheet must not take one of these ids
/// or it would silently inherit that state.
Set<String> sheetIdsWithState(ProviderReader read) {
  final ids = <String>{
    ...read(projectControllerProvider).calibrations.keys,
    for (final n in read(networkControllerProvider).network.nodes) n.sheetId,
    for (final r in read(roomAreasProvider)) r.sheetId,
    for (final t in read(tankAreasProvider)) t.sheetId,
    for (final m in read(measurementsProvider)) m.sheetId,
    for (final l in read(referenceLinesProvider)) l.sheetId,
  };
  for (final p in read(electricalProjectProvider).panels) {
    if (p.layoutPos != null) ids.add(p.layoutPos!.sheetId);
    for (final c in p.circuits) {
      if (c.loadPos != null) ids.add(c.loadPos!.sheetId);
    }
  }
  return ids;
}
