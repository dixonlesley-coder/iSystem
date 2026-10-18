/// The MEP→electrical AUTO-FEED seam (the merge's unified payoff): the rotating
/// equipment the mechanical engine has already sized (pump / fan / fire-pump
/// duties) is assembled into electrical loads and sized circuits, ready to fold
/// into the electrical project via `ElectricalProjectController.syncMepEquipment`.
///
/// These are GENERATED RENDERS of the existing mechanical solve (guardrail §12.5)
/// — the duty providers in `solve_store`/`fire_store` are the single source; the
/// electrical current is derived here (A5 `load_list.dart`), never re-entered.
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/riser_tags.dart' show equipmentDetail;
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/sizing/fan.dart' show FanDuty;
import 'package:mechx_engine/sizing/network_sizing.dart'
    show serviceComponentRoots;
import 'package:mechx_engine/sizing/pump.dart' show PumpDuty;
import 'package:mechx_engine/units.dart';

import 'annotation_store.dart';
import 'app_state.dart'
    show
        CoolingLoadMethod,
        coolingLoadMethodProvider,
        ductSettingsProvider,
        kSupplyService;
import 'fire_store.dart';
import 'network_store.dart';
import 'project_store.dart';
import 'sizing_store.dart' show parallelLegEdgeIdsProvider, sizingProvider;
import 'solve_store.dart';

/// Nominal voltage the MEP equipment panel is fed at (3-phase). The derived FLA
/// is computed against this; equipment phases come from the descriptor.
const Voltage mepPanelVoltage = Voltage(400);

/// The machine-supplied names of the SOLVED-DUTY equipment loads. Named
/// constants (not inline literals) so [mepMintedCircuitNames] can enumerate
/// exactly what the app itself mints — see that set's contract.
const String kSupplyPumpLoadName = 'Supply / booster pump';
const String kSupplyFanLoadName = 'Supply air fan';
const String kFirePumpLoadName = 'Fire pump';
const String kExhaustFanLoadName = 'Exhaust air fan';
const String kHwRecircPumpLoadName = 'HW recirculation pump';

/// Every circuit NAME the MEP auto-feed can itself mint: the placed-equipment
/// path names a way after its [NodeComponent.label], the solved-duty path after
/// the constants above, and [MepLoadSource.label] is A5's own fallback.
///
/// Used by `syncMepEquipment` (C1) to tell an UNTOUCHED derived way from one the
/// engineer has made their own: a way still carrying a minted name (and no
/// override of any kind) is byte-identical to what a re-mint would produce, so
/// dropping it when its source equipment disappears loses nothing. A way whose
/// name is NOT in this set was renamed by hand and is PARKED instead.
///
/// Derived from the engine enums, so a new electrical-load component joins the
/// set automatically — it can never silently start parking pristine ways.
final Set<String> mepMintedCircuitNames = {
  for (final c in NodeComponent.values)
    if (c.isElectricalLoad) c.label,
  for (final s in MepLoadSource.values) s.label,
  kSupplyPumpLoadName,
  kSupplyFanLoadName,
  kFirePumpLoadName,
  kExhaustFanLoadName,
  kHwRecircPumpLoadName,
};

/// Which DRAWN plant node carries which SOLVED duty (audit r8 coupling-1/2).
///
/// Each solved duty IS the duty of the plant node it is rooted at, so a drawn
/// machine and its duty are ONE electrical way, never two:
///  * every pump / booster set piped to a fire service (hydrant / sprinkler)
///    is a FIRE pump — it carries the fire-pump duty (NFPA 20 selected motor)
///    and the life-safety flag;
///  * the cold-water source pump (a component root of the supply service,
///    else the first supply-service pump) carries the supply-pump duty;
///  * the air unit / fan the supply (or return) duct system is rooted at
///    carries the AHU-fan duty; the exhaust system's root fan the exhaust duty.
/// Ids are null when no drawn node carries that duty (then the standalone duty
/// way is minted when the duty feed is on).
class MepDutyBinding {
  final Set<String> firePumpNodeIds;
  final String? supplyPumpNodeId;
  final String? supplyFanNodeId;
  final String? exhaustFanNodeId;

  /// Round 16 — pumps drawn on the HOT-WATER service (not fire, not the
  /// cold-water supply): the recirculation pump(s), fed from the solved
  /// recirculation duty.
  final Set<String> hwRecircPumpNodeIds;

  /// Round 21 (fire-3-parallel-fire-pumps-each-full-duty) — the fire pumps
  /// drawn IN PARALLEL with the duty fire pump (same connected fire network)
  /// that are STANDBY units: wired at the full fire-pump motor, but never
  /// coincident with the duty pump, so their way carries demand factor 0.
  /// A subset of [firePumpNodeIds].
  final Set<String> fireStandbyPumpNodeIds;

