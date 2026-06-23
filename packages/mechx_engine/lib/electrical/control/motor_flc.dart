/// Standard motor full-load current (FLC), IEC 60034-1 typical values at 400 V.
/// Ported from PanelMaker `engine/control/motorFLC.ts` + `standards/control/motor.ts`.
///
/// Actual FLC varies ±5–10 % by manufacturer / motor design — always verify
/// against the motor nameplate before final device selection.
///
/// PURE Dart — zero Flutter imports.
library;

import '../../units.dart';

/// One row of the 400 V three-phase squirrel-cage FLC table.
class _MotorRating {
  /// Rated mechanical (shaft) power (kW).
  final double kw;

  /// Approximate full-load current at 400 V, three-phase (A).
  final double flcA400;

  const _MotorRating(this.kw, this.flcA400);
}

/// Typical 3-phase squirrel-cage motor FLC at 400 V, ascending by kW.
///
/// // VERIFY (secondarySource): IEC 60034-1 typical composite — confirm against
/// the manufacturer's motor nameplate.
const List<_MotorRating> _motorFlc400v = [
  _MotorRating(0.37, 1.0),
  _MotorRating(0.55, 1.5),
  _MotorRating(0.75, 1.9),
  _MotorRating(1.1, 2.6),
  _MotorRating(1.5, 3.5),
  _MotorRating(2.2, 5.0),
  _MotorRating(3, 6.6),
  _MotorRating(4, 8.5),
  _MotorRating(5.5, 11.5),
  _MotorRating(7.5, 15.5),
  _MotorRating(11, 22),
  _MotorRating(15, 29),
  _MotorRating(18.5, 35),
  _MotorRating(22, 42),
  _MotorRating(30, 56),
  _MotorRating(37, 68),
  _MotorRating(45, 83),
  _MotorRating(55, 100),
  _MotorRating(75, 135),
  _MotorRating(90, 162),
  _MotorRating(110, 196),
  _MotorRating(132, 233),
  _MotorRating(160, 282),
  _MotorRating(200, 350),
  _MotorRating(250, 435),
];

/// One row of the 1-phase induction-motor η·cosφ table.
class _Motor1phEffPf {
  final double kw;

  /// Efficiency × power-factor product (η·cosφ).
  final double effPf;

  const _Motor1phEffPf(this.kw, this.effPf);
}

/// Typical single-phase induction-motor η·cosφ by rating. Small 1-ph machines
/// are markedly less efficient than 3-ph, so FLC must be derived as
/// `I = P_shaft / (V · η·cosφ)`, NOT `P_shaft / (V · cosφ)` (the latter
/// underestimates the current by the efficiency, ~15–30 % on small motors).
///
/// // VERIFY (secondarySource): conservative composite of capacitor-start/run
/// motor data — confirm against the motor nameplate.
const List<_Motor1phEffPf> _motor1phEffPf = [
  _Motor1phEffPf(0.18, 0.5),
  _Motor1phEffPf(0.37, 0.54),
  _Motor1phEffPf(0.55, 0.57),
  _Motor1phEffPf(0.75, 0.6),
  _Motor1phEffPf(1.1, 0.62),
  _Motor1phEffPf(1.5, 0.65),
  _Motor1phEffPf(2.2, 0.68),
  _Motor1phEffPf(3, 0.7),
  _Motor1phEffPf(3.7, 0.72),
];

/// Three-phase motor full-load current (A) for [kw], interpolating the IEC 60034-1
/// 400 V table and scaling inversely with voltage (FLC ∝ 1/V at constant power).
///
/// Below the smallest / above the largest table entry the end value is clamped.
Current motorFlc(double kw, [Voltage v = const Voltage(400)]) {
  const table = _motorFlc400v;
  final first = table.first;
  final last = table.last;

  double flc400;
  if (kw <= first.kw) {
    flc400 = first.flcA400;
  } else if (kw >= last.kw) {
    flc400 = last.flcA400;
  } else {
    flc400 = last.flcA400;
    for (var i = 0; i < table.length - 1; i++) {
      final lo = table[i];
      final hi = table[i + 1];
      if (kw >= lo.kw && kw <= hi.kw) {
        final t = (kw - lo.kw) / (hi.kw - lo.kw);
        flc400 = lo.flcA400 + t * (hi.flcA400 - lo.flcA400);
        break;
      }
    }
  }
  final volts = v.volts > 0 ? v.volts : 400.0;
  return Current(flc400 * (400.0 / volts));
}

/// Single-phase motor full-load current (A): `I = P_shaft / (V · η·cosφ)`, with
/// η·cosφ interpolated from typical 1-ph induction-motor data.
Current motorFlc1ph(double kw, [Voltage v = const Voltage(230)]) {
  const table = _motor1phEffPf;
  final first = table.first;
  final last = table.last;

  double effPf;
  if (kw <= first.kw) {
    effPf = first.effPf;
  } else if (kw >= last.kw) {
    effPf = last.effPf;
  } else {
    effPf = last.effPf;
    for (var i = 0; i < table.length - 1; i++) {
      final lo = table[i];
      final hi = table[i + 1];
      if (kw >= lo.kw && kw <= hi.kw) {
        final t = (kw - lo.kw) / (hi.kw - lo.kw);
        effPf = lo.effPf + t * (hi.effPf - lo.effPf);
        break;
      }
    }
  }
  final volts = v.volts > 0 ? v.volts : 230.0;
  return Current((kw * 1000.0) / (volts * effPf));
}
