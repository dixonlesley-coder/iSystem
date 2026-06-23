/// Electrical protection / fault study (A8a) — a PURE POST-PROCESSING pass.
///
/// Ported (core) from PanelMaker's `engine/fault.ts` + `standards/fault.ts`.
/// This function READS the already-computed [ElectricalSystemResult] (+ the
/// [ElectricalProject] + an [ElectricalStandardsProfile]) and returns a NEW
/// result type defined HERE — it constructs none of the A4 result records and
/// edits none of the A4 source files. The parent wires it into the system
/// compute + UI at combine time.
///
/// It computes, walking the feeder tree root→leaf:
///   - **Prospective short-circuit current (Isc, 3-phase symmetrical)** at each
///     panel bus, decaying from the origin fault level through each feeder
///     cable's series impedance Z = R + jX.
///   - **Breaker breaking-capacity adequacy** (Icu ≥ Isc) for each panel incomer
///     and each circuit breaker, against the prospective fault at its point.
///   - **Earth-fault loop impedance (Zs) + automatic-disconnection (ADS)** for
///     TN systems (TT relies on the RCD, already modelled, so it is relaxed).
///   - **Current-based selectivity / discrimination** between cascaded
///     upstream→downstream breaker pairs.
///
/// References: IEC 60909 (fault levels), IEC 60364-4-41 (ADS / Zs), IEC 60898 /
/// 60947-2 (device characteristics), IEC 60364-5-54 (PE adiabatic withstand).
///
/// PROVENANCE: the standards constants introduced here are local (a later
/// follow-up consolidates them into `PuilProfile`). Each carries a `// VERIFY`
/// note + a provenance tier; [FaultStudyResult.verifyItems] lists the
/// unverified-value labels so a report can surface them. Tiers used:
///   - `secondarySource` — real IEC/PUIL engineering figures pending the
///     official clause (X/R, U0, ADS factors, MCB curve trip multiples);
///   - `notAnSniClause` — deliberate general practice / non-Indonesian-standard
///     references (breaking-capacity ladders, selectivity rule of thumb, the PE
///     adiabatic-k table from IEC 60364-5-54 — American/IEC, not an SNI clause).
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

import '../standards/puil.dart'
    show BreakerClass, BreakerCurve, ConductorInsulation, ConductorMaterial,
        ElectricalStandardsProfile;
import '../units.dart';
import 'earthing.dart' show EarthingSystem;
import 'model.dart' show ElectricalCircuit, ElectricalPanel, ElectricalProject;
import 'panel_results.dart'
    show ElectricalCircuitResult, ElectricalPanelResult, ElectricalSystemResult,
        ElectricalWarning, WarningSeverity;

// ───────────────────────────────────────────────────────────────────────────
// Local standards constants (all // VERIFY — define here to stay file-disjoint
// from other agents; consolidating into PuilProfile is a known follow-up).
// ───────────────────────────────────────────────────────────────────────────

/// Assumed prospective fault level at the origin of a direct LV (PLN) supply
/// (kA, 3-phase symmetrical). A conservative urban-LV figure downstream of the
/// distribution transformer.
// VERIFY — secondarySource (IEC 60909 typical urban LV; not a PUIL clause).
const double defaultLvUtilityFaultKa = 16;

/// Nominal line-to-earth (phase) voltage U0 for the LV network (V).
// VERIFY — secondarySource (IEC harmonised 230 V; confirm against PUIL).
const double u0PhaseVoltageV = 230;

/// X/R ratio of the equivalent source impedance behind the LV bus
/// (transformer/utility-dominated, ~7 per IEC 60909). Splits the source |Z|
/// derived from Isc into R and X (magnitude — hence Isc — preserved; only the
/// R/X share that the earth-fault loop sees becomes physical).
// VERIFY — secondarySource (IEC 60909 typical LV value).
const double sourceXrRatio = 7;

/// Cmin-style voltage factor on U0 when deriving the maximum permissible
/// earth-fault loop impedance, allowing for voltage depression during the
/// fault (IEC 60364-4-41).
// VERIFY — secondarySource (IEC 60364-4-41).
const double zsVoltageFactor = 0.95;

