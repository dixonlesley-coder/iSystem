/// Tests for the room air-side sizing engine (ACH → CFM → ducts/diffusers/fan).
///
/// Expected values are hand-computed from first principles; the arithmetic is
/// shown in comments next to each assertion so a reviewer can reproduce it.
library;

import 'package:mechx_engine/sizing/grille_sizing.dart';
import 'package:mechx_engine/sizing/network_sizing.dart'
    show DuctShape, DuctSizingMethod;
import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // ── CFM unit conversion ────────────────────────────────────────────────────

  group('FlowRate CFM conversion', () {
    test('1 m³/s ≈ 2118.88 CFM', () {
      // 1 ft = 0.3048 m → 1 ft³ = 0.3048³ = 0.028316846592 m³.
      //   1 m³/s = 60 / 0.028316846592 = 2118.880 CFM.
      expect(const FlowRate(1.0).inCubicFeetPerMinute, closeTo(2118.88, 0.01));
    });

    test('cubicFeetPerMinute round-trips', () {
      final f = FlowRate.cubicFeetPerMinute(500.0);
      expect(f.inCubicFeetPerMinute, closeTo(500.0, 1e-9));
    });

    test('0.25 m³/s = 250 L/s = 529.72 CFM', () {
      const q = FlowRate(0.25);
      expect(q.inLitersPerSecond, closeTo(250.0, 1e-9));
      // 0.25 × 2118.880 = 529.720 CFM.
      expect(q.inCubicFeetPerMinute, closeTo(529.72, 0.01));
    });
  });

  // ── ACH → airflow ──────────────────────────────────────────────────────────

  group('airChangeFlow', () {
    test('50 m² × 3 m × 6 ACH → 0.25 m³/s (250 L/s, 529.72 CFM)', () {
      // volume = 50 × 3 = 150 m³
      //   Q = volume × ACH / 3600 = 150 × 6 / 3600 = 900 / 3600 = 0.25 m³/s.
      final q = airChangeFlow(
        floorArea: const Area(50.0),
        ceilingHeight: const Length(3.0),
        airChangesPerHour: 6.0,
      );
      expect(q.cubicMetersPerSecond, closeTo(0.25, 1e-12));
      expect(q.inLitersPerSecond, closeTo(250.0, 1e-9));
      expect(q.inCubicFeetPerMinute, closeTo(529.72, 0.01));
    });

    test('airflow scales linearly with ACH and with area', () {
      final base = airChangeFlow(
        floorArea: const Area(40.0),
        ceilingHeight: const Length(3.0),
        airChangesPerHour: 5.0,
      );
      final doubleAch = airChangeFlow(
        floorArea: const Area(40.0),
        ceilingHeight: const Length(3.0),
        airChangesPerHour: 10.0,
      );
      final doubleArea = airChangeFlow(
        floorArea: const Area(80.0),
        ceilingHeight: const Length(3.0),
        airChangesPerHour: 5.0,
      );
      expect(doubleAch.cubicMetersPerSecond,
          closeTo(2.0 * base.cubicMetersPerSecond, 1e-12));
      expect(doubleArea.cubicMetersPerSecond,
          closeTo(2.0 * base.cubicMetersPerSecond, 1e-12));
    });

    test('roomVolumeM3 = area × height', () {
      expect(roomVolumeM3(const Area(50.0), const Length(3.0)),
          closeTo(150.0, 1e-12));
    });
  });

  // ── sizeRoomAir: single-diffuser office room ───────────────────────────────

  group('sizeRoomAir — 50 m² office', () {
    final r = sizeRoomAir(
      floorArea: const Area(50.0),
      ceilingHeight: const Length(3.0),
      airChangesPerHour: 6.0,
      equipmentKind: AirEquipmentKind.fcu,
      grilleApplication: GrilleApplication.office,
    );

    test('airflow = 0.25 m³/s and CFM ≈ 529.72', () {
      expect(r.airflow.cubicMetersPerSecond, closeTo(0.25, 1e-12));
      expect(r.airflowCfm, closeTo(529.72, 0.01));
      expect(r.roomVolumeM3, closeTo(150.0, 1e-12));
    });

    test('one supply diffuser at 450×300 face (≤ 0.864 m³/s/terminal)', () {
      // maxPerTerminal = largestGross(0.36) × 0.8 × 3.0 = 0.864 m³/s.
      //   count = ceil(0.25 / 0.864) = ceil(0.289) = 1, so each carries 0.25.
      // selectStandardGrille(0.25, 3.0): grossArea_min = (0.25/3)/0.8 = 0.10417 m²
      //   → smallest standard face ≥ that is 450×300 = 0.135 m².
      expect(r.supply.count, 1);
      expect(r.supply.airflowEach.cubicMetersPerSecond, closeTo(0.25, 1e-12));
      expect(r.supply.each.grossFaceArea.squareMeters, closeTo(0.135, 1e-9));
      // faceVelocity = 0.25 / (0.135 × 0.8) = 0.25 / 0.108 = 2.3148 m/s ≤ 3.0.
      expect(r.supply.each.faceVelocity.metersPerSecond, closeTo(2.3148, 1e-3));
    });

    test('one return grille, same face as supply for equal airflow', () {
      expect(r.return_.count, 1);
      expect(r.return_.each.grossFaceArea.squareMeters, closeTo(0.135, 1e-9));
    });

    test('round supply trunk rounds up to 315 mm', () {
      // sizeByVelocity(0.25, 5.0): A = 0.25/5 = 0.05 m²;
      //   D_ideal = sqrt(4×0.05/π) = sqrt(0.063662) = 0.25232 m = 252.3 mm;
      //   first standard ≥ 252.3 mm is 315 mm.
      expect(r.supplyDuctRound, isNotNull);
      expect(r.supplyDuctRect, isNull);
      expect(r.supplyDuctRound!.diameter.inMillimeters, closeTo(315.0, 1e-9));
      expect(r.supplyDuctDiameter.inMillimeters, closeTo(315.0, 1e-9));
    });

    test('FCU duty: static ≥ no-duct floor and air power = Q·Δp', () {
      // totalStatic = internal(FCU 50) + ductFriction×15×1.3 + supply 30 + return 20.
      //   The no-duct floor (zero friction) would be 50+30+20 = 100 Pa, so the
      //   estimate must exceed it once duct friction is added.
      expect(r.equipment.airflow.cubicMetersPerSecond, closeTo(0.25, 1e-12));
      expect(r.equipment.totalStaticPressure.pascals, greaterThan(100.0));
      // air power = Q · Δp (fan fundamental).
      expect(
        r.equipment.airPower.watts,
        closeTo(
          r.airflow.cubicMetersPerSecond *
              r.equipment.totalStaticPressure.pascals,
          1e-9,
        ),
      );
      // selected motor must cover the shaft power.
      expect(r.equipment.selectedMotor.watts,
          greaterThanOrEqualTo(r.equipment.shaftPower.watts));
    });

    test('AHU internal static is higher than FCU for the same room', () {
      final ahu = sizeRoomAir(
        floorArea: const Area(50.0),
        ceilingHeight: const Length(3.0),
        airChangesPerHour: 6.0,
        equipmentKind: AirEquipmentKind.ahu,
        grilleApplication: GrilleApplication.office,
      );
      expect(ahu.equipment.totalStaticPressure.pascals,
          greaterThan(r.equipment.totalStaticPressure.pascals));
    });
  });

  // ── sizeRoomAir: multi-diffuser auto-count ─────────────────────────────────

  group('sizeRoomAir — auto-counts diffusers when airflow is large', () {
    test('Q = 1.0 m³/s at office face → 2 supply diffusers, 560 mm trunk', () {
      // volume × ACH = 3600 ⇒ Q = 1.0 m³/s (100 m² × 3 m × 12 ACH).
      // maxPerTerminal = 0.36 × 0.8 × 3.0 = 0.864 m³/s.
      //   count = ceil(1.0 / 0.864) = ceil(1.157) = 2; each carries 0.5 m³/s.
      // Round trunk: A = 1.0/5 = 0.2 m²; D_ideal = sqrt(0.8/π) = 0.5046 m
      //   = 504.6 mm → first standard ≥ that is 560 mm.
      final r = sizeRoomAir(
        floorArea: const Area(100.0),
        ceilingHeight: const Length(3.0),
        airChangesPerHour: 12.0,
        grilleApplication: GrilleApplication.office,
      );
      expect(r.airflow.cubicMetersPerSecond, closeTo(1.0, 1e-12));
      expect(r.supply.count, 2);
      expect(r.supply.airflowEach.cubicMetersPerSecond, closeTo(0.5, 1e-12));
      expect(r.supplyDuctRound!.diameter.inMillimeters, closeTo(560.0, 1e-9));
    });
  });

  // ── sizeRoomAir: rectangular duct path ─────────────────────────────────────

  group('sizeRoomAir — rectangular duct', () {
    test('rectangular shape returns a rectangular trunk, no round result', () {
      final r = sizeRoomAir(
        floorArea: const Area(50.0),
        ceilingHeight: const Length(3.0),
        airChangesPerHour: 6.0,
        ductShape: DuctShape.rectangular,
        ductAspectRatio: 1.5,
      );
      expect(r.supplyDuctRound, isNull);
      expect(r.supplyDuctRect, isNotNull);
      // velocity must respect the 5 m/s cap (sizes round each side up).
      expect(r.supplyDuctRect!.actualVelocity.metersPerSecond,
          lessThanOrEqualTo(5.0));
      expect(r.supplyDuctDiameter.inMillimeters, greaterThan(0.0));
    });
  });

  // ── equal-friction method ──────────────────────────────────────────────────

  group('sizeRoomAir — equal-friction round duct', () {
    test('equal-friction picks a duct whose Δp/L ≤ target', () {
      final r = sizeRoomAir(
        floorArea: const Area(50.0),
        ceilingHeight: const Length(3.0),
        airChangesPerHour: 6.0,
        ductMethod: DuctSizingMethod.equalFriction,
        ductEqualFrictionPa: 1.0,
      );
      expect(r.supplyDuctRound, isNotNull);
      expect(r.supplyDuctRound!.frictionPerMetrePa, lessThanOrEqualTo(1.0));
    });
  });
}
