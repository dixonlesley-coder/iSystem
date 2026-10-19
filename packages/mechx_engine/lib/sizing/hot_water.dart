/// §8 hot-water recirculation sizing path.
///
/// A hot-water recirculation loop continuously circulates a small flow of hot
/// water around the return pipework so that water standing in the loop never
/// cools below the design temperature. The loop must carry away exactly the
/// heat the pipework loses to its surroundings, so that the water arriving back
/// at the heater/calorifier has dropped no more than an allowable temperature
/// difference ΔT.
///
/// This module composes three concerns and owns none of their physics:
///   • the energy balance that sets the *recirculation flow* (here);
///   • the friction the recirc pump must overcome around the return loop —
///     delegated to [headLossHazenWilliams] in the pressurized-flow kernel;
///   • the pump/motor selection — delegated to [sizePump] (§8 pump path).
///
/// It is strictly the recirculation code path (§12): it does NOT reuse the
/// pressurized-supply, gravity-drainage, or fire-flow sizing routines beyond
/// the shared Hazen–Williams friction primitive.
///
/// Pure Dart — zero Flutter imports. All quantities cross module boundaries as
/// typed SI quantities from `units.dart`.
///
/// Energy balance (steady state):
///   Q_recirc [m³/s] = heatLoss [W] / (ρ · c · ΔT)
/// where ρ is the water density (kg/m³), c the specific heat (J/(kg·K)), and ΔT
/// the allowable return-temperature drop (K). The pump head is the friction of
/// driving Q_recirc once around the return loop.
///
/// Assumptions are flagged `// VERIFY`.
library;

import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/standards/sni.dart' show StandardValue, VerificationStatus;
import 'package:mechx_engine/units.dart';

/// Specific heat capacity of water at constant pressure, c [J/(kg·K)].
///
/// Used in the recirculation energy balance Q = heatLoss / (ρ·c·ΔT).
const double waterSpecificHeat = 4186; // J/(kg·K) // VERIFY

/// Assumed hot-water FLOW (supply) temperature leaving the heater/calorifier
/// (°C). The modelled return temperature is this minus the loop temperature
/// drop. 60 °C is a common stored/flow temperature that satisfies the
/// anti-Legionella requirement at the outlet. // VERIFY against SNI / local
/// hot-water guidance (stored vs delivered temperature).
const double kHotWaterFlowTempC = 60.0;

/// Anti-Legionella minimum acceptable RETURN temperature (°C) for the
/// recirculation loop. Legionella proliferates below ~50 °C and is controlled
/// when water is kept above ~55–60 °C throughout the system, including at the
/// return. We flag a modelled return temperature below this floor.
/// // VERIFY against SNI / WHO Legionella guidance (commonly 55 °C at the return,
/// 60 °C stored).
const double kLegionellaMinReturnTempC = 55.0;

/// The sized recirculation duty: the circulating flow, the loop friction head,
/// and the selected recirc pump.
class HotWaterRecircDesign {
  /// Volumetric flow circulated around the loop to replace the heat lost.
  final FlowRate recircFlow;

  /// Friction head the pump must overcome to drive [recircFlow] once around
  /// the return loop.
  final Head loopHead;

  /// Round 16 — the RETURN-leg length the loop head was computed over (the
  /// [sizeHotWaterRecirculation] `loopLength`), reported separately from the
  /// head so the report never prints a head in metres of water as if it were
  /// a pipe length.
  final Length loopLength;

  /// Pump/motor selection for the recirculation duty point.
  final PumpDuty pump;

  /// Modelled water temperature ARRIVING back at the heater (°C): the assumed
  /// flow temperature [kHotWaterFlowTempC] minus the design loop drop
  /// ([allowableDropK]). Compared against [kLegionellaMinReturnTempC] by
  /// [legionellaRisk] — a low return temperature is an anti-Legionella concern.
  final double returnTempC;

