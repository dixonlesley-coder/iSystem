/// Busbar sizing — pure functions ported from PanelMaker `engine/busbar.ts`
/// (`sizeBusbar`, `sizeNeutralPeBars`). Panel-level section splitting
/// (`splitBusbarSections`) belongs with the A4 panel orchestrator.
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

import '../standards/puil.dart';
import '../units.dart';
import 'results.dart';
import 'sizing.dart' show roundTo;

/// Default short-circuit clearing time (s) for the busbar thermal-withstand
/// (Icw) check, when no device clearing time is supplied. 1 s is the basis on
/// which assembly Icw ratings are conventionally declared (IEC 61439-1 §9.3.2).
///
/// IMPORTANT — basis consistency: the adequacy verdict here scales the bar's
/// thermal capability by 1/√t, so it is valid ONLY if the upstream protective
/// device actually clears the fault within [durationS]. Declaring a bar on a
/// 1 s Icw and then checking it at a shorter clearing time (the live app uses
/// ~0.1 s, the instantaneous-trip case) is legitimate for a current-limiting
/// device, but a selective TIME-DELAYED incomer does NOT clear that fast — so
/// do not silently mix bases. Re-check any bar declared on 1 s Icw against the
/// device's real let-through time. The result echoes [durationS] so the basis
/// is explicit, not hidden.
// VERIFY — notAnSniClause (IEC 61439-1 conventional 1-second Icw basis; the
// adequacy holds only if the upstream device clears within durationS).
const double busbarDefaultClearingTimeS = 1;

/// Numerical tolerance (kA) comparing Icw against the prospective fault, so a
/// bar rated exactly at the fault reads as adequate despite FP rounding.
const double _withstandToleranceKa = 1e-6;

/// Minimum copper bar cross-section (mm²) whose adiabatic short-time withstand
/// Icw covers [faultKa] for [durationS] — inverts Icw = density·CSA/√t ≥ fault
/// so the bus sizer can floor the bar at the section the fault demands instead
/// of only flagging an inadequate bar after the fact. 0 when there is no fault.
double minCsaForWithstand(
  ElectricalStandardsProfile profile,
  double faultKa, {
  double durationS = busbarDefaultClearingTimeS,
}) {
  if (faultKa <= 0) return 0;
  final t = durationS > 0 ? durationS : busbarDefaultClearingTimeS;
  return (faultKa * 1000 * math.sqrt(t)) / profile.busbarShortTimeDensityAPerMm2;
}

/// Short-circuit withstand of a copper busbar (IEC 61439-1 §9.3). The thermal
/// rating uses the adiabatic 1-second copper density scaled by 1/√t:
///   icwKa = (density · csaMm2 / 1000) / √durationS
/// and the peak the bar/supports must resist is ipkKa = n(faultKa) · faultKa.
BusbarWithstand checkBusbarWithstand(
  ElectricalStandardsProfile profile,
  double csaMm2,
  double faultKa, {
  double durationS = busbarDefaultClearingTimeS,
}) {
  final t = durationS > 0 ? durationS : busbarDefaultClearingTimeS;
  final oneSecondKa = (profile.busbarShortTimeDensityAPerMm2 * csaMm2) / 1000;
  final icwKa = oneSecondKa / math.sqrt(t);
  final n = profile.busbarPeakFactor(faultKa);
  final ipkKa = n * faultKa;
  final adequate = icwKa + _withstandToleranceKa >= faultKa;
  return BusbarWithstand(
    faultKa: roundTo(faultKa, 2),
    durationS: roundTo(t, 3),
    icwKa: roundTo(icwKa, 2),
    ipkKa: roundTo(ipkKa, 2),
    peakFactor: n,
    adequate: adequate,
    marginKa: roundTo(icwKa - faultKa, 2),
  );
}