  /// Round 21 — the parallel fire pump that is the JOCKEY (pressure
  /// maintenance): fed the rating's jockey duty (1 % rated flow at churn
  /// + 5 m), never the 55-75 kW main motor. A subset of [firePumpNodeIds].
  final Set<String> fireJockeyPumpNodeIds;

  /// Round 21 review — the jockey pumps in [fireJockeyPumpNodeIds] that were
  /// ASSUMED (three or more identical pumps, no smaller bore to tell them
  /// apart, so the last-drawn one was taken as the jockey). Surfaced as an
  /// info Design Issue naming the pump, never silent.
  final Set<String> fireAssumedJockeyPumpNodeIds;

  const MepDutyBinding({
    this.firePumpNodeIds = const {},
    this.supplyPumpNodeId,
    this.supplyFanNodeId,
    this.exhaustFanNodeId,
    this.hwRecircPumpNodeIds = const {},
    this.fireStandbyPumpNodeIds = const {},
    this.fireJockeyPumpNodeIds = const {},
    this.fireAssumedJockeyPumpNodeIds = const {},
  });
}

bool _isPumpComponent(NodeComponent? c) =>
    c == NodeComponent.pump || c == NodeComponent.boosterSet;

/// Services incident to [nodeId] in [net].
Set<ServiceType> _servicesAt(Network net, String nodeId) => {
      for (final e in net.edges)
        if (e.fromId == nodeId || e.toId == nodeId) e.service,
    };

bool _onFireService(Set<ServiceType> s) =>
    s.contains(ServiceType.fireHydrant) || s.contains(ServiceType.fireSprinkler);

final mepDutyBindingProvider = Provider<MepDutyBinding>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final fire = <String>{};
  final supplyPumps = <String>[];
  final hwPumps = <String>{};
  for (final n in net.nodes) {
    if (!_isPumpComponent(n.component)) continue;
    final svc = _servicesAt(net, n.id);
    if (_onFireService(svc)) {
      fire.add(n.id);
    } else if (svc.contains(kSupplyService)) {
      supplyPumps.add(n.id);
    } else if (svc.contains(ServiceType.hotWater)) {
      hwPumps.add(n.id);
    }
  }
  String? supplyPump;
  if (supplyPumps.isNotEmpty) {
    // Round 16 — the node the PRIMARY series duty belongs to; else (Round 15)
    // the inline booster, else the component root, else the first.
    final primary = ref.watch(primarySupplyPumpNodeProvider);
    final booster = ref.watch(supplyBoosterProvider)?.nodeId;
    final roots = serviceComponentRoots(net, kSupplyService).values.toSet();
    supplyPump = (primary != null && supplyPumps.contains(primary))
        ? primary
        : (booster != null && supplyPumps.contains(booster))
            ? booster
            : supplyPumps.firstWhere(roots.contains,
                orElse: () => supplyPumps.first);
  }
  final roles = fire.length < 2
      ? (
          standby: const <String>{},
          jockey: const <String>{},
          assumedJockey: const <String>{},
        )
      : parallelFirePumpRoles(
          net,
          fire,
          bore: (edgeId) =>
              ref.watch(sizingProvider)[edgeId]?.diameter.inMillimeters,
          parallelLegEdgeIds: ref.watch(parallelLegEdgeIdsProvider),
        );
  final units = ref.watch(airSystemRootNodesProvider);
  String? electricalLoad(String? id) {
    if (id == null) return null;
    final c = net.nodeById(id)?.component;
    return (c != null && c.isElectricalLoad) ? id : null;
  }

  return MepDutyBinding(
    firePumpNodeIds: fire,
    supplyPumpNodeId: supplyPump,
    supplyFanNodeId: electricalLoad(units.supply),
    exhaustFanNodeId: electricalLoad(units.exhaust),
    hwRecircPumpNodeIds: hwPumps,
    fireStandbyPumpNodeIds: roles.standby,
    fireJockeyPumpNodeIds: roles.jockey,
    fireAssumedJockeyPumpNodeIds: roles.assumedJockey,
  );
});

