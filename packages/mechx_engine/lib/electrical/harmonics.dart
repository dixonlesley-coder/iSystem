/// Harmonics / power-quality estimate for a panel (A8 advanced pass).
///
/// Ported from PanelMaker `engine/harmonics.ts` + `standards/harmonics.ts`.
/// Estimates a panel's harmonic burden from its non-linear (electronically
/// switched) loads and recommends mitigation:
///  - an oversized neutral for single-phase triplen-harmonic content (3rd, 9th…
///    add arithmetically in the shared neutral — up to ~√3× phase current at
///    100 % single-phase non-linear load); and
///  - an input line reactor / harmonic filter for 3-phase 6-pulse drives
///    (5th/7th harmonics) when the non-linear share of the panel is large.
///
/// This is a DESIGN ESTIMATE, not a measured power-quality survey. The
/// thresholds are defensible rules of thumb drawn from IEC 60364-5-52 §523.6.3
/// (neutral sizing for harmonics) and IEC 61000-2-4 / IEEE 519 (THD bands) —
/// none is an SNI/PUIL clause. See [HarmonicsResult.verifyItems].
///
/// Zero Flutter imports.
library;

import '../standards/puil.dart' show ElectricalStandardsProfile;
import 'load_kind.dart' show LoadKind;
import 'panel_results.dart'
    show ElectricalCircuitResult, ElectricalPanelResult;

// ── Thresholds (// VERIFY — rules of thumb, NOT an SNI/PUIL clause) ──────────

/// Single-phase non-linear fraction (of panel demand) above which triplen
/// harmonics dominate the neutral and a full-size/oversized neutral is needed.
/// IEC 60364-5-52 Annex E rule of thumb. // VERIFY notAnSniClause.
const double neutralOversizeFractionThreshold = 0.33;

/// Three-phase non-linear (6-pulse drive) fraction above which the
/// characteristic 5th/7th harmonics warrant an input line reactor.
/// // VERIFY notAnSniClause (rule of thumb).
const double reactorFractionThreshold = 0.35;

/// Total non-linear fraction above which a harmonic filter (passive trap or
/// active filter) is recommended in addition to drive-level line reactors.
/// // VERIFY notAnSniClause (rule of thumb).
const double filterFractionThreshold = 0.6;

/// Typical input line-reactor impedance recommended for 6-pulse drives (% Z).
/// // VERIFY notAnSniClause (typical 3–5 % value).
const double recommendedReactorPctZ = 3;

/// Neutral-current multiplier of phase current at 100 % single-phase non-linear
/// load: the third-harmonic neutral current approaches √3 ≈ 1.73× phase current
/// (IEC 60364-5-52 Annex E). // VERIFY notAnSniClause.
const double triplenNeutralPeakFactor = 1.7320508075688772; // √3

/// Qualitative total-harmonic-distortion band derived from the non-linear share.
enum ThdBand { low, moderate, high }

extension ThdBandLabel on ThdBand {
  String get label => switch (this) {
        ThdBand.low => 'low',
        ThdBand.moderate => 'moderate',
        ThdBand.high => 'high',
      };
}

/// Non-linear-fraction breakpoints between the qualitative THD bands.
/// // VERIFY notAnSniClause.
const double thdModerateBreak = 0.2;
const double thdHighBreak = 0.45;

/// Map a panel's non-linear load fraction (0–1) to a qualitative THD band.
ThdBand thdBandFor(double nonLinearFraction) {
  if (nonLinearFraction >= thdHighBreak) return ThdBand.high;
  if (nonLinearFraction >= thdModerateBreak) return ThdBand.moderate;
  return ThdBand.low;
}

