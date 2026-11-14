// Backlog W-1 / W-2 / W-3 (2026-11-14) — the app view of every cold-water
// storage tank's FILL: capacity, refill time and the fill flow the sizer
// sized its feed on (`sizing/tank_fill.dart`). Read-only: the sizer already
// applied the fill flow; this only reports it (inspector, calc report,
// Review), never a parallel re-derivation of a size.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart' show EdgeSizing;
import 'package:mechx_engine/sizing/tank_fill.dart';
import 'package:mechx_engine/units.dart';

import 'app_state.dart' show dailyDemandLitresProvider, mainsHeadProvider;
import 'network_store.dart' show sizingNetworkProvider;
import 'project_store.dart' show projectControllerProvider;
import 'sizing_store.dart' show sizingProvider;
import 'fire_store.dart' show fireTankReservesProvider;

/// One cold-water storage tank and its fill.
class TankFill {
  final String tankId;
  final String sheetId;
  final bool roof;

  /// The tank's entered capacity (litres), null when unset.
  final double? capacityLitres;

  /// The refill time it fills in (its own, else the type default).
  final double refillHours;

  /// True when the refill time is the type default (not entered).
  final bool defaultRefill;

  /// capacity / refill time; null without a capacity (never fabricated).
  final FlowRate? fillFlow;

  /// True when a drawn cold-water pipe carries water INTO the tank (a meter
  /// feed or a transfer / fill line) on the solved flow.
  final bool fillDrawn;

  const TankFill({
    required this.tankId,
    required this.sheetId,
    required this.roof,
    required this.capacityLitres,
    required this.refillHours,
    required this.defaultRefill,
    required this.fillFlow,
    required this.fillDrawn,
  });
}

/// Pure core of [tankFillsProvider]: every storage tank on the cold-water
/// service (never a fire tank: a tank with a fire pipe is skipped), sorted by
/// id.
List<TankFill> tankFillsOf(Network net, Map<String, EdgeSizing> sizing) {
  final cold = <String, List<NetEdge>>{};
  final fire = <String>{};
  for (final e in net.edges) {
    if (e.service == ServiceType.fireHydrant ||
        e.service == ServiceType.fireSprinkler) {
      fire
        ..add(e.fromId)
        ..add(e.toId);
    }
    if (e.service != ServiceType.coldWater) continue;
    (cold[e.fromId] ??= []).add(e);
    (cold[e.toId] ??= []).add(e);
  }
  final out = <TankFill>[];
  final tanks = [
    for (final n in net.nodes)
      if (isStorageTankNode(n) && cold.containsKey(n.id) && !fire.contains(n.id))
        n,
  ]..sort((a, b) => a.id.compareTo(b.id));
  for (final t in tanks) {
    final drawn = cold[t.id]!.any((e) {
      final sz = sizing[e.id];
      if (sz == null || sz.flow.cubicMetersPerSecond <= 0) return false;
      final from = sz.flowFromId;
      return from != null && from != t.id;
    });
    out.add(TankFill(
      tankId: t.id,
      sheetId: t.sheetId,
      roof: t.component == NodeComponent.roofTank,
      capacityLitres: t.tankCapacityLitres,
      refillHours: tankRefillHoursOf(t),
      defaultRefill: t.tankRefillHours == null,
      fillFlow: tankFillFlow(t),
      fillDrawn: drawn,
    ));
  }
  return out;
}

/// Backlog W-1 — every cold-water storage tank with its fill.
final tankFillsProvider = Provider<List<TankFill>>((ref) => tankFillsOf(
    ref.watch(sizingNetworkProvider), ref.watch(sizingProvider)));

/// Backlog W-2 — the mains-pressure verdict of every water meter feeding a
/// ground tank (`meterFeedsToGroundTanks`), judged against the project's
/// available mains head ([mainsHeadProvider]) at the feed's SIZED flow and
/// bores (the one solve). Judge-only; sorted by meter id.
final mainsPressureChecksProvider = Provider<List<MainsPressureCheck>>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final feeds = meterFeedsToGroundTanks(net);
  if (feeds.isEmpty) return const [];
  final sizing = ref.watch(sizingProvider);
  final project = ref.watch(projectControllerProvider);
  final available = Head(ref.watch(mainsHeadProvider));
  final sized = {
    for (final e in sizing.entries)
      e.key: (flow: e.value.flow, diameter: e.value.diameter),
  };
  return [
    for (final f in feeds)
      ?mainsPressureCheck(
        net: net,
        feed: f,
        sized: sized,
        available: available,
        lengthOf: (e) => edgeLength(e, net,
                calibrationBySheet: project.calibrations,
                building: project.building,
                mounting: project.mounting)
            .meters,
        elevationOf: (n) =>
            nodeElevation(n, project.building, project.mounting).meters,
      ),
  ];
});

/// Backlog W-4 (2026-11-14) — THE domestic water reserve (the one source
/// the inspector headline, the Building page and the calc report read):
/// every storage tank with a cold-water pipe; a tank also on a fire service
/// counts its capacity less the fire reserve the app computes for it
/// ([fireTankReservesProvider]) and, with no computed reserve, is excluded
/// (named) rather than guessed; a tank with no capacity is excluded and
/// named. Days = stored / [dailyDemandLitresProvider]. Report only — the
/// owner's decision: the fill rate is outside the designer's control and is
/// not judged.
final waterReserveProvider = Provider<WaterReserve>((ref) {
  final net = ref.watch(sizingNetworkProvider);
  final cold = <String>{};
  final fire = <String>{};
  for (final e in net.edges) {
    final set = e.service == ServiceType.coldWater
        ? cold
        : (e.service == ServiceType.fireHydrant ||
                e.service == ServiceType.fireSprinkler)
            ? fire
            : null;
    set?..add(e.fromId)..add(e.toId);
  }
  final fireReserve = {
    for (final r in ref.watch(fireTankReservesProvider))
      r.tankId: r.requiredLitres,
  };
  final tanks = <ReserveTank>[
    for (final n in [
      for (final n in net.nodes)
        if (isStorageTankNode(n) && cold.contains(n.id)) n,
    ]..sort((a, b) => a.id.compareTo(b.id)))
      (
        tankId: n.id,
        roof: n.component == NodeComponent.roofTank,
        // A shared domestic + fire tank with no computed fire reserve has
        // no clean domestic share: excluded (as "no capacity").
        capacityLitres: fire.contains(n.id) && !fireReserve.containsKey(n.id)
            ? null
            : n.tankCapacityLitres,
        fireReserveLitres: fire.contains(n.id) ? (fireReserve[n.id] ?? 0) : 0,
      ),
  ];
  return WaterReserve(
      tanks: tanks, dailyLitres: ref.watch(dailyDemandLitresProvider));
});
