/// Audit 2026-10 — GROUP B-air. Each test hand-derives its expectation from
/// first principles in the comments (CLAUDE.md "tests are the spec").
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/duct_static.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/air_velocity.dart';
import 'package:mechx_engine/sizing/cooling_load_detailed.dart';
import 'package:mechx_engine/sizing/duct_sizing.dart';
import 'package:mechx_engine/sizing/grille_sizing.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('air-hvac-1 — room trunk equal friction honours the velocity cap', () {
    // 200 m² × 3 m × 7.2 ACH / 3600 = 1.2 m³/s.
    // Friction-only equal friction lands on DN500: A = π·0.25² = 0.19635 m²
    // ⇒ v = 1.2/0.19635 = 6.11 m/s > 5 m/s. With the cap the ladder steps to
    // DN560: A = π·0.28² = 0.24630 m² ⇒ v = 4.872 m/s ≤ 5.
    test('round trunk = DN560 at <= 5 m/s', () {
      final r = sizeRoomAir(
        floorArea: const Area(200),
        ceilingHeight: const Length(3),
        airChangesPerHour: 7.2,
        ductMethod: DuctSizingMethod.equalFriction,
      );
      expect(r.airflow.cubicMetersPerSecond, closeTo(1.2, 1e-12));
      final d = r.supplyDuctRound!;
      expect(d.diameter.meters, closeTo(0.560, 1e-12));
      const vHand = 1.2 / (math.pi * 0.28 * 0.28);
      expect(vHand, closeTo(4.872, 1e-3));
      expect(d.actualVelocity.metersPerSecond, closeTo(vHand, 1e-9));
      expect(d.overCapacity, isFalse);
    });

    // Rectangular, aspect 1.5: friction-only gave 600 × 350 = 0.21 m²
    // ⇒ 5.71 m/s. With the cap: 600 × 400 = 0.24 m² ⇒ 1.2/0.24 = 5.000 m/s.
    test('rectangular trunk <= 5 m/s (600 x 400)', () {
      final r = sizeRoomAir(
        floorArea: const Area(200),
        ceilingHeight: const Length(3),
        airChangesPerHour: 7.2,
        ductShape: DuctShape.rectangular,
        ductMethod: DuctSizingMethod.equalFriction,
      );
      final d = r.supplyDuctRect!;
      expect(d.width.meters, closeTo(0.6, 1e-12));
      expect(d.height.meters, closeTo(0.4, 1e-12));
      expect(d.actualVelocity.metersPerSecond, closeTo(5.0, 1e-9));
    });
  });

  group('air-hvac-2 — rectangular velocity sizer re-solves H after W clamps',
      () {
    // Q = 6, cap 5 ⇒ A_req = 1.2 m². Aspect 1.5: W_ideal = 1.5·√(1.2/1.5)
    // = 1.342 m > 1.2 ⇒ W clamps to 1200. H = A/W = 1.2/1.2 = 1.000 m → 1000
    // ⇒ 1200 × 1000 = 1.20 m² ⇒ v = 5.000 m/s, compliant.
    test('Q=6 -> 1200 x 1000, not flagged', () {
      final r = sizeRectangularByVelocity(
          airflow: const FlowRate(6), maxVelocity: const Velocity(5));
      expect(r.width.meters, closeTo(1.2, 1e-12));
      expect(r.height.meters, closeTo(1.0, 1e-12));
      expect(r.actualVelocity.metersPerSecond, closeTo(5.0, 1e-9));
      expect(r.overCapacity, isFalse);
    });

    // Q = 7 ⇒ A_req = 1.4 m²; H = 1.4/1.2 = 1.167 m → 1200 ⇒ 1.44 m²
    // ⇒ v = 7/1.44 = 4.861 m/s, compliant.
    test('Q=7 -> 1200 x 1200, not flagged', () {
      final r = sizeRectangularByVelocity(
          airflow: const FlowRate(7), maxVelocity: const Velocity(5));
      expect(r.width.meters, closeTo(1.2, 1e-12));
      expect(r.height.meters, closeTo(1.2, 1e-12));
      expect(r.actualVelocity.metersPerSecond, closeTo(7 / 1.44, 1e-9));
      expect(r.overCapacity, isFalse);
    });

    // Q = 8 ⇒ A_req = 1.6 m²; H = 1.6/1.2 = 1.333 m > 1200 ⇒ clamps
    // ⇒ 1200 × 1200 = 1.44 m² ⇒ 8/1.44 = 5.556 m/s > 5 ⇒ genuinely over.
    test('Q=8 -> 1200 x 1200, flagged over-capacity', () {
      final r = sizeRectangularByVelocity(
          airflow: const FlowRate(8), maxVelocity: const Velocity(5));
      expect(r.width.meters, closeTo(1.2, 1e-12));
      expect(r.height.meters, closeTo(1.2, 1e-12));
      expect(r.actualVelocity.metersPerSecond, closeTo(8 / 1.44, 1e-9));
      expect(r.overCapacity, isTrue);
    });
  });

  group('air-hvac-3 — auto-sized faces sit inside the checker band', () {
    // 100 m² × 3 m × 6 ACH / 3600 = 0.5 m³/s per bank.
    // Supply limit = min(app, 3.0); return limit = min(app, 4.0).
    // Retail (3.5) supply @ 3.0: gross ≥ 0.5/(0.8·3.0) = 0.2083 m² ⇒ 600×600
    //   (0.36 m²) ⇒ v = 0.5/(0.36·0.8) = 1.736 m/s.
    // Retail return @ 3.5: gross ≥ 0.5/(0.8·3.5) = 0.1786 m² ⇒ 600×300
    //   (0.18 m²) ⇒ v = 0.5/0.144 = 3.472 m/s ≤ 4.0.
    // Industrial (5.0) return @ 4.0: gross ≥ 0.1563 m² ⇒ 600×300 ⇒ 3.472.
    for (final app in [GrilleApplication.retail, GrilleApplication.industrial]) {
      test('$app: supply <= 3.0, return <= 4.0, checker OK', () {
        final r = sizeRoomAir(
          floorArea: const Area(100),
          ceilingHeight: const Length(3),
          airChangesPerHour: 6,
          grilleApplication: app,
        );
        final sv = r.supply.each.faceVelocity;
        final rv = r.return_.each.faceVelocity;
        expect(sv.metersPerSecond, lessThanOrEqualTo(3.0 + 1e-9));
        expect(rv.metersPerSecond, lessThanOrEqualTo(4.0 + 1e-9));
        expect(sv.metersPerSecond, closeTo(0.5 / (0.36 * 0.8), 1e-9));
        expect(rv.metersPerSecond, closeTo(0.5 / (0.18 * 0.8), 1e-9));
        // Judge the face the checker sees (gross area × 0.8).
        final svCheck = faceVelocityFor(r.supply.airflowEach,
            grossFaceArea: r.supply.each.grossFaceArea);
        final rvCheck = faceVelocityFor(r.return_.airflowEach,
            grossFaceArea: r.return_.each.grossFaceArea);
        expect(checkSupplyFaceVelocity(svCheck).isWarning, isFalse);
        expect(checkReturnFaceVelocity(rvCheck).isWarning, isFalse);
      });
    }

    // An office room (3.0 m/s) is untouched: min(3.0, 3.0) = 3.0 supply,
    // min(3.0, 4.0) = 3.0 return — the same limit as before.
    test('office unchanged (limit already inside both bands)', () {
      final r = sizeRoomAir(
        floorArea: const Area(100),
        ceilingHeight: const Length(3),
        airChangesPerHour: 6,
      );
      final expected = selectStandardGrille(
        airflow: const FlowRate(0.5),
        maxFaceVelocity: const Velocity(3.0),
      );
      expect(r.supply.each.grossFaceArea.squareMeters,
          closeTo(expected.grossFaceArea.squareMeters, 1e-12));
      expect(r.return_.each.grossFaceArea.squareMeters,
          closeTo(expected.grossFaceArea.squareMeters, 1e-12));
    });
  });

  group('air-hvac-4 — exact-fit sides survive floating-point noise', () {
    // 1.2 m³/s @ 5 m/s ⇒ A = 0.24 m²; H = √(0.24/1.5) = 0.4 m → 400;
    // W = 1.5·0.4 = 0.6 m (evaluates to 600.0000000000001 mm) → 600, NOT 700.
    // ⇒ 600 × 400 = 0.24 m² ⇒ v = 5.000 m/s exactly on the cap.
    test('1.2 m3/s -> 600 x 400 at 5.0 m/s', () {
      final r = sizeRectangularByVelocity(
          airflow: const FlowRate(1.2), maxVelocity: const Velocity(5));
      expect(r.width.meters, closeTo(0.6, 1e-12));
      expect(r.height.meters, closeTo(0.4, 1e-12));
      expect(r.actualVelocity.metersPerSecond, closeTo(5.0, 1e-9));
      expect(r.overCapacity, isFalse);
    });

    // Round: D_ideal = √(4A/π). For an exact DN400 at 5 m/s,
    // Q = 5·π·0.2² = 0.62832 m³/s ⇒ D_ideal = 0.4 m (± fp) → DN400, not DN450.
    test('round exact-fit lands on DN400', () {
      const q = 5.0 * math.pi * 0.2 * 0.2;
      final r =
          sizeByVelocity(airflow: const FlowRate(q), maxVelocity: const Velocity(5));
      expect(r.diameter.meters, closeTo(0.4, 1e-12));
      expect(r.overCapacity, isFalse);
    });
  });

  group('air-hvac-5 — rectangular restrictor loss uses the true velocity', () {
    // 1.2 m³/s in a 700 × 400 duct into a VAV box (C = 1.5).
    // True v = 1.2/(0.7·0.4) = 4.2857 m/s ⇒ VP = 0.5·1.2·4.2857² = 11.020 Pa
    // ⇒ loss = 1.5 · 11.020 = 16.531 Pa (the De path gave 1.5 · 13.00).
    test('VAV on 700 x 400 adds C * rho v^2/2 at Q/(W*H)', () {
      const building = BuildingLevels([Floor('G', Length(4.0))]);
      const cal = {'s1': ScaleCalibration(0.1)};
      Network net(NodeComponent? c) => Network(
            nodes: [
              const NetNode(
                  id: 'f', sheetId: 's1', x: 0, y: 0, floorIndex: 0,
                  role: NodeRole.plant),
              NetNode(
                  id: 'd', sheetId: 's1', x: 100, y: 0, floorIndex: 0,
                  role: NodeRole.main, component: c),
            ],
            edges: const [
              NetEdge(id: 'e', fromId: 'f', toId: 'd', service: ServiceType.duct),
            ],
          );
      const w = Length(0.7);
      const h = Length(0.4);
      final de = rectangularEquivalentDiameter(w, h);
      final sizing = {
        'e': EdgeSizing(
          edgeId: 'e',
          service: ServiceType.duct,
          flow: const FlowRate(1.2),
          diameter: de,
          velocity: const Velocity(1.2 / 0.28),
          width: w,
          height: h,
        ),
      };
      DuctStaticSolution run(Network n) => solveDuctStatic(
            net: n,
            service: ServiceType.duct,
            fanNodeId: 'f',
            edgeFlows: const {'e': FlowRate(1.2)},
            sizing: sizing,
            calibrationBySheet: cal,
            building: building,
          );
      final extra = run(net(NodeComponent.vavBox)).totalStaticPressure.pascals -
          run(net(null)).totalStaticPressure.pascals;
      const v = 1.2 / 0.28;
      const expected = 1.5 * 0.5 * 1.2 * v * v;
      expect(expected, closeTo(16.531, 1e-3));
      expect(extra, closeTo(expected, 1e-9));
    });
  });

  group('air-hvac-7 — detailed people gain uses the fractional count', () {
    // 4.9 m² × 0.1 p/m² = 0.49 people (rounded display: 0).
    // Sensible = 0.49 · 75 = 36.75 W; latent = 0.49 · 55 = 26.95 W.
    test('4.9 m2 room keeps its people gain', () {
      final r = estimateDetailedCoolingLoad(const DetailedCoolingLoadInputs(
        floorArea: Area(4.9),
        ceilingHeight: Length(3),
      ));
      expect(r.occupants, 0);
      expect(r.peopleSensibleW, closeTo(36.75, 1e-9));
      expect(r.peopleLatentW, closeTo(26.95, 1e-9));
    });

    // Explicit count: 3 people ⇒ 3·75 = 225 W sensible, 3·55 = 165 W latent.
    test('explicit occupant count unchanged', () {
      final r = estimateDetailedCoolingLoad(const DetailedCoolingLoadInputs(
        floorArea: Area(4.9),
        ceilingHeight: Length(3),
        occupantCount: 3,
      ));
      expect(r.occupants, 3);
      expect(r.peopleSensibleW, closeTo(225, 1e-9));
      expect(r.peopleLatentW, closeTo(165, 1e-9));
    });
  });
}
