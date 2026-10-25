/// Round 55 (plumbing-hvac-convergence-5-hot-water-never-pressure-solved) —
/// the HOT-WATER pressure field, carried through each water heater from the
/// solved COLD field.
///
/// Every pressure surface (pump head, the SNI-minimum / comfort verdicts, the
/// over-pressure judges, the heatmap and the node probe) used to solve the
/// cold-water service only, so the heater and the whole hot distribution were
/// invisible: a hotel's top-floor hot shower (usually the index fixture) never
/// sized the pump, and the lower floors' hot showers sat over the 392 / 490 kPa
/// limits unflagged while the cold side passed.
///
/// MODEL — each hot-water component is fed by its HEATER: a plant node on
/// both a cold and a hot edge (the hot tree's root, the node the sizer's
/// Round-48 make-up rule loads on the cold side). The heater's hot outlet
/// sits at its cold-side residual less a heater / calorifier pressure loss
/// ([heaterLoss], default 0 — `// VERIFY notAnSniClause`: the vessel and
/// mixing-valve loss is a product datum, not modelled), and the hot field is
/// the ordinary pressurized solve ([solvePressurized], hot service, sourced
/// at the heater with that head as its delivered source head). The flowing
/// and no-flow fields are solved separately, from the heater's flowing and
/// no-flow cold residuals. A hot circulator's head is NOT added (the
/// recirculation pump moves the loop flow, it does not boost the draw-off —
/// conservative).
///
/// [HotWaterField.shortfall] is the largest head by which a heater's inlet
/// falls short of what its hot index fixture needs (the hot solve's own
/// required head): the cold source must develop that much more for the hot
/// side to hold the target. No hot-water edge ⇒ the empty field (every
/// cold-only project byte-identical).
///
/// Pure Dart, ZERO Flutter imports.
library;

import '../geometry/building.dart';
import '../geometry/scale_calibration.dart';
import '../hydraulics.dart';
import '../sizing/network_sizing.dart';
import '../units.dart';
import 'network.dart';
import 'pressure_solve.dart';

/// The hot-water field carried through the heaters (see the library doc).
class HotWaterField {
  /// Flowing residual at every hot-water node reached from a heater.
  final Map<String, Pressure> residual;

  /// No-flow static at every hot-water node reached from a heater.
  final Map<String, Pressure> noFlowStatic;

  /// The hot DELIVERY nodes (hot fixtures / loaded open ends).
  final Set<String> deliveryNodeIds;

  /// The largest head (≥ 0) by which a heater's inlet falls short of what its
  /// hot index fixture needs to hold the target residual.
  final Head shortfall;

  /// The hot delivery node with the least residual (null when none).
  final String? criticalNodeId;

  /// The heater node of each solved hot component.
  final Set<String> heaterIds;

  const HotWaterField({
    this.residual = const {},
    this.noFlowStatic = const {},
    this.deliveryNodeIds = const {},
    this.shortfall = const Head(0),
    this.criticalNodeId,
    this.heaterIds = const {},
  });

  bool get isEmpty => residual.isEmpty;

  /// The residual at [criticalNodeId] (null when none).
  Pressure? get criticalResidual =>
      criticalNodeId == null ? null : residual[criticalNodeId];

  static const empty = HotWaterField();
}

/// The heater of every hot-water component of [net]: a PLANT node on both a
/// cold-water and a hot-water edge (a component's lowest id when it holds
/// several). Keyed by heater id → the component's node ids. A hot component
/// with no such plant has no known inlet and is absent.
Map<String, Set<String>> hotWaterHeaters(Network net) {
  final cold = <String>{}, hotAdj = <String, List<String>>{};
  for (final e in net.edges) {
    if (e.service == ServiceType.coldWater) cold.addAll([e.fromId, e.toId]);
    if (e.service == ServiceType.hotWater) {
      (hotAdj[e.fromId] ??= []).add(e.toId);
      (hotAdj[e.toId] ??= []).add(e.fromId);
    }
  }
  final out = <String, Set<String>>{};
  final seen = <String>{};
  for (final start in (hotAdj.keys.toList()..sort())) {
    if (seen.contains(start)) continue;
    final comp = <String>{start};
    final stack = [start];
    seen.add(start);
    while (stack.isNotEmpty) {
      for (final o in hotAdj[stack.removeLast()] ?? const <String>[]) {
        if (seen.add(o)) {
          comp.add(o);
          stack.add(o);
        }
      }
    }
    final heaters = [
      for (final id in comp)
        if (cold.contains(id) && net.nodeById(id)?.role == NodeRole.plant) id,
    ]..sort();
    if (heaters.isNotEmpty) out[heaters.first] = comp;
  }
  return out;
}