/// Neutral oversize multiplier (of phase current) for a given single-phase
/// non-linear share (0–1): a linear ramp from 1.0 at the threshold up to the
/// triplen peak factor (√3) at 100 % single-phase non-linear load. Below the
/// threshold the standard reduced neutral remains acceptable (factor 1.0).
double neutralOversizeFactor(double singlePhaseNonLinearFraction) {
  final f = singlePhaseNonLinearFraction.clamp(0.0, 1.0);
  if (f < neutralOversizeFractionThreshold) return 1;
  const span = 1 - neutralOversizeFractionThreshold;
  final t = span > 0 ? (f - neutralOversizeFractionThreshold) / span : 1.0;
  return 1 + t * (triplenNeutralPeakFactor - 1);
}

/// A panel's harmonic burden and the recommended mitigation.
class HarmonicsResult {
  /// Non-linear demand as a fraction of total panel demand (0–1), 3 dp.
  final double nonLinearFraction;

  /// Single-phase non-linear share of total panel demand (0–1), 3 dp.
  final double singlePhaseFraction;

  /// Three-phase non-linear share of total panel demand (0–1), 3 dp.
  final double threePhaseFraction;

  /// Neutral oversize multiplier of phase current (≥ 1.0), 2 dp.
  final double neutralOversizeFactor;

  /// Recommended neutral CSA (mm²) — the largest panel neutral stepped up by
  /// [neutralOversizeFactor] along the standard ladder (unchanged when no
  /// oversizing is needed).
  final double recommendedNeutralCsaMm2;

  /// Whether a 3 % input line reactor is recommended for the 6-pulse drives.
  final bool reactorRecommended;

  /// The recommended input line-reactor impedance (% Z) when applicable.
  final double reactorPctZ;

  /// Whether a harmonic filter is recommended in addition.
  final bool filterRecommended;

  /// Qualitative THD band expected on the panel.
  final ThdBand thdBand;

  final String note;

  /// Honesty surface — the foreign / rule-of-thumb standards behind this
  /// estimate (mirrors the SNI verifyChecklist pattern).
  final List<String> verifyItems;

  const HarmonicsResult({
    required this.nonLinearFraction,
    required this.singlePhaseFraction,
    required this.threePhaseFraction,
    required this.neutralOversizeFactor,
    required this.recommendedNeutralCsaMm2,
    required this.reactorRecommended,
    required this.reactorPctZ,
    required this.filterRecommended,
    required this.thdBand,
    required this.note,
    required this.verifyItems,
  });
}

/// Whether a load draws non-linear (harmonic-rich) current. This Dart port has
/// no starter-type model (that is a PanelMaker control concept), so the
/// classification is by [LoadKind] alone — UPS and welding (rectifier
/// front-ends) are non-linear. The caller can additionally flag drive-fed
/// motors via [nonLinearFraction] on the panel-level call below.
bool isNonLinearKind(LoadKind kind) =>
    kind == LoadKind.ups || kind == LoadKind.welding;

double _round(double v, int dp) {
  final f = _pow10(dp);
  return (v * f).round() / f;
}

double _pow10(int n) {
  var f = 1.0;
  for (var i = 0; i < n; i++) {
    f *= 10;
  }
  return f;
}

/// Step a CSA up the standard ladder by [factor], returning the smallest
/// standard section ≥ csa·factor (falls back to the original csa).
double _upsizeCsa(
  ElectricalStandardsProfile profile,
  double csaMm2,
  double factor,
) {
  final target = csaMm2 * factor;
  for (final s in profile.standardSectionsMm2) {
    if (s >= target) return s;
  }
  return csaMm2;
}