/// Conductor R rises with temperature; for the worst-case ADS loop the loop R
/// is evaluated near the fault temperature (~×1.28 lifts the 70 °C R toward the
/// PVC fault limit), the unfavourable case for guaranteed disconnection.
// VERIFY — secondarySource (IEC 60364-4-41 / IEC 60909 temperature correction).
const double zsFaultTempFactor = 1.28;

/// Current-based selectivity (discrimination) rule of thumb: an upstream device
/// discriminates with a downstream one when its rating is ≥ 1.6× the downstream
/// rating. Full selectivity needs manufacturer let-through curves; first pass.
// VERIFY — notAnSniClause (engineering rule of thumb, not a standard clause).
const double selectivityRatio = 1.6;

/// Magnetic (instantaneous) trip multiple of In for each MCB curve (IEC 60898):
/// the current Ia = multiple·In that guarantees fast tripping. MCCB
/// instantaneous settings are typically ~10× and are treated as a 'C'.
// VERIFY — secondarySource (IEC 60898: B 5×, C 10×, D 20×).
const Map<BreakerCurve, double> curveTripMultiple = {
  BreakerCurve.b: 5,
  BreakerCurve.c: 10,
  BreakerCurve.d: 20,
};

/// Standard short-circuit breaking capacities (Icu, kA rms symmetrical) offered
/// per device class. MCBs: 6/10 kA per IEC 60898 + industrial IEC 60947-2
/// miniature 15/25 kA; MCCBs per IEC 60947-2 across common frames. Ascending.
// VERIFY — notAnSniClause (IEC 60898/60947-2 device ratings; verify Icu at
// 400 V on the datasheet).
const Map<BreakerClass, List<double>> breakingCapacityKa = {
  BreakerClass.mcb: [6, 10, 15, 25],
  BreakerClass.mccb: [16, 25, 36, 50, 70],
};

/// Adiabatic constant k for a protective (PE) conductor (A·s^½/mm²) by material
/// and insulation, PE as a core of the cable, per IEC 60364-5-54 Table 54.3:
/// Cu/PVC 115, Cu/XLPE 143, Al/PVC 76, Al/XLPE 94. (Carried for reporting; the
/// PE adiabatic check itself is an A8b refinement.)
// VERIFY — notAnSniClause (IEC 60364-5-54 Table 54.3; not an SNI clause).
const Map<ConductorMaterial, Map<ConductorInsulation, double>> peAdiabaticK = {
  ConductorMaterial.copper: {
    ConductorInsulation.pvc: 115,
    ConductorInsulation.xlpe: 143,
  },
  ConductorMaterial.aluminum: {
    ConductorInsulation.pvc: 76,
    ConductorInsulation.xlpe: 94,
  },
};

/// The unverified-value labels this study introduces, for a report's
/// "verify against the official PUIL / IEC text" section.
const List<String> faultStudyVerifyItems = [
  'default LV utility prospective fault level (16 kA)',
  'phase voltage U0 (230 V) for Zs / ADS limits',
  'source X/R ratio (7) for the earth-fault loop split',
  'ADS voltage factor (0.95) and fault-temperature factor (1.28)',
  'MCB curve trip multiples (B 5× / C 10× / D 20×)',
  'breaker breaking-capacity ladders (MCB 6–25 kA / MCCB 16–70 kA)',
  'selectivity discrimination ratio (1.6×)',
  'PE adiabatic-k table (IEC 60364-5-54 Table 54.3)',
];

// ───────────────────────────────────────────────────────────────────────────
// Impedance helpers.
// ───────────────────────────────────────────────────────────────────────────

/// A series cable / source impedance (Ω): R + jX.
class Impedance {
  final double rOhm;
  final double xOhm;
  const Impedance(this.rOhm, this.xOhm);

  /// Magnitude |Z| = √(R² + X²).
  double get magnitude => math.sqrt(rOhm * rOhm + xOhm * xOhm);

  /// Series sum.
  Impedance operator +(Impedance other) =>
      Impedance(rOhm + other.rOhm, xOhm + other.xOhm);
}

