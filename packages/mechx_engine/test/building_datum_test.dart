import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// The ground-datum + basement behaviour of [BuildingLevels]. The datum floor
/// ([groundIndex]) reads elevation 0.0; basements below it are negative, floors
/// above positive. The datum is a CONSTANT offset, so every elevation DELTA
/// (hence riser length) is invariant to the datum — the invariant the engine
/// relies on when basements shift the frame.
void main() {
  // Ground (4.0) + Level 1 (3.5) + Level 2 (3.5).
  const noBasement = BuildingLevels([
    Floor('Ground', Length(4.0)),
    Floor('Level 1', Length(3.5)),
    Floor('Level 2', Length(3.5)),
  ]);

  group('default (groundIndex 0) — byte-identical to bottom-sum', () {
    test('elevations accumulate from floor 0', () {
      expect(noBasement.elevationOf(0).meters, 0.0);
      expect(noBasement.elevationOf(1).meters, closeTo(4.0, 1e-9));
      expect(noBasement.elevationOf(2).meters, closeTo(7.5, 1e-9));
    });

    test('roofElevation == totalHeight when ground is the base', () {
      expect(noBasement.roofElevation.meters, closeTo(11.0, 1e-9));
      expect(noBasement.totalHeight.meters, closeTo(11.0, 1e-9));
    });
  });

  group('basements (groundIndex > 0)', () {
    // [Basement 1 (3.0), Ground (4.0), Level 1 (3.5)], ground at index 1.
    const withBasement = BuildingLevels([
      Floor('Basement 1', Length(3.0)),
      Floor('Ground', Length(4.0)),
      Floor('Level 1', Length(3.5)),
    ], groundIndex: 1);

    test('ground reads 0.0; the basement is negative; upper floors positive', () {
      expect(withBasement.elevationOf(1).meters, 0.0, reason: 'ground datum');
      expect(withBasement.elevationOf(0).meters, closeTo(-3.0, 1e-9),
          reason: 'a basement sits below ground');
      expect(withBasement.elevationOf(2).meters, closeTo(4.0, 1e-9));
    });

    test('totalHeight is the whole physical stack; roof is above-ground only', () {
      expect(withBasement.totalHeight.meters, closeTo(10.5, 1e-9));
      expect(withBasement.roofElevation.meters, closeTo(7.5, 1e-9),
          reason: 'Ground(4.0) + Level 1(3.5), excluding the basement');
    });

    test('elevation DELTAS are invariant to the datum (riser lengths hold)', () {
      // The same three floors, once bottom-datumed and once ground-datumed:
      // the surface-to-surface deltas must be identical either way.
      const bottom = BuildingLevels([
        Floor('Basement 1', Length(3.0)),
        Floor('Ground', Length(4.0)),
        Floor('Level 1', Length(3.5)),
      ]);
      for (var a = 0; a < 3; a++) {
        for (var b = 0; b < 3; b++) {
          final dBottom =
              bottom.elevationOf(b).meters - bottom.elevationOf(a).meters;
          final dGround =
              withBasement.elevationOf(b).meters - withBasement.elevationOf(a).meters;
          expect(dGround, closeTo(dBottom, 1e-9),
              reason: 'delta $a->$b must not depend on the datum');
        }
      }
    });

    test('an out-of-range groundIndex is clamped, never crashes', () {
      const bad = BuildingLevels([Floor('Only', Length(3.0))], groundIndex: 9);
      expect(bad.elevationOf(0).meters, 0.0);
      expect(bad.roofElevation.meters, closeTo(3.0, 1e-9));
    });
  });
}
