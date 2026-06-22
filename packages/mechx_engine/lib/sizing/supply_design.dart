/// Supply-side design criteria and pump-head composition (pressurized path).
///
/// These are DESIGN choices the engineer sets — NOT SNI requirements. They sit
/// *between* the SNI 8153:2015 bounds: comfortably above the code minimum
/// residual at a fixture (0.5 kgf/cm² ≈ 0.49 bar at an outlet, 1 kgf/cm² ≈
/// 0.98 bar at a flush valve) and well below the practical maximum (~4 kgf/cm²
/// ≈ 3.92 bar) and the mandatory pressure-relief threshold (5 kgf/cm² ≈
/// 4.9 bar). Keeping the target in this band gives good fixture performance
/// without pushing lower floors toward needing a PRV or a separate zone.
///
/// Pressurized code path only (§7); zero Flutter imports.
library;

import '../hydraulics.dart';
import '../units.dart';

/// Design criteria for a pressurized (boosted/downfed) water-supply zone.
class SupplyDesignCriteria {
  /// The residual (flowing) pressure we want guaranteed at the most-remote /
  /// highest critical fixture in the zone. Pump head is sized so this holds.
  final Pressure targetFixtureResidualPressure;

  const SupplyDesignCriteria({required this.targetFixtureResidualPressure});

  /// Recommended optimal target: **2.25 bar**, the midpoint of the 2.0–2.5 bar
  /// comfort band. Raise toward 2.5 bar for high-end fixtures / long branches;
  /// lower toward 2.0 bar to cut pump energy and keep lower floors away from
  /// the PRV/zoning threshold.
  factory SupplyDesignCriteria.recommended() => const SupplyDesignCriteria(
        targetFixtureResidualPressure: Pressure(225000.0), // 2.25 bar
      );

  /// Lower bound of the recommended comfort band (2.0 bar).
  static const Pressure minComfortTarget = Pressure(200000.0);

  /// Upper bound of the recommended comfort band (2.5 bar).
  static const Pressure maxComfortTarget = Pressure(250000.0);

  /// The target residual expressed as a head of water (what it adds to the
  /// pump duty). At 2.25 bar this is ≈22.94 m.
  Head get targetResidualHead =>
      headFromPressure(targetFixtureResidualPressure);

  /// Pump head required to hold [targetFixtureResidualPressure] at the critical
  /// fixture, given the [staticLift] up to it and the [frictionLoss] along the
  /// critical path. See [requiredPumpHead].
  Head requiredPumpHead({
    required Length staticLift,
    required Head frictionLoss,
    double density = defaultWaterDensity,
    double gravity = standardGravity,
  }) =>
      computeRequiredPumpHead(
        staticLift: staticLift,
        frictionLoss: frictionLoss,
        targetResidualPressure: targetFixtureResidualPressure,
        density: density,
        gravity: gravity,
      );
}

/// Pump head a supply zone must provide so the critical fixture sees
/// [targetResidualPressure]:
///
///   H_pump = H_static + H_friction + H_residual
///
/// where H_static is the elevation rise from the pump to the critical fixture
/// (a length = head directly; geometry/floor-elevation is the source of truth,
/// §10), H_friction is the summed friction + fittings loss along the critical
/// path, and H_residual is [targetResidualPressure] as head. Velocity head is
/// neglected (typically <0.1 m and conservative to omit).
Head computeRequiredPumpHead({
  required Length staticLift,
  required Head frictionLoss,
  required Pressure targetResidualPressure,
  double density = defaultWaterDensity,
  double gravity = standardGravity,
}) {
  final residual = headFromPressure(
    targetResidualPressure,
    density: density,
    gravity: gravity,
  );
  return Head(staticLift.meters + frictionLoss.meters + residual.meters);
}