/// Phase-conductor impedance of a run: R from the profile's CSA table (per
/// material), X flat per-km from the profile reactance.
Impedance conductorImpedance(
  ElectricalStandardsProfile profile,
  double csaMm2,
  double lengthM,
  ConductorMaterial material,
) {
  if (csaMm2 <= 0 || lengthM <= 0) return const Impedance(0, 0);
  final km = lengthM / 1000.0;
  return Impedance(
    profile.conductorResistanceOhmPerKm(csaMm2, material: material) * km,
    profile.conductorReactanceOhmPerKm * km,
  );
}

/// Source per-phase impedance (Ω) backing a prospective fault Isc at a line
/// voltage: |Z| = V_LL / (√3·Isc), split into R/X by [sourceXrRatio] so the
/// magnitude (hence Isc) is preserved while the loop sees a physical source R.
Impedance sourceImpedanceFromIsc(double iscA, double lineVoltageV) {
  if (iscA <= 0 || lineVoltageV <= 0) return const Impedance(0, 0);
  final z = lineVoltageV / (math.sqrt(3) * iscA);
  final r = z / math.sqrt(1 + sourceXrRatio * sourceXrRatio);
  return Impedance(r, sourceXrRatio * r);
}

/// Prospective 3-phase symmetrical fault current (A) at a node given the total
/// per-phase source-to-node impedance: Isc = V_LL / (√3·|Z|), clamped to the
/// upstream value (cable impedance can only reduce the available fault).
double downstreamFaultA(double lineVoltageV, Impedance totalZ, double upstreamIscA) {
  final z = totalZ.magnitude;
  if (z <= 0) return upstreamIscA;
  final isc = lineVoltageV / (math.sqrt(3) * z);
  return math.min(isc, upstreamIscA);
}

/// Breaking capacity (kA) to specify for a device of [deviceClass] and [ratingA]:
/// the smallest standard rating that covers [prospectiveKa], else the class
/// maximum. Larger MCCB frames carry a rating-based floor.
double breakerKa(double ratingA, BreakerClass deviceClass, double prospectiveKa) {
  final options = breakingCapacityKa[deviceClass]!;
  final floorKa = deviceClass == BreakerClass.mccb && ratingA >= 400 ? 36.0 : 0.0;
  final pool = options.where((k) => k >= floorKa).toList();
  final candidates = pool.isNotEmpty ? pool : options;
  final maxKa = candidates.last;
  for (final k in candidates) {
    if (k >= prospectiveKa) return k;
  }
  return maxKa;
}

/// True when an upstream breaker likely does NOT discriminate with a downstream
/// one (its rating is below [selectivityRatio]× the downstream rating).
bool nonSelective(double upstreamInA, double downstreamInA) {
  if (downstreamInA <= 0) return false;
  return upstreamInA < selectivityRatio * downstreamInA;
}

// ───────────────────────────────────────────────────────────────────────────
// Result records (defined HERE — the A4 result types are not touched).
// ───────────────────────────────────────────────────────────────────────────

/// Per-panel fault result.
class PanelFaultResult {
  final String panelId;

  /// Prospective 3-phase symmetrical fault current at the panel bus (kA).
  final double prospectiveFaultkA;

  /// True when the panel incomer's breaking capacity (Icu) covers the fault.
  final bool incomerAdequate;

  /// Breaking capacity specified / available for the incomer (kA).
  final double incomerKa;

  const PanelFaultResult({
    required this.panelId,
    required this.prospectiveFaultkA,
    required this.incomerAdequate,
    required this.incomerKa,
  });
}

/// Per-circuit fault result (the prospective fault is that of the circuit's
/// panel bus — the cable to the load only reduces it further).
class CircuitFaultResult {
  final String circuitId;
  final String panelId;

  /// Prospective fault current at the circuit's origin / panel bus (kA).
  final double faultkA;

  /// True when the breaker's breaking capacity (Icu) covers the fault.
  final bool breakerAdequate;

  /// Breaking capacity specified / available for the breaker (kA).
  final double breakerKa;

  /// Earth-fault loop impedance Zs over the run (Ω) — TN only, else null.
  final double? zsOhm;

  /// Maximum Zs that still guarantees disconnection in time (Ω) — TN only.
  final double? zsMaxOhm;

