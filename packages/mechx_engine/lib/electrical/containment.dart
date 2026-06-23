/// Cable-containment sizing (A8c, post-processing pass): per-circuit conduit
/// fill and the per-panel cable-tray width.
///
/// Ported from PanelMaker `engine/containment.ts` + `standards/containment.ts`.
/// The cable outer diameter is estimated from the conductor CSA and core count
/// (a circular-layup approximation), then the smallest standard conduit whose
/// usable bore satisfies the single-cable fill rule is chosen. Per panel, the
/// outgoing cables are laid side-by-side in one tray layer to pick a standard
/// tray width.
///
/// This is a NEW pure function reading the already-computed
/// [ElectricalPanelResult]; it constructs only the result types in this file.
/// These are first-pass take-off / routing estimates — verify against
/// manufacturer cable diameters and the installation layout.
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

import 'panel_results.dart' show ElectricalPanelResult;

// ---------------------------------------------------------------------------
// Local standards constants (kept local to stay file-disjoint; folding into
// PuilProfile is a known follow-up). Tier: notAnSniClause engineering
// estimates / general installation practice unless noted.
// ---------------------------------------------------------------------------

/// A standard rigid-conduit trade size and its usable internal bore (mm).
class ConduitSize {
  /// Nominal trade size (mm).
  final double nominalMm;

  /// Usable internal diameter (mm).
  final double internalDiaMm;

  const ConduitSize({required this.nominalMm, required this.internalDiaMm});
}

/// Standard rigid conduit sizes (metric), ascending by bore.
// VERIFY (notAnSniClause): representative metric rigid-conduit bores; verify
// against the specified conduit manufacturer's data.
const List<ConduitSize> conduitSizes = [
  ConduitSize(nominalMm: 16, internalDiaMm: 12.5),
  ConduitSize(nominalMm: 20, internalDiaMm: 16.9),
  ConduitSize(nominalMm: 25, internalDiaMm: 21.4),
  ConduitSize(nominalMm: 32, internalDiaMm: 27.8),
  ConduitSize(nominalMm: 40, internalDiaMm: 35.4),
  ConduitSize(nominalMm: 50, internalDiaMm: 44.3),
  ConduitSize(nominalMm: 63, internalDiaMm: 56.5),
];

/// Single-cable conductor-fill limit (fraction of conduit bore).
// VERIFY (notAnSniClause): IEC 60364-5-52 / NEC Ch.9 Table 1 single-cable 53%.
const double conduitFillSingle = 0.53;

/// Standard cable-tray (ladder / perforated) widths (mm), ascending.
// VERIFY (notAnSniClause): representative tray widths; verify against the
// specified tray system.
const List<double> cableTrayWidthsMm = [50, 75, 100, 150, 200, 300, 450, 600];

/// Spacing allowance for cables laid side-by-side in a single tray layer
/// (1.0 = touching; > 1 leaves air gaps that help the grouping derating).
// VERIFY (notAnSniClause): engineering packing allowance.
const double trayPackingFactor = 1.1;

/// Circular cabling lay-up factors (overall-over-core diameter) for n cores.
// VERIFY (notAnSniClause): standard circular-layup multipliers (1..5 cores).
const Map<int, double> layupFactor = {
  1: 1.0,
  2: 2.0,
  3: 2.16,
  4: 2.42,
  5: 2.7,
};

/// Cross-sectional area of a circle of the given diameter (mm²).
double _circleAreaMm2(double diaMm) => (math.pi / 4) * diaMm * diaMm;

/// Internal cross-sectional area of a conduit (mm²).
double conduitInternalAreaMm2(ConduitSize c) =>
    (math.pi / 4) * c.internalDiaMm * c.internalDiaMm;

/// Round [v] to [dp] decimal places (positive-only inputs here).
double _round(double v, [int dp = 1]) {
  final f = math.pow(10, dp);
  return (v * f).round() / f;
}

// ---------------------------------------------------------------------------
// Result types (this file's own constructors).
// ---------------------------------------------------------------------------

/// Conduit sizing result for one cable.
class ConduitSpec {
  /// Estimated cable overall outer diameter (mm).
  final double cableOdMm;

  /// Selected nominal conduit trade size (mm).
  final double conduitSizeMm;

  /// Resulting conductor fill (% of bore). May exceed [conduitFillSingle]×100
  /// when the cable is larger than the widest standard conduit.
  final double fillPct;

  const ConduitSpec({
    required this.cableOdMm,
    required this.conduitSizeMm,
    required this.fillPct,
  });
}

/// Cable-tray sizing result for one panel's outgoing cables.
class CableTraySpec {
  /// Selected standard tray width (mm).
  final double widthMm;

  /// Resulting tray fill (% of width). May exceed 100 when the cables are
  /// wider than the widest standard tray.
  final double fillPct;

  /// Number of cables laid in the tray.
  final int cableCount;

  const CableTraySpec({
    required this.widthMm,
    required this.fillPct,
    required this.cableCount,
  });
}

/// One circuit's conduit entry inside a [ContainmentResult].
class CircuitConduit {
  final String circuitId;
  final String name;
  final ConduitSpec conduit;

  const CircuitConduit({
    required this.circuitId,
    required this.name,
    required this.conduit,
  });
}

/// Bundled per-panel containment: per-circuit conduit + the panel tray.
class ContainmentResult {
  final String panelId;

