/// A8b — electrical supply / transformer determination + PLN connected-power
/// ("daya tersambung") sizing. Pure post-processing pass over the A4 result.
///
/// Ported from PanelMaker `engine/transformer.ts` + `standards/{transformer,
/// pln,metering}.ts`. In Indonesia, PLN low-voltage (220 / 380–400 V) service
/// is limited to ~200 kVA; above it the supply is taken at medium voltage
/// (20 kV) and stepped down through a distribution transformer in a substation
/// fed from an MV panel. The transformer is loaded to ~80 % of nameplate for
/// headroom and losses.
///
/// PROVENANCE: every reference constant below is a local `// VERIFY` value with
/// a tier note (none confirmed verbatim against an official PUIL/PLN document
/// yet — they are secondary-source distribution-engineering practice). Each
/// result carries a [verifyItems] list so the honesty surface (the calc report)
/// can show what still needs checking. Folding these into `PuilProfile` is a
/// known follow-up — they are kept local here to stay file-disjoint.
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

import '../units.dart';
import 'fault.dart' show plnLvServiceCeilingVa;
import 'model.dart' show ElectricalProject, ElectricalSystem, SupplyKind;

// ── Local reference constants (`// VERIFY`) ─────────────────────────────────

/// Maximum demand (kVA) served at low voltage before MV + transformer is
/// needed. // VERIFY — secondary source (Indonesian PLN LV practice ≈ 200 kVA).
///
/// Round 38 (elec-sizing-supply-2) — ONE LV ceiling: the PLN TR ladder top
/// [plnLvServiceCeilingVa] (197 kVA) that `declaredServiceTransformer` /
/// `isDeclaredMvService` and [recommendedDaya] use. A separate 200 kVA here
/// let a 198 kVA demand read 'LV direct' while declaring the recommended LV
/// daya flipped the project to an MV service.
const double lvSupplyLimitKva = plnLvServiceCeilingVa / 1000;

/// Standard Indonesian MV distribution voltage (V).
/// // VERIFY — secondary source (PLN TM 20 kV).
const double mvVoltageV = 20000;

/// Standard distribution-transformer ratings (kVA), ascending.
/// // VERIFY — secondary source (IEC 60076 preferred ratings, common range).
const List<double> transformerKvaLadder = [
  25, 50, 100, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000,
  2500,
];

/// Transformers are loaded to ~80 % of nameplate for headroom and losses.
/// // VERIFY — secondary source (design practice, not a code clause).
const double transformerLoadingFactor = 0.8;

/// Typical short-circuit impedance of a distribution transformer (%).
/// // VERIFY — secondary source (typical Z% for this kVA range).
const double transformerImpedancePct = 4;

/// Single-phase (1φ, 230 V) PLN connected-power ("daya tersambung") steps, VA.
/// // VERIFY — secondary source (published non-subsidised R/B/I tariff steps).
const List<double> plnDayaVa1ph = [
  450, 900, 1300, 2200, 3500, 4400, 5500, 7700, 11000, 13900,
];

/// Three-phase (3φ, 400 V) PLN connected-power steps, VA.
///
/// RECONCILIATION: PanelMaker carried TWO 3φ-relevant daya ladders that
/// disagreed — `standards/pln.ts` `PLN_DAYA_VA_3PH` and the single combined
/// `standards/metering.ts` `PLN_TARIFF_STEPS_VA`. They share the 16500…197000
/// run but differ at the ends: `pln.ts` adds the genuinely 3φ-only low steps
/// (3900 / 6600 / 10600 / 13200) and a top 233000 step, while `metering.ts`
/// adds 164000 (and is phase-agnostic, mixing the 1φ low steps in). This port
/// reconciles to ONE 3φ ladder: the purpose-built `pln.ts` `PLN_DAYA_VA_3PH`
/// (it is the dedicated daya source and is the one PanelMaker's `nextDaya`
/// uses), UNIONED with the `metering.ts`-only 164000 step so no published
/// connected-power value is lost. Result, ascending:
/// // VERIFY — secondary source (PLN tariff; the 164000 step came from the
/// metering ladder only — confirm against the current PLN tariff schedule).
const List<double> plnDayaVa3ph = [
  3900, 6600, 10600, 13200, 16500, 23000, 33000, 41500, 53000, 66000, 82500,
  105000, 131000, 147000, 164000, 197000, 233000,
];