/// Round 21 (fire-3-parallel-fire-pumps-each-full-duty) — classify the fire
/// pumps [firePumps] drawn in ONE connected fire network (hydrant + sprinkler
/// edges) as duty / standby / jockey. Pure.
///
/// Per group of two or more pumps:
///  * the DUTY pump is the one NOT on a mirrored parallel standby leg
///    ([parallelLegEdgeIds], the sizer's record), then the LARGEST incident
///    bore ([bore], mm), then the lowest id;
///  * a JOCKEY is any other pump whose largest incident bore is strictly
///    smaller than the duty pump's (a pressure-maintenance pump sits on a
///    small leg); with three or more pumps and no smaller leg, the
///    smallest-bore remaining pump (tie: the HIGHEST id — the last drawn) is
///    the jockey (the classic duty + standby + jockey pump room) — that pick
///    is an ASSUMPTION (nothing drawn tells the pumps apart), so it is also
///    returned in `assumedJockey` for the Review advisory;
///  * every other pump is a STANDBY.
/// A single fire pump in its network is the duty pump (both sets empty).
({Set<String> standby, Set<String> jockey, Set<String> assumedJockey})
    parallelFirePumpRoles(
  Network net,
  Set<String> firePumps, {
  required double? Function(String edgeId) bore,
  Set<String> parallelLegEdgeIds = const {},
}) {
  bool isFire(NetEdge e) =>
      e.service == ServiceType.fireHydrant ||
      e.service == ServiceType.fireSprinkler;
  final parent = <String, String>{};
  String find(String x) {
    var r = x;
    while (parent[r] != null && parent[r] != r) {
      r = parent[r]!;
    }
    return r;
  }

  for (final e in net.edges) {
    if (!isFire(e)) continue;
    parent.putIfAbsent(e.fromId, () => e.fromId);
    parent.putIfAbsent(e.toId, () => e.toId);
    final a = find(e.fromId);
    final b = find(e.toId);
    if (a != b) parent[a] = b;
  }
  final groups = <String, List<String>>{};
  for (final id in firePumps) {
    if (!parent.containsKey(id)) continue;
    groups.putIfAbsent(find(id), () => []).add(id);
  }
  double boreOf(String id) {
    var best = 0.0;
    for (final e in net.edges) {
      if (!isFire(e) || (e.fromId != id && e.toId != id)) continue;
      final d = bore(e.id) ?? 0.0;
      if (d > best) best = d;
    }
    return best;
  }

  bool onLeg(String id) => net.edges.any((e) =>
      isFire(e) &&
      (e.fromId == id || e.toId == id) &&
      parallelLegEdgeIds.contains(e.id));

  final standby = <String>{};
  final jockey = <String>{};
  final assumed = <String>{};
  for (final g in groups.values) {
    if (g.length < 2) continue;
    final ranked = [...g]..sort((a, b) {
        final la = onLeg(a) ? 1 : 0;
        final lb = onLeg(b) ? 1 : 0;
        if (la != lb) return la - lb;
        final d = boreOf(b).compareTo(boreOf(a));
        if (d != 0) return d;
        return a.compareTo(b);
      });
    final duty = ranked.first;
    final rest = ranked.skip(1).toList();
    final dutyBore = boreOf(duty);
    final small = {
      for (final id in rest)
        if (boreOf(id) < dutyBore - 1e-6) id,
    };
    if (small.isEmpty && g.length >= 3) {
      final byBore = [...rest]..sort((a, b) {
          final d = boreOf(a).compareTo(boreOf(b));
          if (d != 0) return d;
          return b.compareTo(a);
        });
      small.add(byBore.first);
      assumed.add(byBore.first);
    }
    jockey.addAll(small);
    standby.addAll(rest.where((id) => !small.contains(id)));
  }
  return (standby: standby, jockey: jockey, assumedJockey: assumed);
}

