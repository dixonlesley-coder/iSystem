/// Tests for the downfeed pressure-zoning module.
///
/// Hand-computed expected values are documented inline so the derivation is
/// auditable without running the code.
///
/// Building geometry:
///   10 uniform floors, each 3.5 m tall (index 0…9).
///   elevationOf(i) = 3.5 × i  →  floor 9 = 31.5 m, floor 0 = 0.0 m.
///
/// Pressure limit:
///   maxStatic = 196 133 Pa  (≈ 2 kgf/cm²)
///   maxZoneHeight = 196 133 / (1 000 × 9.81) ≈ 19.993 m
///
/// Zone 1 (top floor = 9, elevation 31.5 m):
///   floor 4: 31.5 − 14.0 = 17.5 m  ≤ 19.993  ✓  (included)
///   floor 3: 31.5 − 10.5 = 21.0 m  > 19.993  ✗  → close zone 1 bottom = 4
///   → Zone 1 = floors 4…9  (top=9, bottom=4)
///
/// Zone 2 (top floor = 3, elevation 10.5 m):
///   floor 0: 10.5 − 0.0 = 10.5 m   ≤ 19.993  ✓  (included)
///   → Zone 2 = floors 0…3  (top=3, bottom=0)
library;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/zoning.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

// ── Shared test fixtures ───────────────────────────────────────────────────

/// 10-floor building, each storey 3.5 m.
final _tenFloorBuilding = BuildingLevels(
  List.generate(10, (_) => const Floor('floor', Length(3.5))),
);

/// 3-floor building, each storey 3.5 m.
final _threeFloorBuilding = BuildingLevels(
  List.generate(3, (_) => const Floor('floor', Length(3.5))),
);

/// ≈ 2 kgf/cm²  →  maxZoneHeight ≈ 19.993 m.
const _maxStatic = Pressure(196133);

