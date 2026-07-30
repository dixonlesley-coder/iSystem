/// Tier-1 electrical sizing — pure functions ported from PanelMaker's
/// `engine/{loadCurrent,derating,voltageDrop,breakerSelect,cableSizing}.ts`.
/// Everything is framework-free and takes an [ElectricalStandardsProfile] so the
/// jurisdiction's data (PUIL) is swappable; the math here is universal.
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

import '../standards/puil.dart';
import '../units.dart';
import 'load_kind.dart';
import 'results.dart';

// ── helpers ─────────────────────────────────────────────────────────────────

/// Round to [dp] decimal places (default 2), matching PanelMaker `round`.
double roundTo(double x, [int dp = 2]) {
  final f = math.pow(10, dp).toDouble();
  return (x * f).round() / f;
}

/// Linear interpolation over a (double-keyed) lookup table, clamped at the ends.
/// Mirrors PanelMaker `interpolateTable`.
double interpolateTable(Map<double, double> table, double x) {
  if (table.isEmpty) return 1;
  final keys = table.keys.toList()..sort();
  final first = keys.first;
  final last = keys.last;
  if (x <= first) return table[first]!;
  if (x >= last) return table[last]!;
  for (var i = 0; i < keys.length - 1; i++) {
    final lo = keys[i];
    final hi = keys[i + 1];
    if (x >= lo && x <= hi) {
      final ylo = table[lo]!;
      final yhi = table[hi]!;
      final t = (x - lo) / (hi - lo);
      return ylo + t * (yhi - ylo);
    }
  }
  return table[last]!;
}

// ── load current ──────────────────────────────────────────────────────────

/// Design current Ib from real power.
///   single-phase: I = P / (V·cosφ)
///   three-phase:  I = P / (√3·V·cosφ)
Current loadCurrent({
  required Power power,
  required Voltage voltage,
  required double cosPhi,
  required bool threePhase,
}) {
  if (voltage.volts <= 0 || cosPhi <= 0) return const Current(0);
  final denom = threePhase
      ? math.sqrt(3) * voltage.volts * cosPhi
      : voltage.volts * cosPhi;
  return Current(power.watts / denom);
}

// ── derating ────────────────────────────────────────────────────────────────

/// Ambient air-temperature correction factor (interpolated), per insulation.
double ambientFactor(
  ElectricalStandardsProfile profile,
  double tempC, {
  ConductorInsulation insulation = ConductorInsulation.pvc,
}) =>
    interpolateTable(profile.ambientTempFactors(insulation), tempC);

/// Grouping (bunching) correction factor for [count] grouped circuits — a direct
/// lookup clamped at the table's last entry (NOT interpolated; matches PanelMaker).
double groupingFactor(ElectricalStandardsProfile profile, int count) {
  final table = profile.groupingFactors;
  final n = math.max(1, count);
  final keys = table.keys.toList()..sort();
  final last = keys.last;
  if (n >= last) return table[last]!;
  return table[n.toDouble()] ?? 1;
}

/// Soil thermal-resistivity correction — buried runs only.
double soilThermalFactor(
  ElectricalStandardsProfile profile,
  CableInstallMethod method,
  double? soilThermalResistivityKmW,
) {
  if (method != CableInstallMethod.buried || soilThermalResistivityKmW == null) {
    return 1;
  }
  return interpolateTable(
      profile.soilThermalResistivityFactors, soilThermalResistivityKmW);
}

/// Combined derating factor = temperature × grouping × soil (buried only).
/// Buried runs use the ground-temperature + depth factors; above-ground runs use
/// the air ambient factor. The install method is NOT a multiplier — it selects
/// the per-method ampacity table in [ElectricalStandardsProfile.ampacity].
double deratingFactor(
  ElectricalStandardsProfile profile, {
  required double ambientC,
  required int groupingCount,
  required CableInstallMethod method,
  ConductorInsulation insulation = ConductorInsulation.pvc,
  double? soilThermalResistivityKmW,
  double? groundTempC,
  double? depthM,
}) {
  final double tempFactor;
  if (method == CableInstallMethod.buried) {
    tempFactor =
        interpolateTable(profile.groundTempFactors(insulation), groundTempC ?? 20) *
            interpolateTable(profile.depthOfLayingFactors, depthM ?? 0.5);
  } else {
    tempFactor = ambientFactor(profile, ambientC, insulation: insulation);
  }
  return tempFactor *
      groupingFactor(profile, groupingCount) *
      soilThermalFactor(profile, method, soilThermalResistivityKmW);
}

// ── voltage drop ────────────────────────────────────────────────────────────

