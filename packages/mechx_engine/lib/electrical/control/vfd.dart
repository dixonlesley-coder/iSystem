/// VFD / VSD selection. Ported from PanelMaker `engine/control/selectVFD.ts` +
/// `standards/control/vfd.ts`.
///
/// A drive is selected primarily on rated *output* current (≥ motor FLC × margin).
/// Heat dissipation ≈ rated power × (1 − efficiency).
///
/// PURE Dart — zero Flutter imports.
library;

import '../../units.dart';

/// One standard 400 V drive rating.
class VfdRating {
  /// Rated motor power the drive is matched to (kW).
  final double kw;

  /// Rated continuous output current at 400 V (A).
  final double outputA;

  const VfdRating(this.kw, this.outputA);
}

/// Standard 400 V drive ratings, ascending.
///
/// // VERIFY (secondarySource): typical 400 V drive output-current ladder —
/// confirm against the chosen drive series datasheet.
const List<VfdRating> vfdRatings400v = [
  VfdRating(0.37, 1.5),
  VfdRating(0.75, 2.5),
  VfdRating(1.5, 4.0),
  VfdRating(2.2, 6.0),
  VfdRating(3.7, 9.0),
  VfdRating(5.5, 13),
  VfdRating(7.5, 17),
  VfdRating(11, 25),
  VfdRating(15, 32),
  VfdRating(18.5, 40),
  VfdRating(22, 48),
  VfdRating(30, 65),
  VfdRating(37, 80),
  VfdRating(45, 96),
  VfdRating(55, 115),
  VfdRating(75, 155),
  VfdRating(90, 180),
  VfdRating(110, 225),
  VfdRating(132, 260),
  VfdRating(160, 302),
  VfdRating(200, 370),
  VfdRating(250, 477),
];

/// Safety margin of drive output current over motor FLC.
///
/// // VERIFY (secondarySource): common drive-sizing practice.
const double vfdCurrentMargin = 1.1;

/// Drive efficiency for heat-loss estimation (conservative 0.96 → ~4 % loss).
///
/// // VERIFY (secondarySource): typical drive efficiency.
const double vfdEfficiency = 0.96;

/// Heat dissipated by a drive at rated load (W) from its rated power (kW).
double vfdHeatLossW(double ratedKw) => ratedKw * 1000.0 * (1 - vfdEfficiency);

double _round(double x, [int dp = 2]) {
  var f = 1.0;
  for (var i = 0; i < dp; i++) {
    f *= 10;
  }
  return (x * f).round() / f;
}

/// The result of selecting a VFD.
class VfdSelection {
  /// Chosen rated motor power (kW).
  final double ratedKw;

  /// Chosen rated output current (A).
  final Current outputA;

  /// Heat dissipation at rated load (W).
  final double heatLossW;

  /// Required output current (FLC × margin) the drive must cover (A).
  final Current requiredA;

  /// False when no standard rating is large enough (the largest is returned).
  final bool ok;

  const VfdSelection({
    required this.ratedKw,
    required this.outputA,
    required this.heatLossW,
    required this.requiredA,
    required this.ok,
  });
}

/// Select a VFD by rated output current (≥ motor FLC × margin). Constant-torque
/// duty bumps up one frame for thermal headroom at low speed.
VfdSelection selectVfd(Current flc, {bool constantTorque = false}) {
  final requiredA = flc.amperes * vfdCurrentMargin;
  var idx = vfdRatings400v.indexWhere((v) => v.outputA >= requiredA);
  if (idx == -1) {
    idx = vfdRatings400v.length - 1;
  } else if (constantTorque && idx < vfdRatings400v.length - 1) {
    idx += 1;
  }
  final v = vfdRatings400v[idx];
  return VfdSelection(
    ratedKw: v.kw,
    outputA: Current(v.outputA),
    heatLossW: _round(vfdHeatLossW(v.kw), 0),
    requiredA: Current(_round(requiredA, 1)),
    ok: v.outputA >= requiredA,
  );
}