/// Solve the hot-water field through each heater from the solved cold field
/// ([coldResidual] / [coldNoFlow], keyed by node id). See the library doc.
HotWaterField solveHotWaterFromHeaters({
  required Network net,
  required Map<String, Pressure> coldResidual,
  required Map<String, Pressure> coldNoFlow,
  required Map<String, EdgeSizing> sizing,
  required Map<String, ScaleCalibration> calibrationBySheet,
  required BuildingLevels building,
  required Pressure targetResidual,
  MountingHeights mounting = const MountingHeights(),
  Pressure? prvSetpoint,
  Head heaterLoss = const Head(0),
}) {
  final heaters = hotWaterHeaters(net);
  if (heaters.isEmpty) return HotWaterField.empty;
  final flows = <String, FlowRate>{
    for (final e in net.edges)
      if (e.service == ServiceType.hotWater && sizing[e.id] != null)
        e.id: sizing[e.id]!.flow,
  };
  final residual = <String, Pressure>{};
  final noFlow = <String, Pressure>{};
  final delivery = <String>{};
  final solved = <String>{};
  var shortfall = 0.0;
  for (final heater in (heaters.keys.toList()..sort())) {
    final inP = coldResidual[heater];
    if (inP == null) continue;
    final inlet = headFromPressure(inP).meters - heaterLoss.meters;
    final staticP = coldNoFlow[heater] ?? inP;
    final staticInlet = headFromPressure(staticP).meters - heaterLoss.meters;
    PressureSolution solve(double head) => solvePressurized(
          net: net,
          service: ServiceType.hotWater,
          sourceId: heater,
          edgeFlows: flows,
          sizing: sizing,
          calibrationBySheet: calibrationBySheet,
          building: building,
          targetResidual: targetResidual,
          mounting: mounting,
          prvSetpoint: prvSetpoint,
          moverHeads: {heater: Head(head)},
        );
    final flowing = solve(inlet);
    final still = solve(staticInlet);
    solved.add(heater);
    for (final e in flowing.residualPressure.entries) {
      if (e.key == heater) continue;
      residual[e.key] = e.value;
    }
    for (final e in still.noFlowStaticPressure.entries) {
      if (e.key == heater) continue;
      noFlow[e.key] = e.value;
    }
    delivery.addAll(flowing.deliveryNodeIds);
    // The hot index fixture's need at the heater outlet vs what arrives.
    final need = flowing.requiredPumpHead.meters;
    if (flowing.deliveryNodeIds.isNotEmpty && need - inlet > shortfall) {
      shortfall = need - inlet;
    }
  }
  String? critical;
  for (final id in (delivery.toList()..sort())) {
    final r = residual[id];
    if (r == null) continue;
    if (critical == null || r.pascals < residual[critical]!.pascals - 1e-9) {
      critical = id;
    }
  }
  return HotWaterField(
    residual: residual,
    noFlowStatic: noFlow,
    deliveryNodeIds: delivery,
    shortfall: Head(shortfall),
    criticalNodeId: critical,
    heaterIds: solved,
  );
}