// ── Result types ────────────────────────────────────────────────────────────

/// LV (direct PLN low-voltage) vs MV (medium-voltage + step-down transformer).
enum SupplyLevel { lv, mv }

extension SupplyLevelInfo on SupplyLevel {
  String get label => this == SupplyLevel.mv ? 'MV' : 'LV';
}

/// The project supply arrangement derived from the total diversified demand.
class SupplyDesign {
  /// LV (direct) or MV (transformer-fed).
  final SupplyLevel lvOrMv;

  /// Diversified demand the supply must carry (kVA), for reference.
  final double demandKva;

  /// Nominal low-voltage utilisation voltage (V) — 400 (3φ) by default.
  final Voltage lvVoltage;

  /// Medium-voltage supply voltage (V) — null on an LV service.
  final Voltage? mvVoltage;

  /// Selected transformer nameplate (kVA) — null on an LV service.
  final double? transformerKva;

  /// Number of transformer units (1, or 2 when [dualTransformer]; more when
  /// the requirement exceeds the largest standard rating — then paralleled /
  /// split units of [transformerKva] each).
  final int units;

  /// True when the per-unit requirement exceeded the largest ladder rating
  /// (audit r8 — the ladder used to saturate silently at 2500 kVA, leaving a
  /// unit at 120 %+ loading against the 80 % design basis).
  final bool ladderExceeded;

  /// Round 16 — true when the arrangement is the DECLARED transformer
  /// ([determineSupply] `declaredKva`) and that rating, loaded to
  /// [transformerLoadingFactor], is below the demand it carries.
  final bool declaredBelowDemand;

  /// Round 16 — true when [transformerKva] is the engineer's declared rating
  /// rather than a ladder selection.
  final bool declared;

  /// Transformer short-circuit impedance (%) — null on an LV service.
  final double? impedancePct;

  /// Transformer primary full-load current at [mvVoltage] (A) — null on LV.
  final Current? primaryFlc;

  /// Transformer secondary full-load current at [lvVoltage] (A) — null on LV.
  final Current? secondaryFlc;

  /// Plain-language summary of the arrangement.
  final String note;

  /// Provenance items still to verify against an official document.
  final List<String> verifyItems;

  const SupplyDesign({
    required this.lvOrMv,
    required this.demandKva,
    required this.lvVoltage,
    this.mvVoltage,
    this.transformerKva,
    required this.units,
    this.ladderExceeded = false,
    this.declaredBelowDemand = false,
    this.declared = false,
    this.impedancePct,
    this.primaryFlc,
    this.secondaryFlc,
    required this.note,
    required this.verifyItems,
  });

  bool get isMv => lvOrMv == SupplyLevel.mv;
}

// ── Supply determination ─────────────────────────────────────────────────────

/// Smallest standard transformer kVA covering [requiredKva] with the unit
/// count: one unit when the ladder covers it, else `n = ceil(required / top)`
/// units on the smallest rung covering the per-unit share — never one unit
/// BELOW the requirement.
///
/// Round 45 (regression-declared-capacity-transformer-top-rung) — the ONE
/// covering-units rule, shared by the supply study and the DECLARED service
/// transformer ([declaredServiceTransformer]), so a declared 3 MVA connection
/// is 2 × 1600 kVA on every surface (never 2 × 2500). [tolerance] lets a
/// figure a hair above a rung (floating division) still take that rung.
({double kva, int units}) coveringTransformerUnits(double requiredKva,
    {double tolerance = 0}) {
  for (final k in transformerKvaLadder) {
    if (k >= requiredKva - tolerance) return (kva: k, units: 1);
  }
  final top = transformerKvaLadder.last;
  // Round 44 — n units on the smallest rung covering the per-unit share
  // (2970 kVA ⇒ 2 × 1600, never 2 × 2500).
  final n = (requiredKva / top - tolerance).ceil();
  final share = requiredKva / n;
  for (final k in transformerKvaLadder) {
    if (k >= share - tolerance) return (kva: k, units: n);
  }
  return (kva: top, units: n);
}

