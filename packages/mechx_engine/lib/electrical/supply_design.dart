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
import 'model.dart' show ElectricalSystem;

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

  /// Number of transformer units (1, or 2 when [dualTransformer]).
  final int units;

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
    this.impedancePct,
    this.primaryFlc,
    this.secondaryFlc,
    required this.note,
    required this.verifyItems,
  });

  bool get isMv => lvOrMv == SupplyLevel.mv;
}

// ── Supply determination ─────────────────────────────────────────────────────

/// Smallest standard transformer kVA covering [requiredKva] (the largest ladder
/// entry when the requirement exceeds the catalogue).
double _selectTransformerKva(double requiredKva) {
  for (final k in transformerKvaLadder) {
    if (k >= requiredKva) return k;
  }
  return transformerKvaLadder.last;
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
SupplyDesign determineSupply(
  ApparentPower demand, {
  Voltage lvVoltage = const Voltage(400),
  bool dualTransformer = false,
}) {
  final demandKva = _round1(demand.inKilovoltAmperes);
  final verify = <String>[
    'LV/MV threshold $lvSupplyLimitKva kVA — secondary source (verify vs PLN LV practice).',
  ];

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
    final kva = _selectTransformerKva(perUnitRequired);
    return SupplyDesign(
      lvOrMv: SupplyLevel.mv,
      demandKva: demandKva,
      lvVoltage: lvVoltage,
      mvVoltage: mvV,
      transformerKva: kva,
      units: 2,
      impedancePct: transformerImpedancePct,
      primaryFlc: Current(_round1(_transformerFlc(kva, mvV).amperes)),
      secondaryFlc:
          Current(_transformerFlc(kva, lvVoltage).amperes.roundToDouble()),
      note: 'Dual-transformer MV supply: 2 × ${_fmtKva(kva)} kVA on split bus '
          'sections with a normally-open bus coupler. Each unit carries its '
          'section (~half the $demandKva kVA demand); with one unit out, close '
          'the coupler and shed non-essential load onto the survivor. Fault '
          'level is one unit (coupler N.O.).',
      verifyItems: verify,
    );
  }

  final requiredKva = demand.inKilovoltAmperes / transformerLoadingFactor;
  final kva = _selectTransformerKva(requiredKva);
  return SupplyDesign(
    lvOrMv: SupplyLevel.mv,
    demandKva: demandKva,
    lvVoltage: lvVoltage,
    mvVoltage: mvV,
    transformerKva: kva,
    units: 1,
    impedancePct: transformerImpedancePct,
    primaryFlc: Current(_round1(_transformerFlc(kva, mvV).amperes)),
    secondaryFlc:
        Current(_transformerFlc(kva, lvVoltage).amperes.roundToDouble()),
    note: 'Demand exceeds ${_fmtKva(lvSupplyLimitKva)} kVA — medium-voltage '
        '(20 kV) supply via a ${_fmtKva(kva)} kVA transformer and MV panel '
        '(incomer + metering + transformer feeder) is required.',
    verifyItems: verify,
  );
}

// ── PLN connected power ("daya tersambung") ──────────────────────────────────

/// The standard daya steps (VA) for a given supply [system].
List<double> dayaTiers(ElectricalSystem system) =>
    system == ElectricalSystem.threePhase ? plnDayaVa3ph : plnDayaVa1ph;

/// The smallest standard PLN connected-power step (VA) at or above [demand] for
/// the supply [system]. Returns the largest published step when the demand
/// exceeds the LV catalogue (beyond a standard LV daya — MV territory).
double recommendedDayaVa(ApparentPower demand, ElectricalSystem system) {
  final tiers = dayaTiers(system);
  for (final t in tiers) {
    if (t >= demand.voltAmperes) return t;
  }
  return tiers.last;
}

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
