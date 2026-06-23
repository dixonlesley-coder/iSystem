/// Control-circuit auxiliary sizing: control-transformer VA, coil burden, and
/// control-fuse selection (IEC 60947-4-1 Annex C / common practice).
/// Ported from PanelMaker `engine/control/sizeControlTransformer.ts` +
/// `standards/control/controlGear.ts`.
///
/// PURE Dart — zero Flutter imports.
library;

import 'dart:math' as math;

import '../../units.dart';

/// Standard single-phase control transformer ratings (VA).
///
/// // VERIFY (secondarySource): common control-transformer VA ladder.
const List<double> controlTransformerVa = [
  25,
  50,
  75,
  100,
  150,
  250,
  500,
  750,
  1000,
];

/// Margin applied to the computed VA demand before choosing a transformer.
///
/// // VERIFY (secondarySource): common control-circuit design margin.
const double controlTransformerMargin = 1.2;

/// Standard control-fuse / control-MCB ratings (A).
///
/// // VERIFY (secondarySource): common control-fuse ladder.
const List<double> controlFuseRatingsA = [0.5, 1, 1.6, 2, 4, 6, 10, 16];

/// Secondary-side control-circuit protection sizing factor on full-load current.
///
/// // VERIFY (secondarySource): common control-fuse sizing practice.
const double controlFuseSecondaryFactor = 2.0;

/// Typical small-device sealed burden (pilot lamp, timer, control relay), VA.
///
/// // VERIFY (secondarySource): typical pilot-device burden.
const double pilotDeviceSealedVa = 5;

/// Contactor coil burden (230 VAC coil) — steady-state ("sealed") and pickup
/// ("inrush"), in VA.
class CoilBurden {
  /// Steady-state (sealed) burden (VA).
  final double sealedVa;

  /// Peak inrush burden at pickup (VA).
  final double inrushVa;

  const CoilBurden({required this.sealedVa, required this.inrushVa});
}

/// Approximate coil burden by contactor AC-3 frame (230 VAC coil).
///
/// // VERIFY (secondarySource): typical AC contactor coil burdens.
CoilBurden coilBurdenForFrame(double ac3A) {
  if (ac3A <= 12) return const CoilBurden(sealedVa: 4, inrushVa: 20);
  if (ac3A <= 40) return const CoilBurden(sealedVa: 7, inrushVa: 40);
  if (ac3A <= 115) return const CoilBurden(sealedVa: 10, inrushVa: 65);
  return const CoilBurden(sealedVa: 16, inrushVa: 110);
}

double _round(double x, [int dp = 2]) {
  var f = 1.0;
  for (var i = 0; i < dp; i++) {
    f *= 10;
  }
  return (x * f).round() / f;
}

/// The result of sizing a control transformer.
class ControlTransformerSelection {
  /// Computed VA demand (combined sealed/inrush × margin).
  final ApparentPower requiredVa;

  /// Chosen standard rating (VA).
  final ApparentPower chosenVa;

  /// False when the demand exceeds the largest standard rating.
  final bool ok;

  const ControlTransformerSelection({
    required this.requiredVa,
    required this.chosenVa,
    required this.ok,
  });
}

/// Size a control transformer: combine steady-state and inrush demand
/// (`VA = √(ΣSealed² + ΣInrush²)`), apply margin, round up to a standard rating.
///
/// [pilotSealedVa] is extra steady-state burden (pilot lamps, timers, relays).
ControlTransformerSelection sizeControlTransformer(
  List<CoilBurden> burdens, {
  double pilotSealedVa = 0,
}) {
  final sumSealed =
      burdens.fold<double>(0, (s, b) => s + b.sealedVa) + pilotSealedVa;
  final sumInrush = burdens.fold<double>(0, (s, b) => s + b.inrushVa);
  final combined = math.sqrt(sumSealed * sumSealed + sumInrush * sumInrush);
  final required = combined * controlTransformerMargin;

  final chosen = controlTransformerVa.firstWhere(
    (va) => va >= required,
    orElse: () => controlTransformerVa.last,
  );

  return ControlTransformerSelection(
    requiredVa: ApparentPower(_round(required, 1)),
    chosenVa: ApparentPower(chosen),
    ok: chosen >= required,
  );
}

/// Standard control-fuse rating (A) covering [secondaryFlc] × factor.
///
/// Returns the smallest standard fuse ≥ `secondaryFlc × controlFuseSecondaryFactor`,
/// or the largest standard fuse when the demand exceeds the ladder.
Current selectControlFuse(Current secondaryFlc) {
  final required = secondaryFlc.amperes * controlFuseSecondaryFactor;
  final chosen = controlFuseRatingsA.firstWhere(
    (a) => a >= required,
    orElse: () => controlFuseRatingsA.last,
  );
  return Current(chosen);
}
