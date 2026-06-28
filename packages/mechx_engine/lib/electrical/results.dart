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

  /// Whether the chosen section actually reaches the required ampacity (its
  /// derated Iz ≥ the Iz the breaker In + 1.25·Ib demands). `false` only on the
  /// terminal fallback where no standard section met Iz within the parallel-run
  /// limit — i.e. the breaker In > Iz, so the device NO LONGER protects the
  /// conductor (IEC 60364-4-43 / PUIL cl 2.2.8.3 In ≤ Iz coordination violated).
  /// Defaults true so a normally-sized cable is byte-identical.
  final bool ampacityReached;

  const CableResult({
    required this.csaMm2,
    required this.baseKha,
    required this.deratedIz,
    required this.deratingFactor,
    this.runsPerPhase,
    required this.vdDriven,
    required this.appliedRule,
    this.ampacityReached = true,
  });
}

/// What governed a busbar's selected cross-section: the continuous-current
/// (ampacity / incomer-In) duty, or the prospective-fault short-circuit
/// withstand (Icw) floor that upsized the bar beyond what the load needed.
enum BusbarSizingReason { ampacity, withstand }

/// Sized panel busbar — a standard flat copper bar, or (beyond the table) a
/// density-estimated section ([widthMm]/[thicknessMm] = 0 in that case).
class BusbarResult {
  final double widthMm;
  final double thicknessMm;
  final double csaMm2;
  final Current ampacityA;
  final Current totalCurrentA;

  /// What governed the selected section. [BusbarSizingReason.withstand] means
  /// the short-circuit withstand (Icw) floor upsized the bar beyond the
  /// continuous-current duty; [BusbarSizingReason.ampacity] is the default.
  final BusbarSizingReason sizingReason;

  /// Short-circuit withstand check against the panel's prospective fault — null
  /// when no fault level was supplied (the withstand fold was not applied).
  final BusbarWithstand? withstand;

  const BusbarResult({
    required this.widthMm,
    required this.thicknessMm,
    required this.csaMm2,
    required this.ampacityA,
    required this.totalCurrentA,
    this.sizingReason = BusbarSizingReason.ampacity,
    this.withstand,
  });
}

/// A busbar short-circuit withstand result (IEC 61439-1 §9.3) — additive data
/// attached to a [BusbarResult] when the prospective fault level is known.
class BusbarWithstand {
  /// Prospective rms short-circuit current at the bus (kA).
  final double faultKa;

  /// Fault duration / device clearing time used for the thermal check (s).
  final double durationS;

  /// Rated short-time withstand current of the bar for [durationS] (kA rms) —
  /// the bar's thermal capability, Icw(t) = density·CSA / √t.
  final double icwKa;

  /// Rated peak withstand current the bar + its supports must resist (kA peak),
  /// Ipk = n · faultKa (the mechanical adequacy of supports is out of scope —
  /// reported for the designer to verify separately).
  final double ipkKa;

  /// Peak factor n (Ipk / Irms) applied at this fault level (Table 7).
  final double peakFactor;

  /// Whether the bar's thermal withstand (Icw) covers the prospective fault.
  final bool adequate;

  /// Withstand margin: Icw − fault (kA). Negative ⇒ the bar cannot survive the
  /// fault even at the largest standard section.
  final double marginKa;

  const BusbarWithstand({
    required this.faultKa,
    required this.durationS,
    required this.icwKa,
    required this.ipkKa,
    required this.peakFactor,
    required this.adequate,
    required this.marginKa,
  });
}

/// Neutral + protective-earth (PE) bar sizing derived from the phase bar.
class NeutralPeBars {
  /// Neutral bar (= phase bar by default; oversized for triplen harmonics when
  /// [neutralOversizeFactor] > 1 — FOLD 2).
  final double neutralCsaMm2;
  final Current neutralAmpacityA;

  /// PE bar per IEC 60364-5-54 §543 (S | 16 | S/2), floored at 6 mm².
  final double peCsaMm2;

  /// Triplen-harmonic neutral oversize multiplier of the phase bar applied
  /// (≥ 1.0; 1.0 = no oversize). FOLD 2 — set from the panel's harmonic estimate.
  final double neutralOversizeFactor;

  /// The single-phase non-linear (triplen) share that drove the oversize (0–1).
  /// 0 when no oversize was applied.
  final double triplenFraction;

  const NeutralPeBars({
    required this.neutralCsaMm2,
    required this.neutralAmpacityA,
    required this.peCsaMm2,
    this.neutralOversizeFactor = 1,
    this.triplenFraction = 0,
  });
}
