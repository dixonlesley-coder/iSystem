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
import 'load_kind.dart' show LoadKind;
import 'model.dart'
    show
        SupplyKind,
        ElectricalCircuit,
        ElectricalPanel,
        ElectricalProject,
        ElectricalSystemInfo;
import 'panel_results.dart'
    show ElectricalCircuitResult, ElectricalPanelResult, ElectricalSystemResult,
        ElectricalWarning, WarningSeverity;
import 'results.dart' show kStarDeltaInternalWiringM;
import 'supply_design.dart'
    show
        declaredServiceTransformer,
        determineSupply,
        transformerImpedancePct;

// ───────────────────────────────────────────────────────────────────────────
// Local standards constants (all // VERIFY — define here to stay file-disjoint
// from other agents; consolidating into PuilProfile is a known follow-up).
// ───────────────────────────────────────────────────────────────────────────

/// Assumed prospective fault level at the origin of a direct LV (PLN) supply
/// (kA, 3-phase symmetrical). A conservative urban-LV figure downstream of the
/// distribution transformer.
// VERIFY — secondarySource (IEC 60909 typical urban LV; not a PUIL clause).
const double defaultLvUtilityFaultKa = 16;

/// Nominal LV line-to-line voltage (V) the service-size fault estimate
/// ([estimatedServiceFaultLevelA]) is referred to — the Indonesian 3-phase LV
/// nominal (the same 400 V the panels carry).
// VERIFY — secondarySource (SNI IEC 60038:2013 nominal 400 V; see puil.dart).
const double serviceFaultLineVoltageV = 400;

/// Representative per-unit short-circuit impedance (p.u. on its OWN rating) of
/// an MV/LV distribution transformer, used to estimate the LV-side prospective
/// fault when a customer transformer rating is declared but its nameplate Z% is
/// not modelled. 4–6 % covers the common 100…2000 kVA distribution range, so 5 %
/// is the representative middle; the REAL nameplate Z% governs.
///
/// Round 16 (supply-sources-undeclared-mv-fault-16ka) — ONE impedance for one
/// transformer: this is now the supply study's own
/// [transformerImpedancePct] (4 %), not a separate 5 %. The two used to
/// disagree, and the 5 % estimate under-stated the fault the study's own 4 %
/// unit delivers by 20 % — the unsafe direction for a breaking-capacity check
/// (the LOWER impedance is the conservative one there).
// VERIFY — secondarySource (representative distribution-transformer impedance;
// the transformer test certificate governs. Not a PUIL/SNI clause).
const double representativeTransformerZpu = transformerImpedancePct / 100;

/// Threshold (kA) above which the service-size fault estimate is flagged —
/// the top of the device ladder a specifier realistically lands on for an LV
/// board (see [breakingCapacityKa]). Above it the simplified estimate stops
/// being a sufficient basis and a real IEC 60909 study + 65/70 kA-class gear
/// are required.
///
/// Round 17 (protection-2-service-estimate-50ka-clamp-hides-fault) — this used
/// to CLAMP the estimate, i.e. LOWER a safety quantity: from ~1386 kVA at the
/// 4 % impedance (50e3·√3·400·0.04) every device kA token, the bus Icw check
/// and the arc-flash energy were judged against 50 kA while the transformer
/// delivers more (1600 kVA ⇒ 57.7 kA). The estimate is now returned UNCLAMPED
/// and `computeAdvancedStudy` raises `service-fault-estimate-high` instead.
// VERIFY — notAnSniClause (a modelling threshold, not a standard value).
const double maxEstimatedServiceFaultKa = 50;

/// Declared LV connection capacity ("daya tersambung", VA) at or below which a
/// service is a small / domestic one. 16 500 VA is the first PLN 3-phase daya
/// step above the single-phase ladder (see `supply_design.dart` `plnDayaVa3ph`),
/// so it separates house / shop boards from real commercial services.
// VERIFY — notAnSniClause (a banding choice over the published PLN daya steps).
const double smallServiceCapacityCeilingVa = 16500;

/// Prospective fault (kA) assumed at a small / domestic service entrance. Matches
/// the 4.5 / 6 kA breaking capacity domestic MCBs are actually built to (IEC
/// 60898) — the service main fuse plus the long PLN service drop keep the fault
/// well below the substation figure.
// VERIFY — notAnSniClause (general LV distribution practice, not a PUIL clause).
const double smallServiceFaultKa = 6;

/// Top of the PLN low-voltage (TR) connected-power ladder (VA) — above this a
/// building is served at MV through its own transformer (see `supply_design.dart`
/// `plnDayaVa3ph` / `lvSupplyLimitKva`).
// VERIFY — secondarySource (PLN TR tariff ceiling; confirm the current schedule).
const double plnLvServiceCeilingVa = 197000;

/// Prospective fault (kA) assumed at a larger LV (direct TR) service entrance,
/// up to [plnLvServiceCeilingVa]. A commercial LV service sits closer to the
/// distribution substation than a house, but still below the transformer-terminal
/// figure, so 10 kA (the next IEC 60898 breaking-capacity rung) is the
/// conservative working value.
// VERIFY — notAnSniClause (general LV distribution practice, not a PUIL clause).
const double lvServiceFaultKa = 10;

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
/// is evaluated near the conductor fault-limit temperature (the unfavourable
/// case for guaranteed disconnection), lifting the 70 °C tabulated R toward the
/// 160 °C PVC final short-circuit limit (IEC 60364-4-43 Table 43A).
///
/// Derivation (copper resistance-temperature ratio, β = 235 °C):
///   R(160)/R(70) = (235 + 160) / (235 + 70) = 395 / 305 = 1.295.
/// Rounded down to 1.28 as a slightly less conservative working value (the PE
/// reaches the limit later than the phase). Base 70 °C → target ~160 °C PVC.
// VERIFY — secondarySource (IEC 60364-4-41 / IEC 60364-4-43 temperature
// correction; the 1.28 vs derived 1.295 rounding is an engineering choice).
const double zsFaultTempFactor = 1.28;

/// Resistance-temperature constant (°C) of a conductor material — the
/// inferred zero-resistance temperature of the linear R(T) law
/// R(T2)/R(T1) = (β + T2)/(β + T1): copper 234.5 °C, aluminium 228 °C
/// (IEC 60287-1-1 / IEC 60228 α20 reciprocals).
// VERIFY — secondarySource (IEC 60228 / IEC 60287 conductor constants).
double conductorBetaC(ConductorMaterial material) =>
    material == ConductorMaterial.aluminum ? 228.0 : 234.5;

/// Factor scaling the profile's ~70 °C OPERATING conductor R (the
/// `conductorResistanceOhmPerKm` table) down to 20 °C, the conductor
/// temperature IEC 60909-0 prescribes for the MAXIMUM short-circuit current
/// (the Icu / breaking-capacity basis). Copper: (234.5 + 20)/(234.5 + 70) =
/// 254.5/304.5 = 0.83580; aluminium: 248/298 = 0.83221.
///
/// Round 17 (protection-2-max-fault-uses-70C-resistance) — the "cold"
/// prospective-fault decay used to run on the 70 °C table, i.e. a ~20 % HIGH
/// feeder R, understating every sub-board fault (a 20 m 16 mm² feeder off a
/// 10 kA origin printed 5.86 kA and specified 6 kA MCBs for a 6.42 kA bus).
/// The ADS earth-fault loop keeps the 70 °C table × [zsFaultTempFactor].
// VERIFY — secondarySource (IEC 60909-0 §2.4 cmax / 20 °C conductor basis).
double coldConductorResistanceFactor(ConductorMaterial material) {
  final beta = conductorBetaC(material);
  return (beta + 20) / (beta + 70);
}

/// [z70] (a 70 °C-table impedance) re-referred to 20 °C for the MAXIMUM fault:
/// R scaled by [coldConductorResistanceFactor], X unchanged.
Impedance coldMaxFaultImpedance(Impedance z70, ConductorMaterial material) =>
    Impedance(z70.rOhm * coldConductorResistanceFactor(material), z70.xOhm);

