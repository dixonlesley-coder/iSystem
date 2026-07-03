import '../units.dart';

/// Mounting-height assumptions that turn a node's floor + role into a true
/// elevation (§10: vertical length comes from elevations, never the PDF).
///
/// Overhead distribution mains run near the ceiling; fixtures tap in lower
/// down; the plant (transfer pump / tank base) sits at an explicit datum. These
/// defaults are editable per project.
class MountingHeights {
  /// How far the horizontal distribution main hangs below the slab above, so
  /// the main sits at `floorElevation + floorHeight − ceilingDrop`.
  final Length ceilingDrop;

  /// Height of a fixture connection above its own floor surface.
  final Length fixtureHeight;

  const MountingHeights({
    this.ceilingDrop = const Length(0.3),
    this.fixtureHeight = const Length(1.1),
  });
}

/// One building level with its floor-to-floor [height].
class Floor {
  final String name;
  final Length height;

  const Floor(this.name, this.height);

  Floor copyWith({String? name, Length? height}) =>
      Floor(name ?? this.name, height ?? this.height);

  @override
  bool operator ==(Object other) =>
      other is Floor && other.name == name && other.height == height;

  @override
  int get hashCode => Object.hash(name, height);
}

/// Ordered building levels (index 0 = lowest). Floor elevations are the SINGLE
/// SOURCE OF TRUTH for vertical (riser) length (§10 / §12.3): a riser's length
/// is a floor-elevation delta, never measured from a PDF.
class BuildingLevels {
  /// Lowest level first.
  final List<Floor> floors;

  const BuildingLevels(this.floors);

  int get levelCount => floors.length;

  /// Clamp a possibly-out-of-range floor [index] into `[0, levelCount)`.
  ///
  /// Defense in depth (§10): the app keeps every node's `floorIndex` within the
  /// live floor stack (project floor-stack + sheet-remap edits remap/clamp the
  /// affected nodes when the stack changes), but a stray out-of-range index
  /// must NEVER crash the always-on sizing/solve with a `RangeError` — it
  /// resolves to the nearest real floor instead (a node above the top sits at
  /// the top; a negative index at the base). The retained assert is a dev aid
  /// on the genuine invariant (a building always has at least one floor); the
  /// out-of-range case is CLAMPED rather than thrown so release builds (asserts
  /// stripped) and asserts-enabled tests alike stay crash-free.
  int _safeFloorIndex(int index) {
    assert(floors.isNotEmpty, 'BuildingLevels must have at least one floor');
    if (floors.isEmpty) return 0;
    final maxIndex = floors.length - 1;
    return index < 0 ? 0 : (index > maxIndex ? maxIndex : index);
  }

  /// Elevation of the floor surface at [index] above the base (floor 0 = 0).
  /// [index] is clamped into range ([_safeFloorIndex]) so an out-of-range node
  /// can never crash the solve.
  Length elevationOf(int index) {
    final top = _safeFloorIndex(index);
    var sum = 0.0;
    for (var i = 0; i < top; i++) {
      sum += floors[i].height.meters;
    }
    return Length(sum);
  }

  /// Floor-to-floor height of the level at [index] (clamped into range).
  Length floorHeightOf(int index) => floors[_safeFloorIndex(index)].height;

  /// Elevation of the horizontal distribution main on [index] — the ceiling of
  /// that floor: `floor surface + floor height − ceilingDrop`. [index] is
  /// clamped into range.
  Length ceilingElevationOf(int index,
      [MountingHeights mounting = const MountingHeights()]) {
    final i = _safeFloorIndex(index);
    return Length(elevationOf(i).meters +
        floors[i].height.meters -
        mounting.ceilingDrop.meters);
  }

  /// Elevation of a fixture connection on [index]:
  /// `floor surface + fixtureHeight`. [index] is clamped into range.
  Length fixtureElevationOf(int index,
      [MountingHeights mounting = const MountingHeights()]) {
    return Length(
        elevationOf(_safeFloorIndex(index)).meters + mounting.fixtureHeight.meters);
  }

  /// Vertical run between two floor surfaces (always ≥ 0). Floor-surface delta;
  /// for distribution mains use [ceilingElevationOf] deltas instead.
  Length riserLength(int fromIndex, int toIndex) => Length(
        (elevationOf(toIndex).meters - elevationOf(fromIndex).meters).abs(),
      );

  /// Total building height (sum of all floor heights) — also the roof level.
  Length get totalHeight =>
      Length(floors.fold(0.0, (sum, f) => sum + f.height.meters));

  /// Roof elevation = top of the topmost floor (where a roof tank sits, before
  /// any tank stand). Alias of [totalHeight].
  Length get roofElevation => totalHeight;
}