  /// Per-circuit conduit sizing (one per outgoing circuit cable).
  final List<CircuitConduit> conduits;

  /// Single-layer tray for the panel's outgoing cables.
  final CableTraySpec tray;

  /// Honesty surface: which constants are unverified engineering estimates.
  final List<String> verifyItems;

  const ContainmentResult({
    required this.panelId,
    required this.conduits,
    required this.tray,
    required this.verifyItems,
  });
}

// ---------------------------------------------------------------------------
// Sizing functions.
// ---------------------------------------------------------------------------

/// Estimated overall outer diameter (mm) of a PVC-insulated multi-core cable of
/// the given conductor CSA and core count. Conductor diameter from the CSA, a
/// CSA-scaled insulation thickness, the circular lay-up of the cores, and an
/// outer sheath.
///
///   conductor_d = 2·√(csa/π)
///   insulation  = 0.7 + 0.05·√csa
///   core_d      = conductor_d + 2·insulation
///   layup       = layupFactor[clamp(cores, 1..5)]
///   sheath      = 1.0 + 0.05·core_d
///   od          = core_d·layup + 2·sheath   (rounded to 1 dp)
double cableOuterDiameterMm(double csaMm2, int cores) {
  if (csaMm2 <= 0) return 0;
  final conductorDiaMm = 2 * math.sqrt(csaMm2 / math.pi);
  final insulationThkMm = 0.7 + 0.05 * math.sqrt(csaMm2);
  final coreDiaMm = conductorDiaMm + 2 * insulationThkMm;
  final n = cores.clamp(1, 5);
  final layup = layupFactor[n] ?? (math.sqrt(n) + 1);
  final sheathThkMm = 1.0 + 0.05 * coreDiaMm;
  return _round(coreDiaMm * layup + 2 * sheathThkMm, 1);
}

/// Smallest standard conduit (16..63 mm bore) housing a single cable of the
/// given CSA + core count at ≤ [conduitFillSingle] fill. When the cable exceeds
/// the largest standard conduit, the largest is returned with its (over-) fill
/// so the caller can flag it.
ConduitSpec sizeConduit(double csaMm2, int cores) {
  final cableOdMm = cableOuterDiameterMm(csaMm2, cores);
  final cableArea = _circleAreaMm2(cableOdMm);
  for (final c in conduitSizes) {
    final bore = conduitInternalAreaMm2(c);
    if (cableArea <= bore * conduitFillSingle) {
      return ConduitSpec(
        cableOdMm: _round(cableOdMm, 1),
        conduitSizeMm: c.nominalMm,
        fillPct: _round((cableArea / bore) * 100, 1),
      );
    }
  }
  final largest = conduitSizes.last;
  return ConduitSpec(
    cableOdMm: _round(cableOdMm, 1),
    conduitSizeMm: largest.nominalMm,
    fillPct: _round((cableArea / conduitInternalAreaMm2(largest)) * 100, 1),
  );
}

/// Smallest standard tray holding the panel's outgoing cables side-by-side in a
/// single layer (required width = Σ(cable OD) × [trayPackingFactor]). When the
/// cables exceed the widest standard tray, the widest is returned with its
/// (over-) fill.
///
/// Each circuit's cable OD comes from its sized CSA + protective-conductor core
/// count. Spare ways carry no cable (csa 0) and are excluded.
CableTraySpec sizeCableTray(ElectricalPanelResult panel) {
  final ods = <double>[];
  for (final c in panel.circuits) {
    final od = cableOuterDiameterMm(c.cable.csaMm2, c.grounding.cores);
    if (od > 0) ods.add(od);
  }
  final requiredWidth = ods.fold<double>(0, (s, d) => s + d) * trayPackingFactor;
  for (final w in cableTrayWidthsMm) {
    if (requiredWidth <= w) {
      return CableTraySpec(
        widthMm: w,
        fillPct: _round((requiredWidth / w) * 100, 1),
        cableCount: ods.length,
      );
    }
  }
  final widest = cableTrayWidthsMm.last;
  return CableTraySpec(
    widthMm: widest,
    fillPct: _round((requiredWidth / widest) * 100, 1),
    cableCount: ods.length,
  );
}

/// Containment take-off for a panel: a conduit per outgoing circuit cable plus
/// the single tray that carries them all.
ContainmentResult containmentFor(ElectricalPanelResult panel) {
  final conduits = <CircuitConduit>[];
  for (final c in panel.circuits) {
    // A spare way (no cable) gets no conduit entry.
    if (c.cable.csaMm2 <= 0) continue;
    conduits.add(CircuitConduit(
      circuitId: c.circuitId,
      name: c.name,
      conduit: sizeConduit(c.cable.csaMm2, c.grounding.cores),
    ));
  }
  return ContainmentResult(
    panelId: panel.panelId,
    conduits: conduits,
    tray: sizeCableTray(panel),
    verifyItems: const [
      'Conduit bores + 53% single-cable fill — verify vs the conduit datasheet '
          '(IEC 60364-5-52 / NEC Ch.9 Table 1).',
      'Cable outer diameters are estimated from CSA + cores — verify vs the '
          'cable manufacturer data.',
      'Cable-tray widths + 1.1 packing — verify vs the tray system and the '
          'grouping derating.',
    ],
  );
}
