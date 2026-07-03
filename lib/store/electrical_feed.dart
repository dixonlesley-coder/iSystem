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
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/units.dart';

import 'annotation_store.dart';
import 'fire_store.dart';
import 'network_store.dart';
import 'project_store.dart';
import 'solve_store.dart';

/// Nominal voltage the MEP equipment panel is fed at (3-phase). The derived FLA
/// is computed against this; equipment phases come from the descriptor.
const Voltage mepPanelVoltage = Voltage(400);

/// The MEP equipment the mechanical engine has sized, assembled from the live
/// duty providers. A duty with no selected motor / zero power is skipped.
final mepEquipmentLoadsProvider = Provider<List<MepEquipmentLoad>>((ref) {
  final loads = <MepEquipmentLoad>[];

  final pump = ref.watch(pumpDutyProvider);
  if (pump != null && pump.selectedMotor.watts > 0) {
    loads.add(MepEquipmentLoad.fromPumpDuty(
      pump,
      id: 'supply-pump',
      name: 'Supply / booster pump',
      source: MepLoadSource.supplyPump,
    ));
  }

  final fan = ref.watch(ductFanProvider);
  if (fan != null && fan.selectedMotor.watts > 0) {
    loads.add(MepEquipmentLoad.fromFanDuty(
      fan,
      id: 'supply-fan',
      name: 'Supply air fan',
      source: MepLoadSource.supplyFan,
    ));
  }

  final standpipe = ref.watch(standpipeDesignProvider);
  if (standpipe.pumpShaftPower.watts > 0) {
    loads.add(MepEquipmentLoad(
      id: 'fire-pump',
      name: 'Fire pump',
      source: MepLoadSource.firePump,
      mechanicalPower: standpipe.pumpShaftPower,
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

/// Electrical INPUT power (W) for a placed AC [node], derived from the cooling
/// load of the room it sits inside (split across the AC units in that room) via
/// the AC COP — so the AC's panel circuit tracks the room's PK. Null when the
/// node is in no scaled room (the caller falls back to the component default).
double? _acRoomWatts(
  Network net,
  List<RoomArea> rooms,
  double? Function(String sheetId) mppFor,
  NetNode node,
) {
  RoomArea? room;
  for (final r in rooms) {
    if (r.containsNode(node.sheetId, node.floorIndex, node.x, node.y)) {
      room = r;
      break;
    }
  }
  if (room == null) return null;
  final load = room.coolingLoad(mppFor(room.sheetId));
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
  final perUnit = selectAc(load.btuPerHr / count);
  return acInputPowerW(coolingBtuPerHr: perUnit.nominalBtuPerHr);
}

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
  double? mppFor(String sheetId) =>
      project.calibrationFor(sheetId)?.metersPerPixel;

  final loads = <MepEquipmentLoad>[];
  for (final n in net.nodes) {
    final c = n.component;
    if (c == null || !c.isElectricalLoad) continue;
    // An AC unit's load tracks its room's cooling PK when it sits in a scaled
    // room; an explicit per-node override still wins, else the component default.
    final acWatts =
        RoomArea.isAcComponent(c) ? _acRoomWatts(net, rooms, mppFor, n) : null;
    final watts = n.electricalLoadW ?? acWatts ?? c.defaultMotorKw * 1000;
    if (watts <= 0) continue;
    loads.add(MepEquipmentLoad(
      id: 'node-${n.id}',
      name: c.label,
      source: _sourceFor(c),
      mechanicalPower: Power(watts),
      phases: _phasesFor(c),
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
/// equipment NODES (explicit pumps/fans/units on the plan) — distinct ids, so
/// both coexist without collision. This is the FULL feed (duties + nodes); the
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
/// Transient session state (not persisted to `.mechx`) — a project-file field
/// would need `DesignSettings`, owned elsewhere; the opt-in is a per-session
/// choice, re-asserted by clicking the affordance.
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
