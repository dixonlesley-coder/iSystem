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
  final loopHead = headLossHazenWilliams(
    flow: recircFlow,
    length: loopLength,
    diameter: returnDiameter,
    hazenWilliamsC: hazenWilliamsC,
  );

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