/// Voltage drop over a cable run.
///   single-phase: dV = 2·I·L·(R·cosφ + X·sinφ)
///   three-phase:  dV = √3·I·L·(R·cosφ + X·sinφ)
VoltageDropResult voltageDrop(
  ElectricalStandardsProfile profile, {
  required Current current,
  required Length length,
  required double csaMm2,
  required double cosPhi,
  required bool threePhase,
  required Voltage voltage,
  required bool isLighting,
  ConductorMaterial material = ConductorMaterial.copper,
}) {
  final rPerM =
      profile.conductorResistanceOhmPerKm(csaMm2, material: material) / 1000;
  final xPerM = profile.conductorReactanceOhmPerKm / 1000;
  final sinPhi = math.sqrt(math.max(0, 1 - cosPhi * cosPhi));
  final factor = threePhase ? math.sqrt(3) : 2.0;

  final dropV =
      factor * current.amperes * length.meters * (rPerM * cosPhi + xPerM * sinPhi);
  final dropPercent = voltage.volts > 0 ? (dropV / voltage.volts) * 100 : 0.0;
  final limitPercent = isLighting ? 3.0 : 5.0;

  return VoltageDropResult(
    dropV: roundTo(dropV, 2),
    dropPercent: roundTo(dropPercent, 2),
    limitPercent: limitPercent,
    withinLimit: dropPercent <= limitPercent + 1e-9,
  );
}

// ── breaker selection ─────────────────────────────────────────────────────

/// Smallest standard breaker rating that carries the design current (Ib ≤ In).
/// A positive [overrideA] is used verbatim (marked overridden); [maxRatingA]
/// caps the rating to the protected cable's ampacity.
///
/// [minRatingA] is an optional coordination FLOOR (A): the rating returned is the
/// first standard rung at or above `max(the design-current pick, minRatingA)`.
/// Its caller is the feeder-selectivity floor in `computeSystem` (an upstream
/// feeder must sit a rating band above the board it feeds); an explicit
/// [overrideA] ALWAYS wins outright and is never floored, and a floor above the
/// ladder top keeps the largest rung (the residual non-selectivity is then
/// reported honestly by the fault study rather than hidden by a throw).
/// Null (the default) ⇒ byte-identical selection.
// VERIFY — notAnSniClause: the floor's 1.6× basis is a coarse rating-ratio rule
// of thumb standing in for the manufacturer's selectivity tables (the same
// caveat as `fault.dart`'s selectivity ZONE model), NOT a PUIL clause.
BreakerResult selectBreaker(
  ElectricalStandardsProfile profile, {
  required Current designCurrent,
  required LoadKind loadKind,
  Current? maxRatingA,
  Current? overrideA,
  double? minRatingA,
}) {
  final curve = loadDefaults[loadKind]!.curve;

  if (overrideA != null && overrideA.amperes > 0) {
    return BreakerResult(
      ratingA: overrideA,
      deviceClass: profile.breakerClassFor(overrideA.amperes),
      curve: curve,
      overridden: true,
    );
  }

  final ratings = profile.standardBreakerRatingsA;
  double chosen = ratings.last;
  for (final r in ratings) {
    if (r >= designCurrent.amperes) {
      chosen = r;
      break;
    }
  }

  if (maxRatingA != null && chosen > maxRatingA.amperes) {
    for (final r in ratings.reversed) {
      if (r <= maxRatingA.amperes) {
        chosen = r;
        break;
      }
    }
  }

  // Coordination floor: lift to the first rung that also clears [minRatingA];
  // a floor beyond the ladder top clamps to the largest rung (never throws).
  if (minRatingA != null && chosen + 1e-9 < minRatingA) {
    chosen = ratings.last;
    for (final r in ratings) {
      if (r + 1e-9 >= minRatingA) {
        chosen = r;
        break;
      }
    }
  }

  return BreakerResult(
    ratingA: Current(chosen),
    deviceClass: profile.breakerClassFor(chosen),
    curve: curve,
  );
}

// ── cable sizing (the integrator) ─────────────────────────────────────────

/// Optional voltage-drop constraint: when supplied, [sizeCable] also upsizes the
/// conductor so the run's drop stays within its 3 %/5 % limit.
class CableVoltageDropConstraint {
  final Length length;
  final double cosPhi;
  final bool threePhase;
  final Voltage voltage;
  final bool isLighting;

  const CableVoltageDropConstraint({
    required this.length,
    required this.cosPhi,
    required this.threePhase,
    required this.voltage,
    required this.isLighting,
  });
}