/// The MEP equipment the mechanical engine has sized, assembled from the live
/// duty providers. A duty with no selected motor / zero power is skipped, and so
/// is a duty a DRAWN plant node already carries ([mepDutyBindingProvider]) —
/// that node's own way is filled from the duty instead (audit r8 coupling-2:
/// the same machine used to appear twice, as a duty way AND a node way).
final mepEquipmentLoadsProvider = Provider<List<MepEquipmentLoad>>((ref) {
  final loads = <MepEquipmentLoad>[];
  final bind = ref.watch(mepDutyBindingProvider);

  final pump = ref.watch(pumpDutyProvider);
  if (bind.supplyPumpNodeId == null &&
      pump != null &&
      pump.selectedMotor.watts > 0) {
    loads.add(MepEquipmentLoad.fromPumpDuty(
      pump,
      id: 'supply-pump',
      name: kSupplyPumpLoadName,
      source: MepLoadSource.supplyPump,
    ));
  }

  final fan = ref.watch(ductFanProvider);
  if (bind.supplyFanNodeId == null &&
      fan != null &&
      fan.selectedMotor.watts > 0) {
    loads.add(MepEquipmentLoad.fromFanDuty(
      fan,
      id: 'supply-fan',
      name: kSupplyFanLoadName,
      source: MepLoadSource.supplyFan,
    ));
  }

  // Round 11 (hvac-network-4) — every OTHER drawn supply / exhaust system
  // (a second AHU on another floor …) carries its own solved duty. When its
  // root is a drawn electrical-load node that node's way is fed from the duty
  // ([placedEquipmentLoadsProvider]); a system rooted at a bare node gets its
  // own duty way here, so no solved airflow is silently dropped.
  final roots = ref.watch(airSystemRootNodesProvider);
  final net = ref.watch(networkControllerProvider).network;
  bool isLoadNode(String id) =>
      net.nodeById(id)?.component?.isElectricalLoad ?? false;
  void addSecondary(Map<String, FanDuty> duties, String? primary,
      String idPrefix, String name, MepLoadSource source) {
    for (final e in duties.entries) {
      if (e.key == primary || isLoadNode(e.key)) continue;
      if (e.value.selectedMotor.watts <= 0) continue;
      loads.add(MepEquipmentLoad.fromFanDuty(
        e.value,
        id: '$idPrefix-${e.key}',
        name: name,
        source: source,
      ));
    }
  }

  addSecondary(ref.watch(supplyFanDutiesByRootProvider), roots.supply,
      'supply-fan', kSupplyFanLoadName, MepLoadSource.supplyFan);

  // The drawn EXHAUST system's own fan (separate from the supply/return AHU).
  final exhaust = ref.watch(exhaustFanProvider);
  if (bind.exhaustFanNodeId == null &&
      exhaust != null &&
      exhaust.selectedMotor.watts > 0) {
    loads.add(MepEquipmentLoad.fromFanDuty(
      exhaust,
      id: 'exhaust-fan',
      name: kExhaustFanLoadName,
      source: MepLoadSource.exhaustFan,
    ));
  }
  addSecondary(ref.watch(exhaustFanDutiesByRootProvider), roots.exhaust,
      'exhaust-fan', kExhaustFanLoadName, MepLoadSource.exhaustFan);

  // Round 16 (plumbing-plant-recirc-pump-not-bound) — the solved HW
  // recirculation duty is a way of its own when no pump is drawn on the
  // hot-water loop (a drawn one carries it via [equipmentNodeDutiesProvider]).
  final recirc = ref.watch(hotWaterRecircProvider);
  if (bind.hwRecircPumpNodeIds.isEmpty &&
      recirc != null &&
      recirc.pump.selectedMotor.watts > 0) {
    loads.add(MepEquipmentLoad.fromPumpDuty(
      recirc.pump,
      id: 'hw-recirc-pump',
      name: kHwRecircPumpLoadName,
      source: MepLoadSource.hotWaterRecircPump,
    ));
  }

  // The fire-pump way is sized on the SELECTED NFPA 20 motor frame (the same
  // kW the equipment schedule tells the contractor to buy — it must carry the
  // overload point), not the raw rated-point shaft power. Electrical input is
  // derived by A5 as motor / η so the breaker + cable cover the nameplate.
  final firePump = ref.watch(firePumpDutyProvider);
  if (bind.firePumpNodeIds.isEmpty &&
      firePump != null &&
      firePump.selectedMotor.watts > 0) {
    loads.add(MepEquipmentLoad(
      id: 'fire-pump',
      name: kFirePumpLoadName,
      source: MepLoadSource.firePump,
      mechanicalPower: firePump.selectedMotor,
      // Round 21 — max(nameplate, governing-point input), as the drawn way.
      electricalInputPower: MepEquipmentLoad.nameplateInput(
          firePump.motorInputPower,
          firePump.selectedMotor,
          defaultMotorEfficiency),
    ));
  }

  return loads;
});

/// Map a placed motorised equipment [NodeComponent] to its electrical source
/// taxonomy (drives the default LoadKind + life-safety flag).
MepLoadSource _sourceFor(NodeComponent c) => switch (c) {
      NodeComponent.pump => MepLoadSource.supplyPump,
      NodeComponent.boosterSet => MepLoadSource.boosterPump,
      NodeComponent.supplyFan || NodeComponent.ahu => MepLoadSource.supplyFan,
      NodeComponent.exhaustFan => MepLoadSource.exhaustFan,
      // Round 14 (elec-building-sim-6) — an AC / FCU is an HVAC final
      // (LoadKind.hvac, curve C), not a pump (curve D).
      NodeComponent.fcu ||
      NodeComponent.acCassette ||
      NodeComponent.acSplitWall ||
      NodeComponent.acDucted =>
        MepLoadSource.hvacUnit,
      _ => MepLoadSource.generic, // any other motorised node
    };

/// Phase count for a placed motorised node: small fan-coils + wall/cassette AC
/// are single-phase; the rest (pumps, fans, AHU, ducted AC) default three-phase.
int _phasesFor(NodeComponent c) => switch (c) {
      NodeComponent.fcu ||
      NodeComponent.acSplitWall ||
      NodeComponent.acCassette =>
        1,
      _ => 3,
    };

