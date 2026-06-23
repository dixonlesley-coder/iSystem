/// Arc-flash / incident-energy estimate (A8 advanced pass).
///
/// A SIMPLIFIED estimate of the thermal incident energy at a panel bus and the
/// resulting NFPA 70E PPE category + arc-flash boundary, using the Ralph Lee
/// maximum-power-transfer method as a conservative closed form. This is a
/// design-stage RISK SCREEN, NOT a full IEEE 1584-2018 study — it does not model
/// arc-current reduction, enclosure geometry, or device time-current curves.
///
/// FOREIGN STANDARDS — these are AMERICAN consensus standards (IEEE 1584 /
/// NFPA 70E), NOT SNI or PUIL. There is no Indonesian arc-flash standard; the
/// values are tagged `// VERIFY notAnSniClause` and surfaced in
/// [ArcFlashResult.verifyItems].
///
/// Lee method (distance in mm):
///   E[J/cm²]   = 2.142e6 · V[kV] · I_bf[kA] · t[s] / D[mm]²
///   E[cal/cm²] = E[J/cm²] / 4.184
/// The arc-flash boundary is the distance at which E falls to 1.2 cal/cm².
///
/// Ported from PanelMaker `engine/arcFlash.ts` + `standards/arcFlash.ts`.
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

import '../units.dart' show Current;

/// Joules per calorie (thermochemical).
const double joulesPerCalorie = 4.184;

/// Standard working distance for LV switchgear arc-flash assessment (mm).
/// IEEE 1584 LV switchgear default. // VERIFY notAnSniClause (American).
const double defaultWorkingDistanceMm = 455;

/// Typical electrode gap for LV switchgear (mm), per IEEE 1584. The Lee closed
/// form does not consume the gap; it is carried for reporting / future
/// IEEE 1584 refinement. // VERIFY notAnSniClause (American).
const double defaultGapMm = 18;

/// Incident energy at the arc-flash boundary, by definition (cal/cm²).
/// NFPA 70E. // VERIFY notAnSniClause (American).
const double arcFlashBoundaryIeCalCm2 = 1.2;

/// Incident energy above which the work cannot be performed energized (cal/cm²).
/// NFPA 70E category ceiling. // VERIFY notAnSniClause (American).
const double noSafePpeCalCm2 = 40;

/// NFPA 70E PPE category bands, ascending by incident-energy ceiling (cal/cm²).
/// // VERIFY notAnSniClause (American — NFPA 70E Table 130.5(G)).
enum PpeCategory {
  none, // < 1.2 cal/cm² — no arc-rated PPE required
  cat1, // ≤ 4
  cat2, // ≤ 8
  cat3, // ≤ 25
  cat4, // ≤ 40
  noSafePpe, // > 40 — de-energize
}

extension PpeCategoryInfo on PpeCategory {
  String get label => switch (this) {
        PpeCategory.none => 'No arc-rated PPE (<1.2 cal/cm2)',
        PpeCategory.cat1 => 'CAT 1 (<=4 cal/cm2)',
        PpeCategory.cat2 => 'CAT 2 (<=8 cal/cm2)',
        PpeCategory.cat3 => 'CAT 3 (<=25 cal/cm2)',
        PpeCategory.cat4 => 'CAT 4 (<=40 cal/cm2)',
        PpeCategory.noSafePpe => 'No safe PPE - de-energize',
      };
}

/// Map an incident energy (cal/cm²) to an NFPA 70E PPE category.
PpeCategory ppeCategoryFor(double incidentEnergyCalCm2) {
  if (incidentEnergyCalCm2 > noSafePpeCalCm2) return PpeCategory.noSafePpe;
  if (incidentEnergyCalCm2 <= arcFlashBoundaryIeCalCm2) return PpeCategory.none;
  if (incidentEnergyCalCm2 <= 4) return PpeCategory.cat1;
  if (incidentEnergyCalCm2 <= 8) return PpeCategory.cat2;
  if (incidentEnergyCalCm2 <= 25) return PpeCategory.cat3;
  return PpeCategory.cat4;
}

/// Result of an arc-flash incident-energy screen.
class ArcFlashResult {
  /// Estimated incident energy at the working distance (cal/cm²), 2 dp.
  final double incidentEnergyCalCm2;

  /// Working distance used (mm).
  final double workingDistanceMm;

