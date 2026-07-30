/// §8 Fan-duty sizing module — the HVAC analogue of `pump.dart`.
///
/// Given the design airflow and the total static pressure the duct system
/// imposes, computes the air power (Q·Δp), the shaft and motor-input power, and
/// selects the smallest standard motor. Reuses [selectMotor] from `pump.dart`.
///
/// This is the *fan/energy* code path (§12) — separate from the pressurised and
/// gravity paths. Zero Flutter imports.
library;

import 'package:mechx_engine/sizing/operating_point.dart';
import 'package:mechx_engine/sizing/pump.dart'
    show motorOversizedFor, selectMotor, standardMotorKw;
import 'package:mechx_engine/units.dart';

/// All power quantities for one fan duty point.
class FanDuty {
  /// Design airflow the fan must deliver.
  final FlowRate airflow;

  /// Total static pressure the fan must develop (duct friction + fittings +
  /// terminal losses).
  final Pressure totalStaticPressure;

  /// Useful air power: P_air = Q · Δp.
  final Power airPower;

  /// Shaft (brake) power: P_shaft = P_air / η_fan.
  final Power shaftPower;

  /// Motor electrical input: P_input = P_shaft / η_motor.
  final Power motorInputPower;

  /// Smallest standard motor whose rated output ≥ [shaftPower] — or, when
  /// [motorOversized] is true, the largest frame in [standardMotorKw].
  final Power selectedMotor;

  /// M11 — true when [shaftPower] exceeds the largest frame in
  /// [standardMotorKw] and [selectMotor] therefore CLAMPED: [selectedMotor] is
  /// then SMALLER than the duty needs. The fan analogue of
  /// `PumpDuty.motorOversized`; default false ⇒ in-range duties are
  /// byte-identical.
  final bool motorOversized;

  /// System × equipment curve operating-point analysis (intersection +
  /// stability), composed over this duty by [computeFanOperatingPoint]. Null
  /// unless requested — an absent value leaves the duty byte-identical to before
  /// this feature. Its curve coefficients are // VERIFY representative
  /// estimates, not certified fan data.
  final FanOperatingPoint? operatingPoint;

  const FanDuty({
    required this.airflow,
    required this.totalStaticPressure,
    required this.airPower,
    required this.shaftPower,
    required this.motorInputPower,
    required this.selectedMotor,
    this.operatingPoint,
    this.motorOversized = false,
  });
}

/// Size a fan duty point and select the smallest adequate standard motor.
///
/// - [airflow]         — design volumetric airflow (m³/s).
/// - [totalStaticPressure] — total static the fan must develop (Pa).
/// - [fanEfficiency]   — overall fan efficiency η_f (0 < η ≤ 1); default 0.65.
/// - [motorEfficiency] — motor efficiency η_m (0 < η ≤ 1); default 0.90.
///
/// When [withOperatingPoint] is true (or [systemResistanceK] is supplied) the
/// result also carries a [FanOperatingPoint] (the system × equipment curve
/// intersection) via [computeFanOperatingPoint]. Omitting both leaves
/// [FanDuty.operatingPoint] null and the result byte-identical to before.
FanDuty sizeFan({
  required FlowRate airflow,
  required Pressure totalStaticPressure,
  double fanEfficiency = 0.65,
  double motorEfficiency = 0.90,
  bool withOperatingPoint = false,
  double? systemResistanceK,
}) {
  assert(fanEfficiency > 0 && fanEfficiency <= 1, 'fanEfficiency in (0,1]');
  assert(motorEfficiency > 0 && motorEfficiency <= 1, 'motorEfficiency in (0,1]');

  final air = Power(
    airflow.cubicMetersPerSecond * totalStaticPressure.pascals,
  );
  final shaft = Power(air.watts / fanEfficiency);
  final motorInput = Power(shaft.watts / motorEfficiency);

  final wantsOp = withOperatingPoint || systemResistanceK != null;
  final operatingPoint = wantsOp
      ? computeFanOperatingPoint(
          designAirflow: airflow,
          designPressure: totalStaticPressure,
          systemResistanceK: systemResistanceK,
        )
      : null;

  return FanDuty(
    airflow: airflow,
    totalStaticPressure: totalStaticPressure,
    airPower: air,
    shaftPower: shaft,
    motorInputPower: motorInput,
    selectedMotor: selectMotor(shaft),
    operatingPoint: operatingPoint,
    motorOversized: motorOversizedFor(shaft),
  );
}