({double kva, int units}) _selectTransformerUnits(double requiredKva) =>
    coveringTransformerUnits(requiredKva);

/// Transformer full-load current on a winding at a given line voltage (A):
/// `I = kVA·1000 / (√3·V)`. Returns 0 A for a non-positive voltage.
Current _transformerFlc(double kva, Voltage v) {
  if (v.volts <= 0) return const Current(0);
  return Current((kva * 1000) / (math.sqrt(3) * v.volts));
}

double _round1(double x) => (x * 10).round() / 10;

/// Decide the project supply arrangement from the total diversified [demand].
///
/// Within the Indonesian [lvSupplyLimitKva] LV ceiling (and not [dualTransformer])
/// → a direct PLN low-voltage connection (no transformer). Above it (or when
/// [dualTransformer] is set, e.g. hotels / data centres) → a medium-voltage
/// (20 kV) supply through a step-down transformer sized to ~80 % loading:
///   `requiredKva = demand / transformerLoadingFactor`
/// then the smallest [transformerKvaLadder] entry ≥ requiredKva. A
/// [dualTransformer] service forces MV (even below the LV ceiling) with TWO
/// units each sized for HALF the demand, on split bus sections behind a
/// normally-open coupler — the boards' fault level is one unit's (the coupler
/// never parallels them).
///
/// Round 16 (supply-sources-declared-tx-ignored-by-study) — a DECLARED
/// customer transformer ([declaredKva], `ElectricalProject.transformerKva`)
/// IS the arrangement: the service is MV whatever the demand, the declared
/// rating is reported (one unit, or two on a [dualTransformer] service), no
/// ladder pick is made, and [SupplyDesign.declaredBelowDemand] flags a unit
/// whose 80 %-loaded rating is below the demand it carries (each section's
/// half on a dual service). The study used to ignore it and print 'LV
/// direct · daya 164 kVA' beside drawings showing a 630 kVA substation.
SupplyDesign determineSupply(
  ApparentPower demand, {
  Voltage lvVoltage = const Voltage(400),
  bool dualTransformer = false,
  ApparentPower? declaredKva,
  int? declaredUnits,
  bool singleSectionCarriesAll = false,
  ApparentPower? perPhaseDemand,
  ApparentPower? largestSectionDemand,
  int? sections,
  SupplyKind supplyKind = SupplyKind.pln,
  ApparentPower? plantCapacity,
  String basisLabel = 'worst-phase basis',
}) {
  // Round 58 — the separate-section count (null ⇒ 2 on a dual service, else
  // 1: byte-identical). On a declared N-section service each unit carries its
  // own root board.
  final nSections = (sections != null && sections >= 1)
      ? sections
      : (dualTransformer ? 2 : 1);
  // Round 61 (regression-dual-with-one-section-study-mv-nothing-printed-
  // fault-doubled) — ONE section count: a dual flag is a dual service only
  // when the service HAS two sections. An explicit `sections: 1` on a dual
  // flag (the inspector's Dual ticked + 1 typed in Sections) is a single
  // section — the LV exit / one unit, exactly as [isDeclaredMvService] and
  // the printed transformer read it — never 2 units faulted as a paralleled
  // pair on a service the drawings show as LV.
  final dual = dualTransformer && nSections == 2;
  // Round 40 (electrical-sim-5-dual-tx-section-overload-missed) — on a dual
  // service each root board sits on ONE unit (coupler normally open — the
  // fault model gives each section one unit's fault), so a section carries
  // what ITS root board demands, never an equal half of the total. Null ⇒
  // the equal split ⇒ byte-identical.
  final sectionKva = largestSectionDemand?.inKilovoltAmperes ?? 0;
  final demandKva = _round1(demand.inKilovoltAmperes);
  // Round 39 (regression-lv-supply-verdict-without-any-lv-daya) — a PLN 3φ
  // service is limited PER PHASE, so an undeclared service is judged (LV vs
  // MV) and its transformer sized on max(total demand, the worst-phase basis
  // √3·400·I_worst) — the SAME basis the daya recommendation uses, so the
  // verdict reads LV exactly when an LV daya can carry the worst phase.
  // Null ⇒ the total demand ⇒ byte-identical.
  final perPhaseKva = perPhaseDemand?.inKilovoltAmperes ?? 0;
  final perPhaseGoverns = perPhaseKva > demand.inKilovoltAmperes + 1e-9;
  final basisKva =
      perPhaseGoverns ? perPhaseKva : demand.inKilovoltAmperes;
  final basisNote = perPhaseGoverns
      ? ' The $basisLabel (${_fmtKva(_round1(perPhaseKva))} kVA) '
          'governs over the $demandKva kVA total.'
      : '';
  final verify = <String>[
    'LV/MV threshold $lvSupplyLimitKva kVA — secondary source (verify vs PLN LV practice).',
  ];

  final declared = declaredKva?.inKilovoltAmperes;
  if (declared != null && declared > 0) {
    const mvV = Voltage(mvVoltageV);
    verify.add('Transformer loading factor $transformerLoadingFactor and Z% '
        '$transformerImpedancePct — secondary source (design practice).');
    // Round 30 — each unit carries demand / units (a dual service's two
    // sections; paralleled units above the ladder top).
    final units = (declaredUnits != null && declaredUnits > 0)
        ? declaredUnits
        : nSections;
    final sectioned = nSections > 1;
    // Round 37 r2 — a SINGLE service-entrance board on a dual service sits
    // on ONE section (coupler normally open), so that section carries the
    // whole demand — the basis the incomer floor and the
    // `service-capacity-below-demand` judge use (never demand / 2).
    final oneSection = sectioned && singleSectionCarriesAll && units > 1;
    final split = oneSection
        ? demand.inKilovoltAmperes / math.max(1, units ~/ nSections)
        : demand.inKilovoltAmperes / units;
    // Round 40 — the most loaded SECTION governs a dual service whose two
    // root boards are unequal (one unit per section on a 2-unit service).
    // Round 61 — and a service with paralleled units per section
    // (`units` a multiple of the section count, e.g. 4 x 1600 kVA on a dual
    // service): that section's units share its load, so each carries the
    // section load / units-per-section — never the gate that skipped every
    // service whose unit count differs from its section count.
    final unitsPerSection =
        sectioned && units % nSections == 0 ? units ~/ nSections : 0;
    final sectionPerUnit =
        unitsPerSection > 0 ? sectionKva / unitsPerSection : 0.0;
    final sectionGoverns = sectioned &&
        !oneSection &&
        unitsPerSection > 0 &&
        sectionPerUnit > split + 1e-9;
    final carried = sectionGoverns ? sectionPerUnit : split;
    final below = declared * transformerLoadingFactor < carried - 1e-9;
    final unitsText = units > 1 ? '$units × ' : '';
    final carrierText = oneSection
        ? 'the one section feeding the single service-entrance board '
            '(coupler normally open) carries'
        : sectionGoverns
            ? 'the most loaded section carries (its unit is '
                '${(carried / declared * 100).round()} % of nameplate)'
            : units > 1
                ? (sectioned && units == nSections
                    ? 'each section carries'
                    : 'each unit carries')
                : 'demand';
    return SupplyDesign(
      lvOrMv: SupplyLevel.mv,
      demandKva: demandKva,
      lvVoltage: lvVoltage,
      mvVoltage: mvV,
      transformerKva: declared,
      units: units,
      declared: true,
      declaredBelowDemand: below,
      impedancePct: transformerImpedancePct,
      primaryFlc: Current(_round1(_transformerFlc(declared, mvV).amperes)),
      secondaryFlc:
          Current(_transformerFlc(declared, lvVoltage).amperes.roundToDouble()),
      note: 'Declared customer transformer: $unitsText${_fmtKva(declared)} kVA '
          'MV supply (20 kV) for the $demandKva kVA demand.'
          '${oneSection ? ' One section feeds the single service-entrance '
              'board (coupler normally open).' : ''}'
          '${below ? ' At ${(transformerLoadingFactor * 100).round()} % '
              'loading it carries ${_fmtKva(_round1(declared * transformerLoadingFactor))} kVA '
              '— below the ${_fmtKva(_round1(carried))} kVA $carrierText; '
              'raise the rating.' : ''}',
      verifyItems: verify,
    );
  }

  // Round 58 (elec-convergence-10-power-oneline-pln-on-genset-supply) — an
  // on-site GENERATOR / SOLAR primary supply is an LV source whatever the
  // demand (Round 39): no PLN connection, no daya, no transformer.
  if (supplyKind != SupplyKind.pln) {
    final plant = plantCapacity?.inKilovoltAmperes;
    final label =
        supplyKind == SupplyKind.generator ? 'genset' : 'solar PV';
    return SupplyDesign(
      lvOrMv: SupplyLevel.lv,
      demandKva: demandKva,
      lvVoltage: lvVoltage,
      units: 0,
      note: 'On-site $label primary supply'
          '${plant != null && plant > 0 ? ' (${_fmtKva(plant)} kVA)' : ''} '
          'for the $demandKva kVA demand — no PLN connection.',
      verifyItems: verify,
    );
  }

  // Round 60 (regression-transformer-units-undeclared-lv-vs-dual-mv) — a
  // SECTIONED service (> 1 separate transformer section, a dual service or
  // [sections] > 1) is a transformer (MV) service whatever the demand: it
  // never takes the direct-LV exit, so `transformerUnits = 2` and a dual
  // service are studied identically.
  if (!dual && nSections <= 1 && basisKva <= lvSupplyLimitKva) {
    return SupplyDesign(
      lvOrMv: SupplyLevel.lv,
      demandKva: demandKva,
      lvVoltage: lvVoltage,
      units: 0,
      note: 'Within the ${_fmtKva(lvSupplyLimitKva)} kVA low-voltage limit — '
          'direct PLN LV connection (no transformer needed).$basisNote',
      verifyItems: verify,
    );
  }

  const mvV = Voltage(mvVoltageV);
  verify
    ..add('Transformer loading factor $transformerLoadingFactor and Z% '
        '$transformerImpedancePct — secondary source (design practice).')
    ..add('Transformer kVA ladder — secondary source (IEC 60076 preferred '
        'ratings; verify the exact ratings against the chosen manufacturer).');

  // Round 59 (regression-undeclared-n-section-service-ignores-sections) —
  // an undeclared N-section service ([sections] > 1, e.g. a campus with one
  // transformer per building) is studied per SECTION like the dual service
  // (its N = 2 case): each unit carries its own root board (the largest
  // section, never below an even share), on separate sections behind
  // normally-open couplers, so the boards see ONE unit's fault. Sizing one
  // paralleled bank on the whole demand overstated the origin fault ~60 %
  // (2 x 1600 kVA = 57.7 kA where each section's 1000 kVA unit gives
  // 36.1 kA) — optimistic ADS on every TN loop. (A dual service keeps its
  // own note below: byte-identical.)
  // Round 60 (elec-convergence-12-undeclared-sectioned-single-root-
  // transformer-undersized) — a SINGLE service-entrance board sits on ONE
  // section (couplers normally open, the fault model's one unit), so that
  // unit carries the whole demand ([singleSectionCarriesAll]) — never an
  // even share it cannot reach (Round 37 r2's one-section basis, now on the
  // undeclared study too).
  final perSectionKva = singleSectionCarriesAll
      ? basisKva
      : math.max(basisKva / nSections, sectionKva);
  if (nSections > 1 && !dual) {
    final perUnitRequired = perSectionKva / transformerLoadingFactor;
    final sel = _selectTransformerUnits(perUnitRequired);
    final kva = sel.kva;
    final exceeded = sel.units > 1;
    return SupplyDesign(
      lvOrMv: SupplyLevel.mv,
      demandKva: demandKva,
      lvVoltage: lvVoltage,
      mvVoltage: mvV,
      transformerKva: kva,
      units: nSections * sel.units,
      ladderExceeded: exceeded,
      impedancePct: transformerImpedancePct,
      primaryFlc: Current(_round1(_transformerFlc(kva, mvV).amperes)),
      secondaryFlc:
          Current(_transformerFlc(kva, lvVoltage).amperes.roundToDouble()),
      note: 'Sectioned MV supply: $nSections x ${_fmtKva(kva)} kVA on '
          'separate sections (couplers normally open). Each unit carries its '
          '${singleSectionCarriesAll ? 'the single service-entrance board '
              '(the whole $demandKva kVA demand)' : 'root board (~1/$nSections '
              'of the $demandKva kVA demand)'}; fault level is one unit '
          '(couplers N.O.).'
          '${exceeded ? ' Each section needs ${sel.units} x ${_fmtKva(kva)} '
              'kVA — the requirement exceeds the largest standard '
              'transformer.' : ''}'
          '$basisNote',
      verifyItems: verify,
    );
  }

  if (dual) {
    // Two transformers, each sized for half the demand, on split bus sections
    // behind a normally-open coupler. The fault level the boards see is ONE
    // unit's (the coupler never parallels them).
    final perUnitRequired = perSectionKva / transformerLoadingFactor;
    final sel = _selectTransformerUnits(perUnitRequired);
    final kva = sel.kva;
    final exceeded = sel.units > 1;
    return SupplyDesign(
      lvOrMv: SupplyLevel.mv,
      demandKva: demandKva,
      lvVoltage: lvVoltage,
      mvVoltage: mvV,
      transformerKva: kva,
      units: 2 * sel.units,
      ladderExceeded: exceeded,
      impedancePct: transformerImpedancePct,
      primaryFlc: Current(_round1(_transformerFlc(kva, mvV).amperes)),
      secondaryFlc:
          Current(_transformerFlc(kva, lvVoltage).amperes.roundToDouble()),
      note: 'Dual-transformer MV supply: 2 × ${_fmtKva(kva)} kVA on split bus '
          'sections with a normally-open bus coupler. Each unit carries its '
          'section (${singleSectionCarriesAll ? 'the one section feeding the '
              'single service-entrance board carries the whole' : '~half the'}'
          ' $demandKva kVA demand); with one unit out, close '
          'the coupler and shed non-essential load onto the survivor. Fault '
          'level is one unit (coupler N.O.).'
          '${exceeded ? ' Each section needs ${sel.units} x ${_fmtKva(kva)} kVA '
              '— the requirement exceeds the largest standard transformer.' : ''}'
          '$basisNote',
      verifyItems: verify,
    );
  }

  final requiredKva = basisKva / transformerLoadingFactor;
  final sel = _selectTransformerUnits(requiredKva);
  final kva = sel.kva;
  final exceeded = sel.units > 1;
  return SupplyDesign(
    lvOrMv: SupplyLevel.mv,
    demandKva: demandKva,
    lvVoltage: lvVoltage,
    mvVoltage: mvV,
    transformerKva: kva,
    units: sel.units,
    ladderExceeded: exceeded,
    impedancePct: transformerImpedancePct,
    primaryFlc: Current(_round1(_transformerFlc(kva, mvV).amperes)),
    secondaryFlc:
        Current(_transformerFlc(kva, lvVoltage).amperes.roundToDouble()),
    note: 'Demand exceeds ${_fmtKva(lvSupplyLimitKva)} kVA — medium-voltage '
        '(20 kV) supply via '
        '${exceeded ? '${sel.units} x ${_fmtKva(kva)} kVA transformers (the '
            'requirement exceeds the largest standard rating)' : 'a ${_fmtKva(kva)} kVA transformer'} '
        'and MV panel (incomer + metering + transformer feeder) is required.'
        '$basisNote',
    verifyItems: verify,
  );
}