/// Smallest standard copper bar whose continuous rating covers the total current.
/// Falls back to a current-density estimate when the load exceeds the table.
///
/// [minAmpacityA] floors the rating to the incomer's In (IEC 61439-1 — the bus
/// must carry the incoming device's rating, not just today's demand).
/// [minCsaMm2] floors the cross-section so the bar also meets the short-circuit
/// withstand (Icw) the prospective fault demands.
///
/// FOLD 1 (busbar short-circuit withstand): when [faultKa] > 0 the bar is ALSO
/// floored at [minCsaForWithstand]\(faultKa, durationS), so it grows to survive
/// the fault instead of merely carrying the load — and the result reports the
/// governing [BusbarSizingReason] (ampacity vs withstand) + the withstand
/// margin. With the default `faultKa = 0` no withstand floor applies and the
/// result is byte-identical to a load-only sizing (the regression guard).
BusbarResult sizeBusbar(
  ElectricalStandardsProfile profile,
  Current totalCurrent, {
  Current minAmpacityA = const Current(0),
  double minCsaMm2 = 0,
  double faultKa = 0,
  double clearingTimeS = busbarDefaultClearingTimeS,
}) {
  // The withstand floor (FOLD 1): the section the prospective fault's Icw needs.
  final withstandCsa =
      faultKa > 0 ? minCsaForWithstand(profile, faultKa, durationS: clearingTimeS) : 0.0;
  // The effective cross-section floor = max(caller floor, withstand floor).
  final csaFloor = math.max(minCsaMm2, withstandCsa);

  final requiredA = math.max(totalCurrent.amperes, minAmpacityA.amperes);
  // The section the continuous duty alone would pick (ignoring the withstand
  // floor) — used to decide which constraint GOVERNED the final selection.
  final ampacityOnlyCsa = _ampacityOnlyCsa(profile, requiredA, minCsaMm2);

  BusbarWithstand? withstandFor(double csa) =>
      faultKa > 0 ? checkBusbarWithstand(profile, csa, faultKa, durationS: clearingTimeS) : null;

  BusbarSizingReason reasonFor(double csa) =>
      faultKa > 0 && csa > ampacityOnlyCsa + 1e-9
          ? BusbarSizingReason.withstand
          : BusbarSizingReason.ampacity;

  for (final b in profile.copperBusbarTable) {
    if (b.ampacityA.amperes >= requiredA && b.csaMm2 >= csaFloor) {
      return BusbarResult(
        widthMm: b.widthMm,
        thicknessMm: b.thicknessMm,
        csaMm2: b.csaMm2,
        ampacityA: b.ampacityA,
        totalCurrentA: Current(roundTo(totalCurrent.amperes, 1)),
        sizingReason: reasonFor(b.csaMm2),
        withstand: withstandFor(b.csaMm2),
      );
    }
  }
  // Beyond the table — Round 74 (regression-2): n PARALLEL top-rung bars
  // (an orderable make-up), never an invented 0×0 density-estimate section.
  // Round 75 (regression-1) — the set is RATED at the derated
  // `top × parallelBarFactor(n)` (proximity / skin effect: adjacent flat bars
  // do not share current evenly), never n × the single-bar figure, and n is
  // chosen on that derated rating (the withstand floor stays on the SUMMED
  // section — the adiabatic Icw of n bars does add).
  final set = parallelTopBarsFor(profile, requiredA, csaFloor);
  final top = profile.copperBusbarTable.last;
  return BusbarResult(
    widthMm: top.widthMm,
    thicknessMm: top.thicknessMm,
    csaMm2: set.csaMm2,
    ampacityA: Current(roundTo(set.ampacityA, 0)),
    totalCurrentA: Current(roundTo(totalCurrent.amperes, 1)),
    sizingReason: reasonFor(set.csaMm2),
    withstand: withstandFor(set.csaMm2),
    parallelBars: set.n,
  );
}

/// Round 75 (regression-1) — the current-sharing factor of n PARALLEL
/// identical flat copper bars per phase: the set carries
/// `parallelBarFactor(n) × the single-bar rating`, never n × (proximity and
/// skin effect crowd the current into the outer bars).
///   1 → 1.0 · 2 → 1.7 · 3 → 2.35 · 4 → 2.8 · n ≥ 5 → 0.7·n
// VERIFY — notAnSniClause: DIN 43671-style ratios for vertical bars spaced
// one bar thickness apart; the assembly manufacturer confirms. They compound
// with the table's already-conservative 1430 A single 100×10 bar (DIN 43671
// gives ≈1600–1800 A for a lone bar), so the derated set errs safe.
double parallelBarFactor(int n) {
  if (n <= 1) return 1.0;
  switch (n) {
    case 2:
      return 1.7;
    case 3:
      return 2.35;
    case 4:
      return 2.8;
    default:
      return 0.7 * n;
  }
}

/// Round 75 — the ONE past-the-table rule: the smallest count n ≥ 2 of
/// parallel top-rung bars whose DERATED rating
/// (`top × [parallelBarFactor]\(n)`) covers [requiredA] and whose SUMMED
/// section covers [csaFloor]. Shared by the phase bar, the neutral bar and
/// the PE bar so every issued bar past the table is an orderable
/// `n × (100×10)` set.
({int n, double csaMm2, double ampacityA}) parallelTopBarsFor(
    ElectricalStandardsProfile profile, double requiredA, double csaFloor) {
  final top = profile.copperBusbarTable.last;
  final topA = top.ampacityA.amperes;
  var n = math.max(2, (csaFloor / top.csaMm2 - 1e-9).ceil());
  while (topA * parallelBarFactor(n) + 1e-9 < requiredA) {
    n++;
  }
  return (n: n, csaMm2: n * top.csaMm2, ampacityA: topA * parallelBarFactor(n));
}