/// One placed AC unit's share of its room: the room, the per-unit cooling
/// (BTU/h), the selected unit, and the electrical INPUT (W) its panel way is
/// sized on. Shared by the MEP→electrical feed AND the equipment schedule so a
/// scheduled AC unit and its panel way can never disagree (audit r8
/// coupling-6). Null when the node is in no scaled room.
({RoomArea room, double btuPerHr, AcSelection unit, double inputW})?
    acUnitShare(
  Network net,
  List<RoomArea> rooms,
  double? Function(String sheetId) mppFor,
  NetNode node, {
  CoolingLoadMethod method = CoolingLoadMethod.simple,
}) {
  // Round 20 (hvac-3-1) — the OWNING room (smallest containing, tie on id),
  // never the first room in list order: the room draw order is not a design
  // input, and a unit in a nested meeting room used to be fed the office load.
  final ownerId = roomUnitOwnerId(node, rooms);
  if (ownerId == null) return null;
  final room = rooms.firstWhere((r) => r.id == ownerId);
  // The project's AC-load basis (Building page) drives the fed circuit too, so
  // the panel schedule and the Rooms inspector can never disagree on the PK.
  final load = room.coolingLoad(mppFor(room.sheetId), method: method);
  if (load == null) return null;
  // Split the room load across the AC indoor units the room OWNS (a unit in
  // a nested room is that room's, never counted in the outer room's split).
  var count = 0;
  for (final n in net.nodes) {
    if (RoomArea.isAcComponent(n.component) &&
        roomUnitOwnerId(n, rooms) == room.id) {
      count++;
    }
  }
  if (count == 0) return null;
  final perUnitBtu = load.btuPerHr / count;
  final perUnit = selectAc(perUnitBtu);
  // Above the largest standard rung (3 PK) the ladder SATURATES at 27 000
  // BTU/h; feeding that nominal would understate a bigger unit's input by
  // up to 60 % (audit r8 fire-hvac-1). Feed the real per-unit requirement.
  final input = acInputPowerW(
      coolingBtuPerHr:
          perUnit.exceedsRange ? perUnitBtu : perUnit.nominalBtuPerHr);
  return (room: room, btuPerHr: perUnitBtu, unit: perUnit, inputW: input);
}

/// Electrical INPUT power (W) for a placed AC [node] ([acUnitShare]). Null when
/// the node is in no scaled room (the caller falls back to the component
/// default).
double? _acRoomWatts(
  Network net,
  List<RoomArea> rooms,
  double? Function(String sheetId) mppFor,
  NetNode node, {
  CoolingLoadMethod method = CoolingLoadMethod.simple,
}) =>
    acUnitShare(net, rooms, mppFor, node, method: method)?.inputW;

/// The solved duty each DRAWN equipment node carries — its OWN duty, keyed by
/// node id (absent when none / not solved): a fire-piped pump the NFPA 20
/// fire-pump frame, the cold-water source pump the domestic booster duty,
/// every air unit a supply / return / exhaust system is rooted at THAT
/// system's duty. Round 12 (printed-parity-1) — the ONE per-node duty map the
/// panel feed AND the riser drawing read, so the riser can never print the
/// booster's kW beside the fire pump or the supply AHU's kW beside an exhaust
/// fan while the schedule prints each unit's own duty under the same tag.
final equipmentNodeDutiesProvider =
    Provider<Map<String, ({Power motor, Power input})>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final bind = ref.watch(mepDutyBindingProvider);

  ({Power motor, Power input})? dutyFor(NetNode n) {
    PumpDuty? p;
    FanDuty? f;
    if (bind.firePumpNodeIds.contains(n.id)) {
      // Round 21 — a JOCKEY is fed its own pressure-maintenance duty.
      p = bind.fireJockeyPumpNodeIds.contains(n.id)
          ? ref.watch(fireJockeyDutyProvider)
          : ref.watch(firePumpDutyProvider);
      if (p == null || p.selectedMotor.watts <= 0) return null;
      // NFPA 20 selected frame; Round 21 — the input is the larger of the
      // nameplate (motor / η) and the governing-point input, so a frame
      // clamped at the top of the ladder still sizes the way on the duty.
      return (
        motor: p.selectedMotor,
        input: MepEquipmentLoad.nameplateInput(
            p.motorInputPower, p.selectedMotor, defaultMotorEfficiency),
      );
    }
    // Round 16 — every drawn supply mover carries its OWN series / transfer
    // duty; the primary binding keeps the legacy single duty as a fallback.
    // (The primary node reads [pumpDutyProvider] — the same duty, by
    // construction, as its map entry.)
    p = (n.id == bind.supplyPumpNodeId ? ref.watch(pumpDutyProvider) : null) ??
        ref.watch(supplyMoverDutiesProvider)[n.id];
    if (bind.hwRecircPumpNodeIds.contains(n.id)) {
      p = ref.watch(hotWaterRecircProvider)?.pump;
    }
    // Round 11 (hvac-network-4) — ANY drawn air unit a system is rooted at
    // carries THAT system's duty (the primary one included), not only the
    // single primary unit.
    f = ref.watch(supplyFanDutiesByRootProvider)[n.id] ??
        ref.watch(exhaustFanDutiesByRootProvider)[n.id];
    if (n.id == bind.supplyFanNodeId) f = ref.watch(ductFanProvider);
    if (n.id == bind.exhaustFanNodeId) f = ref.watch(exhaustFanProvider);
    final motor = p?.selectedMotor ?? f?.selectedMotor;
    final op = p?.motorInputPower ?? f?.motorInputPower;
    if (motor == null || op == null || motor.watts <= 0) return null;
    // Sized on the NAMEPLATE (coupling-4) — the same basis as the duty way.
    return (
      motor: motor,
      input: MepEquipmentLoad.nameplateInput(
          op, motor, defaultMotorEfficiency),
    );
  }

  final out = <String, ({Power motor, Power input})>{};
  for (final n in net.nodes) {
    final c = n.component;
    if (c == null || !c.isElectricalLoad) continue;
    final d = dutyFor(n);
    if (d != null) out[n.id] = d;
  }
  return out;
});

