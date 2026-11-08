/// ROUND 11 (2026-10-18, hvac-network-2) — a toilet / commercial kitchen is an
/// EXTRACT room: its ACH airflow is exhausted through exhaust grilles by a plain
/// exhaust fan — never supplied as conditioned air nor returned to an AHU/FCU.
library;

import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  test('only toilet + commercial kitchen are extract rooms', () {
    for (final t in RoomType.values) {
      expect(isExtractRoomType(t),
          t == RoomType.toilet || t == RoomType.commercialKitchen,
          reason: t.name);
    }
  });

  group('a 3 x 2 m toilet, 3 m ceiling, 10 ACH', () {
    // Volume 3·2·3 = 18 m³; Q = 18 × 10 / 3600 = 0.05 m³/s = 50 L/s.
    RoomAirResult size({required bool extract}) => sizeRoomAir(
          floorArea: const Area(6),
          ceilingHeight: const Length(3),
          airChangesPerHour: 10,
          equipmentKind: AirEquipmentKind.fcu,
          extractOnly: extract,
        );
    final ex = size(extract: true);
    final rec = size(extract: false);

    test('the whole 50 L/s is EXHAUST — no supply bank, no air unit', () {
      expect(ex.airflow.inLitersPerSecond, closeTo(50, 1e-9));
      expect(ex.extractOnly, isTrue);
      expect(ex.supply.count, 0);
      expect(ex.supply.airflowEach.cubicMetersPerSecond, 0);
      expect(ex.extract, isNotNull);
      // The exhaust bank carries the full room airflow.
      expect(ex.return_.count * ex.return_.airflowEach.cubicMetersPerSecond,
          closeTo(0.05, 1e-12));
      // The unit is a plain exhaust fan, whatever unit the room named.
      expect(ex.equipmentKind, AirEquipmentKind.fan);
    });

    test('the fan sees duct + extract-grille loss only (no coil, no supply)',
        () {
      // The recirculating FCU build-up is internal 50 + duct + supply 30 +
      // return 20 Pa; the exhaust fan drops the FCU internal and the supply
      // terminal: static_ex = static_rec − 50 − 30 (same duct, same airflow).
      expect(
        ex.equipment.totalStaticPressure.pascals,
        closeTo(
            rec.equipment.totalStaticPressure.pascals -
                defaultInternalStatic(AirEquipmentKind.fcu).pascals -
                30.0,
            1e-9),
      );
      expect(ex.supplyDuctDiameter.meters, rec.supplyDuctDiameter.meters);
    });

    test('a supply/return room is unchanged (byte-identical path)', () {
      expect(rec.extractOnly, isFalse);
      expect(rec.extract, isNull);
      expect(rec.supply.count, greaterThanOrEqualTo(1));
      expect(rec.equipmentKind, AirEquipmentKind.fcu);
    });
  });
}