/// Smallest standard section whose derated ampacity satisfies both Iz ≥ In and
/// Iz ≥ factor·Ib (PUIL 125 %), respecting the minimum section, optionally also
/// holding voltage drop within limit. Tries 1 then 2–4 parallel runs.
///
/// NOTE: this first slice uses the generic per-method ampacity
/// ([ElectricalStandardsProfile.ampacity]); the manufacturer per-family (NYY/
/// NYM/NYA) ampacity tables are a later refinement (they change the value, not
/// the algorithm). `// VERIFY` family tables before BOM order-codes rely on them.
CableResult sizeCable(
  ElectricalStandardsProfile profile, {
  required Current designCurrent,
  required Current breakerRating,
  required double deratingFactor,
  required double minSectionMm2,
  ConductorInsulation insulation = ConductorInsulation.pvc,
  ConductorMaterial material = ConductorMaterial.copper,
  CableInstallMethod method = CableInstallMethod.conduit,
  bool threePhase = false,
  CableVoltageDropConstraint? vd,
}) {
  double kha(double section) =>
      profile.ampacity(section, insulation: insulation, material: material, method: method).amperes;

  final minByMaterial = material == ConductorMaterial.aluminum
      ? math.max(minSectionMm2, profile.aluminiumMinSectionMm2)
      : minSectionMm2;
  final factor = profile.continuousLoadFactor.value;
  final izRequired = math.max(breakerRating.amperes, factor * designCurrent.amperes);
  final df = deratingFactor > 0 ? deratingFactor : 1.0;
  const parallelMaxRuns = 4;
  const parallelMinSection = 50.0;

  bool vdOk(double section, int runs) =>
      vd == null ||
      voltageDrop(
        profile,
        current: Current(designCurrent.amperes / runs),
        length: vd.length,
        csaMm2: section,
        cosPhi: vd.cosPhi,
        threePhase: vd.threePhase,
        voltage: vd.voltage,
        isLighting: vd.isLighting,
        material: material,
      ).withinLimit;

  final ampacityRuleBase =
      'Iz {iz}A >= max(In ${_fmt(breakerRating.amperes)}A, '
      '${_fmt(factor)}*Ib ${_fmt(roundTo(factor * designCurrent.amperes, 1))}A)';

  var anyAmpacityReached = false;
  for (var runs = 1; runs <= parallelMaxRuns; runs++) {
    final minSec =
        runs == 1 ? minByMaterial : math.max(minByMaterial, parallelMinSection);
    final izRequiredPerRun = izRequired / runs;
    double? ampacityMinSection;

    for (final section in profile.standardSectionsMm2) {
      if (section < minSec) continue;
      final deratedRun = kha(section) * df;
      if (deratedRun < izRequiredPerRun) continue;
      ampacityMinSection ??= section;
      anyAmpacityReached = true;
      if (!vdOk(section, runs)) continue;

      final vdDriven = section > ampacityMinSection;
      final totalIz = roundTo(deratedRun * runs, 1);
      final rule = ampacityRuleBase.replaceFirst('{iz}', _fmt(totalIz));
      return CableResult(
        csaMm2: section,
        baseKha: Current(kha(section)),
        deratedIz: Current(totalIz),
        deratingFactor: roundTo(df, 3),
        runsPerPhase: runs > 1 ? runs : null,
        vdDriven: vdDriven,
        appliedRule: (runs > 1 ? '$runs× parallel runs — ' : '') +
            (vdDriven
                ? '$rule; upsized to hold Vd <= ${vd!.isLighting ? 3 : 5}%'
                : rule),
      );
    }
  }

  // Neither constraint satisfied even at 4 parallel runs.
  final largest = profile.standardSectionsMm2.last;
  final ampacityImpossible = !anyAmpacityReached;
  return CableResult(
    csaMm2: largest,
    baseKha: Current(kha(largest)),
    deratedIz: Current(roundTo(kha(largest) * df * parallelMaxRuns, 1)),
    deratingFactor: roundTo(df, 3),
    runsPerPhase: parallelMaxRuns,
    vdDriven: !ampacityImpossible,
    // ampacity-impossible ⇒ even 4× the largest section never met Iz, so the
    // breaker In now exceeds Iz (coordination violated). The vd-only fallback
    // DID reach ampacity (it is over-limit only on voltage drop).
    ampacityReached: !ampacityImpossible,
    appliedRule: ampacityImpossible
        ? 'exceeds-range: $parallelMaxRuns× largest standard section still below required Iz'
        : 'voltage-drop-exceeds-range: largest standard section still over the Vd limit',
  );
}

/// Format a double without a trailing `.0` for whole numbers (rule text only).
String _fmt(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();
