/// §7 Pressurized water-supply pipe-sizing module.
///
/// Selects the smallest standard nominal diameter whose mean velocity stays at
/// or below the supply-velocity limit, then computes Darcy–Weisbach friction
/// parameters for the chosen pipe.
///
/// This is strictly the *pressurized* code path (§12): it calls only the
/// Reynolds / Swamee-Jain / Darcy–Weisbach chain — the Manning drainage path
/// and the pump-energy path are separate concerns and are NOT used here.
///
/// Zero Flutter imports.
library;

import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

// ── Standard nominal diameters ─────────────────────────────────────────────

/// DN series (millimetres) covered by SNI plumbing design practice.
const List<double> standardPipeDiametersMm = <double>[
  15,
  20,
  25,
  32,
  40,
  50,
  65,
  80,
  100,
  125,
  150,
  200,
];

// ── Result ─────────────────────────────────────────────────────────────────

/// All quantities produced by [sizeForFlow] for one flow condition.
///
/// Every field is a typed SI quantity except [reynolds] and [frictionFactor],
/// which are dimensionless ratios.
class WaterSupplySizingResult {
  /// Selected inside diameter (smallest DN whose velocity satisfies the limit).
  final Diameter diameter;

  /// Mean velocity in the selected pipe (Q / A).
  final Velocity velocity;

  /// Reynolds number at the selected operating point (dimensionless).
  final double reynolds;

  /// Darcy friction factor via Swamee–Jain (dimensionless).
  final double frictionFactor;

  /// Darcy–Weisbach friction head loss per metre of pipe run (m/m).
  final Head headLossPerMetre;

  /// `true` when even the largest DN in the table cannot keep velocity within
  /// the limit (flow too large for the series): the returned [velocity] then
  /// EXCEEDS the limit and the caller must split the flow or extend the table.
  final bool overVelocity;

  const WaterSupplySizingResult({
    required this.diameter,
    required this.velocity,
    required this.reynolds,
    required this.frictionFactor,
    required this.headLossPerMetre,
    this.overVelocity = false,
  });
}

// ── Public API ─────────────────────────────────────────────────────────────

/// Select the smallest standard pipe diameter for [flow] and compute the
/// Darcy–Weisbach friction parameters.
///
/// Selection rule (§7 pressurized path):
///   1. Iterate [standardPipeDiametersMm] from smallest to largest.
///   2. Choose the first diameter whose mean velocity ≤ [maxVelocity].
///   3. If no diameter qualifies (flow is too large for the table), use the
///      largest diameter and accept the over-velocity condition.
///
/// [maxVelocity] defaults to [SniProfile.maxSupplyVelocity] (2.0 m/s).
/// [material] governs the pipe-wall roughness used for friction.
WaterSupplySizingResult sizeForFlow({
  required FlowRate flow,
  Velocity? maxVelocity,
  PipeMaterial material = PipeMaterial.pvc,
}) {
  const profile = SniProfile();
  final maxV = maxVelocity ?? profile.maxSupplyVelocity.value;
  assert(flow.cubicMetersPerSecond >= 0, 'flow must be non-negative');
  assert(maxV.metersPerSecond > 0, 'maxVelocity must be positive');

  // Diameter selection — pressurized path only. Velocity falls as D rises, so
  // the first DN that satisfies the limit is the smallest adequate size.
  Diameter chosen = Diameter.mm(standardPipeDiametersMm.last);
  var overVelocity = true;
  for (final nominalMm in standardPipeDiametersMm) {
    final candidate = Diameter.mm(nominalMm);
    final candidateVelocity = velocityFromFlow(flow, candidate);
    if (candidateVelocity.metersPerSecond <= maxV.metersPerSecond) {
      chosen = candidate;
      overVelocity = false;
      break;
    }
  }

  // Friction parameters for the chosen diameter.
  final v = velocityFromFlow(flow, chosen);
  final re = reynolds(v, chosen); // uses default ν = 1.004e-6 m²/s
  final relRoughness = profile.absoluteRoughness(material).meters / chosen.meters;
  final ff = frictionFactorSwameeJain(re, relRoughness);
  final hlPerMetre = headLossDarcy(
    frictionFactor: ff,
    length: const Length(1.0),
    diameter: chosen,
    velocity: v,
  );

  return WaterSupplySizingResult(
    diameter: chosen,
    velocity: v,
    reynolds: re,
    frictionFactor: ff,
    headLossPerMetre: hlPerMetre,
    overVelocity: overVelocity,
  );
}

/// Convert a total fixture-unit (UBAP) load to the SNI probable simultaneous
/// design flow via the flush-tank demand curve (SNI 8153:2015 Gambar 1).
///
/// This is a thin, named convenience wrapper over
/// [SniProfile.probableFlowForFixtureUnits] so sizing callers need not
/// construct the profile themselves.
FlowRate designFlowForFixtureUnits(double fixtureUnits) =>
    const SniProfile().probableFlowForFixtureUnits(fixtureUnits);
