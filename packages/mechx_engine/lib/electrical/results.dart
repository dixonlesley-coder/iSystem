/// Result records produced by the electrical sizing functions. Immutable plain
/// data (the "only constructors" are the sizing functions in `sizing.dart`).
/// Mirrors PanelMaker's CableResult / BreakerResult / VoltageDropResult.
///
/// Zero Flutter imports.
library;

import '../standards/puil.dart' show BreakerClass, BreakerCurve;
import '../units.dart';

/// Voltage-drop over a cable run, with the applicable limit + pass/fail.
class VoltageDropResult {
  /// Absolute drop (V).
  final double dropV;

  /// Drop as a percentage of nominal voltage.
  final double dropPercent;

  /// Applicable limit (%) — 5 general / 3 lighting.
  final double limitPercent;

  /// Whether [dropPercent] is within [limitPercent] (1e-9 tolerance).
  final bool withinLimit;

  const VoltageDropResult({
    required this.dropV,
    required this.dropPercent,
    required this.limitPercent,
    required this.withinLimit,
  });
}

/// Selected protective device.
class BreakerResult {
  /// Nominal rating In.
  final Current ratingA;

  /// MCB vs MCCB frame.
  final BreakerClass deviceClass;

  /// Trip curve.
  final BreakerCurve curve;

  /// True when a manual override rating was used verbatim (not auto-sized).
  final bool overridden;

  const BreakerResult({
    required this.ratingA,
    required this.deviceClass,
    required this.curve,
    this.overridden = false,
  });
}

/// Selected cable conductor.
class CableResult {
  /// Per-run conductor cross-section (mm²).
  final double csaMm2;

  /// Base (30 °C, underated) ampacity of the chosen section.
  final Current baseKha;

  /// Derated ampacity actually available (× derating × parallel runs).
  final Current deratedIz;

  /// The derating factor applied (rounded to 3 dp).
  final double deratingFactor;

  /// Parallel runs per phase (null/1 = a single cable).
  final int? runsPerPhase;

  /// True when the voltage-drop limit — not ampacity — forced the section.
  final bool vdDriven;

  /// Human-readable governing rule (for the "why this size" note).
  final String appliedRule;

  const CableResult({
    required this.csaMm2,
    required this.baseKha,
    required this.deratedIz,
    required this.deratingFactor,
    this.runsPerPhase,
    required this.vdDriven,
    required this.appliedRule,
  });
}