  /// True when ADS disconnects in time (Zs ≤ Zs_max) — TN only, else null
  /// (TT clears earth faults via the RCD, already modelled).
  final bool? adsOk;

  const CircuitFaultResult({
    required this.circuitId,
    required this.panelId,
    required this.faultkA,
    required this.breakerAdequate,
    required this.breakerKa,
    this.zsOhm,
    this.zsMaxOhm,
    this.adsOk,
  });
}

/// One upstream→downstream breaker pair examined for current discrimination.
class SelectivityResult {
  final String upstreamCircuitId;
  final String downstreamPanelId;
  final double upstreamRatingA;
  final double downstreamRatingA;

  /// True when the pair likely does NOT discriminate (upstream < 1.6×downstream).
  final bool nonSelective;

  const SelectivityResult({
    required this.upstreamCircuitId,
    required this.downstreamPanelId,
    required this.upstreamRatingA,
    required this.downstreamRatingA,
    required this.nonSelective,
  });
}

/// The whole-project fault study.
class FaultStudyResult {
  /// Prospective fault level assumed at the supply origin (kA).
  final double originFaultkA;

  /// Per-panel results keyed by panel id.
  final Map<String, PanelFaultResult> panels;

  /// Per-circuit results keyed by circuit id.
  final Map<String, CircuitFaultResult> circuits;

  /// Upstream→downstream breaker discrimination pairs.
  final List<SelectivityResult> selectivity;

  /// Findings (inadequate breaking capacity, failed ADS, non-selective pairs).
  final List<ElectricalWarning> warnings;

  /// Unverified-value labels this study relies on.
  final List<String> verifyItems;

  const FaultStudyResult({
    required this.originFaultkA,
    required this.panels,
    required this.circuits,
    required this.selectivity,
    required this.warnings,
    required this.verifyItems,
  });
}

// ───────────────────────────────────────────────────────────────────────────
// The study.
// ───────────────────────────────────────────────────────────────────────────

double _round(double v, int dp) {
  final f = math.pow(10, dp).toDouble();
  return (v * f).roundToDouble() / f;
}