/// Estimate a panel's harmonic burden from its sized circuits.
///
/// [nonLinearFraction] optionally pins the panel's non-linear demand share
/// directly (0–1) — use it when the caller knows drive-fed motors that the
/// kind-only [isNonLinearKind] classifier cannot see (the MEP feed marks
/// VFD-driven pumps/fans). When omitted, the share is derived from the circuit
/// load kinds (UPS / welding). Returns `null` when the panel carries no
/// non-linear load (nothing to report).
HarmonicsResult? estimateHarmonics(
  ElectricalPanelResult panel,
  ElectricalStandardsProfile profile, {
  double? nonLinearFraction,
}) {
  // Per-circuit demand proxy: use the breaker rating as the circuit weight
  // (the panel result does not carry per-circuit watts; rating tracks load).
  var totalW = 0.0;
  var nonLinearW = 0.0;
  var singlePhaseNonLinearW = 0.0;
  var threePhaseNonLinearW = 0.0;
  double largestNeutral = 0;

  for (final ElectricalCircuitResult c in panel.circuits) {
    if (c.loadKind == LoadKind.spare) continue;
    final w = c.designCurrent.amperes; // weight ∝ current
    totalW += w;
    if (c.grounding.neutralCsaMm2 > largestNeutral) {
      largestNeutral = c.grounding.neutralCsaMm2;
    }
    if (isNonLinearKind(c.loadKind)) {
      nonLinearW += w;
      if (c.threePhase) {
        threePhaseNonLinearW += w;
      } else {
        singlePhaseNonLinearW += w;
      }
    }
  }

  // A caller-supplied fraction overrides the kind-derived share entirely
  // (e.g. when VFD-driven equipment dominates the panel). Distribute it across
  // single/three-phase by the panel's three-phase incomer, conservatively.
  double nlFrac;
  double spFrac;
  double tpFrac;
  if (nonLinearFraction != null) {
    nlFrac = nonLinearFraction.clamp(0.0, 1.0);
    final threePhasePanel = panel.incomer.poles >= 3;
    tpFrac = threePhasePanel ? nlFrac : 0;
    spFrac = threePhasePanel ? 0 : nlFrac;
  } else {
    if (nonLinearW <= 0 || totalW <= 0) return null;
    nlFrac = _round(nonLinearW / totalW, 3);
    spFrac = _round(singlePhaseNonLinearW / totalW, 3);
    tpFrac = _round(threePhaseNonLinearW / totalW, 3);
  }

  final nFactor = _round(neutralOversizeFactor(spFrac), 2);
  final neutralOversizeNeeded = spFrac >= neutralOversizeFractionThreshold;
  final recNeutral = neutralOversizeNeeded && largestNeutral > 0
      ? _upsizeCsa(profile, largestNeutral, nFactor)
      : largestNeutral;

  final reactorRecommended = tpFrac >= reactorFractionThreshold;
  final filterRecommended = nlFrac >= filterFractionThreshold;
  final band = thdBandFor(nlFrac);

  final notes = <String>[];
  if (neutralOversizeNeeded) {
    notes.add(
      'Single-phase non-linear load (${(spFrac * 100).round()}%) raises '
      'triplen-harmonic neutral current to ~${nFactor}x phase'
      '${recNeutral > 0 ? ' — use a ${_num(recNeutral)} mm2 neutral' : ''}.',
    );
  }
  if (reactorRecommended) {
    notes.add(
      'Three-phase 6-pulse drive share (${(tpFrac * 100).round()}%) injects '
      '5th/7th harmonics — fit ${_num(recommendedReactorPctZ)}% input line '
      'reactors${filterRecommended ? ' and a harmonic filter' : ''}.',
    );
  } else if (filterRecommended) {
    notes.add('High non-linear load — a harmonic filter is recommended.');
  }
  if (notes.isEmpty) {
    notes.add(
      'Non-linear load ${(nlFrac * 100).round()}% of demand — '
      '${band.label} distortion expected.',
    );
  }

  return HarmonicsResult(
    nonLinearFraction: nlFrac,
    singlePhaseFraction: spFrac,
    threePhaseFraction: tpFrac,
    neutralOversizeFactor: nFactor,
    recommendedNeutralCsaMm2: recNeutral,
    reactorRecommended: reactorRecommended,
    reactorPctZ: recommendedReactorPctZ,
    filterRecommended: filterRecommended,
    thdBand: band,
    note: notes.join(' '),
    verifyItems: const [
      'Harmonic thresholds are design rules of thumb (IEC 60364-5-52 Annex E '
          'neutral sizing; IEC 61000-2-4 / IEEE 519 THD bands) — NOT an '
          'SNI/PUIL clause and not a substitute for a measured power-quality '
          'survey.',
    ],
  );
}

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();