/// Current-based selectivity (discrimination) rule of thumb: an upstream device
/// discriminates with a downstream one when its rating is ≥ 1.6× the downstream
/// rating. Full selectivity needs manufacturer let-through curves; first pass.
// VERIFY — notAnSniClause (engineering rule of thumb, not a standard clause).
const double selectivityRatio = 1.6;

/// Above this upstream/downstream rating ratio TOTAL selectivity (both the
/// overload AND the short-circuit zone discriminate) is taken as likely — the
/// time-current bands separate enough that the downstream device always clears
/// first. A coarse stand-in for reading the manufacturer's selectivity tables.
// VERIFY — notAnSniClause (engineering rule of thumb, not a standard clause).
const double totalSelectivityRatio = 2.5;

/// A representative motor full-load current contributes a brief sub-transient
/// fault infeed of ~this multiple of its FLA (a locked-rotor / sub-transient
/// pulse, ~6× FLA, decaying over the first cycles). Folded into the prospective
/// fault as a conservative uplift; a soft-starter / VFD front-end limits this in
/// practice, so it is an UPPER-bound estimate, not a manufacturer figure.
// VERIFY — secondarySource (IEC 60909 motor contribution ~ locked-rotor ratio).
const double motorFaultContributionMultiple = 6;

/// The sub-transient motor-fault pulse persists for roughly this long before the
/// asynchronous-machine contribution decays away (the first few cycles at 50 Hz).
/// Reported as the [SelectivityResult] estimated clearing-time context.
// VERIFY — secondarySource (IEC 60909 sub-transient decay ~100 ms).
const double motorFaultPulseMs = 100;

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
  // Round 42 (electrical-sim-7-mccb-icu-ladder-tops-at-70ka) — the IEC
  // 60947-2 high-performance frames (L / V, 100 / 150 kA) exist: a 2000 kVA
  // LVMDP (~72 kA) must have an achievable outgoing MCCB. // VERIFY
  // (notAnSniClause).
  BreakerClass.mccb: [16, 25, 36, 50, 70, 100, 150],
  // Round 23 — ACB frames (IEC 60947-2 Icu, general practice, // VERIFY).
  BreakerClass.acb: [50, 65, 80, 100],
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
///
/// Round 29 (electrical-sim-3-motor-fault-contribution-claimed-not-applied) —
/// the motor-infeed line ([faultStudyMotorVerifyItem]) is NOT in this base
/// list: [faultStudy] appends it only when a motor contribution was actually
/// folded in (> 0). Every report used to assert a basis the study never used
/// (the default contribution is 0).
/// Round 30 — the U0 basis line (a report that also prints the PUIL profile's
/// own U0 entry prints it once).
const String faultStudyU0VerifyItem =
    'phase voltage U0 (230 V) for Zs / ADS limits';

const List<String> faultStudyVerifyItems = [
  'default LV utility prospective fault level (16 kA)',
  faultStudyU0VerifyItem,
  'source X/R ratio (7) for the earth-fault loop split',
  'ADS voltage factor (0.95) and fault-temperature factor (1.28)',
  'MCB curve trip multiples (B 5× / C 10× / D 20×)',
  'breaker breaking-capacity ladders (MCB 6–25 kA / MCCB 16–150 kA)',
  'selectivity discrimination ratios (partial 1.6× / total 2.5×) — a simplified '
      'time-current zone model, not manufacturer let-through / selectivity tables',
  'Ics vs Icu service/ultimate breaking-capacity check (IEC 60947-2)',
  'PE adiabatic-k table (IEC 60364-5-54 Table 54.3)',
];

/// Round 29 — the motor-infeed provenance line, emitted by [faultStudy] only
/// when [faultStudy]'s `estimatedMotorFaultContributionA` is > 0.
const String faultStudyMotorVerifyItem =
    'estimated motor fault contribution (~6× FLA sub-transient pulse, ~100 ms) '
    'folded into the prospective fault level';

// ───────────────────────────────────────────────────────────────────────────
// Service-size-derived prospective fault level.
// ───────────────────────────────────────────────────────────────────────────

/// The unverified-value labels [estimatedServiceFaultLevelA] relies on, ready
/// for a report / honesty surface to pick up. Deliberately NOT appended to
/// [faultStudyVerifyItems] this pass (that would change every existing study's
/// printed verify section) — surfacing it via `SniProfile.verifyChecklist` /
/// `AdvancedStudy.verifyItems` is the RECORDED FOLLOW-UP.
/// Round 39 — representative alternator sub-transient reactance Xd'' (p.u.)
/// for the generator-plant fault estimate. // VERIFY — secondarySource
/// (typical LV alternator 0.10–0.15 p.u.; the alternator datasheet governs).
const double kAlternatorXdPu = 0.12;

/// Round 39 — an inverter's fault contribution as a multiple of its rated
/// current (current-limited, ~1.2–1.5 × In). // VERIFY — secondarySource
/// (the inverter datasheet governs).
const double inverterFaultMultiple = 1.5;

/// Round 39 — the prospective 3φ fault (A) at the terminals of an on-site
/// primary source of [sVa] VA: a generator S/(√3·400·Xd''), a solar
/// inverter [inverterFaultMultiple] × S/(√3·400). Pure.
double onSiteSourceFaultA(SupplyKind kind, double sVa) {
  final ratedA = sVa / (math.sqrt(3) * serviceFaultLineVoltageV);
  return switch (kind) {
    SupplyKind.generator => ratedA / kAlternatorXdPu,
    SupplyKind.solar => ratedA * inverterFaultMultiple,
    SupplyKind.pln => ratedA / representativeTransformerZpu,
  };
}

final List<String> serviceFaultEstimateVerifyItems = [
  'representative transformer impedance '
      '(${transformerImpedancePct.toStringAsFixed(0)} % p.u.) behind the service-size '
      'fault estimate — the nameplate Z% governs',
  // ASCII in the printed label: a report PDF encodes WinAnsi, which has no
  // '≤' / '⇒' (they would garble to '?' — the Wave-7 separator defect).
  'service-entrance prospective-fault rungs by declared connection capacity '
      '(up to 16.5 kVA: 6 kA / up to 197 kVA: 10 kA / above: the declared '
      'capacity\'s own transformer fault at the representative Z%, at least '
      '16 kA)',
  'service-size fault estimate review threshold (50 kA) and its 400 V LV '
      'reference voltage',
  'generator / solar primary-supply fault estimate: alternator Xd\'\' '
      '${kAlternatorXdPu.toStringAsFixed(2)} p.u. / inverter '
      '${inverterFaultMultiple.toStringAsFixed(1)} x rated current — the '
      'source datasheet governs',
];