// ── PLN connected power ("daya tersambung") ──────────────────────────────────

/// The standard daya steps (VA) for a given supply [system].
List<double> dayaTiers(ElectricalSystem system) =>
    system == ElectricalSystem.threePhase ? plnDayaVa3ph : plnDayaVa1ph;

/// The smallest standard PLN connected-power step at or above [demand], with
/// the supply system it belongs to. A single-phase demand above the 1φ ceiling
/// (13 900 VA) moves to the 3φ ladder — the honest answer is "take a 3-phase
/// service", never a 1φ step BELOW the demand. Returns null when the demand
/// exceeds the whole LV catalogue (MV territory — no LV daya exists).
({double va, ElectricalSystem system})? recommendedDaya(
  ApparentPower demand,
  ElectricalSystem system,
) {
  for (final sys in system == ElectricalSystem.threePhase
      ? const [ElectricalSystem.threePhase]
      : const [ElectricalSystem.singlePhase, ElectricalSystem.threePhase]) {
    for (final t in dayaTiers(sys)) {
      // Round 38 — never recommend an LV step above the LV service ceiling
      // (the 233 kVA step): declaring it would make the service MV.
      if (t > plnLvServiceCeilingVa + 1e-9) break;
      if (t >= demand.voltAmperes) return (va: t, system: sys);
    }
  }
  return null;
}