/// The smallest flat bar — a table rung, else an `n × top` parallel set —
/// whose (derated) ampacity covers [requiredA] and whose section covers
/// [csaFloor]. Round 75: the neutral / PE bars use it so they are never an
/// invented section.
({int n, double csaMm2, double ampacityA}) _barFor(
    ElectricalStandardsProfile profile, double requiredA, double csaFloor) {
  for (final b in profile.copperBusbarTable) {
    if (b.ampacityA.amperes + 1e-9 >= requiredA && b.csaMm2 + 1e-9 >= csaFloor) {
      return (n: 1, csaMm2: b.csaMm2, ampacityA: b.ampacityA.amperes);
    }
  }
  return parallelTopBarsFor(profile, requiredA, csaFloor);
}

/// The cross-section the continuous-current duty ALONE would select (ignoring
/// any withstand floor) — the smallest tabulated bar with ampacity ≥ [requiredA]
/// and CSA ≥ [minCsaMm2], else the density estimate. Used to attribute the
/// governing [BusbarSizingReason].
double _ampacityOnlyCsa(
  ElectricalStandardsProfile profile,
  double requiredA,
  double minCsaMm2,
) {
  for (final b in profile.copperBusbarTable) {
    if (b.ampacityA.amperes >= requiredA && b.csaMm2 >= minCsaMm2) {
      return b.csaMm2;
    }
  }
  return parallelTopBarsFor(profile, requiredA, minCsaMm2).csaMm2;
}

