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
import 'package:mechx_engine/units.dart';

import 'fire_store.dart';
import 'network_store.dart';
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
      _ => MepLoadSource.generic, // fcu + any other motorised node
    };

/// Motorised equipment NODES the engineer has placed on the plan (pumps, fans,
/// AHUs, FCUs…) surfaced as electrical loads — so a pump drawn on the PLUMBING
/// layer is INTER-RELATED with the electrical model and appears as its own
/// circuit on the panel. Each node's load is its explicit `electricalLoadW`
/// override, else the component's representative `defaultMotorKw`. Keyed by the
/// node id, so editing/moving the node updates its circuit in place.
final placedEquipmentLoadsProvider = Provider<List<MepEquipmentLoad>>((ref) {
  final net = ref.watch(networkControllerProvider).network;
  final loads = <MepEquipmentLoad>[];
  for (final n in net.nodes) {
    final c = n.component;
    if (c == null || !c.isElectricalLoad) continue;
    final watts = n.electricalLoadW ?? c.defaultMotorKw * 1000;
    if (watts <= 0) continue;
    loads.add(MepEquipmentLoad(
      id: 'node-${n.id}',
      name: c.label,
      source: _sourceFor(c),
      mechanicalPower: Power(watts),
      // A small fan-coil is single-phase; the rest default to three-phase.
      phases: c == NodeComponent.fcu ? 1 : 3,
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
/// both coexist without collision. Exposed for a full manual sync; the
/// AUTO-feed uses [placedEquipmentCircuitsProvider] (placed-only) so the
/// always-on fire-pump duty doesn't force a panel into an untouched project.
final mepEquipmentCircuitsProvider = Provider<List<ElectricalCircuit>>(
  (ref) => buildEquipmentCircuits(
    [
      ...ref.watch(mepEquipmentLoadsProvider),
      ...ref.watch(placedEquipmentLoadsProvider),
    ],
    panelVoltage: mepPanelVoltage,
  ),
);