/// The smallest standard PLN connected-power step (VA) at or above [demand]
/// (see [recommendedDaya]). Always ≥ the demand when non-null; null beyond the
/// LV catalogue (audit r8 — it used to return the top step, BELOW demand).
double? recommendedDayaVa(ApparentPower demand, ElectricalSystem system) =>
    recommendedDaya(demand, system)?.va;

/// Format a daya step for display, e.g. 23000 → "23,000 VA (23 kVA)".
String formatDaya(double va) {
  final kva = va / 1000;
  final kvaStr = kva == kva.roundToDouble()
      ? kva.toInt().toString()
      : kva.toStringAsFixed(1);
  return '${_thousands(va)} VA ($kvaStr kVA)';
}

String _fmtKva(double kva) =>
    kva == kva.roundToDouble() ? kva.toInt().toString() : kva.toStringAsFixed(1);

/// Group an integer-valued double with thousands separators (e.g. 23000 →
/// "23,000"). Pure — avoids any locale/Intl dependency in the engine.
String _thousands(double va) {
  final digits = va.round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return buf.toString();
}

/// Round 29 (electrical-sim-3-declared-capacity-above-tr-ceiling) — the ONE
/// declared customer transformer rating: the explicit
/// [ElectricalProject.transformerKva] when set (> 0), else — a declared PLN
/// connection capacity ([ElectricalProject.supplyCapacityVa]) ABOVE the LV
/// (TR) ceiling [plnLvServiceCeilingVa] is a TM (MV) connection — the
/// smallest [transformerKvaLadder] rating covering it (a 555 kVA daya ⇒ a
/// 630 kVA unit; above the ladder, the capacity itself). Null on an LV
/// service. The supply study, the fault estimate, the drawings and the power
/// one-line all read this, so one declared service is described ONE way.
ApparentPower? declaredServiceTransformerKva(ElectricalProject project) =>
    declaredServiceTransformer(project)?.kva;

