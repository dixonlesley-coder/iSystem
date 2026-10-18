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
import 'model.dart' show ElectricalProject, ElectricalSystem;

// ── Local reference constants (`// VERIFY`) ─────────────────────────────────

/// Maximum demand (kVA) served at low voltage before MV + transformer is
/// needed. // VERIFY — secondary source (Indonesian PLN LV practice ≈ 200 kVA).
const double lvSupplyLimitKva = 200;

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
/// units of the largest rating — never one unit BELOW the requirement.
({double kva, int units}) _selectTransformerUnits(double requiredKva) {
  for (final k in transformerKvaLadder) {
    if (k >= requiredKva) return (kva: k, units: 1);
  }
  final top = transformerKvaLadder.last;
  return (kva: top, units: (requiredKva / top).ceil());
}

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
}) {
  final demandKva = _round1(demand.inKilovoltAmperes);
  final verify = <String>[
    'LV/MV threshold $lvSupplyLimitKva kVA — secondary source (verify vs PLN LV practice).',
  ];

  final declared = declaredKva?.inKilovoltAmperes;
  if (declared != null && declared > 0) {
    const mvV = Voltage(mvVoltageV);
    verify.add('Transformer loading factor $transformerLoadingFactor and Z% '
        '$transformerImpedancePct — secondary source (design practice).');
    final carried = dualTransformer
        ? demand.inKilovoltAmperes / 2
        : demand.inKilovoltAmperes;
    final below = declared * transformerLoadingFactor < carried - 1e-9;
    final unitsText = dualTransformer ? '2 × ' : '';
    return SupplyDesign(
      lvOrMv: SupplyLevel.mv,
      demandKva: demandKva,
      lvVoltage: lvVoltage,
      mvVoltage: mvV,
      transformerKva: declared,
      units: dualTransformer ? 2 : 1,
      declared: true,
      declaredBelowDemand: below,
      impedancePct: transformerImpedancePct,
      primaryFlc: Current(_round1(_transformerFlc(declared, mvV).amperes)),
      secondaryFlc:
          Current(_transformerFlc(declared, lvVoltage).amperes.roundToDouble()),
      note: 'Declared customer transformer: $unitsText${_fmtKva(declared)} kVA '
          'MV supply (20 kV) for the $demandKva kVA demand.'
          '${below ? ' At ${(transformerLoadingFactor * 100).round()} % '
              'loading it carries ${_fmtKva(_round1(declared * transformerLoadingFactor))} kVA '
              '— below the ${_fmtKva(_round1(carried))} kVA ${dualTransformer ? 'each section carries' : 'demand'}; '
              'raise the rating.' : ''}',
      verifyItems: verify,
    );
  }

  if (!dualTransformer && demand.inKilovoltAmperes <= lvSupplyLimitKva) {
    return SupplyDesign(
      lvOrMv: SupplyLevel.lv,
      demandKva: demandKva,
      lvVoltage: lvVoltage,
      units: 0,
      note: 'Within the ${_fmtKva(lvSupplyLimitKva)} kVA low-voltage limit — '
          'direct PLN LV connection (no transformer needed).',
      verifyItems: verify,
    );
  }

  const mvV = Voltage(mvVoltageV);
  verify
    ..add('Transformer loading factor $transformerLoadingFactor and Z% '
        '$transformerImpedancePct — secondary source (design practice).')
    ..add('Transformer kVA ladder — secondary source (IEC 60076 preferred '
        'ratings; verify the exact ratings against the chosen manufacturer).');

  if (dualTransformer) {
    // Two transformers, each sized for half the demand, on split bus sections
    // behind a normally-open coupler. The fault level the boards see is ONE
    // unit's (the coupler never parallels them).
    final perUnitRequired =
        (demand.inKilovoltAmperes / 2) / transformerLoadingFactor;
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
          'section (~half the $demandKva kVA demand); with one unit out, close '
          'the coupler and shed non-essential load onto the survivor. Fault '
          'level is one unit (coupler N.O.).'
          '${exceeded ? ' Each section needs ${sel.units} x ${_fmtKva(kva)} kVA '
              '— the requirement exceeds the largest standard transformer.' : ''}',
      verifyItems: verify,
    );
  }

  final requiredKva = demand.inKilovoltAmperes / transformerLoadingFactor;
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
        'and MV panel (incomer + metering + transformer feeder) is required.',
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

/// Round 16 (supply-sources-dual-tx-spine-genset-ladder) — the service
/// transformer the DRAWINGS and the equipment schedule print, from the SAME
/// [determineSupply] the study reports: the declared rating when one is set
/// (one unit, or two on a dual service), else — on an undeclared
/// dual-transformer service — the study's own `2 × (demand / 2 / 0.8)` pick
/// on the IEC [transformerKvaLadder] (never the genset ladder at 100 % of the
/// whole demand). Null when the project declares no MV service, or an
/// undeclared one has no demand to size from.
({double kva, int units})? serviceTransformer(
    ElectricalProject project, ApparentPower demand) {
  final declared = project.transformerKva;
  final hasDeclared = declared != null && declared.inKilovoltAmperes > 0;
  if (!hasDeclared && !project.dualTransformer) return null;
  if (!hasDeclared && demand.voltAmperes <= 0) return null;
  final s = determineSupply(demand,
      dualTransformer: project.dualTransformer,
      declaredKva: hasDeclared ? declared : null);
  final kva = s.transformerKva;
  if (kva == null || kva <= 0) return null;
  return (kva: kva, units: s.units);
}
