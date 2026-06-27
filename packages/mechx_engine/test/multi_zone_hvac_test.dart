/// Tests for multi-zone HVAC aggregation (one AHU serving several rooms).
///
/// Hand-derived: airflow summation, diversity-factor application, governing
/// static pressure, make-up / exhaust balance, and per-zone contributions.
library;

import 'package:mechx_engine/sizing/network_sizing.dart' show DuctShape;
import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // Three rooms sized via the existing sizeRoomAir path. We read each room's
  // own airflow (Q = volume × ACH / 3600) and sum it.
  //
  //   A: 50 m² × 3 m, 6 ACH → 150 × 6 / 3600 = 0.25     m³/s
  //   B: 40 m² × 3 m, 6 ACH → 120 × 6 / 3600 = 0.20     m³/s
  //   C: 30 m² × 3 m, 4 ACH →  90 × 4 / 3600 = 0.10     m³/s
  //   Σ = 0.55 m³/s.
  final roomA = sizeRoomAir(
    floorArea: const Area(50.0),
    ceilingHeight: const Length(3.0),
    airChangesPerHour: 6.0,
    ductShape: DuctShape.round,
  );
  final roomB = sizeRoomAir(
    floorArea: const Area(40.0),
    ceilingHeight: const Length(3.0),
    airChangesPerHour: 6.0,
    ductShape: DuctShape.round,
  );
  final roomC = sizeRoomAir(
    floorArea: const Area(30.0),
    ceilingHeight: const Length(3.0),
    airChangesPerHour: 4.0,
    ductShape: DuctShape.round,
  );

  group('airflow summation + diversity', () {
    test('per-room airflows are 0.25 / 0.20 / 0.10 m³/s', () {
      expect(roomA.airflow.cubicMetersPerSecond, closeTo(0.25, 1e-9));
      expect(roomB.airflow.cubicMetersPerSecond, closeTo(0.20, 1e-9));
      expect(roomC.airflow.cubicMetersPerSecond, closeTo(0.10, 1e-9));
    });

    test('summed = 0.55, diversified ×0.9 = 0.495 m³/s', () {
      final r = multiZoneAirSystem(
        zones: [roomA, roomB, roomC],
        diversityFactor: 0.9,
      );
      expect(r.summedAirflow.cubicMetersPerSecond, closeTo(0.55, 1e-9));
      // 0.55 × 0.9 = 0.495.
      expect(r.aggregatedAirflow.cubicMetersPerSecond, closeTo(0.495, 1e-9));
    });

    test('diversity = 1.0 leaves the sum unchanged', () {
      final r = multiZoneAirSystem(
        zones: [roomA, roomB, roomC],
        diversityFactor: 1.0,
      );
      expect(r.aggregatedAirflow.cubicMetersPerSecond, closeTo(0.55, 1e-9));
    });
  });

  group('governing static + equipment duty', () {
    test('central fan air power = Q_div × governing static', () {
      final governing = [roomA, roomB, roomC]
          .map((z) => z.equipment.totalStaticPressure.pascals)
          .reduce((a, b) => a > b ? a : b);
      final r = multiZoneAirSystem(
        zones: [roomA, roomB, roomC],
        diversityFactor: 0.9,
      );
      // P_air = Q · Δp at the diversified airflow + governing static.
      final expectedAir = 0.495 * governing;
      expect(r.equipment.airPower.watts, closeTo(expectedAir, 1e-6));
      expect(r.equipment.totalStaticPressure.pascals,
          closeTo(governing, 1e-9));
    });

    test('shaft = air / 0.65, motor input = shaft / 0.90', () {
      final r = multiZoneAirSystem(
        zones: [roomA, roomB, roomC],
        diversityFactor: 0.9,
      );
      expect(r.equipment.shaftPower.watts,
          closeTo(r.equipment.airPower.watts / 0.65, 1e-6));
      expect(r.equipment.motorInputPower.watts,
          closeTo(r.equipment.shaftPower.watts / 0.90, 1e-6));
    });
  });

  group('make-up / exhaust balance', () {
    test('return-all: supply = extract, imbalance ~0', () {
      final r = multiZoneAirSystem(
        zones: [roomA, roomB, roomC],
        exhaustStrategy: ExhaustStrategy.returnAll,
        diversityFactor: 0.9,
      );
      expect(r.summedReturnAirflow.cubicMetersPerSecond, closeTo(0.55, 1e-9));
      expect(r.makeUpExhaustImbalanceM3s, closeTo(0.0, 1e-12));
      expect(r.makeUpExhaustBalanceNote, contains('balanced'));
    });

    test('supply-all: no return, full net SUPPLY imbalance', () {
      final r = multiZoneAirSystem(
        zones: [roomA, roomB, roomC],
        exhaustStrategy: ExhaustStrategy.supplyAll,
        diversityFactor: 0.9,
      );
      expect(r.summedReturnAirflow.cubicMetersPerSecond, 0.0);
      // Net supply = diversified supply (0.495) − 0 = 0.495.
      expect(r.makeUpExhaustImbalanceM3s, closeTo(0.495, 1e-9));
      expect(r.makeUpExhaustBalanceNote, contains('SUPPLY'));
    });
  });

  group('per-zone contributions', () {
    test('one entry per zone, fractions sum to 1', () {
      final r = multiZoneAirSystem(
        zones: [roomA, roomB, roomC],
        diversityFactor: 0.9,
      );
      expect(r.contributions.length, 3);
      final total = r.contributions.fold<double>(
          0.0, (s, c) => s + c.airflowFraction);
      expect(total, closeTo(1.0, 1e-9));
      // Room A fraction = 0.25 / 0.55.
      expect(r.contributions.first.airflowFraction,
          closeTo(0.25 / 0.55, 1e-9));
    });
  });

  group('single zone', () {
    test('one room: aggregated = its airflow × diversity', () {
      final r = multiZoneAirSystem(zones: [roomA], diversityFactor: 0.9);
      expect(r.aggregatedAirflow.cubicMetersPerSecond, closeTo(0.225, 1e-9));
      expect(r.contributions.single.airflowFraction, closeTo(1.0, 1e-9));
    });
  });
}
