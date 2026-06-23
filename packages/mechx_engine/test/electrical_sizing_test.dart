import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Seed tests for Tier-1 electrical sizing (A3). Expected values are hand-derived
/// from the formulas + the PUIL/Supreme tables and act as the correctness anchor.
void main() {
  const p = PuilProfile();

  group('loadCurrent (Ib)', () {
    test('3φ 10 kW @ 400 V, cosφ 0.85 → 10000/(√3·400·0.85) ≈ 16.98 A', () {
      final i = loadCurrent(
        power: Power.kiloWatts(10),
        voltage: const Voltage(400),
        cosPhi: 0.85,
        threePhase: true,
      );
      expect(i.amperes, closeTo(16.9809, 1e-3));
    });

    test('1φ 2.2 kW @ 220 V, cosφ 0.9 → 2200/(220·0.9) ≈ 11.11 A', () {
      final i = loadCurrent(
        power: Power.kiloWatts(2.2),
        voltage: const Voltage(220),
        cosPhi: 0.9,
        threePhase: false,
      );
      expect(i.amperes, closeTo(11.1111, 1e-3));
    });

    test('zero voltage or cosφ → 0 A (guard)', () {
      expect(
        loadCurrent(power: Power.kiloWatts(5), voltage: const Voltage(0), cosPhi: 0.9, threePhase: false).amperes,
        0.0,
      );
    });
  });

  group('deratingFactor', () {
    test('above ground, 30 °C, 1 circuit, conduit → 1.0', () {
      expect(
        deratingFactor(p,
            ambientC: 30, groupingCount: 1, method: CableInstallMethod.conduit),
        closeTo(1.0, 1e-12),
      );
    });

    test('40 °C ambient × 3 grouped (PVC) = 0.87 × 0.7 = 0.609', () {
      expect(
        deratingFactor(p,
            ambientC: 40, groupingCount: 3, method: CableInstallMethod.conduit),
        closeTo(0.609, 1e-9),
      );
    });

    test('buried: ground 30 °C × depth 1.0 m (PVC) = 0.89 × 0.95 = 0.8455', () {
      expect(
        deratingFactor(p,
            ambientC: 30,
            groupingCount: 1,
            method: CableInstallMethod.buried,
            groundTempC: 30,
            depthM: 1.0,
            soilThermalResistivityKmW: 2.5),
        closeTo(0.8455, 1e-9),
      );
    });
  });

  group('voltageDrop', () {
    test('3φ 16.98 A, 30 m, 4 mm² Cu, cosφ 0.85 → ≈4.18 V / 1.04 %', () {
      final vd = voltageDrop(
        p,
        current: const Current(16.9809),
        length: Length.mm(30000), // 30 m
        csaMm2: 4,
        cosPhi: 0.85,
        threePhase: true,
        voltage: const Voltage(400),
        isLighting: false,
      );
      // dV = √3·16.98·30·(0.00552·0.85 + 0.00008·0.5268) ≈ 4.18 V
      expect(vd.dropV, closeTo(4.18, 0.02));
      expect(vd.dropPercent, closeTo(1.04, 0.02));
      expect(vd.limitPercent, 5.0);
      expect(vd.withinLimit, isTrue);
    });

    test('lighting run uses the 3 % limit', () {
      final vd = voltageDrop(
        p,
        current: const Current(10),
        length: Length.mm(80000), // 80 m
        csaMm2: 1.5,
        cosPhi: 0.9,
        threePhase: false,
        voltage: const Voltage(220),
        isLighting: true,
      );
      expect(vd.limitPercent, 3.0);
      expect(vd.withinLimit, isFalse); // ~9.5 % over a long thin lighting run
    });
  });

  group('selectBreaker', () {
    test('16.98 A general → 20 A MCB, curve C', () {
      final b = selectBreaker(p,
          designCurrent: const Current(16.9809), loadKind: LoadKind.general);
      expect(b.ratingA.amperes, 20);
      expect(b.deviceClass, BreakerClass.mcb);
      expect(b.curve, BreakerCurve.c);
      expect(b.overridden, isFalse);
    });

    test('cap to the cable ampacity (maxRatingA)', () {
      final b = selectBreaker(p,
          designCurrent: const Current(16.9809),
          loadKind: LoadKind.general,
          maxRatingA: const Current(16));
      expect(b.ratingA.amperes, 16); // 20 capped down to ≤16
    });

    test('override is honored verbatim + flagged', () {
      final b = selectBreaker(p,
          designCurrent: const Current(16.9809),
          loadKind: LoadKind.general,
          overrideA: const Current(25));
      expect(b.ratingA.amperes, 25);
      expect(b.overridden, isTrue);
    });

    test('large current picks an MCCB frame', () {
      final b = selectBreaker(p,
          designCurrent: const Current(700), loadKind: LoadKind.feeder);
      expect(b.ratingA.amperes, 800);
      expect(b.deviceClass, BreakerClass.mccb);
    });
  });

  group('sizeCable (Iz ≥ max(In, 1.25·Ib))', () {
    test('17 A / 20 A breaker, df 1.0, min 2.5 → 2.5 mm² (kha 25 ≥ 21.2)', () {
      final c = sizeCable(p,
          designCurrent: const Current(16.9809),
          breakerRating: const Current(20),
          deratingFactor: 1.0,
          minSectionMm2: 2.5,
          threePhase: true);
      expect(c.csaMm2, 2.5);
      expect(c.baseKha.amperes, 25);
      expect(c.deratedIz.amperes, 25);
      expect(c.vdDriven, isFalse);
      expect(c.runsPerPhase, isNull);
    });

    test('derating 0.7 forces an upsize: 2.5→4 mm² (34×0.7 = 23.8 ≥ 21.2)', () {
      final c = sizeCable(p,
          designCurrent: const Current(16.9809),
          breakerRating: const Current(20),
          deratingFactor: 0.7,
          minSectionMm2: 2.5,
          threePhase: true);
      expect(c.csaMm2, 4);
      expect(c.deratedIz.amperes, closeTo(23.8, 1e-6));
      expect(c.vdDriven, isFalse);
    });

    test('voltage-drop drives the size up: long thin lighting run → 6 mm²', () {
      final c = sizeCable(p,
          designCurrent: const Current(10),
          breakerRating: const Current(10),
          deratingFactor: 1.0,
          minSectionMm2: 1.5,
          threePhase: false,
          vd: const CableVoltageDropConstraint(
            length: Length(80), // 80 m
            cosPhi: 0.9,
            threePhase: false,
            voltage: Voltage(220),
            isLighting: true,
          ));
      // ampacity alone allows 1.5 mm² (kha 18 ≥ 12.5), but Vd at 1.5/2.5/4 mm²
      // all exceed 3 %; 6 mm² is the first within limit.
      expect(c.csaMm2, 6);
      expect(c.vdDriven, isTrue);
    });

    test('beyond range: 4× largest section still under Iz → flagged', () {
      final c = sizeCable(p,
          designCurrent: const Current(5000),
          breakerRating: const Current(5000),
          deratingFactor: 1.0,
          minSectionMm2: 4,
          threePhase: true);
      expect(c.csaMm2, 300); // largest standard section
      expect(c.runsPerPhase, 4);
      expect(c.vdDriven, isFalse);
      expect(c.appliedRule, contains('exceeds-range'));
    });
  });
}
