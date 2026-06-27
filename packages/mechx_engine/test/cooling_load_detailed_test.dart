/// Tests for the detailed (heat-gain) cooling-load estimate.
///
/// Every expected value is hand-derived from first principles; the arithmetic
/// is shown in comments. The streams are:
///   transmission  Q = U·A·ΔT
///   solar         Q = SHGC · irradiance · area
///   internal      people (sens+lat), lighting, equipment (W/m² × area)
///   ventilation   sensible ρ·cp·V̇·ΔT, latent ρ·h_fg·V̇·Δw
library;

import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/sizing/cooling_load_detailed.dart';
import 'package:mechx_engine/standards/sni.dart' show VerificationStatus;
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('transmissionGainW (U·A·ΔT)', () {
    test('10 m² wall, U=2.5, ΔT=9 → 225 W', () {
      // 2.5 × 10 × 9 = 225.
      final q = transmissionGainW(
        const EnvelopeSurface(area: Area(10.0), uValueWPerM2K: 2.5),
        9.0,
      );
      expect(q, closeTo(225.0, 1e-9));
    });

    test('zero area → zero gain', () {
      final q = transmissionGainW(
        const EnvelopeSurface(area: Area(0.0), uValueWPerM2K: 3.0),
        9.0,
      );
      expect(q, 0.0);
    });
  });

  group('solarGainW (SHGC·irr·A)', () {
    test('4 m² glass, SHGC 0.65, 300 W/m² → 780 W', () {
      // 0.65 × 300 × 4 = 780.
      final q = solarGainW(
        glassArea: const Area(4.0),
        shgc: 0.65,
        irradianceWPerM2: 300.0,
      );
      expect(q, closeTo(780.0, 1e-9));
    });
  });

  group('ventilation gains', () {
    test('sensible ρ·cp·V̇·ΔT: 0.1 m³/s, ΔT=9 → 1085.4 W', () {
      // 1.2 × 1005 × 0.1 × 9 = 1085.4.
      final q = ventilationSensibleW(
        airflow: const FlowRate(0.1),
        deltaTK: 9.0,
      );
      expect(q, closeTo(1085.4, 1e-6));
    });

    test('latent ρ·h_fg·V̇·Δw: 0.1 m³/s, Δw=0.010 → 2940 W', () {
      // 1.2 × 2_450_000 × 0.1 × 0.010 = 2940.
      final q = ventilationLatentW(
        airflow: const FlowRate(0.1),
        deltaWKgPerKg: 0.010,
      );
      expect(q, closeTo(2940.0, 1e-6));
    });
  });

  group('estimateDetailedCoolingLoad — full hand-worked case', () {
    // A 20 m² × 3 m office with:
    //   walls 30 m² (U 2.5), roof 0, glass 6 m² (U 3.0, SHGC 0.65, 300 W/m²)
    //   2 occupants (75 W sens / 55 W lat each), lighting 10 W/m², equip 12 W/m²
    //   ventilation 0.05 m³/s, ΔT 9 K, Δw 0.010.
    const inputs = DetailedCoolingLoadInputs(
      floorArea: Area(20.0),
      ceilingHeight: Length(3.0),
      wallArea: Area(30.0),
      glassArea: Area(6.0),
      occupantCount: 2,
      ventilationAirflow: FlowRate(0.05),
    );
    final r = estimateDetailedCoolingLoad(inputs);

    test('transmission = walls + glass = 675 + 162 = 837 W', () {
      // wall: 2.5 × 30 × 9 = 675; roof: 0; glass cond: 3.0 × 6 × 9 = 162.
      expect(r.transmissionW, closeTo(837.0, 1e-6));
    });

    test('solar = 0.65 × 300 × 6 = 1170 W', () {
      expect(r.solarW, closeTo(1170.0, 1e-6));
    });

    test('people sensible 2×75=150, latent 2×55=110 W', () {
      expect(r.peopleSensibleW, closeTo(150.0, 1e-9));
      expect(r.peopleLatentW, closeTo(110.0, 1e-9));
    });

    test('lighting 10×20=200, equipment 12×20=240 W', () {
      expect(r.lightingW, closeTo(200.0, 1e-9));
      expect(r.equipmentW, closeTo(240.0, 1e-9));
    });

    test('ventilation sensible 542.7, latent 1470 W', () {
      // sens: 1.2 × 1005 × 0.05 × 9 = 542.7.
      // lat:  1.2 × 2_450_000 × 0.05 × 0.010 = 1470.
      expect(r.ventilationSensibleW, closeTo(542.7, 1e-6));
      expect(r.ventilationLatentW, closeTo(1470.0, 1e-6));
    });

    test('sensible = 837+1170+150+200+240+542.7 = 3139.7 W', () {
      expect(r.sensibleW, closeTo(3139.7, 1e-6));
    });

    test('latent = 110 + 1470 = 1580 W', () {
      expect(r.latentW, closeTo(1580.0, 1e-6));
    });

    test('total = 3139.7 + 1580 = 4719.7 W', () {
      expect(r.totalW, closeTo(4719.7, 1e-6));
    });

    test('SHR = 3139.7 / 4719.7 ≈ 0.665', () {
      expect(r.sensibleHeatRatio, closeTo(3139.7 / 4719.7, 1e-9));
    });

    test('total BTU/h = 4719.7 × 3.412141633 ≈ 16104.5', () {
      // 4719.7 × 3.412141633 = 16104.5...
      expect(r.totalBtuPerHr, closeTo(wattsToBtuPerHr(4719.7), 1e-6));
      expect(r.totalBtuPerHr, closeTo(16104.5, 0.5));
    });

    test('total PK = BTU/h ÷ 9000 ≈ 1.789', () {
      expect(r.totalPk, closeTo(r.totalBtuPerHr / 9000.0, 1e-9));
    });

    test('recommended AC = 2.0 PK (18000 BTU/h ≥ 16104.5)', () {
      // ladder: 12000 (<16104.5) → 18000 (≥) ⇒ 2.0 PK.
      final ac = r.recommended;
      expect(ac.pk, 2.0);
      expect(ac.nominalBtuPerHr, 18000.0);
      expect(ac.exceedsRange, isFalse);
    });
  });

  group('default coefficients + resolution', () {
    test('occupant count defaults to density × floor area (rounded)', () {
      // 0.1 people/m² × 50 m² = 5 occupants.
      const inputs = DetailedCoolingLoadInputs(
        floorArea: Area(50.0),
        ceilingHeight: Length(3.0),
      );
      expect(inputs.resolvedOccupants, 5);
    });

    test('ventilation airflow defaults to ACH × volume / 3600', () {
      // 1 ACH × (20 × 3) / 3600 = 60/3600 = 0.016666… m³/s.
      const inputs = DetailedCoolingLoadInputs(
        floorArea: Area(20.0),
        ceilingHeight: Length(3.0),
      );
      expect(inputs.resolvedVentilationAirflow.cubicMetersPerSecond,
          closeTo(60.0 / 3600.0, 1e-12));
    });

    test('interior room (no envelope) → transmission + solar are zero', () {
      const inputs = DetailedCoolingLoadInputs(
        floorArea: Area(20.0),
        ceilingHeight: Length(3.0),
        occupantCount: 0,
      );
      final r = estimateDetailedCoolingLoad(inputs);
      expect(r.transmissionW, 0.0);
      expect(r.solarW, 0.0);
      // Internal + ventilation still contribute (lighting/equip/vent).
      expect(r.totalW, greaterThan(0.0));
    });
  });

  group('VERIFY surface', () {
    test('checklist is non-empty and entirely unverified', () {
      final list = detailedCoolingVerifyChecklist;
      expect(list, isNotEmpty);
      for (final v in list) {
        expect(v.isUnverified, isTrue);
        expect(v.status, VerificationStatus.secondarySource);
      }
    });
  });
}