/// Estimate the prospective 3-phase symmetrical fault current at the SERVICE
/// ENTRANCE from the declared service SIZE, so a domestic board is no longer
/// specified against the same flat [defaultLvUtilityFaultKa] as a 1000 kVA
/// substation (a small house board printing a 25 kA device token is the defect
/// this closes). Pure — reads [project] only, no side effects.
///
/// Resolution order:
///
/// 1. **[ElectricalProject.transformerKva] declared** — a customer MV/LV
///    transformer feeds the installation, so the LV-side fault is dominated by
///    the transformer's own impedance. The standard simplified estimate is
///
///        Isc = S / (√3·U_LL·Zpu)
///
///    with S the transformer rating (VA), U_LL = [serviceFaultLineVoltageV] and
///    Zpu = [representativeTransformerZpu]. Worked example, a 630 kVA unit at
///    4 %: 630000 / (1.732050808·400·0.04) = 630000 / 27.712813 = 22733.2 A.
///    The utility impedance UPSTREAM of the transformer and the substation-to-
///    board cable are deliberately ignored — both only REDUCE the fault, so the
///    estimate stays conservative. NOT clamped (Round 17): above
///    [maxEstimatedServiceFaultKa] the caller flags the estimate instead.
///
/// 2. **[ElectricalProject.supplyCapacityVa] declared** (an LV direct service —
///    daya tersambung, no customer transformer): a conservative service-entrance
///    RUNG off the declared capacity, monotone non-decreasing —
///    ≤ [smallServiceCapacityCeilingVa] ⇒ [smallServiceFaultKa];
///    ≤ [plnLvServiceCeilingVa] ⇒ [lvServiceFaultKa];
///    above the PLN TR ceiling the service is fed at MV through its own
///    transformer (Round 25): the fault is that transformer's, rated at the
///    declared capacity (or the [demand], whichever is larger, through the
///    supply study's own pick — step 3) by the same formula as step 1, and
///    NEVER below [defaultLvUtilityFaultKa]. Declaring a 630 kVA service gives
///    630000 / (1.732050808·400·0.04) = 22733.2 A — more information never
///    LOWERS the safety quantity below the undeclared estimate.
///
/// 3. **Nothing declared, but the [demand] needs an MV service** (Round 16,
///    supply-sources-undeclared-mv-fault-16ka) — when the caller passes the
///    solved building demand and [determineSupply] selects a transformer for
///    it (above the LV ceiling, or a [ElectricalProject.dualTransformer]
///    service), the fault is that unit's, by the same formula: one SECTION's
///    units (a dual service's coupler is normally open), e.g. an 800 kVA
///    demand ⇒ 1000 kVA at 4 %: 1e6 / (1.732050808·400·0.04) = 36084.4 A —
///    not the flat 16 kA, which specified every device kA token at under half
///    the fault the study's own transformer delivers.
///
/// 4. **Nothing declared, LV demand** ⇒ `null`.
///
/// A declared value that is zero or negative is treated as undeclared (it falls
/// through to the next step). The returned current is rounded to 0.1 A.
///
/// CALLER CONTRACT: `null` means "no better claim than the existing default" —
/// the caller MUST keep its existing flat [defaultLvUtilityFaultKa] (16 kA), so
/// an untouched project stays byte-identical. An explicit
/// [ElectricalProject.originFaultLevelA] always WINS: the caller checks it first
/// and only falls back to this estimate when it is null.
///
/// PROVENANCE: every figure is `// VERIFY` (see the constants above) —
/// secondary-source distribution practice, none of it an SNI/PUIL clause. The
/// debt is carried in [serviceFaultEstimateVerifyItems] pending the follow-up
/// that wires it into the honesty surfaces.
Current? estimatedServiceFaultLevelA(ElectricalProject project,
    {ApparentPower? demand}) {
  // 1. Customer transformer declared ⇒ transformer-impedance-limited fault.
  final txVa = project.transformerKva?.voltAmperes;
  if (txVa != null && txVa > 0) {
    final iscA = txVa /
        (math.sqrt(3) *
            serviceFaultLineVoltageV *
            representativeTransformerZpu);
    return Current(_round(iscA, 1));
  }

  // Round 39 (elec-ui-journeys-2-generator-supply-drawn-as-mv) — a GENERATOR
  // or SOLAR (inverter) primary supply is never a utility: its fault is the
  // source's own — the alternator's S/(√3·U·Xd'') or the inverter's
  // [inverterFaultMultiple] × rated current — sized on the declared capacity,
  // else the demand. Never the 16 kA utility default (that overstated the
  // earth-fault current >5x and could PASS ADS that will not disconnect).
  if (project.supplyKind != SupplyKind.pln) {
    final cap = project.supplyCapacityVa?.voltAmperes;
    final sVa = (cap != null && cap > 0) ? cap : demand?.voltAmperes;
    if (sVa == null || sVa <= 0) return null;
    return Current(_round(onSiteSourceFaultA(project.supplyKind, sVa), 1));
  }

  // 2. LV direct service ⇒ a rung off the declared connection capacity.
  final capacityVa = project.supplyCapacityVa?.voltAmperes;
  if (capacityVa != null && capacityVa > 0) {
    if (capacityVa <= smallServiceCapacityCeilingVa) {
      return Current.kiloamperes(smallServiceFaultKa);
    }
    if (capacityVa <= plnLvServiceCeilingVa) {
      return Current.kiloamperes(lvServiceFaultKa);
    }
    // Round 25 — above the PLN TR ceiling: the declared capacity's own
    // transformer fault, never below the study transformer for the demand
    // (step 3) nor the flat 16 kA the rung used to return.
    // Round 29 — that transformer is the SNAPPED unit the supply study,
    // drawings and power one-line all print
    // ([declaredServiceTransformerKva]: a 555 kVA daya ⇒ 630 kVA), never
    // the raw daya figure (no 555 kVA unit exists).
    // Round 30 — per-unit rating × the units one section parallels (a dual
    // service's coupler is N.O. ⇒ one section's units only).
    final declaredTx = declaredServiceTransformer(project);
    final txKva = declaredTx == null
        ? capacityVa
        : declaredTx.kva.voltAmperes *
            math.max(1,
                project.dualTransformer ? declaredTx.units ~/ 2 : declaredTx.units);
    final declaredA = txKva /
        (math.sqrt(3) *
            serviceFaultLineVoltageV *
            representativeTransformerZpu);
    final studyA = demand == null ? null : _studyTransformerFaultA(project, demand);
    return Current(_round(
        math.max(math.max(declaredA, studyA ?? 0),
            defaultLvUtilityFaultKa * 1000),
        1));
  }

  // 3. Nothing declared, but the demand needs a transformer ⇒ the unit the
  //    supply study itself selects (one section's units: coupler N.O.).
  if (demand != null) {
    final studyA = _studyTransformerFaultA(project, demand);
    if (studyA != null) return Current(_round(studyA, 1));
  }

  // 4. Nothing declared, LV demand (dualTransformer alone has no rating) ⇒
  //    no claim; the caller keeps its flat default.
  return null;
}

/// The fault (A, unrounded) of the transformer the supply study selects for
/// [demand] (one section's units — a dual service's coupler is N.O.), or null
/// when the demand needs no MV service.
double? _studyTransformerFaultA(ElectricalProject project, ApparentPower demand) {
  if (demand.voltAmperes <= 0) return null;
  final supply =
      determineSupply(demand, dualTransformer: project.dualTransformer);
  final kva = supply.transformerKva;
  if (!supply.isMv || kva == null || kva <= 0) return null;
  final perSection = project.dualTransformer ? supply.units ~/ 2 : supply.units;
  final va = kva * 1000 * math.max(1, perSection);
  return va /
      (math.sqrt(3) *
          serviceFaultLineVoltageV *
          (supply.impedancePct ?? transformerImpedancePct) /
          100);
}

/// Round 25 — true when the project DECLARES its service size (a customer
/// transformer or a connection capacity), so a resolved estimate's basis is
/// the declared service rather than the supply study.
bool hasDeclaredServiceSize(ElectricalProject project) =>
    (project.transformerKva?.voltAmperes ?? 0) > 0 ||
    (project.supplyCapacityVa?.voltAmperes ?? 0) > 0;

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

/// Line-to-line basis voltage (V) a panel's SOURCE impedance is referred to.
///
/// A 3-phase board carries its line voltage in [ElectricalPanel.voltage]
/// (400 V). A 1-phase board stores its PHASE-to-neutral voltage there (220 V,
/// see `model.dart`), but it still hangs off the same 3-phase LV network whose
/// origin fault is a 3-phase symmetrical figure — so its source impedance must
/// be derived on the network's line basis ([serviceFaultLineVoltageV], 400 V),
/// never on 220 V (that would give |Z| = 220/(√3·Isc), ~0.55× the real source
/// impedance — an optimistic Zs and a fault mis-referred to the wrong voltage).
double faultBasisLineVoltageV(ElectricalPanel panel) =>
    panel.system.isThreePhase ? panel.voltage.volts : serviceFaultLineVoltageV;