/// The riser single-line's per-node equipment DETAIL suffix (tank m3 / the
/// node's OWN motor kW) — one map shared by the Auto canvas and the issued
/// riser PDF/DXF (Round 12, printed-parity-1/2), resolved from
/// [equipmentNodeDutiesProvider] so the riser and the equipment schedule /
/// panel feed print the same machine's duty under the same tag.
final riserEquipmentDetailsProvider = Provider<Map<String, String>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final duties = ref.watch(equipmentNodeDutiesProvider);
  return {
    for (final node in net.nodes)
      node.id: ?equipmentDetail(node, motor: duties[node.id]?.motor),
  };
});

/// Where a placed equipment node's FED electrical load comes from (Round 13,
/// ui-journey-2): the engineer's explicit override, the solved pump/fan duty
/// the node roots, the room cooling PK (an AC in a scaled room), or the
/// component's representative default.
///
/// Round 20 (hvac-3-3) — [roomAir]: an UNPIPED AHU / FCU (no solved duct
/// duty) is fed its owning room's room-air equipment duty, the same machine
/// the equipment schedule prints under its tag.
enum NodeLoadSource { explicit, solvedDuty, roomPk, roomAir, componentDefault }

/// Round 20 (hvac-3-2 / hvac-3-3) — the room-air equipment duty each drawn
/// AHU / FCU carries when it roots NO solved duct system: for every scaled,
/// conditioned (non-extract) room, the FIRST AHU / FCU node the room owns
/// ([roomUnitOwnerId], smallest containing room) — provided no unit the room
/// owns already carries a solved network duty ([equipmentNodeDutiesProvider];
/// that duty row IS the room's air handling). Keyed by node id. The equipment
/// schedule's room rows and the panel feed both read it, so a drawn unit is
/// scheduled once (never a room row beside its solved-duty row under one tag)
/// and its panel way is the machine the schedule prints (never the 5.5 kW
/// component default beside a 0.37 kW room-air row).
final roomAirUnitDutiesProvider =
    Provider<Map<String, ({RoomArea room, FanDuty duty})>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final rooms = ref.watch(roomAreasProvider);
  final project = ref.watch(projectControllerProvider);
  final duties = ref.watch(equipmentNodeDutiesProvider);
  final ducts = ref.watch(ductSettingsProvider);
  bool isAirUnit(NetNode n) =>
      n.component == NodeComponent.ahu || n.component == NodeComponent.fcu;
  final out = <String, ({RoomArea room, FanDuty duty})>{};
  for (final r in rooms) {
    final owned = [
      for (final n in net.nodes)
        if (isAirUnit(n) && roomUnitOwnerId(n, rooms) == r.id) n,
    ];
    if (owned.isEmpty || owned.any((n) => duties.containsKey(n.id))) continue;
    final sizing = r.sizing(
      project.calibrationFor(r.sheetId)?.metersPerPixel,
      ductShape: ducts.shape,
      ductMethod: ducts.method,
    );
    if (sizing == null || sizing.extractOnly) continue;
    out[owned.first.id] = (room: r, duty: sizing.equipment);
  }
  return out;
});

/// The electrical load a placed equipment node actually FEEDS to the panel —
/// [watts] (the figure the panel way is sized from), the electrical [input]
/// when it is already an input power, and its [source].
@immutable
class NodeFedLoad {
  final double watts;
  final double? input;
  final NodeLoadSource source;
  const NodeFedLoad(this.watts, this.input, this.source);
}

