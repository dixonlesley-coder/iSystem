import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Anchors the supply design target (2.0–2.5 bar, recommended 2.25 bar) and the
/// pump-head composition it feeds.
void main() {
  group('design target band', () {
    test('recommended target = 2.25 bar', () {
      final c = SupplyDesignCriteria.recommended();
      expect(c.targetFixtureResidualPressure.inBar, closeTo(2.25, 1e-12));
    });

    test('comfort band is 2.0–2.5 bar', () {
      expect(SupplyDesignCriteria.minComfortTarget.inBar, closeTo(2.0, 1e-12));
      expect(SupplyDesignCriteria.maxComfortTarget.inBar, closeTo(2.5, 1e-12));
    });

    test('2.25 bar target → ≈22.94 m residual head', () {
      expect(
        SupplyDesignCriteria.recommended().targetResidualHead.meters,
        closeTo(22.9358, 1e-3),
      );
    });
  });

  group('pump-head composition', () {
    test('H_pump = static + friction + residual', () {
      // 40 m lift + 10 m friction + 2.25 bar residual (22.9358 m) = 72.9358 m
      final h = computeRequiredPumpHead(
        staticLift: const Length(40),
        frictionLoss: const Head(10),
        targetResidualPressure: const Pressure(225000),
      );
      expect(h.meters, closeTo(72.9358, 1e-3));
    });

    test('criteria.requiredPumpHead matches the free function', () {
      final c = SupplyDesignCriteria.recommended();
      final viaMethod = c.requiredPumpHead(
        staticLift: const Length(35),
        frictionLoss: const Head(8.0),
      );
      final viaFn = computeRequiredPumpHead(
        staticLift: const Length(35),
        frictionLoss: const Head(8.0),
        targetResidualPressure: c.targetFixtureResidualPressure,
      );
      expect(viaMethod.meters, closeTo(viaFn.meters, 1e-12));
    });

    test('integrated: Darcy friction feeds the pump duty', () {
      // Critical riser: 35 m static lift, friction from a worked Darcy loss,
      // 2.25 bar target residual.
      final friction = headLossDarcy(
        frictionFactor: 0.02,
        length: const Length(100),
        diameter: Diameter.mm(50),
        velocity: const Velocity(2.0),
      ); // ≈8.1549 m
      final h = SupplyDesignCriteria.recommended().requiredPumpHead(
        staticLift: const Length(35),
        frictionLoss: friction,
      );
      // 35 + 8.1549 + 22.9358 ≈ 66.091 m
      expect(h.meters, closeTo(66.0907, 1e-3));
    });
  });

  group('feasibility against SNI 8153:2015', () {
    test('2.25 bar target sits inside the SNI band', () {
      const sni = SniProfile();
      final target = SupplyDesignCriteria.recommended()
          .targetFixtureResidualPressure
          .pascals;
      // above the code minimum at a flush valve…
      expect(
        target,
        greaterThan(sni.minResidualPressureFlushValve.value.pascals),
      );
      // …and below the practical max + the mandatory-relief threshold.
      expect(target, lessThan(sni.maxFixtureStaticPressure.value.pascals));
      expect(
        target,
        lessThan(sni.mandatoryPressureReliefThreshold.value.pascals),
      );
    });
  });
}
