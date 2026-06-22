import '../units.dart';

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

  /// Elevation of the floor surface at [index] above the base (floor 0 = 0).
  Length elevationOf(int index) {
    assert(index >= 0 && index < floors.length, 'floor index out of range');
    var sum = 0.0;
    for (var i = 0; i < index; i++) {
      sum += floors[i].height.meters;
    }
    return Length(sum);
  }

  /// Vertical run between two floor surfaces (always ≥ 0).
  Length riserLength(int fromIndex, int toIndex) => Length(
        (elevationOf(toIndex).meters - elevationOf(fromIndex).meters).abs(),
      );

  /// Total building height (sum of all floor heights).
  Length get totalHeight =>
      Length(floors.fold(0.0, (sum, f) => sum + f.height.meters));
}
