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

/// Smallest standard copper bar whose continuous rating covers the total current.
/// Falls back to a current-density estimate when the load exceeds the table.
///
/// [minAmpacityA] floors the rating to the incomer's In (IEC 61439-1 — the bus
/// must carry the incoming device's rating, not just today's demand).
/// [minCsaMm2] floors the cross-section so the bar also meets the short-circuit
/// withstand (Icw) the prospective fault demands.
BusbarResult sizeBusbar(
  ElectricalStandardsProfile profile,
  Current totalCurrent, {
  Current minAmpacityA = const Current(0),
  double minCsaMm2 = 0,
}) {
  final requiredA = math.max(totalCurrent.amperes, minAmpacityA.amperes);
  for (final b in profile.copperBusbarTable) {
    if (b.ampacityA.amperes >= requiredA && b.csaMm2 >= minCsaMm2) {
      return BusbarResult(
        widthMm: b.widthMm,
        thicknessMm: b.thicknessMm,
        csaMm2: b.csaMm2,
        ampacityA: b.ampacityA,
        totalCurrentA: Current(roundTo(totalCurrent.amperes, 1)),
      );
    }
  }
  // Beyond the table — estimate a section from the current density.
  final density = profile.copperCurrentDensityAPerMm2;
  final csa = math
      .max((requiredA / density).ceil(), minCsaMm2.ceil())
      .toDouble();
  return BusbarResult(
    widthMm: 0,
    thicknessMm: 0,
    csaMm2: csa,
    ampacityA: Current(roundTo(csa * density, 0)),
    totalCurrentA: Current(roundTo(totalCurrent.amperes, 1)),
  );
}

/// Size the neutral and PE bars from the phase bar.
///   - Neutral: full-size (= phase bar) — single-phase + triplen-harmonic load
///     can make neutral current ≥ phase current, so a reduced neutral is unsafe.
///   - PE: IEC 60364-5-54 §543 adiabatic rule on the phase section S
///     (S | 16 | S/2), floored at 6 mm².
NeutralPeBars sizeNeutralPeBars(double phaseCsaMm2, Current phaseAmpacity) {
  final pe = phaseCsaMm2 <= 16
      ? phaseCsaMm2
      : phaseCsaMm2 <= 35
          ? 16.0
          : phaseCsaMm2 / 2;
  return NeutralPeBars(
    neutralCsaMm2: roundTo(phaseCsaMm2, 1),
    neutralAmpacityA: Current(roundTo(phaseAmpacity.amperes, 0)),
    peCsaMm2: roundTo(math.max(pe, 6), 1),
  );
}
