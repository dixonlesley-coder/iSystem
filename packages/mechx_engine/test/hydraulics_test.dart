import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Seed tests for the hydraulic kernel. Expected values are hand-computed from
/// the underlying formulas (SI), and act as the correctness anchor for the
/// engine — nothing else proceeds until these are green.
void main() {
  group('geometry / continuity', () {
    test('circularArea of DN100 = πD²/4', () {
      expect(
        circularArea(Diameter.mm(100)).squareMeters,
        closeTo(0.007853981633974483, 1e-12),
      );
    });

    test('velocityFromFlow: 10 L/s through DN100 ≈ 1.2732 m/s', () {
      final v = velocityFromFlow(const FlowRate(0.01), Diameter.mm(100));
      expect(v.metersPerSecond, closeTo(1.2732395447, 1e-9));
    });

    test('flowFromVelocity: 2 m/s through DN50 ≈ 3.927e-3 m³/s', () {
      final q = flowFromVelocity(const Velocity(2.0), Diameter.mm(50));
      expect(q.cubicMetersPerSecond, closeTo(0.003926990817, 1e-9));
    });

    test('velocityFromFlow ∘ flowFromVelocity round-trips', () {
      const d = Diameter(0.08);
      const v0 = Velocity(1.6);
      final back = velocityFromFlow(flowFromVelocity(v0, d), d);
      expect(back.metersPerSecond, closeTo(1.6, 1e-12));
    });
  });

  group('pressurized flow', () {
    test('Reynolds with explicit ν=1e-6 gives a clean 100 000', () {
      final re = reynolds(
        const Velocity(2.0),
        Diameter.mm(50),
        kinematicViscosity: 1e-6,
      );
      expect(re, closeTo(100000.0, 1e-6));
    });

    test('Reynolds with default water viscosity ≈ 99 601.6', () {
      final re = reynolds(const Velocity(2.0), Diameter.mm(50));
      expect(re, closeTo(99601.5936, 1e-3));
    });

    test('Swamee–Jain friction factor (Re=1e5, ε/D=1e-3) ≈ 0.02234', () {
      expect(frictionFactorSwameeJain(1e5, 1e-3), closeTo(0.022342, 5e-5));
    });

    test('Colebrook agrees with Swamee–Jain to a few percent', () {
      final sj = frictionFactorSwameeJain(1e5, 1e-3);
      final cw = frictionFactorColebrook(1e5, 1e-3);
      expect(cw, closeTo(sj, 0.0015));
    });

    test('Darcy–Weisbach head loss (f=0.02, L=100, DN50, v=2) ≈ 8.155 m', () {
      final hf = headLossDarcy(
        frictionFactor: 0.02,
        length: const Length(100),
        diameter: Diameter.mm(50),
        velocity: const Velocity(2.0),
      );
      expect(hf.meters, closeTo(8.1549449, 1e-5));
    });

    test('Hazen–Williams head loss (Q=10 L/s, L=100, DN100, C=130) ≈ 1.904 m',
        () {
      final hf = headLossHazenWilliams(
        flow: const FlowRate(0.01),
        length: const Length(100),
        diameter: Diameter.mm(100),
        hazenWilliamsC: 130,
      );
      expect(hf.meters, closeTo(1.9036, 5e-3));
    });
  });

  group('gravity flow (Manning)', () {
    test('Manning velocity (n=0.013, R=0.05, S=0.01) ≈ 1.044 m/s', () {
      final v = manningVelocity(
        manningN: 0.013,
        hydraulicRadius: const Length(0.05),
        slope: 0.01,
      );
      expect(v.metersPerSecond, closeTo(1.044, 2e-3));
    });

    test('Manning full-bore discharge (DN100, n=0.013, S=0.01) ≈ 5.17 L/s', () {
      final q = manningFlowFull(
        Diameter.mm(100),
        manningN: 0.013,
        slope: 0.01,
      );
      expect(q.cubicMetersPerSecond, closeTo(0.0051654, 1e-4));
    });
  });

  group('pump / energy', () {
    test('hydraulic power (Q=20 L/s, H=30 m) = 5886 W', () {
      final p = hydraulicPower(flow: const FlowRate(0.02), head: const Head(30));
      expect(p.watts, closeTo(5886.0, 1e-9));
    });

    test('shaft power at η=0.70 ≈ 8408.57 W', () {
      final p = shaftPower(
        flow: const FlowRate(0.02),
        head: const Head(30),
        efficiency: 0.7,
      );
      expect(p.watts, closeTo(8408.5714286, 1e-6));
    });
  });

  group('pressure ↔ head', () {
    test('pressureFromHead(10 m) = 98.1 kPa', () {
      expect(pressureFromHead(const Head(10)).pascals, closeTo(98100.0, 1e-6));
    });

    test('headFromPressure(98.1 kPa) = 10 m', () {
      expect(headFromPressure(const Pressure(98100)).meters, closeTo(10.0, 1e-9));
    });

    test('pressure ↔ head round-trips', () {
      final back = headFromPressure(pressureFromHead(const Head(7.5)));
      expect(back.meters, closeTo(7.5, 1e-9));
    });
  });
}
