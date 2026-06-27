/// §8 Pump-duty sizing module.
///
/// Selects the smallest standard motor frame size whose rated power covers the
/// pump shaft demand, then bundles all four power values — hydraulic, shaft,
/// motor-input, and selected motor — into a single [PumpDuty] record.
///
/// This is strictly the *pump/energy* code path (§12): it calls only
/// [hydraulicPower] and [shaftPower] from the hydraulic kernel. The
/// pressurised-pipe and gravity-drainage paths are separate concerns and are
/// NOT used here.
///
/// Zero Flutter imports.
library;

import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/sizing/operating_point.dart';
import 'package:mechx_engine/units.dart';

// ── Standard motor frame sizes ─────────────────────────────────────────────

/// IEC / NEMA standard motor rated outputs in kilowatts, ascending.
///
/// Callers select the smallest entry whose value is ≥ the required shaft power.
const List<double> standardMotorKw = <double>[
  0.37,
  0.55,
  0.75,
  1.1,
  1.5,
  2.2,
  3.0,
  4.0,
  5.5,
  7.5,
  11,
  15,
  18.5,
  22,
  30,
  37,
  45,
  55,
  75,
];

// ── Result ─────────────────────────────────────────────────────────────────

/// All power quantities produced by [sizePump] for one duty point.
class PumpDuty {
  /// Useful (hydraulic) power transferred to the fluid: P = ρ·g·Q·H.
  final Power hydraulicPower;

  /// Shaft (brake) power the pump must receive from the motor:
  /// P_shaft = P_hydraulic / η_pump.
  final Power shaftPower;

  /// Motor electrical input power:
  /// P_input = P_shaft / η_motor.
  final Power motorInputPower;

  /// Smallest standard motor whose rated output ≥ [shaftPower].
  final Power selectedMotor;

  /// The volumetric flow at which this duty was sized.
  final FlowRate flow;

  /// The total head against which the pump must operate.
  final Head head;

  /// System × equipment curve operating-point analysis (intersection +
  /// stability + NPSH cavitation check), composed over this duty by
  /// [computePumpOperatingPoint]. Null unless requested — an absent value leaves
  /// the duty byte-identical to before this feature. Its curve coefficients are
  /// // VERIFY representative estimates, not certified pump data.
  final PumpOperatingPoint? operatingPoint;

  const PumpDuty({
    required this.flow,
    required this.head,
    required this.hydraulicPower,
    required this.shaftPower,
    required this.motorInputPower,
    required this.selectedMotor,
    this.operatingPoint,
  });
}

// ── Motor selection ────────────────────────────────────────────────────────

/// Return the smallest entry in [standardMotorKw] whose value is ≥
/// [shaft].inKiloWatts, as a [Power].
///
/// If [shaft] exceeds all standard entries the largest listed motor is returned
/// (oversized condition — caller should flag this to the user).
Power selectMotor(Power shaft) {
  final required = shaft.inKiloWatts;
  for (final kw in standardMotorKw) {
    if (kw >= required) {
      return Power.kiloWatts(kw);
    }
  }
  // Shaft demand exceeds the table: return the largest available.
  return Power.kiloWatts(standardMotorKw.last);
}

// ── Public API ─────────────────────────────────────────────────────────────

/// Size a pump duty point and select the smallest adequate standard motor.
///
/// Parameters:
/// - [flow]            — design volumetric flow rate (m³/s).
/// - [head]            — total head the pump must develop (m).
/// - [pumpEfficiency]  — overall pump hydraulic efficiency η_p (0 < η ≤ 1);
///                       defaults to 0.70 (70 %).
/// - [motorEfficiency] — motor efficiency η_m (0 < η ≤ 1);
///                       defaults to 0.90 (90 %).
///
/// When [withOperatingPoint] is true (or any system-curve / NPSH input is
/// supplied) the result also carries a [PumpOperatingPoint] (the system ×
/// equipment curve intersection + NPSH cavitation check) via
/// [computePumpOperatingPoint]. Omitting all of these leaves [PumpDuty.operatingPoint]
/// null and the result byte-identical to before this feature.
///
/// Returns a [PumpDuty] containing all five calculated values.
PumpDuty sizePump({
  required FlowRate flow,
  required Head head,
  double pumpEfficiency = 0.70,
  double motorEfficiency = 0.90,
  bool withOperatingPoint = false,
  Head? systemStaticHead,
  double? systemResistanceK,
  Head? suctionStaticHead,
}) {
  assert(
    pumpEfficiency > 0 && pumpEfficiency <= 1,
    'pumpEfficiency must be in (0, 1]',
  );
  assert(
    motorEfficiency > 0 && motorEfficiency <= 1,
    'motorEfficiency must be in (0, 1]',
  );

  final hydraulic = hydraulicPower(flow: flow, head: head);
  final shaft = shaftPower(
    flow: flow,
    head: head,
    efficiency: pumpEfficiency,
  );
  final motorInput = Power(shaft.watts / motorEfficiency);
  final selectedMotor = selectMotor(shaft);

  // Compose the operating-point analysis only when requested (or any system /
  // suction input is supplied) — otherwise the field stays null and the duty is
  // byte-identical to before this feature.
  final wantsOp = withOperatingPoint ||
      systemStaticHead != null ||
      systemResistanceK != null ||
      suctionStaticHead != null;
  final operatingPoint = wantsOp
      ? computePumpOperatingPoint(
          designFlow: flow,
          designHead: head,
          systemStaticHead: systemStaticHead,
          systemResistanceK: systemResistanceK,
          suctionStaticHead: suctionStaticHead ?? const Head(0),
        )
      : null;

  return PumpDuty(
    flow: flow,
    head: head,
    hydraulicPower: hydraulic,
    shaftPower: shaft,
    motorInputPower: motorInput,
    selectedMotor: selectedMotor,
    operatingPoint: operatingPoint,
  );
}
