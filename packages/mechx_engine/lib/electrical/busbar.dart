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
  // Beyond the table — estimate a section from the current density.
  final density = profile.copperCurrentDensityAPerMm2;
  final csa = math
      .max((requiredA / density).ceil(), csaFloor.ceil())
      .toDouble();
  return BusbarResult(
    widthMm: 0,
    thicknessMm: 0,
    csaMm2: csa,
    ampacityA: Current(roundTo(csa * density, 0)),
    totalCurrentA: Current(roundTo(totalCurrent.amperes, 1)),
    sizingReason: reasonFor(csa),
    withstand: withstandFor(csa),
  );
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
  return math
      .max((requiredA / profile.copperCurrentDensityAPerMm2).ceil(), minCsaMm2.ceil())
      .toDouble();
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
NeutralPeBars sizeNeutralPeBars(
  double phaseCsaMm2,
  Current phaseAmpacity, {
  ElectricalStandardsProfile? profile,
  double neutralOversizeFactor = 1,
  double triplenFraction = 0,
}) {
  final pe = phaseCsaMm2 <= 16
      ? phaseCsaMm2
      : phaseCsaMm2 <= 35
          ? 16.0
          : phaseCsaMm2 / 2;

  // Triplen oversize: step the neutral up the standard ladder by the factor.
  var neutral = phaseCsaMm2;
  if (profile != null && neutralOversizeFactor > 1 && phaseCsaMm2 > 0) {
    final target = phaseCsaMm2 * neutralOversizeFactor;
    for (final s in profile.standardSectionsMm2) {
      if (s >= target) {
        neutral = s;
        break;
      }
    }
  }
  // The bar's continuous rating tracks the phase bar (the oversize is a thermal
  // headroom for the harmonic neutral RMS, not a higher continuous duty).
  return NeutralPeBars(
    neutralCsaMm2: roundTo(neutral, 1),
    neutralAmpacityA: Current(roundTo(phaseAmpacity.amperes, 0)),
    peCsaMm2: roundTo(math.max(pe, 6), 1),
    neutralOversizeFactor: neutral > phaseCsaMm2 ? neutralOversizeFactor : 1,
    triplenFraction: neutral > phaseCsaMm2 ? triplenFraction : 0,
  );
}