/// The ONE resolution of each electrical-load node's fed watts — the panel
/// feed ([placedEquipmentLoadsProvider]) AND the node inspector's 'Electrical
/// load' field read it, so the inspector can never show the generic component
/// default while the panel carries the room-PK or solved-duty load (it used
/// to, and a look-and-leave then pinned that default as an override).
final nodeFedLoadsProvider = Provider<Map<String, NodeFedLoad>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final rooms = ref.watch(roomAreasProvider);
  final project = ref.watch(projectControllerProvider);
  final duties = ref.watch(equipmentNodeDutiesProvider);
  final roomAirUnits = ref.watch(roomAirUnitDutiesProvider);
  double? mppFor(String sheetId) =>
      project.calibrationFor(sheetId)?.metersPerPixel;
  final out = <String, NodeFedLoad>{};
  for (final n in net.nodes) {
    final c = n.component;
    if (c == null || !c.isElectricalLoad) continue;
    // An AC unit's load tracks its room's cooling PK when it sits in a scaled
    // room; an explicit per-node override still wins, else the component
    // default.
    final acWatts = RoomArea.isAcComponent(c)
        ? _acRoomWatts(net, rooms, mppFor, n,
            method: ref.watch(coolingLoadMethodProvider))
        : null;
    // A drawn plant node that roots a solved duty is fed FROM that duty, so the
    // schedule's kW and the panel way describe one machine (coupling-2).
    final duty = duties[n.id];
    // An explicit `electricalLoadW` ('Electrical load (feeds the panel)') and
    // an AC's cooling ÷ COP are ALREADY electrical input power — pass them as
    // the input verbatim so A5 does not divide by motor efficiency a second
    // time. Only the component's `defaultMotorKw` is a SHAFT rating (÷ η).
    //
    // Round 16 (air-systems-2-ducted-ac-load-replaced-by-fan-duty) — a
    // PACKAGED AC unit's fan is inside its rated input: once a ducted AC roots
    // its own supply system it picks up a fan duty, which used to replace the
    // compressor load (cooling ÷ COP) on its panel way (370 W fed for a
    // 7.2 kW unit, while the schedule printed the 7.2 kW AC row). An AC in a
    // scaled room is fed its room-PK input, or the solved fan input when that
    // is (implausibly) larger.
    final acGoverns = acWatts != null &&
        (duty == null || acWatts >= duty.input.watts);
    final input = n.electricalLoadW ??
        (acGoverns ? acWatts : (duty?.input.watts ?? acWatts));
    final NodeLoadSource source;
    final double watts;
    if (n.electricalLoadW != null) {
      source = NodeLoadSource.explicit;
      watts = n.electricalLoadW!;
    } else if (acGoverns) {
      source = NodeLoadSource.roomPk;
      watts = acWatts;
    } else if (duty != null) {
      source = NodeLoadSource.solvedDuty;
      watts = duty.motor.watts;
    } else if (acWatts != null) {
      source = NodeLoadSource.roomPk;
      watts = acWatts;
    } else if (roomAirUnits[n.id] case final ra?) {
      // Round 20 (hvac-3-3) — an unpiped AHU / FCU: the owning room's
      // room-air equipment duty, on the same nameplate basis as a solved
      // duty way (motor rating, input at the nameplate).
      final motor = ra.duty.selectedMotor;
      out[n.id] = NodeFedLoad(
          motor.watts,
          MepEquipmentLoad.nameplateInput(
                  ra.duty.motorInputPower, motor, defaultMotorEfficiency)
              .watts,
          NodeLoadSource.roomAir);
      continue;
    } else {
      source = NodeLoadSource.componentDefault;
      watts = c.defaultMotorKw * 1000;
    }
    out[n.id] = NodeFedLoad(watts, input, source);
  }
  return out;
});

/// Motorised equipment NODES the engineer has placed on the plan (pumps, fans,
/// AHUs, FCUs…) surfaced as electrical loads — so a pump drawn on the PLUMBING
/// layer is INTER-RELATED with the electrical model and appears as its own
/// circuit on the panel. Each node's load is resolved ONCE by
/// [nodeFedLoadsProvider] (explicit override → solved duty → room PK →
/// component default). Keyed by the node id, so editing/moving the node
/// updates its circuit in place.
final placedEquipmentLoadsProvider = Provider<List<MepEquipmentLoad>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final bind = ref.watch(mepDutyBindingProvider);
  final fed = ref.watch(nodeFedLoadsProvider);

  final loads = <MepEquipmentLoad>[];
  for (final n in net.nodes) {
    final c = n.component;
    if (c == null || !c.isElectricalLoad) continue;
    final f = fed[n.id];
    if (f == null || f.watts <= 0) continue;
    final fire = bind.firePumpNodeIds.contains(n.id);
    final input = f.input;
    loads.add(MepEquipmentLoad(
      id: 'node-${n.id}',
      name: c.label,
      // A pump piped to a fire service is a FIRE pump (life-safety), never an
      // ordinary 1.5 kW supply pump (audit r8 coupling-1).
      source: fire
          ? MepLoadSource.firePump
          : bind.hwRecircPumpNodeIds.contains(n.id)
              ? MepLoadSource.hotWaterRecircPump
              : _sourceFor(c),
      mechanicalPower: Power(f.watts),
      electricalInputPower: input == null ? null : Power(input),
      // Round 21 — a STANDBY fire pump is wired at full size but never runs
      // with the duty pump: it adds no demand to the board.
      demandFactor: bind.fireStandbyPumpNodeIds.contains(n.id) ? 0 : null,
      phases: _phasesFor(c),
      loadPos: LayoutPos(
        sheetId: n.sheetId,
        floorIndex: n.floorIndex,
        x: n.x,
        y: n.y,
      ),
    ));
  }
  return loads;
});