/// Size the neutral and PE bars from the phase bar.
///   - Neutral: full-size (= phase bar) — single-phase + triplen-harmonic load
///     can make neutral current ≥ phase current, so a reduced neutral is unsafe.
///   - PE: IEC 60364-5-54 §543 adiabatic rule on the phase section S
///     (S | 16 | S/2), floored at 6 mm².
///
/// FOLD 2 (harmonics triplen-neutral oversize): when [neutralOversizeFactor] > 1
/// the neutral bar is grown to the smallest standard section ≥
/// phaseCsaMm2 · factor (IEC 60364-5-52 §523.6.3 / Annex E — the shared neutral
/// carries the summed triplen (3rd/9th…) harmonic current that can exceed the
/// phase current). [profile] supplies the standard section ladder for the
/// step-up; [triplenFraction] is recorded for the report. With the default
/// factor 1.0 the neutral is byte-identical to the phase bar (the regression
/// guard for a linear panel).
///
/// Round 44 (electrical-sim-9-neutral-bar-double-counts-withstand) — the
/// triplen factor is a CURRENT multiplier: with [phaseSizingCurrentA] given,
/// the neutral is the larger of the phase bar (already floored at the
/// short-circuit withstand section) and the smallest bar whose AMPACITY
/// covers `factor × phaseSizingCurrentA` — never `phase CSA × factor`, which
/// multiplied a withstand-governed section by a current ratio (a 75 mm² bar
/// floored by a 17.84 kA fault became a 150 mm² neutral where 75 mm² covers
/// both the fault and 1.73 × 77 A). Omitted ⇒ the legacy CSA basis.
NeutralPeBars sizeNeutralPeBars(
  double phaseCsaMm2,
  Current phaseAmpacity, {
  ElectricalStandardsProfile? profile,
  double neutralOversizeFactor = 1,
  double triplenFraction = 0,
  double? phaseSizingCurrentA,
  int phaseParallelBars = 1,
}) {
  final peTarget = phaseCsaMm2 <= 16
      ? phaseCsaMm2
      : phaseCsaMm2 <= 35
          ? 16.0
          : phaseCsaMm2 / 2;
  // Round 75 (elec-convergence-26) — past the standard table (a parallel
  // phase set, or an S/2 above the largest bar) the PE bar is an orderable
  // rung or an `n × top` set, never an invented section (a 3 × 1000 mm²
  // phase set's S/2 = 1500 mm² is no bar). Inside the table: unchanged.
  final peTop = profile?.copperBusbarTable.last.csaMm2;
  final pePast = profile != null &&
      (phaseParallelBars > 1 || (peTop != null && peTarget > peTop + 1e-9));
  final peBar = pePast ? _barFor(profile, 0, peTarget) : null;
  final pe = peBar?.csaMm2 ?? peTarget;
  final peN = peBar?.n ?? 1;

  // Triplen oversize: step the neutral up the BUSBAR ladder by the factor.
  //
  // Round 11 — it used to step the CABLE ladder (`standardSectionsMm2`, which
  // tops out at 300 mm²); it now steps the profile's copper flat-bar ladder.
  // Round 75 (elec-convergence-26) — beyond the largest bar the neutral is
  // the SAME parallel `n × top` set rule the phase bar follows
  // ([parallelTopBarsFor], derated), never `needA / density` or
  // `target.ceil()` (an invented 1221 mm² section no fabricator can order),
  // and a parallel phase set's full-size neutral is that set (n bars), never
  // one bar of the summed section.
  var neutral = phaseCsaMm2;
  var neutralN = phaseParallelBars;
  var neutralA = phaseAmpacity.amperes;
  if (profile != null &&
      neutralOversizeFactor > 1 &&
      phaseCsaMm2 > 0 &&
      phaseSizingCurrentA != null &&
      phaseSizingCurrentA > 0) {
    final needA = neutralOversizeFactor * phaseSizingCurrentA;
    // The phase bar (already floored at the withstand / incomer) is the
    // floor; grow only when its rating cannot carry the triplen current.
    if (phaseAmpacity.amperes + 1e-9 < needA) {
      final bar = _barFor(profile, needA, phaseCsaMm2);
      neutral = bar.csaMm2;
      neutralN = bar.n;
      neutralA = bar.ampacityA;
    }
    // The factor is a property of the LOAD (it feeds the feeder neutral
    // sizing upstream) — reported whenever it applies; whether the bar grew
    // is [NeutralPeBars.oversized].
    return NeutralPeBars(
      neutralCsaMm2: roundTo(neutral, 1),
      neutralAmpacityA: Current(roundTo(neutralA, 0)),
      peCsaMm2: roundTo(math.max(pe, 6), 1),
      neutralOversizeFactor: neutralOversizeFactor,
      triplenFraction: triplenFraction,
      oversized: neutral > phaseCsaMm2 + 1e-9,
      neutralParallelBars: neutralN,
      peParallelBars: peN,
      setBarWidthMm:
          neutralN > 1 || peN > 1 ? profile.copperBusbarTable.last.widthMm : 0,
      setBarThicknessMm: neutralN > 1 || peN > 1
          ? profile.copperBusbarTable.last.thicknessMm
          : 0,
    );
  } else if (profile != null && neutralOversizeFactor > 1 && phaseCsaMm2 > 0) {
    final target = phaseCsaMm2 * neutralOversizeFactor;
    final bar = _barFor(profile, 0, target);
    neutral = bar.csaMm2;
    neutralN = bar.n;
    neutralA = bar.ampacityA;
  }
  return NeutralPeBars(
    neutralCsaMm2: roundTo(neutral, 1),
    // Round 75 — the neutral bar's OWN rating (the phase bar's when it is
    // full-size), never the phase bar's figure beside a larger neutral.
    neutralAmpacityA: Current(roundTo(neutralA, 0)),
    peCsaMm2: roundTo(math.max(pe, 6), 1),
    neutralOversizeFactor: neutral > phaseCsaMm2 ? neutralOversizeFactor : 1,
    triplenFraction: neutral > phaseCsaMm2 ? triplenFraction : 0,
    oversized: neutral > phaseCsaMm2 + 1e-9,
    neutralParallelBars: neutralN,
    peParallelBars: peN,
    setBarWidthMm: profile != null && (neutralN > 1 || peN > 1)
        ? profile.copperBusbarTable.last.widthMm
        : 0,
    setBarThicknessMm: profile != null && (neutralN > 1 || peN > 1)
        ? profile.copperBusbarTable.last.thicknessMm
        : 0,
  );
}

String _fmtMm(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// Round 75 — the printed make-up of a bar: `<csa> mm²`, or for a parallel
/// set `<n> × (<w>×<t> mm) (<csa> mm²)` — the form the phase busbar line
/// already prints, so a neutral / PE set never reads as one summed bar.
String barSetSpec(double csaMm2, int n, double widthMm, double thicknessMm) =>
    n > 1 && widthMm > 0 && thicknessMm > 0
        ? '$n × (${_fmtMm(widthMm)}×${_fmtMm(thicknessMm)} mm) '
            '(${_fmtMm(csaMm2)} mm²)'
        : '${_fmtMm(csaMm2)} mm²';

/// The neutral bar's printed make-up (see [barSetSpec]).
String neutralBarSpec(NeutralPeBars b) => barSetSpec(b.neutralCsaMm2,
    b.neutralParallelBars, b.setBarWidthMm, b.setBarThicknessMm);

/// The PE bar's printed make-up (see [barSetSpec]).
String peBarSpec(NeutralPeBars b) => barSetSpec(
    b.peCsaMm2, b.peParallelBars, b.setBarWidthMm, b.setBarThicknessMm);