/// Prospective fault (A) at a SUB-panel bus fed through a feeder chain.
///
/// - **3-phase board**: the 3-phase symmetrical fault
///   `V_LL / (√3·|Z_phase|)` ([downstreamFaultA]) — the neutral carries no
///   current in a balanced 3-phase fault.
/// - **1-phase board**: the only fault it can see is LINE-to-NEUTRAL, driven by
///   U0 (the board's stored phase voltage) round the loop source + every
///   feeder's phase leg + every feeder's neutral return:
///   `U0 / |Z_phase + Z_neutral|`. (Feeding `220 V` into the 3-phase formula
///   instead gave `127/|Z|` — ~40 % below the true L-N fault, which let an
///   under-rated MCB pass the Icu check.)
///
/// Both are clamped to the upstream value (impedance only reduces the fault).
/// [phasePathZ] = source Z + Σ feeder phase legs; [neutralPathZ] = Σ feeder
/// neutral legs (the source neutral is not modelled — omitting it keeps the
/// fault conservatively HIGH for the Icu check).
double subPanelBusFaultA(
  ElectricalPanel panel,
  Impedance phasePathZ,
  Impedance neutralPathZ,
  double upstreamIscA,
) {
  if (panel.system.isThreePhase) {
    return downstreamFaultA(panel.voltage.volts, phasePathZ, upstreamIscA);
  }
  final z = (phasePathZ + neutralPathZ).magnitude;
  if (z <= 0) return upstreamIscA;
  return math.min(panel.voltage.volts / z, upstreamIscA);
}

/// Neutral-leg impedance of a feeder run (Ω), per parallel run: the neutral
/// conductor's section when the sizer recorded one, else the phase section
/// (a full-size neutral — conservative-high fault for the Icu check).
Impedance feederNeutralImpedance(
  ElectricalStandardsProfile profile,
  double phaseCsaMm2,
  double neutralCsaMm2,
  double lengthM,
  ConductorMaterial material,
  int runs,
) {
  final csa = neutralCsaMm2 > 0 ? neutralCsaMm2 : phaseCsaMm2;
  final z = conductorImpedance(profile, csa, lengthM, material);
  return Impedance(z.rOhm / runs, z.xOhm / runs);
}

/// Breaking capacity (kA) to specify for a device of [deviceClass] and [ratingA]:
/// the smallest standard rating that covers [prospectiveKa], else the class
/// maximum. Larger MCCB frames carry a rating-based floor.
double breakerKa(double ratingA, BreakerClass deviceClass, double prospectiveKa) {
  final options = breakingCapacityKa[deviceClass]!;
  final floorKa = deviceClass != BreakerClass.mcb && ratingA >= 400 ? 36.0 : 0.0;
  final pool = options.where((k) => k >= floorKa).toList();
  final candidates = pool.isNotEmpty ? pool : options;
  final maxKa = candidates.last;
  for (final k in candidates) {
    if (k >= prospectiveKa) return k;
  }
  return maxKa;
}

/// Breaking capacity (kA) the study SPECIFIES for a device: the smallest
/// standard Icu rung (honouring [breakerKa]'s large-frame floor) that covers the
/// prospective fault for BOTH its ultimate capacity (Icu ≥ Isc) AND its service
/// capacity (Ics = [serviceCapacityFraction]·Icu ≥ Isc, IEC 60947-2), else the
/// class maximum.
///
/// Picking on Icu alone ([breakerKa]) and then judging Ics made the study
/// condemn its own specification whenever the fault landed in
/// (0.75·rung, rung] — e.g. every MCCB on an untouched 16 kA root bus (Icu 16,
/// Ics 12 < 16). MCBs carry Ics = Icu, so their pick is unchanged.
double specifiedBreakerKa(
    double ratingA, BreakerClass deviceClass, double prospectiveKa) {
  final options = breakingCapacityKa[deviceClass]!;
  final floorKa = deviceClass != BreakerClass.mcb && ratingA >= 400 ? 36.0 : 0.0;
  final pool = options.where((k) => k >= floorKa).toList();
  final candidates = pool.isNotEmpty ? pool : options;
  final ics = serviceCapacityFraction[deviceClass] ?? 1;
  for (final k in candidates) {
    if (k + 1e-9 >= prospectiveKa && k * ics + 1e-9 >= prospectiveKa) return k;
  }
  return candidates.last;
}

/// True when an upstream breaker likely does NOT discriminate with a downstream
/// one (its rating is below [selectivityRatio]× the downstream rating).
bool nonSelective(double upstreamInA, double downstreamInA) {
  if (downstreamInA <= 0) return false;
  return upstreamInA < selectivityRatio * downstreamInA;
}

/// A coarse selectivity classification by upstream/downstream rating band — a
/// simplified time-current ZONE model standing in for reading the manufacturer's
/// selectivity tables. NOT a fabricated TCC: it only buckets the rating ratio.
///   - [nonSelective] — ratio < 1.6× ⇒ the overload zones likely overlap; a
///     downstream fault may trip the upstream device too;
///   - [partial] — 1.6×..2.5× ⇒ overload discrimination is likely but the
///     short-circuit (instantaneous) zones may still overlap on a high fault;
///   - [total] — ≥ 2.5× ⇒ both zones likely discriminate.
// VERIFY — notAnSniClause (a rating-ratio rule of thumb, not a standard clause).
enum SelectivityZone { nonSelective, partial, total }

extension SelectivityZoneInfo on SelectivityZone {
  String get label => switch (this) {
        SelectivityZone.nonSelective => 'non-selective',
        SelectivityZone.partial => 'partial',
        SelectivityZone.total => 'total',
      };
}

/// Classify an upstream→downstream breaker pair into a [SelectivityZone] from
/// the rating ratio alone (a coarse stand-in for the manufacturer tables).
SelectivityZone classifySelectivity(double upstreamInA, double downstreamInA) {
  if (downstreamInA <= 0) return SelectivityZone.total;
  final ratio = upstreamInA / downstreamInA;
  if (ratio < selectivityRatio) return SelectivityZone.nonSelective;
  if (ratio < totalSelectivityRatio) return SelectivityZone.partial;
  return SelectivityZone.total;
}

/// Estimated sub-transient fault current (A) an asynchronous motor of
/// [motorFlaA] full-load amps feeds INTO a nearby fault: ~[motorFaultContribution
/// Multiple]× FLA, a locked-rotor-scale pulse that decays over the first cycles.
/// A conservative UPPER bound (a soft-starter / VFD limits it); // VERIFY.
double estimatedMotorFaultA(double motorFlaA) {
  if (motorFlaA <= 0) return 0;
  return motorFaultContributionMultiple * motorFlaA;
}

/// Sum the estimated sub-transient motor-fault contribution (A) of every motor /
/// pump / HVAC (motor-like) circuit in the system, from the already-computed
/// design currents. Folded into the origin prospective fault as a conservative
/// uplift when requested. Returns 0 when there are no motor loads ⇒ the fault
/// study is byte-identical (the default path passes 0).
double systemMotorFaultContributionA(ElectricalSystemResult sys) {
  var total = 0.0;
  for (final panel in sys.panels.values) {
    for (final c in panel.circuits) {
      final motorLike = c.loadKind == LoadKind.motor ||
          c.loadKind == LoadKind.pump ||
          c.loadKind == LoadKind.hvac;
      if (motorLike) total += estimatedMotorFaultA(c.designCurrent.amperes);
    }
  }
  return total;
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
  /// Round 20: stored at 3 dp rounded in the direction of the ADS verdict
  /// (up on a FAIL, down on a PASS) — see [zsMaxOhm].
  final double? zsOhm;

  /// Maximum Zs that still guarantees disconnection in time (Ω) — TN only.
  ///
  /// Round 20: VERDICT-DIRECTED 3-dp rounding, NOT the exact limit — floored
  /// on a FAIL, ceiled on a PASS, so the printed pair always backs the
  /// verdict. The same device can therefore print a limit up to 0.001 Ω
  /// apart depending on the verdict (0.6828125 Ω prints 0.682 on a FAIL,
  /// 0.683 on a PASS); recompute from the device data for the exact figure.
  final double? zsMaxOhm;

  /// True when ADS disconnects in time (Zs ≤ Zs_max) — TN only, else null
  /// (TT clears earth faults via the RCD, already modelled).
  final bool? adsOk;

  /// Round 11 — true when the way's RCD (not its overcurrent device) is what
  /// satisfies ADS in TN: IEC 60364-4-41 411.4.5 lets an RCD provide the
  /// disconnection when Zs × IΔn ≤ U0. False otherwise (and for TT).
  final bool adsByRcd;

  /// Round 11 — the permitted disconnection time (s) the TN verdict was judged
  /// against (0.4 or 5); null for TT.
  final double? disconnectionTimeS;

  const CircuitFaultResult({
    required this.circuitId,
    required this.panelId,
    required this.faultkA,
    required this.breakerAdequate,
    required this.breakerKa,
    this.zsOhm,
    this.zsMaxOhm,
    this.adsOk,
    this.adsByRcd = false,
    this.disconnectionTimeS,
  });
}