  const HotWaterRecircDesign({
    required this.recircFlow,
    required this.loopHead,
    required this.pump,
    required this.returnTempC,
    this.loopLength = const Length(0),
  });

  /// `true` when the modelled [returnTempC] falls below the anti-Legionella
  /// floor [kLegionellaMinReturnTempC] — the loop is not kept hot enough at the
  /// return and risks bacterial growth. // VERIFY threshold vs SNI guidance.
  bool get legionellaRisk => returnTempC < kLegionellaMinReturnTempC;
}

/// Size a hot-water recirculation loop.
///
/// Parameters:
/// - [heatLoss]        — total heat the loop sheds to its surroundings (W).
/// - [loopLength]      — total length of the recirculation return run (m).
/// - [returnDiameter]  — inside diameter of the return pipe (m).
/// - [allowableDropK]  — maximum permitted return-temperature drop ΔT (K);
///                       defaults to 5 K. // VERIFY: typical design ΔT.
/// - [flowTempC]       — assumed flow (supply) temperature leaving the heater
///                       (°C); defaults to [kHotWaterFlowTempC]. The modelled
///                       return temperature is `flowTempC − allowableDropK`.
/// - [hazenWilliamsC]  — Hazen–Williams roughness coefficient for the return
///                       pipe; defaults to 150 (smooth copper/plastic).
/// - [density]         — water density ρ (kg/m³); defaults to 1000.
///
/// Returns a [HotWaterRecircDesign] with the circulating flow, loop head, pump
/// selection, and the modelled return temperature (for the anti-Legionella
/// check, [HotWaterRecircDesign.legionellaRisk]).
HotWaterRecircDesign sizeHotWaterRecirculation({
  required Power heatLoss,
  required Length loopLength,
  required Diameter returnDiameter,
  double allowableDropK = 5.0,
  double flowTempC = kHotWaterFlowTempC,
  double hazenWilliamsC = 150.0,
  double density = 1000.0,
  List<({Length length, Diameter diameter})> supplyPath = const [],
  List<double>? supplyPathFlowShares,
}) {
  assert(heatLoss.watts >= 0, 'heatLoss must be non-negative');
  assert(allowableDropK > 0, 'allowableDropK must be positive');
  assert(returnDiameter.meters > 0, 'returnDiameter must be positive');
  assert(loopLength.meters >= 0, 'loopLength must be non-negative');

  // Energy balance: the recirc flow carries the loop heat loss away within the
  // allowable temperature drop. Q = heatLoss / (ρ · c · ΔT)  [m³/s].
  final recircFlow = FlowRate(
    heatLoss.watts / (density * waterSpecificHeat * allowableDropK),
  );

  // Friction of driving that flow once around the return loop. Hazen–Williams
  // is the conventional plumbing friction law and folds roughness into C.
  //
  // Round 16 (plumbing-plant-hw-recirc-loop-head) — the circulating flow also
  // passes OUT along the circulated supply pipework ([supplyPath], the index
  // run from the heater, each segment at its OWN sized bore) before the return
  // leg brings it back, so the loop head is Σ over those segments plus the
  // return leg. Empty [supplyPath] ⇒ the return leg alone (byte-identical).
  var loopHeadM = headLossHazenWilliams(
    flow: recircFlow,
    length: loopLength,
    diameter: returnDiameter,
    hazenWilliamsC: hazenWilliamsC,
  ).meters;
  // Round 26 (hot-water-2-multi-loop-full-flow-one-loop) — PARALLEL return
  // loops each carry only their share of the circulating flow: segment i of
  // the index loop carries `supplyPathFlowShares[i] × recircFlow` (a shared
  // trunk the sum of the loops through it, an unshared riser its own loop's
  // share). Null ⇒ every segment at the full flow (one loop, byte-identical).
  assert(supplyPathFlowShares == null ||
      supplyPathFlowShares.length == supplyPath.length);
  for (var i = 0; i < supplyPath.length; i++) {
    final seg = supplyPath[i];
    if (seg.length.meters <= 0 || seg.diameter.meters <= 0) continue;
    final share = supplyPathFlowShares?[i] ?? 1.0;
    if (share <= 0) continue;
    loopHeadM += headLossHazenWilliams(
      flow: FlowRate(recircFlow.cubicMetersPerSecond * share),
      length: seg.length,
      diameter: seg.diameter,
      hazenWilliamsC: hazenWilliamsC,
    ).meters;
  }
  final loopHead = Head(loopHeadM);

  // Select the recirc pump for this (flow, head) duty point using the §8 pump
  // path's default pump/motor efficiencies.
  final pump = sizePump(flow: recircFlow, head: loopHead);

  // Modelled return temperature: the loop is SIZED so the recirc flow carries
  // the heat loss within the allowable drop ΔT (Q = heatLoss / (ρ·c·ΔT)), so by
  // construction the temperature arriving back is flowTemp − ΔT. We surface it
  // explicitly so the anti-Legionella check ([legionellaRisk]) can flag a design
  // ΔT large enough to pull the return below the safe floor. // VERIFY model.
  final returnTempC = flowTempC - allowableDropK;

  return HotWaterRecircDesign(
    recircFlow: recircFlow,
    loopHead: loopHead,
    pump: pump,
    returnTempC: returnTempC,
    loopLength: loopLength,
  );
}

