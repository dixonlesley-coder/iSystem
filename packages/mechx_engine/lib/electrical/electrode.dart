/// Earth-electrode (grounding-electrode) array design (A8 advanced pass).
///
/// Ported from PanelMaker `engine/electrode.ts` + `standards/soil.ts`. Computes
/// the resistance to earth of a single driven rod from the soil resistivity,
/// then the number of parallel rods needed to reach a target electrode
/// resistance (PUIL 2011 §3 target of 5 Ω by default).
///
/// Method:
///  - Single driven rod (Dwight / IEEE Std 142 "Green Book"):
///      R = ρ / (2π·L) · (ln(8L/d) − 1),  L (length) and d (diameter) in metres.
///  - n vertical rods in parallel IN LINE at spacing s (BS 7430 §9.5):
///      R_n = R_single · (1 + λ·α) / n,   α = ρ / (2π·R_single·s),
///    i.e. a utilisation factor η = 1 / (1 + λ·α), with λ(n) the BS 7430
///    in-line mutual-resistance factor (Round 17 — the previous fixed η(n)
///    table was 4–12 % optimistic above 2 rods and clamped at 0.70 past 10,
///    so a 10-rod array at 100 Ω·m printed 4.78 Ω "meets 5 Ω" while BS 7430
///    gives 5.37 Ω).
///
/// FOREIGN STANDARDS — Dwight / IEEE 142 (American) and BS 7430 (British); the
/// 5 Ω target mirrors PUIL 2011 §3 (secondarySource). First-pass estimates only:
/// the achieved resistance is dominated by the true on-site soil resistivity
/// (confirm with a Wenner survey). Surfaced in [ElectrodeDesign.verifyItems].
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

import '../units.dart' show Resistance;

/// Default driven-rod length (m). // VERIFY secondarySource (BS 7430 §9).
const double defaultRodLengthM = 3.0;

/// Default copper-bonded rod diameter (mm) — common Indonesian/IEC stock size.
/// // VERIFY secondarySource.
const double defaultRodDiameterMm = 16;

/// PUIL earthing-electrode resistance target (Ω). // VERIFY secondarySource
/// (PUIL 2011 §3).
const double targetElectrodeOhm = 5;

/// BS 7430 in-line mutual-resistance factor λ for n = 2..10 rods in a
/// straight line (BS 7430 Table / §9.5). λ(1) = 0.
// VERIFY secondarySource (BS 7430:2011 §9.5 in-line λ table).
const List<({int count, double lambda})> bs7430InLineLambda = [
  (count: 2, lambda: 1.00),
  (count: 3, lambda: 1.66),
  (count: 4, lambda: 2.15),
  (count: 5, lambda: 2.54),
  (count: 6, lambda: 2.87),
  (count: 7, lambda: 3.15),
  (count: 8, lambda: 3.39),
  (count: 9, lambda: 3.61),
  (count: 10, lambda: 3.81),
];

/// λ(n) for n rods in line. 2..10 read [bs7430InLineLambda]; beyond the table
/// the first-principles equal-spacing sum it tabulates is used,
/// `λ(n) = (2/n)·Σ_{k=1}^{n−1} (n − k)/k` (every rod pair at k spacings
/// contributes 1/k; it reproduces the table — n = 3: (2/3)(2 + 0.5) = 1.667 —
/// and runs ~1 % HIGH at n = 10: 3.858 vs 3.81, i.e. it errs pessimistic).
// VERIFY secondarySource (extrapolation of BS 7430 beyond its table).
double bs7430Lambda(int count) {
  if (count <= 1) return 0;
  for (final row in bs7430InLineLambda) {
    if (row.count == count) return row.lambda;
  }
  var sum = 0.0;
  for (var k = 1; k < count; k++) {
    sum += (count - k) / k;
  }
  return 2 * sum / count;
}

/// Result of an earth-electrode array design.
class ElectrodeDesign {
  /// Resistance to earth of one driven rod (Ω).
  final Resistance singleRod;

  /// Number of parallel rods chosen to meet (or best approach) the target.
  final int rodCount;

  /// Achieved resistance of the rod array (Ω).
  final Resistance achieved;

  /// Rod length used (m).
  final double rodLengthM;

  /// Rod diameter used (mm).
  final double rodDiameterMm;

  /// Rod-to-rod spacing used (m).
  final double spacingM;

  /// Soil resistivity used (Ω·m).
  final double soilResistivityOhmM;

  /// Target electrode resistance (Ω).
  final double targetOhm;

  /// True when the achieved resistance is at or below the target.
  final bool meetsTarget;

  final String note;

  /// Honesty surface — the foreign / secondary-source standards behind this.
  final List<String> verifyItems;

  const ElectrodeDesign({
    required this.singleRod,
    required this.rodCount,
    required this.achieved,
    required this.rodLengthM,
    required this.rodDiameterMm,
    required this.spacingM,
    required this.soilResistivityOhmM,
    required this.targetOhm,
    required this.meetsTarget,
    required this.note,
    required this.verifyItems,
  });
}

