import 'package:mechx_engine/sizing/hot_water.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// §8 hot-water recirculation sizing tests.
///
/// All expected values are hand-computed in SI and verified before being
/// recorded here as the correctness anchor.
///
/// Energy balance: Q_recirc = heatLoss / (ρ · c · ΔT), ρ = 1000 kg/m³,
/// c = 4186 J/(kg·K).
///
/// Anchor case:
///   heatLoss = 4186 W, ΔT = 5 K, ρ = 1000, c = 4186
///   Q = 4186 / (1000 · 4186 · 5) = 4186 / 20 930 000 = 1/5000
///     = 0.000 2 m³/s = 0.2 L/s   ✓ (the 4186s cancel)
///
/// Loop head (Hazen–Williams, SI):
///   h_f = 10.67 · L · Q^1.852 / (C^1.852 · D^4.8704)
///   L = 40 m, D = 0.025 m, C = 150, Q = 0.000 2 m³/s
///       Q^1.852      = 0.000 2^1.852      ≈ 1.0455e-7
///       C^1.852      = 150^1.852          ≈ 9 587.6
///       D^4.8704     = 0.025^4.8704       ≈ 1.247e-8
///   h_f ≈ 10.67 · 40 · 1.0455e-7 / (9 587.6 · 1.247e-8)
///       ≈ 4.463e-5 / 1.1956e-4 ≈ 0.356 7 m  (computed precisely: 0.356 684 m)
///   For L = 20 m the head halves to ≈ 0.178 342 m (h_f is linear in L).
///
/// Pump shaft demand is tiny (Q·H ≈ 7.13e-5 m⁴/s), so hydraulic power
///   P = ρ·g·Q·H = 1000 · 9.81 · 0.000 2 · 0.356 684 ≈ 0.699 8 W,
///   shaft ≈ 0.699 8 / 0.70 ≈ 0.999 7 W → smallest standard motor 0.37 kW.
///
/// heatLossFromLength: 50 m · 25 W/m = 1250 W.
void main() {
  // ── Anchor case: recirc flow from energy balance ─────────────────────────

  group('sizeHotWaterRecirculation — anchor (heatLoss=4186 W, ΔT=5 K)', () {
    late HotWaterRecircDesign design;

    setUpAll(() {
      design = sizeHotWaterRecirculation(
        heatLoss: const Power(4186),
        loopLength: const Length(40),
        returnDiameter: Diameter.mm(25),
        allowableDropK: 5.0,
      );
    });

    test('recircFlow = 0.000 2 m³/s', () {
      expect(design.recircFlow.cubicMetersPerSecond, closeTo(0.0002, 1e-12));
    });

    test('recircFlow = 0.2 L/s', () {
      expect(design.recircFlow.inLitersPerSecond, closeTo(0.2, 1e-9));
    });

    test('loopHead ≈ 0.356 684 m and > 0', () {
      expect(design.loopHead.meters, closeTo(0.3566842499711116, 1e-9));
      expect(design.loopHead.meters, greaterThan(0));
    });

    test('pump.flow equals recircFlow', () {
      expect(
        design.pump.flow.cubicMetersPerSecond,
        closeTo(design.recircFlow.cubicMetersPerSecond, 1e-15),
      );
    });

    test('pump.selectedMotor power is positive', () {
      expect(design.pump.selectedMotor.inKiloWatts, greaterThan(0));
    });
  });

  // ── Zero-length loop: no friction, zero head ─────────────────────────────

  group('sizeHotWaterRecirculation — zero-length loop', () {
    test('loopHead is 0 for a zero-length loop', () {
      final design = sizeHotWaterRecirculation(
        heatLoss: const Power(4186),
        loopLength: const Length(0),
        returnDiameter: Diameter.mm(25),
      );
      expect(design.loopHead.meters, closeTo(0.0, 1e-12));
    });
  });

  // ── Monotonicity ─────────────────────────────────────────────────────────

  group('sizeHotWaterRecirculation — monotonicity', () {
    test('larger heatLoss → larger recircFlow', () {
      final small = sizeHotWaterRecirculation(
        heatLoss: const Power(2000),
        loopLength: const Length(30),
        returnDiameter: Diameter.mm(25),
      );
      final big = sizeHotWaterRecirculation(
        heatLoss: const Power(8000),
        loopLength: const Length(30),
        returnDiameter: Diameter.mm(25),
      );
      expect(
        big.recircFlow.cubicMetersPerSecond,
        greaterThan(small.recircFlow.cubicMetersPerSecond),
      );
    });

    test('larger allowableDropK → smaller recircFlow', () {
      final tightDrop = sizeHotWaterRecirculation(
        heatLoss: const Power(4186),
        loopLength: const Length(30),
        returnDiameter: Diameter.mm(25),
        allowableDropK: 2.0,
      );
      final looseDrop = sizeHotWaterRecirculation(
        heatLoss: const Power(4186),
        loopLength: const Length(30),
        returnDiameter: Diameter.mm(25),
        allowableDropK: 10.0,
      );
      expect(
        looseDrop.recircFlow.cubicMetersPerSecond,
        lessThan(tightDrop.recircFlow.cubicMetersPerSecond),
      );
    });
  });

  // ── heatLossFromLength convenience ───────────────────────────────────────

  group('heatLossFromLength', () {
    test('50 m × 25 W/m = 1250 W', () {
      final loss = heatLossFromLength(loopLength: const Length(50));
      expect(loss.watts, closeTo(1250.0, 1e-9));
    });

    test('custom lossPerMetreW scales linearly', () {
      final loss = heatLossFromLength(
        loopLength: const Length(50),
        lossPerMetreW: 10.0,
      );
      expect(loss.watts, closeTo(500.0, 1e-9));
    });
  });
}