  /// Arcing (clearing) time assumed (s).
  final double clearingTimeS;

  /// Electrode gap carried for reporting (mm).
  final double gapMm;

  /// Assigned NFPA 70E PPE category.
  final PpeCategory ppeCategory;

  /// Arc-flash boundary — distance where E falls to 1.2 cal/cm² (mm), 0 dp.
  final double arcFlashBoundaryMm;

  final String note;

  /// Honesty surface — the foreign / rule-of-thumb standards behind this screen.
  final List<String> verifyItems;

  const ArcFlashResult({
    required this.incidentEnergyCalCm2,
    required this.workingDistanceMm,
    required this.clearingTimeS,
    required this.gapMm,
    required this.ppeCategory,
    required this.arcFlashBoundaryMm,
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

/// Lee-method incident energy (cal/cm²) at distance [distanceMm] for the given
/// fault. Distance stays in MILLIMETRES — the 2.142e6 coefficient is defined for
/// D in mm.
double _leeIncidentEnergyCalCm2({
  required double voltageV,
  required double boltedFaultA,
  required double arcingTimeS,
  required double distanceMm,
}) {
  if (distanceMm <= 0) return double.infinity;
  final vKv = voltageV / 1000;
  final iKa = boltedFaultA / 1000;
  final eJ = (2.142e6 * vKv * iKa * arcingTimeS) / (distanceMm * distanceMm);
  return eJ / joulesPerCalorie;
}

/// Estimate the incident energy, PPE category and arc-flash boundary at a bus.
///
/// [faultkA] is the prospective bolted 3-phase fault current at the bus,
/// [clearingTimeS] the assumed protective-device clearing (arcing) duration,
/// [voltageV] the system line voltage at the bus (default 400 V LV).
///
/// Returns `null` when there is no meaningful fault to assess.
ArcFlashResult? estimateArcFlash({
  required Current faultkA,
  required double clearingTimeS,
  double voltageV = 400,
  double workingDistanceMm = defaultWorkingDistanceMm,
  double gapMm = defaultGapMm,
}) {
  final boltedFaultA = faultkA.amperes;
  if (boltedFaultA <= 0 || voltageV <= 0 || clearingTimeS <= 0) return null;

  final ie = _leeIncidentEnergyCalCm2(
    voltageV: voltageV,
    boltedFaultA: boltedFaultA,
    arcingTimeS: clearingTimeS,
    distanceMm: workingDistanceMm,
  );
  final incidentEnergy = _round(ie, 2);

  // E ∝ 1/D², so D_afb = D_work · sqrt(E_work / 1.2).
  final boundary = _round(
    workingDistanceMm *
        math.sqrt(incidentEnergy / arcFlashBoundaryIeCalCm2),
    0,
  );

  final category = ppeCategoryFor(incidentEnergy);

  var note =
      'Lee-method estimate at ${_num(workingDistanceMm)} mm, ${_num(clearingTimeS)} s '
      'clearing - ${category.label}. SIMPLIFIED screen, not a full IEEE 1584 study.';
  if (incidentEnergy > noSafePpeCalCm2) {
    note = 'Incident energy $incidentEnergy cal/cm2 exceeds '
        '${_num(noSafePpeCalCm2)} cal/cm2 - no listed PPE; de-energize or reduce '
        'clearing time (instantaneous setting / zone-selective interlocking / '
        'current-limiting device). $note';
  } else if (incidentEnergy > 8) {
    note = 'High incident energy - reduce clearing time (instantaneous / '
        'zone-selective interlocking) or a current-limiting device to lower the '
        'PPE category. $note';
  }

  return ArcFlashResult(
    incidentEnergyCalCm2: incidentEnergy,
    workingDistanceMm: workingDistanceMm,
    clearingTimeS: clearingTimeS,
    gapMm: gapMm,
    ppeCategory: category,
    arcFlashBoundaryMm: boundary,
    note: note,
    verifyItems: const [
      'Arc-flash uses AMERICAN consensus standards (Ralph Lee / IEEE 1584-2018 '
          'incident energy, NFPA 70E PPE categories) - NOT SNI or PUIL. This is '
          'a SIMPLIFIED design risk screen, not a full IEEE 1584 study; confirm '
          'with measured electrode geometry, enclosure size and device '
          'time-current curves.',
    ],
  );
}

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();
