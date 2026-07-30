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
///
/// ONE MEASUREMENT (M1) — the span a zone is BUDGETED on
/// ([computeDownfeedZones]) is the same span it is CHECKED on
/// ([downfeedZoneStatics]): the feed point is the ceiling main on the zone's TOP
/// floor and the worst case is the fixture connection on the zone's BOTTOM
/// floor, i.e.
///   span = ceilingElevationOf(top) − fixtureElevationOf(bottom)
///        = (elevationOf(top) − elevationOf(bottom))
///          + floorHeight(top) − ceilingDrop − fixtureHeight.
/// Budgeting on the bare floor-surface delta (as the zoner used to) silently
/// omits that `floorHeight(top) − ceilingDrop − fixtureHeight` term, so a
/// building with tall storeys was handed zones the module's own checker
/// rejected. The checker is the honest measurement; the zoner now budgets
/// against it, so a generated zone is compliant BY CONSTRUCTION.
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

// ── PRV zone statics ─────────────────────────────────────────────────────────

/// Static-pressure profile of one downfeed zone fed through a PRV (or the tank
/// for the top zone).
class DownfeedZoneStatic {
  final PressureZone zone;

  /// Residual maintained just downstream of the PRV at the zone's top
  /// (the PRV setpoint).
  final Pressure topResidual;

  /// Static pressure at the zone's lowest fixture — the worst case in the zone.
  final Pressure bottomStatic;

  /// True when [bottomStatic] stays at or below the project limit.
  final bool withinLimit;

  const DownfeedZoneStatic({
    required this.zone,
    required this.topResidual,
    required this.bottomStatic,
    required this.withinLimit,
  });
}

/// For each downfeed [zone], the static pressure at its lowest fixture when the
/// zone is fed through a PRV set to [prvSetpoint] (the residual held at the zone
/// top), and whether that stays at or below [maxStatic].
///
/// Feed elevation is the ceiling main at the zone's top floor; the bottom
/// fixture sits at fixture height on the zone's lowest floor:
///   bottomStatic = prvSetpoint + ρg·(ceiling(top) − fixture(bottom)).
List<DownfeedZoneStatic> downfeedZoneStatics({
  required BuildingLevels building,
  required List<PressureZone> zones,
  required Pressure prvSetpoint,
  required Pressure maxStatic,
  MountingHeights mounting = const MountingHeights(),
}) {
  final out = <DownfeedZoneStatic>[];
  for (final z in zones) {
    final feed = building.ceilingElevationOf(z.topFloorIndex, mounting).meters;
    final bottom =
        building.fixtureElevationOf(z.bottomFloorIndex, mounting).meters;
    final span = (feed - bottom).clamp(0.0, double.infinity);
    final bottomStatic =
        Pressure(prvSetpoint.pascals + pressureFromHead(Head(span)).pascals);
    out.add(DownfeedZoneStatic(
      zone: z,
      topResidual: prvSetpoint,
      bottomStatic: bottomStatic,
      withinLimit: bottomStatic.pascals <= maxStatic.pascals,
    ));
  }
  return out;
}

// ── Core algorithm ─────────────────────────────────────────────────────────

/// Partition [building] into downfeed pressure zones so that the static head
/// at the bottom floor of every zone does not exceed [maxStaticPressure].
///
/// The span budgeted here is the SAME span [downfeedZoneStatics] measures — the
/// ceiling main on the zone's top floor down to the fixture connection on its
/// bottom floor, per [mounting] — so every generated zone is compliant by
/// construction against that check (see the library note). [maxStaticPressure]
/// is the span budget: a caller holding a PRV setpoint at each zone top passes
/// the REMAINING allowance (max-fixture-static − setpoint).
///
/// Algorithm (greedy, top-down):
/// 1. Start the first zone at the highest floor (index `levelCount − 1`).
/// 2. Walk downward, including each floor f while
///    `ceilingElevationOf(zoneTop) − fixtureElevationOf(f) ≤ maxZoneHeightMetres`.
/// 3. When the next floor would violate the limit, close the current zone
///    (its bottom = the last included floor) and open a new zone whose top is
///    the next (violating) floor.
/// 4. At floor 0, always close the last zone.
///
/// A zone is never split below one floor (step 2 always admits `f == zoneTop`):
/// a single storey is physically indivisible, so when one floor's own
/// ceiling-to-fixture drop already exceeds the budget the zone is still emitted
/// — [downfeedZoneStatics] then reports it over-limit, which is the honest
/// outcome (the remedy is a lower PRV setpoint / higher limit, not more zones).
///
/// IDENTITY — a building whose PREVIOUS zoning already passed
/// [downfeedZoneStatics] gets exactly the same zones from this stricter budget.
/// The new span exceeds the old floor-surface span by a constant
/// `floorHeight(top) − ceilingDrop − fixtureHeight ≥ 0` (any storey taller than
/// 1.4 m), so the walk cannot admit a floor the old one rejected, and "already
/// passed" means it does not reject a floor the old one admitted.
///
/// Returns zones ordered **top → bottom** (index 0 = highest zone).
List<PressureZone> computeDownfeedZones({
  required BuildingLevels building,
  required Pressure maxStaticPressure,
  MountingHeights mounting = const MountingHeights(),
}) {
  assert(building.levelCount > 0, 'building must have at least one floor');

  final maxHeight = maxZoneHeightMetres(maxStaticPressure);
  final zones = <PressureZone>[];

  var zoneTop = building.levelCount - 1;

  for (var f = building.levelCount - 1; f >= 0; f--) {
    // The measured span of the candidate zone [zoneTop … f] — identical to the
    // one downfeedZoneStatics evaluates.
    final span = building.ceilingElevationOf(zoneTop, mounting).meters -
        building.fixtureElevationOf(f, mounting).meters;

    if (span > maxHeight && f < zoneTop) {
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