/// Compute the protection / fault study over an already-solved system.
///
/// [originFaultLevel] is the prospective 3-phase symmetrical fault current the
/// supply origin can deliver (default 16 kA — a conservative direct-LV PLN
/// figure when no transformer impedance is modelled). The fault decays down the
/// feeder tree through each feeder cable's series impedance.
FaultStudyResult faultStudy(
  ElectricalSystemResult sys,
  ElectricalProject project,
  ElectricalStandardsProfile profile, {
  Current originFaultLevel = const Current(16000),
}) {
  final warnings = <ElectricalWarning>[];
  final panelResults = <String, PanelFaultResult>{};
  final circuitResults = <String, CircuitFaultResult>{};
  final selectivity = <SelectivityResult>[];

  final originIscA = originFaultLevel.amperes > 0 ? originFaultLevel.amperes : 0.0;

  // Project model lookups (lengths, materials, feeder links live on the input).
  final modelById = {for (final p in project.panels) p.id: p};

  // child panel id -> the feeder circuit id that feeds it (parent way).
  final feederToPanel = <String, String>{}; // feeder circuit id -> child panel id
  final panelFeederCircuit = <String, String>{}; // child panel id -> feeder circuit id
  final panelParent = <String, String>{}; // child panel id -> parent panel id
  for (final p in project.panels) {
    for (final c in p.circuits) {
      if (c.feedsPanelId != null) {
        feederToPanel[c.id] = c.feedsPanelId!;
        panelFeederCircuit[c.feedsPanelId!] = c.id;
        panelParent[c.feedsPanelId!] = p.id;
      }
    }
  }

  // Per-panel prospective fault (A) + the source impedance backing it (for Zs),
  // filled root→leaf so a child reads its parent's value.
  final panelFaultA = <String, double>{};
  final panelSourceZ = <String, Impedance>{};

  // The earthing system is installation-wide (TN vs TT) — drives the ADS check.
  // TT clears earth faults via the RCD (already modelled), so its loop is relaxed.
  final isTn = sys.earthing.system == EarthingSystem.tnS ||
      sys.earthing.system == EarthingSystem.tnCs;

  // sys.order is root-first, so a single forward pass propagates the fault down.
  for (final panelId in sys.order) {
    final panelResult = sys.panels[panelId];
    final panelModel = modelById[panelId];
    if (panelResult == null || panelModel == null) continue;

    final lineVoltageV = panelModel.voltage.volts;

    // Prospective fault + source impedance at this bus.
    final double faultA;
    final Impedance sourceZ;
    final feederId = panelFeederCircuit[panelId];
    final parentId = panelParent[panelId];
    if (feederId == null || parentId == null) {
      // Root / utility-fed panel — origin fault level + its source impedance.
      faultA = originIscA;
      sourceZ = sourceImpedanceFromIsc(originIscA, lineVoltageV);
    } else {
      // Sub-panel — decay the parent fault through the feeder cable impedance.
      final upstreamIscA = panelFaultA[parentId] ?? originIscA;
      final upstreamSourceZ =
          panelSourceZ[parentId] ?? sourceImpedanceFromIsc(originIscA, lineVoltageV);
      final feederResult = _circuitById(sys.panels[parentId], feederId);
      final feederModel = _modelCircuitById(modelById[parentId], feederId);
      final csa = feederResult?.cable.csaMm2 ?? 0;
      final runs = (feederResult?.cable.runsPerPhase ?? 1) > 1
          ? feederResult!.cable.runsPerPhase!
          : 1;
      final lengthM = feederModel?.length.meters ?? 0;
      final single = conductorImpedance(profile, csa, lengthM, panelModel.material);
      final feederZ = Impedance(single.rOhm / runs, single.xOhm / runs);
      sourceZ = upstreamSourceZ + feederZ;
      faultA = downstreamFaultA(lineVoltageV, sourceZ, upstreamIscA);
    }
    panelFaultA[panelId] = faultA;
    panelSourceZ[panelId] = sourceZ;

    final faultKaRounded = _round(faultA / 1000.0, 2);

    // ── Incomer breaking-capacity adequacy ─────────────────────────────────
    final incomer = panelResult.incomer.breaker;
    final incomerKa = breakerKa(
      incomer.ratingA.amperes,
      incomer.deviceClass,
      faultA / 1000.0,
    );
    final incomerAdequate = incomerKa + 1e-9 >= faultA / 1000.0;
    panelResults[panelId] = PanelFaultResult(
      panelId: panelId,
      prospectiveFaultkA: faultKaRounded,
      incomerAdequate: incomerAdequate,
      incomerKa: incomerKa,
    );
    if (!incomerAdequate) {
      warnings.add(ElectricalWarning(
        code: 'breaking-capacity-inadequate',
        severity: WarningSeverity.error,
        message:
            '${panelResult.name}: incomer breaking capacity ${_fmt(incomerKa)} kA '
            'is below the prospective fault ${_fmt(faultKaRounded)} kA — specify a '
            'higher-Icu device or add a current-limiting upstream.',
        panelId: panelId,
      ));
    }

    // ── Per-circuit: kA adequacy + Zs/ADS (TN) ─────────────────────────────
    for (final c in panelResult.circuits) {
      final cModel = _modelCircuitById(panelModel, c.circuitId);
      final ka = breakerKa(
        c.breaker.ratingA.amperes,
        c.breaker.deviceClass,
        faultA / 1000.0,
      );
      final adequate = ka + 1e-9 >= faultA / 1000.0;
      if (!adequate) {
        warnings.add(ElectricalWarning(
          code: 'breaking-capacity-inadequate',
          severity: WarningSeverity.error,
          message:
              '${panelResult.name} / ${c.name}: breaker breaking capacity '
              '${_fmt(ka)} kA is below the prospective fault '
              '${_fmt(faultKaRounded)} kA.',
          panelId: panelId,
          circuitId: c.circuitId,
        ));
      }

      // Zs / ADS — TN only (TT clears earth faults via the RCD, already modelled).
      double? zsOhm;
      double? zsMaxOhm;
      bool? adsOk;
      if (isTn) {
        final runs = (c.cable.runsPerPhase ?? 1) > 1 ? c.cable.runsPerPhase! : 1;
        final lengthM = cModel?.length.meters ?? 0;
        final phaseZ0 =
            conductorImpedance(profile, c.cable.csaMm2, lengthM, panelModel.material);
        final peZ0 = conductorImpedance(
            profile, c.grounding.peCsaMm2, lengthM, panelModel.material);
        // Fault-temperature R, parallel runs each carry their own PE.
        final phaseZ = Impedance(
            phaseZ0.rOhm * zsFaultTempFactor / runs, phaseZ0.xOhm / runs);
        final peZ =
            Impedance(peZ0.rOhm * zsFaultTempFactor / runs, peZ0.xOhm / runs);
        final loop = sourceZ + phaseZ + peZ;
        final zs = loop.magnitude;
        final ia = (curveTripMultiple[c.breaker.curve] ?? 10) *
            c.breaker.ratingA.amperes;
        final zsMax = ia > 0 ? (zsVoltageFactor * u0PhaseVoltageV) / ia : double.infinity;
        zsOhm = _round(zs, 3);
        zsMaxOhm = zsMax.isFinite ? _round(zsMax, 3) : zsMax;
        adsOk = zs <= zsMax + 1e-9;
        if (!adsOk) {
          warnings.add(ElectricalWarning(
            code: 'ads-disconnection',
            severity: WarningSeverity.error,
            message:
                '${panelResult.name} / ${c.name}: earth-fault loop Zs '
                '${_fmt(zsOhm)} Ω exceeds the ${_fmt(zsMaxOhm)} Ω limit for '
                'disconnection in time — shorten the run, increase the CSA, or '
                'fit an RCD.',
            panelId: panelId,
            circuitId: c.circuitId,
          ));
        }
      }

      circuitResults[c.circuitId] = CircuitFaultResult(
        circuitId: c.circuitId,
        panelId: panelId,
        faultkA: faultKaRounded,
        breakerAdequate: adequate,
        breakerKa: ka,
        zsOhm: zsOhm,
        zsMaxOhm: zsMaxOhm,
        adsOk: adsOk,
      );
    }
  }

  // ── Selectivity: each feeder way vs the incomer of the panel it feeds ─────
  for (final entry in feederToPanel.entries) {
    final feederCircuitId = entry.key;
    final childPanelId = entry.value;
    final parentId = panelParent[childPanelId];
    final feeder = _circuitById(sys.panels[parentId], feederCircuitId);
    final child = sys.panels[childPanelId];
    if (feeder == null || child == null) continue;
    final upstreamIn = feeder.breaker.ratingA.amperes;
    final downstreamIn = child.incomer.breaker.ratingA.amperes;
    final ns = nonSelective(upstreamIn, downstreamIn);
    selectivity.add(SelectivityResult(
      upstreamCircuitId: feederCircuitId,
      downstreamPanelId: childPanelId,
      upstreamRatingA: upstreamIn,
      downstreamRatingA: downstreamIn,
      nonSelective: ns,
    ));
    if (ns) {
      warnings.add(ElectricalWarning(
        code: 'non-selective',
        severity: WarningSeverity.warning,
        message:
            '${feeder.name} (${_fmt(upstreamIn)} A) may not discriminate with '
            '${child.name} incomer (${_fmt(downstreamIn)} A): ratio < '
            '${_fmt(selectivityRatio)}× — verify against the manufacturer '
            'time-current / let-through curves.',
        panelId: parentId,
        circuitId: feederCircuitId,
      ));
    }
  }

  return FaultStudyResult(
    originFaultkA: _round(originIscA / 1000.0, 2),
    panels: panelResults,
    circuits: circuitResults,
    selectivity: selectivity,
    warnings: warnings,
    verifyItems: faultStudyVerifyItems,
  );
}

ElectricalCircuitResult? _circuitById(ElectricalPanelResult? panel, String id) {
  if (panel == null) return null;
  for (final c in panel.circuits) {
    if (c.circuitId == id) return c;
  }
  return null;
}

/// Look up the INPUT circuit (carries `length` / overrides not in the result).
ElectricalCircuit? _modelCircuitById(ElectricalPanel? panelModel, String id) {
  if (panelModel == null) return null;
  for (final c in panelModel.circuits) {
    if (c.id == id) return c;
  }
  return null;
}

String _fmt(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