/// Round 11 — the magnetic multiple Ia/In that guarantees disconnection within
/// the 5 s limit IEC 60364-4-41 411.3.2.3 permits for DISTRIBUTION circuits and
/// TN FINAL circuits above 32 A (the 0.4 s [curveTripMultiple] applies to
/// finals ≤ 32 A). A type D device clears inside 5 s at 10 × In (vs 20 × In for
/// 0.4 s); B and C are unchanged (their 0.4 s multiple already sits in the
/// instantaneous band). Using the 0.4 s multiple everywhere raised a false
/// `ads-disconnection` ERROR on ordinary D-curve pump / motor runs.
// VERIFY — secondarySource (BS 7671 Table 41.4 / IEC 60898 time-current
// bands; not a PUIL clause).
const Map<BreakerCurve, double> curveTripMultiple5s = {
  BreakerCurve.b: 5,
  BreakerCurve.c: 10,
  BreakerCurve.d: 10,
};

/// The final-circuit rating (A) above which IEC 60364-4-41 411.3.2.3 allows the
/// 5 s disconnection time in TN (finals ≤ this must clear in 0.4 s).
// VERIFY — secondarySource (IEC 60364-4-41 Table 41.1 note, 32 A boundary).
const double kAds04sMaxFinalRatingA = 32;

/// The permitted ADS disconnection time (s) for a TN circuit (Round 11): 5 s for
/// a distribution circuit (a feeder) or a final above [kAds04sMaxFinalRatingA],
/// else 0.4 s.
double adsDisconnectionTimeS({required bool isFeeder, required double ratingA}) =>
    (isFeeder || ratingA > kAds04sMaxFinalRatingA + 1e-9) ? 5.0 : 0.4;

/// Service-vs-ultimate breaking-capacity ratio (Ics/Icu) per device class.
/// MCCBs are commonly rated Ics = 50–100 % Icu; small MCBs are effectively
/// Ics = Icu (single-use is rare in practice). A conservative MCCB 0.75 is used.
/// Used for the Ics-adequacy check (a device should clear a SERVICE fault and
/// remain usable, IEC 60947-2), distinct from the one-shot Icu rating.
// VERIFY — notAnSniClause (IEC 60947-2 Ics declaration; verify on the datasheet).
const Map<BreakerClass, double> serviceCapacityFraction = {
  BreakerClass.mcb: 1.0,
  BreakerClass.mccb: 0.75,
  // An ACB's Ics is typically 100 % of Icu (IEC 60947-2, // VERIFY).
  BreakerClass.acb: 1.0,
};

/// One upstream→downstream breaker pair examined for current discrimination.
class SelectivityResult {
  final String upstreamCircuitId;
  final String downstreamPanelId;
  final double upstreamRatingA;
  final double downstreamRatingA;

  /// True when the pair likely does NOT discriminate (upstream < 1.6×downstream).
  final bool nonSelective;

  /// Coarse time-current ZONE classification (non-selective / partial / total)
  /// from the rating ratio — a simplified stand-in for the manufacturer
  /// selectivity tables. Additive (defaults to a ratio-derived value).
  final SelectivityZone zone;

  /// True when the upstream device's ULTIMATE breaking capacity (Icu) covers the
  /// prospective fault at its bus. Additive (default true when not assessed).
  final bool icuAdequate;

  /// True when the upstream device's SERVICE breaking capacity (Ics) covers the
  /// prospective fault — so it remains usable after clearing a fault, not merely
  /// surviving one shot (IEC 60947-2). Additive (default true when not assessed).
  final bool icsAdequate;

  /// True when the busbar short-time withstand (Icw) is NOT exceeded by the
  /// prospective fault at the upstream bus. Additive (default true).
  final bool icwAdequate;

