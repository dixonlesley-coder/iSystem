// Backlog F-1 (2026-11-13) — ONE duct roughness basis.
//
// The room-air equipment estimate (`sizeRoomAir`) read its trunk friction
// with galvanised roughness (0.09 mm) while the drawn network's fan static
// (`duct_static`) read the edge's effective duct product (PU 0.03 mm for
// supply / return air). Both now read the product roughness through one
// resolver (`defaultDuctRoughnessForService` / `effectiveDuctRoughnessFor`).
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/duct_sizing.dart';
import 'package:mechx_engine/sizing/grille_sizing.dart';
import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('backlog F-1 — one duct roughness basis', () {
    test('the service default resolver is the product roughness', () {
      expect(defaultDuctRoughnessForService(ServiceType.duct).meters,
          ductRoughnessFor(DuctProduct.pu).meters);
      expect(defaultDuctRoughnessForService(ServiceType.returnAir).meters,
          ductRoughnessFor(DuctProduct.pu).meters);
      expect(defaultDuctRoughnessForService(ServiceType.exhaust).meters,
          ductRoughnessFor(DuctProduct.bjls).meters);
      // An unset drawn edge resolves to the same value; a chosen product wins.
      const unset = NetEdge(
          id: 'e', fromId: 'a', toId: 'b', service: ServiceType.duct);
      expect(effectiveDuctRoughnessFor(unset).meters, 3.0e-5);
      final bjls = unset.copyWith(ductProduct: DuctProduct.bjls);
      expect(effectiveDuctRoughnessFor(bjls).meters, 9.0e-5);
    });

    test('office room: Ø500 at 0.925 m³/s on PU 0.03 mm — 108.70 Pa', () {
      final r = sizeRoomAir(
        floorArea: const Area(150.0),
        ceilingHeight: const Length(3.7),
        airChangesPerHour: 6.0,
        equipmentKind: AirEquipmentKind.fcu,
        grilleApplication: GrilleApplication.office,
      );
      // Q = 150 x 3.7 x 6 / 3600 = 0.925 m³/s; Ø500 (velocity method).
      // v = 0.925 / (π 0.5² / 4) = 4.71099 m/s; Re = 4.71099 x 0.5 / 1.5e-5
      // = 157 033; Swamee–Jain f = 0.25 / log10(ε/D/3.7 + 5.74 / Re^0.9)²
      // with ε/D = 3e-5 / 0.5 = 6e-5 ⇒ f = 0.016754;
      // Δp/L = f / D x ρv²/2 = 0.016754 / 0.5 x 1.2 x 4.71099² / 2
      // = 0.44620 Pa/m (galvanised 0.09 mm read 0.46829).
      const q = 0.925, d = 0.5;
      const v = q / (math.pi * d * d / 4);
      const re = v * d / 1.5e-5;
      final f = 0.25 /
          math.pow(
              math.log(6e-5 / 3.7 + 5.74 / math.pow(re, 0.9)) / math.ln10, 2);
      final dpl = f / d * 1.2 * v * v / 2;
      expect(dpl, closeTo(0.44620, 5e-6));
      expect(r.supplyDuctRound!.diameter.inMillimeters, 500);
      expect(r.supplyDuctRound!.frictionPerMetrePa, closeTo(dpl, 1e-12));
      // The SAME per-metre friction the drawn network reads for an unset PU
      // duct of that size and flow.
      expect(
          ductFrictionPaPerMetre(const FlowRate(q), Diameter.mm(500),
              roughness: defaultDuctRoughnessForService(ServiceType.duct)),
          closeTo(dpl, 1e-12));
      // Static = 50 internal + 0.44620 x 15 x 1.3 + 30 + 20 = 108.70 Pa
      // (was 109.13 Pa on galvanised 0.46829 Pa/m).
      expect(r.equipment.totalStaticPressure.pascals,
          closeTo(50 + dpl * 15 * 1.3 + 30 + 20, 1e-9));
      expect(r.equipment.totalStaticPressure.pascals, closeTo(108.70, 5e-3));
    });

    test('an extract room keeps the BJLS (galvanised) basis', () {
      final r = sizeRoomAir(
        floorArea: const Area(24.0),
        ceilingHeight: const Length(3.7),
        airChangesPerHour: 10.0,
        extractOnly: true,
      );
      expect(
          r.supplyDuctRound!.frictionPerMetrePa,
          closeTo(
              ductFrictionPaPerMetre(r.airflow, r.supplyDuctRound!.diameter),
              1e-15));
    });

    test('an explicit trunk roughness overrides the service default', () {
      Pressure stat(Roughness? rough) => sizeRoomAir(
            floorArea: const Area(150.0),
            ceilingHeight: const Length(3.7),
            airChangesPerHour: 6.0,
            trunkRoughness: rough,
          ).equipment.totalStaticPressure;
      expect(stat(ductRoughnessFor(DuctProduct.bjls)).pascals,
          closeTo(109.13, 5e-3));
      expect(stat(null).pascals, closeTo(108.70, 5e-3));
    });
  });
}