/// Convenience estimate of loop [heatLoss] from its length, assuming a uniform
/// heat-loss rate per metre of insulated pipe.
///
/// heatLoss [W] = loopLength [m] · lossPerMetreW [W/m].
Power heatLossFromLength({
  required Length loopLength,
  double lossPerMetreW = 25.0, // W/m for insulated DN pipe // VERIFY
}) =>
    Power(loopLength.meters * lossPerMetreW);

/// Round 16 — the default inside diameter of an UNDRAWN recirculation return
/// leg (a DN20 return is the common minimum). // VERIFY — confirm against the
/// drawn return pipe when one is modelled.
const Diameter kDefaultRecircReturnDiameter = Diameter(0.020);

/// Round 26 (hot-water-2-house-fabricated-recirc-pump) — the developed length
/// (heater → farthest hot-water fixture, m) above which a hot-water system is
/// ASSUMED to need recirculation when no return is drawn. IPC 607.2 / UPC
/// practice: circulation (or heat trace) where the developed length exceeds
/// ~50 ft (15 m). At or below it (a house, a small wing) no recirc pump, way,
/// HWR leg or report line is fabricated. `// VERIFY` notAnSniClause.
const double kRecircMinDevelopedLengthM = 15.0;

/// Round 12 (report-recompute-verify-items-incomplete) — the unverified
/// constants behind the PRINTED hot-water recirculation line (loop heat loss →
/// recirc flow), surfaced in the calc report's Unverified section.
const List<StandardValue<Object?>> hotWaterRecircVerifyChecklist = [
  StandardValue<Object?>(25.0,
      unit: 'W/m',
      citation: 'HW recirculation loop heat loss (heatLossFromLength default)',
      status: VerificationStatus.notAnSniClause,
      note: 'Representative 25 W/m loss for insulated DN pipe — general '
          'practice; verify against the insulation specification.'),
  StandardValue<Object?>(waterSpecificHeat,
      unit: 'J/(kg·K)',
      citation: 'Specific heat of water cp',
      status: VerificationStatus.notAnSniClause,
      note: 'Physical property 4186 J/(kg·K) at ~20 °C (varies slightly with '
          'temperature) — not an SNI clause.'),
  StandardValue<Object?>(kRecircMinDevelopedLengthM,
      unit: 'm',
      citation: 'IPC 607.2 / UPC — HW circulation threshold (developed length)',
      status: VerificationStatus.notAnSniClause,
      note: 'Recirculation is assumed only when no return is drawn AND the '
          'developed length heater → farthest fixture exceeds 15 m (~50 ft) — '
          'general practice, not an SNI clause.'),
];