/// Round 30 (regression-dual-tx-declared-capacity-doubled) — the declared
/// customer transformer as PER-UNIT rating × unit count. An explicit
/// [ElectricalProject.transformerKva] is per-unit by contract (one unit, or
/// two on a [ElectricalProject.dualTransformer] service — byte-identical). A
/// declared PLN connection capacity ([ElectricalProject.supplyCapacityVa])
/// above the LV ceiling is the TOTAL connection: a dual service splits it
/// across its two sections (each unit covers HALF the daya), and a figure
/// above the ladder top becomes n units on the smallest covering rung
/// (Round 45, [coveringTransformerUnits]) — never one non-standard
/// unit, never 2 × the whole capacity. Null on an LV service.
({ApparentPower kva, int units})? declaredServiceTransformer(
    ElectricalProject project) {
  final tx = project.transformerKva;
  // Round 58 — the section count ([serviceSections]): one unit per section.
  final sections = serviceSections(project);
  if (tx != null && tx.inKilovoltAmperes > 0) {
    return (kva: tx, units: sections);
  }
  // Round 39 (elec-ui-journeys-2-generator-supply-drawn-as-mv) — only a PLN
  // connection above the LV ceiling implies a customer MV transformer: a
  // GENERATOR-plant or SOLAR primary supply is an LV source, whatever its
  // capacity (no MVMDP / TRAFO behind an LV genset).
  if (project.supplyKind != SupplyKind.pln) return null;
  final cap = project.supplyCapacityVa?.voltAmperes;
  if (cap == null || cap <= plnLvServiceCeilingVa) return null;
  final perSection = (cap / 1000) / sections;
  // Round 45 — the SAME covering-units rule as the supply study.
  final u = coveringTransformerUnits(perSection, tolerance: 1e-9);
  return (kva: ApparentPower.kilovoltAmperes(u.kva), units: sections * u.units);
}