/// Utilisation (combining) factor η = 1 / (1 + λ(n)·α) for [count] rods in
/// line, with α = ρ/(2π·R_single·s) the BS 7430 spacing term ([alpha]). For a
/// rod of length L spaced s = L apart α = 1/(ln(8L/d) − 1), independent of ρ —
/// 0.1584 for the default 3 m × 16 mm rod. A single rod is η = 1.
double utilisationFactor(int count, {required double alpha}) {
  if (count <= 1) return 1;
  return 1 / (1 + bs7430Lambda(count) * alpha);
}

/// Resistance of a single driven vertical rod to earth (Dwight / IEEE 142).
///
/// [rho] soil resistivity (Ω·m), [lengthM] rod length (m), [diaMm] rod diameter
/// (mm). Returns the resistance (Ω).
double singleRodResistance(double rho, double lengthM, double diaMm) {
  final l = math.max(lengthM, 0.1);
  final d = math.max(diaMm, 1) / 1000; // mm → m
  return (rho / (2 * math.pi * l)) * (math.log((8 * l) / d) - 1);
}

/// Search cap on the parallel-rod count. Beyond ~100 rods an array is no longer
/// a sensible remedy (the soil, not the rod count, is the problem), so the
/// design stops there and reports the target as unmet.
// VERIFY — notAnSniClause (a modelling/search cap, not a standard value).
const int maxElectrodeRods = 100;

/// Design an earth-electrode array: size a single rod, then find the minimum
/// number of parallel rods needed to reach [targetOhm].
ElectrodeDesign designElectrode({
  required double soilResistivityOhmM,
  double targetOhm = targetElectrodeOhm,
  double rodLengthM = defaultRodLengthM,
  double rodDiameterMm = defaultRodDiameterMm,
  double? spacingM,
}) {
  final spacing = spacingM ?? rodLengthM;
  final rho = soilResistivityOhmM;

  final singleRodOhm = singleRodResistance(rho, rodLengthM, rodDiameterMm);
  // BS 7430 spacing term α = ρ/(2π·R1·s) (0 when there is nothing to couple).
  final alpha = singleRodOhm > 0 && singleRodOhm.isFinite && spacing > 0
      ? rho / (2 * math.pi * singleRodOhm * spacing)
      : 0.0;

  // MINIMUM rod count that actually reaches the target with the count's OWN
  // BS 7430 utilisation η(n) = 1/(1 + λ(n)·α): the smallest n with
  // R_single / (n·η(n)) ≤ target. No count within [maxElectrodeRods] ⇒ the
  // cap, flagged.
  var rodCount = maxElectrodeRods;
  if (singleRodOhm.isFinite) {
    for (var n = 1; n <= maxElectrodeRods; n++) {
      if (singleRodOhm / (n * utilisationFactor(n, alpha: alpha)) <= targetOhm) {
        rodCount = n;
        break;
      }
    }
  } else {
    rodCount = 1;
  }

  final eta = utilisationFactor(rodCount, alpha: alpha);
  final achievedOhm = singleRodOhm / (rodCount * eta);
  final meetsTarget = achievedOhm <= targetOhm;

  final r1 = _round(singleRodOhm, 2);
  final rn = _round(achievedOhm, 2);
  final tail = meetsTarget
      ? ' (<= ${_num(targetOhm)} ohm target).'
      : ' (above ${_num(targetOhm)} ohm target; survey soil / extend array).';
  final note = rodCount == 1
      ? '1 rod of ${_num(rodLengthM)} m x ${_num(rodDiameterMm)} mm in '
          '${_num(rho)} ohm-m soil -> $rn ohm$tail'
      : '$rodCount rods of ${_num(rodLengthM)} m, spaced ${_num(spacing)} m, in '
          'parallel (single rod $r1 ohm) -> $rn ohm$tail';

  return ElectrodeDesign(
    singleRod: Resistance(singleRodOhm),
    rodCount: rodCount,
    achieved: Resistance(achievedOhm),
    rodLengthM: rodLengthM,
    rodDiameterMm: rodDiameterMm,
    spacingM: spacing,
    soilResistivityOhmM: rho,
    targetOhm: targetOhm,
    meetsTarget: meetsTarget,
    note: note,
    verifyItems: const [
      'Earth-electrode sizing uses the Dwight single-rod formula (IEEE Std 142, '
          'American) and the BS 7430 in-line mutual-resistance method '
          '(R_n = R1(1 + lambda*alpha)/n, British); the 5 ohm '
          'target mirrors PUIL 2011 §3 (secondarySource). First-pass estimate - '
          'the achieved resistance is dominated by the true site soil '
          'resistivity; confirm with a Wenner four-pole survey.',
    ],
  );
}

double _round(double v, int dp) {
  var f = 1.0;
  for (var i = 0; i < dp; i++) {
    f *= 10;
  }
  return (v * f).round() / f;
}

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();
