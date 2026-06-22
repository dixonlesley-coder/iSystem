/// Pressure-zoning module for a downfeed (top-fed) water-supply system.
///
/// In a downfeed system, water is stored in a roof tank and distributed
/// downward. Static pressure therefore *increases* going down: the static head
/// at any floor equals ρg × (feedElevation − floorElevation). Each pressure
/// zone is fed at its TOP floor via a tank outlet or PRV set. We must prevent
/// the static pressure at the lowest floor of any zone from exceeding a
/// project-specified limit [maxStaticPressure].
///
/// The maximum height a single zone may span is therefore:
///   maxZoneHeight = maxStaticPressure / (ρ × g)   [metres]
/// which is exactly [headFromPressure](maxStaticPressure).
library;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/units.dart';

// ── Domain type ────────────────────────────────────────────────────────────

/// A contiguous band of floors served by a single pressure zone in a downfeed
/// water-supply system.
///
/// [topFloorIndex] is the highest floor (feed point / PRV inlet).
/// [bottomFloorIndex] is the lowest floor (highest static pressure in zone).
/// Indices are 0-based, matching [BuildingLevels.elevationOf].
class PressureZone {
  final int topFloorIndex;
  final int bottomFloorIndex;

  const PressureZone(this.topFloorIndex, this.bottomFloorIndex);

  /// All floor indices in this zone, ordered bottom → top.
  List<int> get floors =>
      [for (var f = bottomFloorIndex; f <= topFloorIndex; f++) f];

  @override
  String toString() =>
      'PressureZone(top: $topFloorIndex, bottom: $bottomFloorIndex)';

  @override
  bool operator ==(Object other) =>
      other is PressureZone &&
      other.topFloorIndex == topFloorIndex &&
      other.bottomFloorIndex == bottomFloorIndex;

  @override
  int get hashCode => Object.hash(topFloorIndex, bottomFloorIndex);
}

// ── Helpers ────────────────────────────────────────────────────────────────

/// Maximum vertical height (metres) that a single downfeed pressure zone may
/// span, given [maxStatic] as the upper bound on static pressure at the lowest
/// floor.
///
/// Derivation: P = ρ·g·h  →  h = P/(ρ·g)  = headFromPressure(P).
double maxZoneHeightMetres(Pressure maxStatic) =>
    headFromPressure(maxStatic).meters;

// ── Core algorithm ─────────────────────────────────────────────────────────

/// Partition [building] into downfeed pressure zones so that the static head
/// at the bottom floor of every zone does not exceed [maxStaticPressure].
///
/// Algorithm (greedy, top-down):
/// 1. Start the first zone at the highest floor (index `levelCount − 1`).
/// 2. Walk downward, including each floor f while
///    `elevationOf(zoneTop) − elevationOf(f) ≤ maxZoneHeightMetres`.
/// 3. When the next floor would violate the limit, close the current zone
///    (its bottom = the last included floor) and open a new zone whose top is
///    the next (violating) floor.
/// 4. At floor 0, always close the last zone.
///
/// Returns zones ordered **top → bottom** (index 0 = highest zone).
List<PressureZone> computeDownfeedZones({
  required BuildingLevels building,
  required Pressure maxStaticPressure,
}) {
  assert(building.levelCount > 0, 'building must have at least one floor');

  final maxHeight = maxZoneHeightMetres(maxStaticPressure);
  final zones = <PressureZone>[];

  var zoneTop = building.levelCount - 1;

  for (var f = building.levelCount - 1; f >= 0; f--) {
    final span = building.elevationOf(zoneTop).meters -
        building.elevationOf(f).meters;

    if (span > maxHeight) {
      // Floor f would breach the limit — close the current zone at f+1 (the
      // last floor that was still within the limit) and start a new zone
      // whose top is f.
      zones.add(PressureZone(zoneTop, f + 1));
      zoneTop = f;
    }

    // Always close the last zone at floor 0.
    if (f == 0) {
      zones.add(PressureZone(zoneTop, 0));
    }
  }

  return zones;
}