  const SelectivityResult({
    required this.upstreamCircuitId,
    required this.downstreamPanelId,
    required this.upstreamRatingA,
    required this.downstreamRatingA,
    required this.nonSelective,
    this.zone = SelectivityZone.total,
    this.icuAdequate = true,
    this.icsAdequate = true,
    this.icwAdequate = true,
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

/// Round 20 — [v] rounded UP / DOWN to 3 dp (a 1e-9 milli-unit guard keeps an
/// exactly representable 0.683 at 0.683 despite binary noise).
double _ceil3(double v) => (v * 1000 - 1e-9).ceilToDouble() / 1000;
double _floor3(double v) => (v * 1000 + 1e-9).floorToDouble() / 1000;

/// Compute the protection / fault study over an already-solved system.
///
/// [originFaultLevel] is the prospective 3-phase symmetrical fault current the
/// supply origin can deliver (default 16 kA — a conservative direct-LV PLN
/// figure when no transformer impedance is modelled). The fault decays down the
/// feeder tree through each feeder cable's series impedance.
/// [estimatedMotorFaultContributionA] folds a sub-transient MOTOR fault infeed
/// (asynchronous machines briefly feed ~6× FLA into a nearby fault) into the
/// origin prospective fault as a conservative uplift. Default 0 ⇒ no uplift ⇒
/// the study is BYTE-IDENTICAL to before (the regression guard). Pass
/// [systemMotorFaultContributionA]`(sys)` to apply the engine's own estimate.
///
/// [engineFlooredFeederIds] lists feeder circuit ids the SIZER deliberately
/// lifted onto its selectivity floor and which reached the full
/// [selectivityRatio] target; the `selectivity-partial` ADVISORY is suppressed
/// for those pairs, because landing in the 1.6×..2.5× band is exactly what the
/// floor targets — the engine's own best trade-off, not a finding. `non-selective`
/// is NEVER suppressed, and neither is a floor the conductor-protection cap held
/// back (such a feeder is not in the set). Null (the default) reads the set the
/// solve itself recorded on [ElectricalSystemResult.feederFloorsApplied], so a
/// result built the legacy way (empty set) suppresses nothing ⇒ byte-identical.
FaultStudyResult faultStudy(
  ElectricalSystemResult sys,
  ElectricalProject project,
  ElectricalStandardsProfile profile, {
  Current originFaultLevel = const Current(16000),
  Current estimatedMotorFaultContributionA = const Current(0),
  Set<String>? engineFlooredFeederIds,
}) {
  final flooredFeeders = engineFlooredFeederIds ?? sys.feederFloorsApplied;
  // G3 — feeders whose selectivity floor was held back by the conductor-
  // protection cap (In ≤ Iz). Explanatory only: it changes no verdict and no
  // severity, it changes what the residual pair's message TELLS the engineer to
  // do. Empty (a legacy-constructed result) ⇒ every message keeps its original
  // wording ⇒ byte-identical.
  final cappedFeeders = sys.feederFloorsCapped;
  final warnings = <ElectricalWarning>[];
  // Round 26 — devices already given a service-capacity (Ics) warning in the
  // per-way pass, so the feeder selectivity pass never repeats it.
  final icsWarned = <String>{};
  final panelResults = <String, PanelFaultResult>{};
  final circuitResults = <String, CircuitFaultResult>{};
  final selectivity = <SelectivityResult>[];

  final baseIscA = originFaultLevel.amperes > 0 ? originFaultLevel.amperes : 0.0;
  // Motor sub-transient infeed lifts the prospective fault the devices must
  // break. 0 ⇒ unchanged (byte-identical). Only added when there is a base fault.
  final motorA = estimatedMotorFaultContributionA.amperes > 0
      ? estimatedMotorFaultContributionA.amperes
      : 0.0;
  final originIscA = baseIscA > 0 ? baseIscA + motorA : baseIscA;

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

  // Per-panel prospective fault (A) + the source impedance backing it, filled
  // root→leaf so a child reads its parent's value. Four running impedances:
  //   - panelSourceZ  — COLD phase path (source + Σ feeder phase legs) for the
  //     prospective fault (the conservative-high Icu basis);
  //   - panelNeutralZ — COLD Σ feeder neutral legs (the 1-phase L-N fault's
  //     return path);
  //   - panelSourceZHot — the phase path with each FEEDER leg's R at the
  //     fault temperature (×[zsFaultTempFactor]) — the earth-fault loop basis;
  //   - panelPeZ — HOT Σ feeder PE legs: an earth fault on a sub-board circuit
  //     returns through every upstream feeder's PE, not just its own.
  final panelFaultA = <String, double>{};
  final panelSourceZ = <String, Impedance>{};
  final panelNeutralZ = <String, Impedance>{};
  final panelSourceZHot = <String, Impedance>{};
  final panelPeZ = <String, Impedance>{};

  // The earthing system is installation-wide (TN vs TT) — drives the ADS check.
  // TT clears earth faults via the RCD (already modelled), so its loop is relaxed.
  final isTn = sys.earthing.system == EarthingSystem.tnS ||
      sys.earthing.system == EarthingSystem.tnCs;

  // sys.order is root-first, so a single forward pass propagates the fault down.
  for (final panelId in sys.order) {
    final panelResult = sys.panels[panelId];
    final panelModel = modelById[panelId];
    if (panelResult == null || panelModel == null) continue;

    // Source impedance is referred to the LV network LINE voltage (a 1-phase
    // board stores its 220 V phase voltage — see [faultBasisLineVoltageV]).
    final basisV = faultBasisLineVoltageV(panelModel);

    // Prospective fault + source impedance at this bus.
    final double faultA;
    final Impedance sourceZ;
    final Impedance neutralZ;
    final Impedance sourceZHot;
    final Impedance peReturnZ;
    final feederId = panelFeederCircuit[panelId];
    final parentId = panelParent[panelId];
    if (feederId == null || parentId == null) {
      // Root / utility-fed panel — origin fault level + its source impedance.
      faultA = originIscA;
      sourceZ = sourceImpedanceFromIsc(originIscA, basisV);
      neutralZ = const Impedance(0, 0);
      sourceZHot = sourceZ;
      peReturnZ = const Impedance(0, 0);
    } else {
      // Sub-panel — decay the parent fault through the feeder cable impedance.
      final upstreamIscA = panelFaultA[parentId] ?? originIscA;
      final upstreamSourceZ =
          panelSourceZ[parentId] ?? sourceImpedanceFromIsc(originIscA, basisV);
      final feederResult = _circuitById(sys.panels[parentId], feederId);
      final feederModel = _modelCircuitById(modelById[parentId], feederId);
      final csa = feederResult?.cable.csaMm2 ?? 0;
      final runs = (feederResult?.cable.runsPerPhase ?? 1) > 1
          ? feederResult!.cable.runsPerPhase!
          : 1;
      // The run the cable was SIZED on (geo when placed, else manual) and the
      // PARENT's conductor material (the parent sized this feeder).
      final lengthM = solvedRunLengthM(feederResult, feederModel);
      final feederMaterial =
          modelById[parentId]?.material ?? panelModel.material;
      final single = conductorImpedance(profile, csa, lengthM, feederMaterial);
      // 70 °C-table leg — the basis the HOT earth-fault loop scales below.
      final feederZ = Impedance(single.rOhm / runs, single.xOhm / runs);
      // Round 17 — the MAXIMUM (Icu) prospective fault decays through the
      // conductor at 20 °C (IEC 60909-0), not the 70 °C operating table.
      sourceZ = upstreamSourceZ + coldMaxFaultImpedance(feederZ, feederMaterial);
      neutralZ = (panelNeutralZ[parentId] ?? const Impedance(0, 0)) +
          coldMaxFaultImpedance(
              feederNeutralImpedance(profile, csa,
                  feederResult?.grounding.neutralCsaMm2 ?? 0, lengthM,
                  // elec-props-1 — the feeder's neutral is the PARENT's cable
                  // (the same material the phase leg + Fold-1 use), never the
                  // fed board's own bus material.
                  feederMaterial, runs),
              feederMaterial);
      faultA = subPanelBusFaultA(panelModel, sourceZ, neutralZ, upstreamIscA);
      // Earth-fault loop legs at the fault temperature (cold decay above).
      sourceZHot = (panelSourceZHot[parentId] ?? upstreamSourceZ) +
          Impedance(feederZ.rOhm * zsFaultTempFactor, feederZ.xOhm);
      // elec-props-1 — the feeder's PE conductor runs in the PARENT's cable.
      final pe0 = conductorImpedance(profile,
          feederResult?.grounding.peCsaMm2 ?? 0, lengthM, feederMaterial);
      peReturnZ = (panelPeZ[parentId] ?? const Impedance(0, 0)) +
          Impedance(pe0.rOhm * zsFaultTempFactor / runs, pe0.xOhm / runs);
    }
    panelFaultA[panelId] = faultA;
    panelSourceZ[panelId] = sourceZ;
    panelNeutralZ[panelId] = neutralZ;
    panelSourceZHot[panelId] = sourceZHot;
    panelPeZ[panelId] = peReturnZ;

    final faultKaRounded = _round(faultA / 1000.0, 2);

    // ── Incomer breaking-capacity adequacy ─────────────────────────────────
    final incomer = panelResult.incomer.breaker;
    final incomerKa = specifiedBreakerKa(
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
    final incomerIcs = incomerAdequate
        ? _icsShortfall(
            label: '${panelResult.name} incomer',
            icuKa: incomerKa,
            deviceClass: incomer.deviceClass,
            faultKa: faultA / 1000.0,
            panelId: panelId)
        : null;
    if (incomerIcs != null) warnings.add(incomerIcs);
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
      final ka = specifiedBreakerKa(
        c.breaker.ratingA.amperes,
        c.breaker.deviceClass,
        faultA / 1000.0,
      );
      final adequate = ka + 1e-9 >= faultA / 1000.0;
      final wayIcs = adequate
          ? _icsShortfall(
              label: '${panelResult.name} / ${c.name}',
              icuKa: ka,
              deviceClass: c.breaker.deviceClass,
              faultKa: faultA / 1000.0,
              panelId: panelId,
              circuitId: c.circuitId)
          : null;
      if (wayIcs != null) {
        warnings.add(wayIcs);
        icsWarned.add('$panelId|${c.circuitId}');
      }
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
      var adsByRcd = false;
      double? disconnectionTimeS;
      if (isTn) {
        final runs = (c.cable.runsPerPhase ?? 1) > 1 ? c.cable.runsPerPhase! : 1;
        // Zs on the run the cable + Vd were sized on (geo-derived when placed),
        // never the stale manual length.
        final lengthM = solvedRunLengthM(c, cModel);
        // Round 42 — a STAR-DELTA way's field run is its two motor-lead
        // cables (the starter in the board, [kStarDeltaInternalWiringM] of
        // internal supply link): in run (delta) each line feeds TWO winding
        // conductors, one in each lead cable, so the loop sees the lead
        // section on 2 × lead runs in parallel (each lead with its PE), plus
        // the short internal link on the supply section.
        final leads = c.motorLeads;
        final Impedance phaseZ;
        final Impedance peZ;
        if (leads == null) {
          final phaseZ0 = conductorImpedance(
              profile, c.cable.csaMm2, lengthM, panelModel.material);
          final peZ0 = conductorImpedance(
              profile, c.grounding.peCsaMm2, lengthM, panelModel.material);
          // Fault-temperature R, parallel runs each carry their own PE.
          phaseZ = Impedance(
              phaseZ0.rOhm * zsFaultTempFactor / runs, phaseZ0.xOhm / runs);
          peZ = Impedance(
              peZ0.rOhm * zsFaultTempFactor / runs, peZ0.xOhm / runs);
        } else {
          final leadPaths = 2 * ((leads.runsPerPhase ?? 1) > 1
              ? leads.runsPerPhase!
              : 1);
          final leadPe = c.motorLeadsPeCsaMm2 ?? leads.csaMm2;
          final lPh = conductorImpedance(
              profile, leads.csaMm2, lengthM, panelModel.material);
          final lPe =
              conductorImpedance(profile, leadPe, lengthM, panelModel.material);
          final iPh = conductorImpedance(profile, c.cable.csaMm2,
              kStarDeltaInternalWiringM, panelModel.material);
          final iPe = conductorImpedance(profile, c.grounding.peCsaMm2,
              kStarDeltaInternalWiringM, panelModel.material);
          phaseZ = Impedance(
              lPh.rOhm * zsFaultTempFactor / leadPaths +
                  iPh.rOhm * zsFaultTempFactor / runs,
              lPh.xOhm / leadPaths + iPh.xOhm / runs);
          peZ = Impedance(
              lPe.rOhm * zsFaultTempFactor / leadPaths +
                  iPe.rOhm * zsFaultTempFactor / runs,
              lPe.xOhm / leadPaths + iPe.xOhm / runs);
        }
        // Loop = hot source/feeder phase path + every upstream feeder's PE
        // return + this circuit's own phase + PE (elec-advanced-2).
        final loop = sourceZHot + peReturnZ + phaseZ + peZ;
        final zs = loop.magnitude;
        // Round 11 — the magnetic multiple follows the PERMITTED disconnection
        // time: 5 s for a feeder / a final > 32 A, 0.4 s otherwise.
        final isFeeder =
            cModel?.isFeeder ?? (c.loadKind == LoadKind.feeder);
        final tDisc = adsDisconnectionTimeS(
            isFeeder: isFeeder, ratingA: c.breaker.ratingA.amperes);
        disconnectionTimeS = tDisc;
        final multiples =
            tDisc >= 5.0 ? curveTripMultiple5s : curveTripMultiple;
        final ia = (multiples[c.breaker.curve] ?? 10) *
            c.breaker.ratingA.amperes;
        final zsMaxOcpd =
            ia > 0 ? (zsVoltageFactor * u0PhaseVoltageV) / ia : double.infinity;
        // Round 11 — an RCD on the way may provide ADS (IEC 60364-4-41
        // 411.4.5: Zs × IΔn ≤ U0); the governing limit is the more lenient of
        // the two devices, and the RCD is reported as the disconnecting device
        // when only it satisfies the loop.
        final idnA = c.rcd.required && c.rcd.ratingMa > 0
            ? c.rcd.ratingMa / 1000.0
            : 0.0;
        final zsMaxRcd = idnA > 0
            ? (zsVoltageFactor * u0PhaseVoltageV) / idnA
            : 0.0;
        final zsMax = zsMaxRcd > zsMaxOcpd ? zsMaxRcd : zsMaxOcpd;
        adsOk = zs <= zsMax + 1e-9;
        // Round 20 (electrical-property-ads-message-rounds-to-equal) — the
        // stored / printed 3-dp pair is rounded IN THE DIRECTION OF THE
        // VERDICT, so the figures always back it up: a failure rounds Zs up
        // and the limit down (never 'Zs 0.683 Ω exceeds the 0.683 Ω limit'),
        // a pass rounds Zs down and the limit up (never a printed Zs above
        // its printed limit on a PASS). Each figure moves < 0.001 Ω.
        zsOhm = adsOk ? _floor3(zs) : _ceil3(zs);
        zsMaxOhm = zsMax.isFinite
            ? (adsOk ? _ceil3(zsMax) : _floor3(zsMax))
            : zsMax;
        adsByRcd = adsOk && zs > zsMaxOcpd + 1e-9;
        if (!adsOk) {
          warnings.add(ElectricalWarning(
            code: 'ads-disconnection',
            severity: WarningSeverity.error,
            message:
                '${panelResult.name} / ${c.name}: earth-fault loop Zs '
                '${_fmt(zsOhm)} Ω exceeds the ${_fmt(zsMaxOhm)} Ω limit for '
                'disconnection in ${_fmt(tDisc)} s — shorten the run, '
                'increase the CSA (cable override)'
                // Round 38 (elec-protection-ads-advice-fit-rcd-impossible)
                // — the model has no RCD request on a TN way, so the only
                // levers named are the ones the tool provides.
                '${c.breaker.deviceClass == BreakerClass.mcb ? ', or a lower trip curve / rating (breaker override)' : ', or a lower rating (breaker override)'}.',
            panelId: panelId,
            circuitId: c.circuitId,
          ));
        }
      } else if (!c.rcd.required) {
        // TT loop: ADS via overcurrent is not modelled (the loop impedance is
        // too high to guarantee disconnection), and this way carries no
        // modelled RCD either — so its earth fault is protected by NEITHER
        // mechanism. (TT finals and feeders now get an RCD in `circuitRcd`, so
        // only a genuinely uncovered way, e.g. an RCD-exempt life-safety run,
        // reaches here.)
        // Round 24 — an upstream FEEDER RCD does detect this way's earth
        // fault: name it (and what it does to a life-safety way) instead of
        // claiming the fault goes undetected.
        ElectricalCircuitResult? upstreamRcd;
        String? upstreamBoard;
        for (var pid = panelId, hops = 0;
            hops < sys.order.length && upstreamRcd == null;
            hops++) {
          final fid = panelFeederCircuit[pid];
          final par = panelParent[pid];
          if (fid == null || par == null) break;
          final fr = _circuitById(sys.panels[par], fid);
          if (fr != null && fr.rcd.required) {
            upstreamRcd = fr;
            upstreamBoard = sys.panels[par]?.name ?? par;
          }
          pid = par;
        }
        warnings.add(ElectricalWarning(
          code: 'tt-no-earth-fault-protection',
          severity: WarningSeverity.warning,
          message: upstreamRcd == null
              ? '${panelResult.name} / ${c.name}: TT circuit with no modelled '
                  'earth-fault protection — the high TT earth-loop impedance gives '
                  'no ADS by overcurrent and this way carries no RCD. Fit a '
                  'time-delayed/S-type RCD or verify the earth-loop disconnection.'
              : '${panelResult.name} / ${c.name}: TT circuit with no RCD of its '
                  'own — its earth fault is cleared only by the upstream '
                  '${upstreamRcd.rcd.ratingMa} mA RCD on $upstreamBoard / '
                  '${upstreamRcd.name}, which disconnects that whole feeder'
                  '${c.loadKind == LoadKind.pump || c.loadKind == LoadKind.motor ? ' (a life-safety pump stops with it)' : ''}. '
                  'Fit a selective RCD on this way, or feed it from a board '
                  'with no tripping RCD upstream.',
          panelId: panelId,
          circuitId: c.circuitId,
        ));
      }

      circuitResults[c.circuitId] = CircuitFaultResult(
        circuitId: c.circuitId,
        panelId: panelId,
        faultkA: faultKaRounded,
        breakerAdequate: adequate,
        breakerKa: ka,
        zsOhm: zsOhm,
        zsMaxOhm: zsMaxOhm,
        adsByRcd: adsByRcd,
        disconnectionTimeS: disconnectionTimeS,
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
    final zone = classifySelectivity(upstreamIn, downstreamIn);

    // Ics vs Icu (IEC 60947-2) at the UPSTREAM device's bus: Icu must cover the
    // prospective fault (survive one shot); Ics (service capacity) must too if
    // the device is to remain usable. Icw: the upstream panel's busbar
    // short-time withstand must not be exceeded.
    final upstreamFaultKa = (panelFaultA[parentId] ?? originIscA) / 1000.0;
    final icu = specifiedBreakerKa(
      upstreamIn,
      feeder.breaker.deviceClass,
      upstreamFaultKa,
    );
    final icsFraction = serviceCapacityFraction[feeder.breaker.deviceClass] ?? 1;
    final icuAdequate = icu + 1e-9 >= upstreamFaultKa;
    final icsAdequate = icu * icsFraction + 1e-9 >= upstreamFaultKa;
    final parentBusbar = sys.panels[parentId]?.busbar;
    final icwKa = parentBusbar?.withstand?.icwKa;
    final icwAdequate = icwKa == null ? true : icwKa + 1e-9 >= upstreamFaultKa;

    selectivity.add(SelectivityResult(
      upstreamCircuitId: feederCircuitId,
      downstreamPanelId: childPanelId,
      upstreamRatingA: upstreamIn,
      downstreamRatingA: downstreamIn,
      nonSelective: ns,
      zone: zone,
      icuAdequate: icuAdequate,
      icsAdequate: icsAdequate,
      icwAdequate: icwAdequate,
    ));
    // G3 — when the sizer's floor was CAPPED by this feeder's own load-sized
    // cable, the obvious move (fit a bigger breaker) is exactly what the engine
    // forbids: In ≤ Iz always wins. Name the cap, its two numbers, and the one
    // lever that actually moves the device — the CABLE.
    //
    // One honesty guard on the advice: the 1.6× target can itself sit ABOVE the
    // largest standard frame (a very large sub-board). Copper cannot buy a rung
    // the ladder does not have, so that corner is told the truth instead of
    // being sent shopping for cable that changes nothing.
    final capped = cappedFeeders.contains(feederCircuitId);
    final targetA = selectivityRatio * downstreamIn;
    final ladderTopA = profile.standardBreakerRatingsA.isEmpty
        ? double.infinity
        : profile.standardBreakerRatingsA.last;
    final capHead = 'the device is already at the largest rung the '
        '${_fmt(feeder.cable.csaMm2)} mm2 feeder cable protects (Iz '
        '${feeder.cable.deratedIz.amperes.toStringAsFixed(1)} A). ';
    final capNote = !capped
        ? ''
        : targetA > ladderTopA
            ? '$capHead'
                'The ${_fmt(selectivityRatio)}x target (${_fmt(targetA)} A) is '
                'itself beyond the largest standard frame '
                '(${_fmt(ladderTopA)} A), so no cable increase reaches it - '
                'split the load or verify against manufacturer curves.'
            : '$capHead'
                'To reach the ${_fmt(selectivityRatio)}x target, increase the '
                'feeder cable (then the device can rise); verify against '
                'manufacturer curves otherwise.';
    if (ns) {
      warnings.add(ElectricalWarning(
        code: 'non-selective',
        severity: WarningSeverity.warning,
        message: capped
            ? '${feeder.name} (${_fmt(upstreamIn)} A) may not discriminate with '
                '${child.name} incomer (${_fmt(downstreamIn)} A): $capNote'
            : '${feeder.name} (${_fmt(upstreamIn)} A) may not discriminate with '
                '${child.name} incomer (${_fmt(downstreamIn)} A): ratio < '
                '${_fmt(selectivityRatio)}× — verify against the manufacturer '
                'time-current / let-through curves.',
        panelId: parentId,
        circuitId: feederCircuitId,
      ));
    } else if (zone == SelectivityZone.partial && capped) {
      // A capped floor that landed in the partial band is still the conductor
      // holding the device back, not a free choice — say so rather than sending
      // the engineer to the selectivity tables for a rung they cannot fit.
      warnings.add(ElectricalWarning(
        code: 'selectivity-partial',
        severity: WarningSeverity.info,
        message: '${feeder.name} (${_fmt(upstreamIn)} A) over ${child.name} '
            'incomer (${_fmt(downstreamIn)} A): partial selectivity - $capNote',
        panelId: parentId,
        circuitId: feederCircuitId,
      ));
    } else if (zone == SelectivityZone.partial &&
        !flooredFeeders.contains(feederCircuitId)) {
      // Overload zone discriminates but the short-circuit (instantaneous) zone
      // may overlap on a high fault — an advisory, not an error. Suppressed when
      // the sizer itself floored this feeder onto the 1.6× target: the partial
      // band is the deliberate outcome of that floor, so re-reporting it would
      // guarantee an advisory on every feeder the engine correctly coordinated.
      warnings.add(ElectricalWarning(
        code: 'selectivity-partial',
        severity: WarningSeverity.info,
        message:
            '${feeder.name} (${_fmt(upstreamIn)} A) over ${child.name} incomer '
            '(${_fmt(downstreamIn)} A): partial selectivity (ratio '
            '${_fmt(selectivityRatio)}×..${_fmt(totalSelectivityRatio)}×) — the '
            'short-circuit zone may overlap on a high fault; confirm against the '
            'manufacturer selectivity tables.',
        panelId: parentId,
        circuitId: feederCircuitId,
      ));
    }
    // Round 38 (elec-protection-ics-warning-when-icu-short) — only an
    // Icu-ADEQUATE device can be short on Ics (as the per-way pass); an
    // Icu-short feeder already carries the breaking-capacity error, and a
    // '100 % Ics' advice on it contradicts that error.
    if (icuAdequate &&
        !icsAdequate &&
        !icsWarned.contains('$parentId|$feederCircuitId')) {
      final w = _icsShortfall(
          label: feeder.name,
          icuKa: icu,
          deviceClass: feeder.breaker.deviceClass,
          faultKa: upstreamFaultKa,
          panelId: parentId,
          circuitId: feederCircuitId);
      if (w != null) warnings.add(w);
    }
  }

  return FaultStudyResult(
    originFaultkA: _round(originIscA / 1000.0, 2),
    panels: panelResults,
    circuits: circuitResults,
    selectivity: selectivity,
    warnings: warnings,
    verifyItems: motorA > 0 && baseIscA > 0
        ? const [...faultStudyVerifyItems, faultStudyMotorVerifyItem]
        : faultStudyVerifyItems,
  );
}

/// The run length (m) a circuit's impedance must be computed on: the SOLVED
/// [ElectricalCircuitResult.lengthM] — the same run its cable + Vd were sized
/// on (geo-derived when the panel and load are placed, else the manual length)
/// — falling back to the model's manual length when the result carries none
/// (0, e.g. a hand-built result). Using the manual length on a placed layout
/// computed Zs/ADS and the downstream fault on a stale run (a 50 m placed run
/// checked as the 10 m default ⇒ a failing ADS reported as a pass).
double solvedRunLengthM(
    ElectricalCircuitResult? result, ElectricalCircuit? model) {
  if (result != null && result.lengthM > 0) return result.lengthM;
  return model?.length.meters ?? 0;
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

/// Round 26 (ics-unchecked-on-incomers-and-final-mccbs) — the ONE IEC
/// 60947-2 service-capacity test, applied to EVERY device the study specifies
/// (incomer, each way, each feeder): Ics = [serviceCapacityFraction]·Icu must
/// cover the prospective fault at its bus. Null when adequate. The CODE stays
/// `service-capacity-inadequate` (E8d — a stable acknowledgement / compliance
/// discriminator). "Service capacity" is the DEVICE rating Ics (the fault a
/// breaker can clear and stay in service after), NOT the PLN supply capacity.
ElectricalWarning? _icsShortfall({
  required String label,
  required double icuKa,
  required BreakerClass deviceClass,
  required double faultKa,
  required String? panelId,
  String? circuitId,
}) {
  final icsFraction = serviceCapacityFraction[deviceClass] ?? 1;
  if (icuKa * icsFraction + 1e-9 >= faultKa) return null;
  return ElectricalWarning(
    code: 'service-capacity-inadequate',
    severity: WarningSeverity.warning,
    message:
        '$label: DEVICE rated service short-circuit breaking '
        'capacity Ics (~${_fmt(_round(icuKa * icsFraction, 1))} kA, '
        '${(icsFraction * 100).round()} % of Icu ${_fmt(icuKa)} kA, IEC '
        '60947-2) is below the ${_fmt(_round(faultKa, 2))} kA '
        'prospective fault at its bus — the breaker may survive one '
        'clearance (Icu) but is not rated to remain in service afterwards; '
        'specify a 100 % Ics device. (A device rating, not the PLN supply '
        'connection capacity.)',
    panelId: panelId,
    circuitId: circuitId,
  );
}

String _fmt(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