/// [cold] (an upfeed solve) with the hot-water field merged in. The caller
/// passes [requiredPumpHead] when it raised the source head by
/// [HotWaterField.shortfall] (and re-solved the cold field at it); the hot
/// critical node then governs ([hotGoverns]). The verdict stays falsifiable:
/// a hot delivery node below [targetResidual] (500 Pa slack, the verdict
/// ladder's) clears [PressureSolution.targetHeldByDesign] and becomes the
/// critical node when it is the least-served one.
/// Round 57 (plumbing-hvac-convergence-7-dual-fixture-cold-pressure-masked-
/// by-hot) — a dual-fed fixture (a shower on a cold AND a hot edge) is ONE
/// node id in both fields, so a last-writer-wins spread let its hot figure
/// replace the cold one and a hot-side PRV hid a cold over-pressure. Merge
/// per JUDGE: the RESIDUAL (SNI floor / below-target / heatmap) takes the
/// LEAST of the two services, the NO-FLOW STATIC (the over-pressure judge)
/// the WORST (largest); a key in one map only passes through, so a
/// cold-only project is byte-identical.
Map<String, Pressure> mergeLeastResidual(
    Map<String, Pressure> cold, Map<String, Pressure> hot) {
  final out = {...cold};
  hot.forEach((id, p) {
    final c = out[id];
    out[id] = c == null || p.pascals < c.pascals ? p : c;
  });
  return out;
}

/// The worst (largest) of the two services' no-flow static per node — see
/// [mergeLeastResidual].
Map<String, Pressure> mergeWorstStatic(
    Map<String, Pressure> cold, Map<String, Pressure> hot) {
  final out = {...cold};
  hot.forEach((id, p) {
    final c = out[id];
    out[id] = c == null || p.pascals > c.pascals ? p : c;
  });
  return out;
}

PressureSolution mergeHotWaterField(
  PressureSolution cold,
  HotWaterField hot, {
  required Pressure targetResidual,
  Head? requiredPumpHead,
  bool hotGoverns = false,
}) {
  if (hot.isEmpty && requiredPumpHead == null) return cold;
  final hc = hot.criticalNodeId;
  final hr = hot.criticalResidual;
  var held = cold.targetHeldByDesign;
  if (hr != null && hr.pascals < targetResidual.pascals - 500) held = false;
  var critical = cold.criticalNodeId;
  if (hc != null && hr != null) {
    if (hotGoverns) {
      critical = hc;
    } else if (!held) {
      final cr = cold.residualPressure[cold.criticalNodeId];
      if (cr == null ||
          hr.pascals < cr.pascals - 1e-9 ||
          cold.targetHeldByDesign) {
        critical = hc;
      }
    }
  }
  return PressureSolution(
    residualPressure: mergeLeastResidual(cold.residualPressure, hot.residual),
    requiredPumpHead: requiredPumpHead ?? cold.requiredPumpHead,
    criticalNodeId: critical,
    targetHeldByDesign: held,
    noFlowStaticPressure:
        mergeWorstStatic(cold.noFlowStaticPressure, hot.noFlowStatic),
    deliveryNodeIds: {...cold.deliveryNodeIds, ...hot.deliveryNodeIds},
  );
}

/// [cold] (a downfeed solve) with the hot-water field merged in: the critical
/// node is the least-residual delivery node over both services, and the
/// booster shortfall is re-read there.
DownfeedSolution mergeHotWaterDownfeed(
  DownfeedSolution cold,
  HotWaterField hot, {
  required Pressure targetResidual,
}) {
  if (hot.isEmpty) return cold;
  var critical = cold.criticalNodeId;
  var minR = cold.minResidual;
  final hc = hot.criticalNodeId;
  if (hc != null && hot.residual[hc]!.pascals < minR.pascals - 1e-9) {
    critical = hc;
    minR = hot.residual[hc]!;
  }
  final short = targetResidual.pascals - minR.pascals;
  final booster = short > 0 ? headFromPressure(Pressure(short)) : const Head(0);
  return DownfeedSolution(
    residualPressure: mergeLeastResidual(cold.residualPressure, hot.residual),
    criticalNodeId: critical,
    minResidual: minR,
    boosterHeadRequired: booster.meters > cold.boosterHeadRequired.meters
        ? booster
        : cold.boosterHeadRequired,
    targetHeldByDesign: cold.targetHeldByDesign,
    noFlowStaticPressure:
        mergeWorstStatic(cold.noFlowStaticPressure, hot.noFlowStatic),
    deliveryNodeIds: {...cold.deliveryNodeIds, ...hot.deliveryNodeIds},
  );
}