void main() {
  group('maxZoneHeightMetres', () {
    test('returns headFromPressure in metres — expected ≈ 19.993 m', () {
      // 196 133 / (1 000 × 9.81) = 19.9930...
      expect(maxZoneHeightMetres(_maxStatic), closeTo(19.993, 1e-2));
    });

    test('scales linearly: doubling pressure doubles height', () {
      const p = Pressure(100000);
      expect(
        maxZoneHeightMetres(const Pressure(200000)),
        closeTo(maxZoneHeightMetres(p) * 2, 1e-9),
      );
    });
  });

  group('PressureZone', () {
    test('floors list is bottom-inclusive to top-inclusive', () {
      const zone = PressureZone(9, 4);
      expect(zone.floors, [4, 5, 6, 7, 8, 9]);
    });

    test('floors for a single-floor zone returns one element', () {
      const zone = PressureZone(5, 5);
      expect(zone.floors, [5]);
    });

    test('equality is value-based', () {
      expect(const PressureZone(3, 0), equals(const PressureZone(3, 0)));
      expect(const PressureZone(3, 0), isNot(equals(const PressureZone(3, 1))));
    });
  });

  group('computeDownfeedZones — 10-floor building', () {
    late List<PressureZone> zones;

    setUp(() {
      zones = computeDownfeedZones(
        building: _tenFloorBuilding,
        maxStaticPressure: _maxStatic,
      );
    });

    test('produces exactly 2 zones', () {
      expect(zones, hasLength(2));
    });

    test('zone 0: top=9, bottom=4 (upper zone)', () {
      expect(zones[0].topFloorIndex, 9);
      expect(zones[0].bottomFloorIndex, 4);
    });

    test('zone 1: top=3, bottom=0 (lower zone)', () {
      expect(zones[1].topFloorIndex, 3);
      expect(zones[1].bottomFloorIndex, 0);
    });

    test('zones are ordered top → bottom (zone 0 is highest)', () {
      expect(
        zones[0].topFloorIndex,
        greaterThan(zones[1].topFloorIndex),
      );
    });

    test('every floor index from 0 to 9 appears in exactly one zone', () {
      final allFloors =
          zones.expand((z) => z.floors).toList()..sort();
      expect(allFloors, List.generate(10, (i) => i));
    });

    test('static head at bottom of zone 0 is within limit', () {
      // elevationOf(9) − elevationOf(4) = 31.5 − 14.0 = 17.5 m
      final span = _tenFloorBuilding.elevationOf(9).meters -
          _tenFloorBuilding.elevationOf(4).meters;
      expect(span, closeTo(17.5, 1e-9));
      expect(span, lessThanOrEqualTo(maxZoneHeightMetres(_maxStatic)));
    });

    test('adding floor 3 to zone 0 would violate the limit', () {
      // elevationOf(9) − elevationOf(3) = 31.5 − 10.5 = 21.0 m > 19.993 m
      final span = _tenFloorBuilding.elevationOf(9).meters -
          _tenFloorBuilding.elevationOf(3).meters;
      expect(span, closeTo(21.0, 1e-9));
      expect(span, greaterThan(maxZoneHeightMetres(_maxStatic)));
    });

    test('static head at bottom of zone 1 is within limit', () {
      // elevationOf(3) − elevationOf(0) = 10.5 − 0.0 = 10.5 m
      final span = _tenFloorBuilding.elevationOf(3).meters -
          _tenFloorBuilding.elevationOf(0).meters;
      expect(span, closeTo(10.5, 1e-9));
      expect(span, lessThanOrEqualTo(maxZoneHeightMetres(_maxStatic)));
    });
  });

  group('computeDownfeedZones — 3-floor building (fits in one zone)', () {
    late List<PressureZone> zones;

    setUp(() {
      zones = computeDownfeedZones(
        building: _threeFloorBuilding,
        maxStaticPressure: _maxStatic,
      );
    });

    test('produces exactly 1 zone', () {
      expect(zones, hasLength(1));
    });

    test('single zone spans top=2, bottom=0', () {
      expect(zones[0].topFloorIndex, 2);
      expect(zones[0].bottomFloorIndex, 0);
    });

    test('total span (7.0 m) is within maxZoneHeight (≈19.993 m)', () {
      // elevationOf(2) = 3.5 × 2 = 7.0 m; elevationOf(0) = 0 m → span = 7.0 m
      final span = _threeFloorBuilding.elevationOf(2).meters -
          _threeFloorBuilding.elevationOf(0).meters;
      expect(span, closeTo(7.0, 1e-9));
      expect(span, lessThanOrEqualTo(maxZoneHeightMetres(_maxStatic)));
    });
  });

  group('computeDownfeedZones — edge cases', () {
    test('single-floor building returns one zone top=0, bottom=0', () {
      const single = BuildingLevels([Floor('G', Length(3.5))]);
      final zones = computeDownfeedZones(
        building: single,
        maxStaticPressure: _maxStatic,
      );
      expect(zones, hasLength(1));
      expect(zones[0].topFloorIndex, 0);
      expect(zones[0].bottomFloorIndex, 0);
    });

    test('very low pressure limit forces one zone per floor on tall building',
        () {
      // maxStatic = 1 Pa → maxZoneHeight ≈ 1.02e-4 m (essentially zero).
      // Each consecutive floor pair at 3.5 m apart is a separate zone.
      const veryLow = Pressure(1);
      final zones = computeDownfeedZones(
        building: _tenFloorBuilding,
        maxStaticPressure: veryLow,
      );
      // Each floor becomes its own zone (10 zones for 10 floors).
      expect(zones, hasLength(10));
      for (var i = 0; i < 10; i++) {
        expect(zones[i].topFloorIndex, equals(zones[i].bottomFloorIndex));
      }
    });
  });

  group('downfeedZoneStatics (PRV per-zone profile)', () {
    test('bottom static = PRV setpoint + ρg·(ceiling(top) − fixture(bottom))',
        () {
      // Effective ceiling for zoning = maxFixtureStatic − PRV setpoint, so each
      // zone's bottom fixture stays under the real limit.
      const maxFixtureStatic = Pressure(392266); // ~4 kgf/cm²
      const prv = Pressure(225000); // ~2.25 bar setpoint
      const effectiveCeiling = Pressure(392266 - 225000);
      final zones = computeDownfeedZones(
        building: _tenFloorBuilding,
        maxStaticPressure: effectiveCeiling,
      );
      final statics = downfeedZoneStatics(
        building: _tenFloorBuilding,
        zones: zones,
        prvSetpoint: prv,
        maxStatic: maxFixtureStatic,
      );
      expect(statics, hasLength(zones.length));
      // Every zone must stay within the real fixture limit.
      for (final s in statics) {
        expect(s.withinLimit, isTrue,
            reason: 'zone ${s.zone} exceeds the limit');
        expect(s.bottomStatic.pascals,
            greaterThanOrEqualTo(prv.pascals)); // never below the PRV setpoint
        expect(s.topResidual.pascals, prv.pascals);
      }
    });

    test('a tank far above a tall zone breaches the limit (flagged)', () {
      // One zone spanning all 10 floors (no zoning) with a high PRV setpoint
      // must exceed the limit at the bottom.
      const zones = [PressureZone(9, 0)];
      final statics = downfeedZoneStatics(
        building: _tenFloorBuilding,
        zones: zones,
        prvSetpoint: const Pressure(225000),
        maxStatic: const Pressure(392266),
      );
      expect(statics.single.withinLimit, isFalse);
    });
  });
}
