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
///  - n vertical rods in parallel, spaced ~ one rod-length apart, with a
///    utilisation/combining factor η (< 1) for mutual resistance (BS 7430 §9.5):
///      R_n = R_single / (n · η).
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

/// Nominal utilisation factor for "several" rods ~ one rod-length apart, used to
/// size the count before the exact η is applied. // VERIFY secondarySource.
const double defaultRodUtilisation = 0.8;

/// Utilisation (combining) factor η for n vertical rods in parallel ~ one
/// rod-length apart (BS 7430 §9.5 / IEEE 142). // VERIFY secondarySource.
const List<({int count, double eta})> rodUtilisation = [
  (count: 1, eta: 1.0),
  (count: 2, eta: 0.86),
  (count: 3, eta: 0.82),
  (count: 4, eta: 0.80),
  (count: 5, eta: 0.78),
  (count: 6, eta: 0.76),
  (count: 8, eta: 0.73),
  (count: 10, eta: 0.70),
];

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

/// Utilisation/combining factor η for [count] parallel rods (~one rod-length
/// apart), interpolated from [rodUtilisation]. Counts above the table clamp to
/// its last value; a single rod is η = 1.
double utilisationFactor(int count) {
  if (count <= 1) return 1;
  const table = rodUtilisation;
  final last = table.last;
  if (count >= last.count) return last.eta;
  for (var i = 0; i < table.length - 1; i++) {
    final lo = table[i];
    final hi = table[i + 1];
    if (count >= lo.count && count <= hi.count) {
      final span = hi.count - lo.count;
      if (span == 0) return lo.eta;
      final frac = (count - lo.count) / span;
      return lo.eta + frac * (hi.eta - lo.eta);
    }
  }
  return defaultRodUtilisation;
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

  // Minimum rod count to reach the target, using a representative η:
  // n ≥ R_single / (target · η).
  final rawCount = (singleRodOhm / (targetOhm * defaultRodUtilisation)).ceil();
  final rodCount = math.max(1, rawCount.isFinite ? rawCount : 1);

  final eta = utilisationFactor(rodCount);
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
          'American) and the BS 7430 utilisation factors (British); the 5 ohm '
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