/// Round 61 (elec-convergence-13-roots-outnumber-sections-section-overload)
/// — the least achievable load of the MOST loaded section when the
/// service-entrance boards [loads] (VA or kVA, any one unit) are shared
/// among [sections] separate transformer sections (each board on exactly one
/// section, couplers normally open). With no more boards than sections every
/// board can sit alone, so it is the largest board. With more boards than
/// sections at least one section carries two or more (pigeonhole), so the
/// figure is the optimum of the multiway partition: exact (branch and bound,
/// boards largest first, empty sections symmetric) for up to
/// [kSectionPartitionExactMax] boards, else the LPT greedy (largest board
/// onto the lightest section) — an UPPER bound on the optimum, so the
/// section is never sized below what it can be made to carry. Pure.
const int kSectionPartitionExactMax = 12;

double minimalMaxSectionLoad(List<double> loads, int sections) {
  final xs = [for (final l in loads) if (l > 0) l]
    ..sort((a, b) => b.compareTo(a));
  if (xs.isEmpty) return 0;
  if (sections <= 1) return xs.fold(0.0, (a, b) => a + b);
  if (xs.length <= sections) return xs.first;
  // LPT greedy — the upper bound (and the answer above the exact cap).
  final greedy = List<double>.filled(sections, 0);
  for (final x in xs) {
    var k = 0;
    for (var i = 1; i < sections; i++) {
      if (greedy[i] < greedy[k]) k = i;
    }
    greedy[k] += x;
  }
  var best = greedy.reduce(math.max);
  if (xs.length > kSectionPartitionExactMax) return best;
  final total = xs.fold(0.0, (a, b) => a + b);
  final lower = math.max(xs.first, total / sections);
  final bins = List<double>.filled(sections, 0);
  void place(int i, double currentMax) {
    if (best <= lower + 1e-9) return;
    if (i == xs.length) {
      if (currentMax < best) best = currentMax;
      return;
    }
    final seen = <double>{};
    for (var k = 0; k < sections; k++) {
      final next = bins[k] + xs[i];
      if (next >= best - 1e-12) continue;
      // Sections holding the same load are interchangeable.
      if (!seen.add(bins[k])) continue;
      bins[k] = next;
      place(i + 1, math.max(currentMax, next));
      bins[k] -= xs[i];
    }
  }

  place(0, 0);
  return best;
}

/// Round 58 (elec-convergence-10-n-section-transformer-service-
/// unrepresentable) — the number of SEPARATE (never paralleled) transformer
/// sections on the service: [ElectricalProject.transformerUnits] when set,
/// else 2 on a [ElectricalProject.dualTransformer] service, else 1. Each
/// service-entrance board sits on one section; the fault, the loading judge
/// and the service-entrance capacity all read ONE section.
int serviceSections(ElectricalProject project) {
  final n = project.transformerUnits;
  if (n != null && n >= 1) return n;
  return project.dualTransformer ? 2 : 1;
}

/// Round 29 — the ONE 'declared MV service' predicate: a declared transformer
/// ([declaredServiceTransformerKva], incl. a connection capacity above the LV
/// ceiling) or a SECTIONED service (Round 60: [serviceSections] > 1 — a
/// dual-transformer service or `transformerUnits >= 2`, the ONE sectioned
/// predicate the supply study also reads).
bool isDeclaredMvService(ElectricalProject project) =>
    declaredServiceTransformerKva(project) != null ||
    serviceSections(project) > 1;