/// The PLACED equipment nodes as sized electrical circuits (via A5) — the loads
/// auto-synced to the electrical panel, so a pump/fan/AHU drawn on the plan is
/// inter-related with the electrical model. Empty when nothing motorised is
/// placed (⇒ no MEP panel), which keeps the default project unchanged.
final placedEquipmentCircuitsProvider = Provider<List<ElectricalCircuit>>(
  (ref) => buildEquipmentCircuits(
    ref.watch(placedEquipmentLoadsProvider),
    panelVoltage: mepPanelVoltage,
  ),
);

/// The MEP equipment as sized electrical circuits (via A5), keyed by
/// `sourceEquipmentId` so a re-sync updates in place. Combines the sized DUTY
/// providers (the auto-sized system pump/fan/fire-pump) with the placed
/// equipment NODES (explicit pumps/fans/units on the plan). A duty whose drawn
/// plant node exists is carried BY that node's way and not minted again
/// ([mepDutyBindingProvider]) — one machine, one way. This is the FULL feed
/// (duties + nodes); the
/// reactive auto-sync consumes it only once the engineer opts in via
/// [mepDutyFeedEnabledProvider] (see [mepAutoFeedCircuitsProvider]).
final mepEquipmentCircuitsProvider = Provider<List<ElectricalCircuit>>(
  (ref) => buildEquipmentCircuits(
    [
      ...ref.watch(mepEquipmentLoadsProvider),
      ...ref.watch(placedEquipmentLoadsProvider),
    ],
    panelVoltage: mepPanelVoltage,
  ),
);

/// G1 — whether the SOLVED-DUTY MEP equipment (the auto-sized system pump / fan /
/// fire-pump duties from `solve_store`/`fire_store`) is folded into the "MEP
/// Equipment" panel IN ADDITION to the equipment NODES placed on the plan.
///
/// Default FALSE — the always-on fire-pump duty (a standpipe pump is derived
/// from the building height for ANY project) must not silently conjure an
/// electrical panel into a project the engineer never chose to electrify, so an
/// untouched project stays placed-only and byte-identical. The electrical
/// workspace's "Feed solved MEP duties" affordance (Service & Earthing inspector)
/// flips it on; once on, the reactive auto-sync KEEPS the duty circuits synced
/// (they no longer get dropped as "source removed" on the next placed sync).
///
/// Persisted with the project (`DesignSettings.mepDutyFeedEnabled`, default off
/// ⇒ omitted from the JSON so an untouched project is byte-identical) — a project
/// saved with the feed ON reopens with it ON and its duty circuits stay synced,
/// rather than silently reverting to placed-only on the next load-time sync.
final mepDutyFeedEnabledProvider =
    NotifierProvider<MepDutyFeedController, bool>(MepDutyFeedController.new);

class MepDutyFeedController extends Notifier<bool> {
  @override
  bool build() => false;

  void enable() => state = true;
  void disable() => state = false;
  void set(bool value) => state = value;
  void toggle() => state = !state;
}

/// The circuits the reactive auto-sync folds into the MEP panel: the placed
/// equipment NODES always, PLUS the solved-duty circuits (pump / fan / fire pump)
/// when the engineer has opted in ([mepDutyFeedEnabledProvider]). Default
/// (opt-out) ⇒ placed-only, IDENTICAL to the prior wiring, so an untouched
/// project is byte-identical. This is the provider the store's reactive listener
/// watches — the seam that finally makes the solved-duty bridge reachable.
final mepAutoFeedCircuitsProvider = Provider<List<ElectricalCircuit>>(
  (ref) => ref.watch(mepDutyFeedEnabledProvider)
      ? ref.watch(mepEquipmentCircuitsProvider)
      : ref.watch(placedEquipmentCircuitsProvider),
);
