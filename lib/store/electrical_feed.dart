/// The MEP→electrical AUTO-FEED seam (the merge's unified payoff): the rotating
/// equipment the mechanical engine has already sized (pump / fan / fire-pump
/// duties) is assembled into electrical loads and sized circuits, ready to fold
/// into the electrical project via `ElectricalProjectController.syncMepEquipment`.
///
/// These are GENERATED RENDERS of the existing mechanical solve (guardrail §12.5)
/// — the duty providers in `solve_store`/`fire_store` are the single source; the
/// electrical current is derived here (A5 `load_list.dart`), never re-entered.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/sizing/fan.dart' show FanDuty;
import 'package:mechx_engine/sizing/network_sizing.dart'
    show serviceComponentRoots;
import 'package:mechx_engine/sizing/pump.dart' show PumpDuty;
import 'package:mechx_engine/units.dart';

import 'annotation_store.dart';
import 'app_state.dart'
    show CoolingLoadMethod, coolingLoadMethodProvider, kSupplyService;
import 'fire_store.dart';
import 'network_store.dart';
import 'project_store.dart';
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

  const MepDutyBinding({
    this.firePumpNodeIds = const {},
    this.supplyPumpNodeId,
    this.supplyFanNodeId,
    this.exhaustFanNodeId,
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
  for (final n in net.nodes) {
    if (!_isPumpComponent(n.component)) continue;
    final svc = _servicesAt(net, n.id);
    if (_onFireService(svc)) {
      fire.add(n.id);
    } else if (svc.contains(kSupplyService)) {
      supplyPumps.add(n.id);
    }
  }
  String? supplyPump;
  if (supplyPumps.isNotEmpty) {
    final roots = serviceComponentRoots(net, kSupplyService).values.toSet();
    supplyPump = supplyPumps.firstWhere(roots.contains,
        orElse: () => supplyPumps.first);
  }
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
  );
});

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
      _ => MepLoadSource.generic, // fcu / AC / any other motorised node
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
  RoomArea? room;
  for (final r in rooms) {
    if (r.containsNode(node.sheetId, node.floorIndex, node.x, node.y)) {
      room = r;
      break;
    }
  }
  if (room == null) return null;
  // The project's AC-load basis (Building page) drives the fed circuit too, so
  // the panel schedule and the Rooms inspector can never disagree on the PK.
  final load = room.coolingLoad(mppFor(room.sheetId), method: method);
  if (load == null) return null;
  // Split the room load across the AC indoor units inside the same footprint.
  var count = 0;
  for (final n in net.nodes) {
    if (RoomArea.isAcComponent(n.component) &&
        room.containsNode(n.sheetId, n.floorIndex, n.x, n.y)) {
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

/// Motorised equipment NODES the engineer has placed on the plan (pumps, fans,
/// AHUs, FCUs…) surfaced as electrical loads — so a pump drawn on the PLUMBING
/// layer is INTER-RELATED with the electrical model and appears as its own
/// circuit on the panel. Each node's load is its explicit `electricalLoadW`
/// override, else the component's representative `defaultMotorKw`. Keyed by the
/// node id, so editing/moving the node updates its circuit in place.
final placedEquipmentLoadsProvider = Provider<List<MepEquipmentLoad>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final rooms = ref.watch(roomAreasProvider);
  final project = ref.watch(projectControllerProvider);
  final bind = ref.watch(mepDutyBindingProvider);
  double? mppFor(String sheetId) =>
      project.calibrationFor(sheetId)?.metersPerPixel;

  // The solved duty a drawn node carries (null when none / not solved).
  ({Power motor, Power input})? dutyFor(NetNode n) {
    PumpDuty? p;
    FanDuty? f;
    if (bind.firePumpNodeIds.contains(n.id)) {
      p = ref.watch(firePumpDutyProvider);
      // NFPA 20 selected frame; A5 derives the input as motor / η.
      if (p == null || p.selectedMotor.watts <= 0) return null;
      return (
        motor: p.selectedMotor,
        input: Power(p.selectedMotor.watts / defaultMotorEfficiency),
      );
    }
    if (n.id == bind.supplyPumpNodeId) p = ref.watch(pumpDutyProvider);
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

  final loads = <MepEquipmentLoad>[];
  for (final n in net.nodes) {
    final c = n.component;
    if (c == null || !c.isElectricalLoad) continue;
    final fire = bind.firePumpNodeIds.contains(n.id);
    // An AC unit's load tracks its room's cooling PK when it sits in a scaled
    // room; an explicit per-node override still wins, else the component default.
    final acWatts = RoomArea.isAcComponent(c)
        ? _acRoomWatts(net, rooms, mppFor, n,
            method: ref.watch(coolingLoadMethodProvider))
        : null;
    // A drawn plant node that roots a solved duty is fed FROM that duty, so the
    // schedule's kW and the panel way describe one machine (coupling-2).
    final duty = dutyFor(n);
    // An explicit `electricalLoadW` ('Electrical load (feeds the panel)') and
    // an AC's cooling ÷ COP are ALREADY electrical input power — pass them as
    // the input verbatim so A5 does not divide by motor efficiency a second
    // time. Only the component's `defaultMotorKw` is a SHAFT rating (÷ η).
    final input = n.electricalLoadW ?? duty?.input.watts ?? acWatts;
    final watts = n.electricalLoadW ??
        duty?.motor.watts ??
        acWatts ??
        c.defaultMotorKw * 1000;
    if (watts <= 0) continue;
    loads.add(MepEquipmentLoad(
      id: 'node-${n.id}',
      name: c.label,
      // A pump piped to a fire service is a FIRE pump (life-safety), never an
      // ordinary 1.5 kW supply pump (audit r8 coupling-1).
      source: fire ? MepLoadSource.firePump : _sourceFor(c),
      mechanicalPower: Power(watts),
      electricalInputPower: input == null ? null : Power(input),
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
