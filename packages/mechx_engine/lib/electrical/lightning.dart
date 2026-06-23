/// IEC 62305-2 lightning risk screening (A8 advanced pass).
///
/// Ported from PanelMaker `engine/lightning.ts` + `standards/lightning.ts`.
/// Compares the expected number of dangerous direct strikes per year `Nd`
/// (from the structure's collection area and the local ground flash density)
/// against a tolerable frequency `Nc` to decide whether a Lightning Protection
/// System (LPS) is required and, if so, at what protection level (I–IV) via the
/// required efficiency E = 1 − Nc/Nd.
///
/// FOREIGN STANDARD — IEC 62305 is the international (not SNI-verbatim) lightning
/// standard; the screening method is the SIMPLIFIED frequency method, not a full
/// IEC 62305-2 risk study (R1…R4 with all loss components). Values are tagged
/// `// VERIFY` and surfaced in [LightningRisk.verifyItems].
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

/// National default ground flash density Ng (flashes/km²/year). Indonesia sits
/// in the equatorial maximum (very high keraunic level). // VERIFY
/// notAnSniClause (conservative default).
const double defaultGroundFlashDensity = 12;

/// Tolerable frequency of dangerous events Nc (events/year) for an ordinary
/// structure with risk of loss of human life. // VERIFY secondarySource
/// (IEC 62305-2).
const double tolerableEventsPerYear = 1e-3;

/// LPS protection levels in descending required efficiency.
enum LpsLevel { i, ii, iii, iv }

extension LpsLevelLabel on LpsLevel {
  String get label => switch (this) {
        LpsLevel.i => 'I',
        LpsLevel.ii => 'II',
        LpsLevel.iii => 'III',
        LpsLevel.iv => 'IV',
      };
}

/// Map the required protection efficiency E to an LPS level (IEC 62305-1 Table 6
/// efficiencies: I ≈ 0.98, II ≈ 0.95, III ≈ 0.90, IV ≈ 0.80). `null` when no LPS
/// is required (E ≤ 0). // VERIFY secondarySource.
LpsLevel? lpsLevelForEfficiency(double e) {
  if (e <= 0) return null;
  if (e > 0.95) return LpsLevel.i;
  if (e > 0.9) return LpsLevel.ii;
  if (e > 0.8) return LpsLevel.iii;
  return LpsLevel.iv;
}

/// The collection area Ad for an isolated rectangular structure L×W×H (IEC
/// 62305-2 §A.2): the footprint plus the area swept by a 1:3 rolling-sphere
/// skirt. Ad = L·W + 2·(3H)·(L+W) + π·(3H)² (m²).
double collectionArea(double lengthM, double widthM, double heightM) {
  final h3 = 3 * heightM;
  return lengthM * widthM + 2 * h3 * (lengthM + widthM) + math.pi * h3 * h3;
}

/// Result of a lightning risk screen.
class LightningRisk {
  /// Lightning collection area of the structure (m²).
  final double collectionAreaM2;

  /// Ground flash density used (flashes/km²/year).
  final double groundFlashDensity;

  /// Expected dangerous events per year (Nd).
  final double eventsPerYear;

  /// Tolerable events per year (Nc).
  final double tolerablePerYear;

  /// True when Nd > Nc — an LPS is recommended.
  final bool lpsRequired;

  /// Required protection efficiency E = 1 − Nc/Nd (0 when not required).
  final double efficiency;

  /// Recommended LPS protection level, or null when none is required.
  final LpsLevel? level;

  final String note;

  /// Honesty surface — the foreign standard behind this screen.
  final List<String> verifyItems;

  const LightningRisk({
    required this.collectionAreaM2,
    required this.groundFlashDensity,
    required this.eventsPerYear,
    required this.tolerablePerYear,
    required this.lpsRequired,
    required this.efficiency,
    required this.level,
    required this.note,
    required this.verifyItems,
  });
}

double _round(double v, int dp) {
  var f = 1.0;
  for (var i = 0; i < dp; i++) {
    f *= 10;
  }
  return (v * f).round() / f;
}

/// Screen the lightning risk for a structure of collection area [areaM2] under a
/// local ground flash density [groundFlashDensity] (flashes/km²/yr).
///
/// [locationFactor] Cd captures the structure's relative location (isolated ≈ 1,
/// surrounded by taller objects < 1); [tolerablePerYear] is Nc.
///
/// Use [collectionArea] to derive [areaM2] from the building L×W×H first.
LightningRisk assessLightning({
  required double groundFlashDensity,
  required double areaM2,
  double locationFactor = 1,
  double tolerablePerYear = tolerableEventsPerYear,
}) {
  final ng = groundFlashDensity;
  final cd = locationFactor;
  final ad = areaM2;
  // Nd = Ng · Ad · Cd · 1e-6 (Ad m² → km²).
  final nd = ng * ad * cd * 1e-6;
  final nc = tolerablePerYear;
  final lpsRequired = nd > nc;
  final efficiency = lpsRequired ? 1 - nc / nd : 0.0;
  final level = lpsLevelForEfficiency(efficiency);

  final note = lpsRequired
      ? 'Expected direct strikes Nd ~ ${_round(nd, 4)}/yr exceed the tolerable '
          '$nc/yr - an external LPS to protection level ${level?.label} '
          '(IEC 62305) is recommended, plus a coordinated Type 1 SPD at the '
          'service.'
      : 'Expected direct strikes Nd ~ ${_round(nd, 4)}/yr are within the '
          'tolerable $nc/yr - no external LPS is indicated by the screening; '
          'surge protection still applies.';

  return LightningRisk(
    collectionAreaM2: _round(ad, 0),
    groundFlashDensity: ng,
    eventsPerYear: _round(nd, 5),
    tolerablePerYear: nc,
    lpsRequired: lpsRequired,
    efficiency: _round(efficiency, 3),
    level: level,
    note: note,
    verifyItems: const [
      'Lightning risk uses the IEC 62305-2 SIMPLIFIED frequency method (Nd vs '
          'Nc) - the international standard, NOT SNI-verbatim, and not a full '
          'IEC 62305-2 risk study (R1...R4). Ground flash density and tolerable '
          'frequency are conservative defaults; confirm Ng for the site.',
    ],
  );
}
