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
import 'package:mechx_engine/units.dart';

import 'fire_store.dart';
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

/// The MEP equipment as sized electrical circuits (via A5), keyed by
/// `sourceEquipmentId` so a re-sync updates in place.
final mepEquipmentCircuitsProvider = Provider<List<ElectricalCircuit>>(
  (ref) => buildEquipmentCircuits(
    ref.watch(mepEquipmentLoadsProvider),
    panelVoltage: mepPanelVoltage,
  ),
);
