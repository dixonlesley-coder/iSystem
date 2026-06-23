/// Riverpod store for the electrical ("E") domain — the single source of truth
/// for the [ElectricalProject] the A7 UI renders. The project is sized live by
/// the pure A4 engine (`computeSystem`), exposed as a derived [Provider].
///
/// For this first cut the controller seeds a small built-in SAMPLE project (one
/// 3-phase MDP with mixed final circuits plus a single-phase lighting sub-panel)
/// so the Electrical workspace has something meaningful to render. The parent
/// will later wire the MechX pump/fan auto-feed (A5) and `.mechx` persistence
/// (A6) into this store — keep it cleanly the single owner of the project.
///
/// Riverpod: a [Notifier] for the mutable project, a [Provider] for the derived
/// result (recomputed whenever the project changes), mirroring the app's other
/// stores (`solve_store.dart`).
library;

import 'package:flutter/widgets.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';

/// Which whole-area workspace the center of the shell shows. Generalises the old
/// binary plan/schematic toggle into a three-way selection (plan / schematic /
/// electrical).
enum WorkspaceView { plan, schematic, electrical }

extension WorkspaceViewInfo on WorkspaceView {
  /// Short top-bar control label.
  String get label => switch (this) {
        WorkspaceView.plan => 'Plan',
        WorkspaceView.schematic => 'Schematic',
        WorkspaceView.electrical => 'Electrical',
      };
}

/// The active workspace view. Defaults to the plan canvas (the drawing surface).
final workspaceViewProvider =
    NotifierProvider<WorkspaceViewController, WorkspaceView>(
  WorkspaceViewController.new,
);

class WorkspaceViewController extends Notifier<WorkspaceView> {
  @override
  WorkspaceView build() => WorkspaceView.plan;

  void set(WorkspaceView view) => state = view;
}

/// The canonical electrical project. The controller owns the single
/// [ElectricalProject]; intent methods mutate it immutably (replace the project)
/// so the derived [electricalResultProvider] recomputes.
final electricalProjectProvider =
    NotifierProvider<ElectricalProjectController, ElectricalProject>(
  ElectricalProjectController.new,
);

/// Derived: the sized whole-project result, recomputed by the pure A4 engine
/// whenever the project changes. Read-only for the UI.
final electricalResultProvider = Provider<ElectricalSystemResult>(
  (ref) => computeSystem(const PuilProfile(), ref.watch(electricalProjectProvider)),
);

@immutable
class ElectricalProjectController extends Notifier<ElectricalProject> {
  @override
  ElectricalProject build() => sampleElectricalProject();

  /// Replace the whole project (used by A6 persistence / A5 auto-feed later).
  void setProject(ElectricalProject project) => state = project;

  /// Rename the project.
  void setName(String name) => state = ElectricalProject(
        id: state.id,
        name: name,
        panels: state.panels,
        earthingSystem: state.earthingSystem,
      );

  /// Set the installation earthing system (drives RCD policy + main earthing).
  void setEarthingSystem(EarthingSystem system) => state = ElectricalProject(
        id: state.id,
        name: state.name,
        panels: state.panels,
        earthingSystem: system,
      );

  /// Restore the built-in sample project.
  void resetToSample() => state = sampleElectricalProject();
}

/// A small, representative built-in project: a 3-phase main distribution panel
/// (MDP) fed from the utility, with a mix of lighting, socket, HVAC, motor and
/// feeder ways, feeding a single-phase lighting panel (LP-1). Demonstrates the
/// schedule, phase balancing, the feeder tree and the supply summary.
ElectricalProject sampleElectricalProject() {
  const lp1 = ElectricalPanel(
    id: 'lp1',
    name: 'Lighting Panel',
    tag: 'LP-1',
    system: ElectricalSystem.singlePhase,
    voltage: Voltage(220),
    sourceType: PanelSource.feeder,
    fedByCircuitId: 'mdp-f1',
    diversityFactor: 0.9,
    circuits: [
      ElectricalCircuit(
        id: 'lp1-c1',
        name: 'Lighting — Level 1',
        loadKind: LoadKind.lighting,
        isLighting: true,
        loadW: 1800,
        cosPhi: 0.9,
        length: Length(35),
      ),
      ElectricalCircuit(
        id: 'lp1-c2',
        name: 'Lighting — Level 2',
        loadKind: LoadKind.lighting,
        isLighting: true,
        loadW: 1600,
        cosPhi: 0.9,
        length: Length(42),
      ),
      ElectricalCircuit(
        id: 'lp1-c3',
        name: 'Socket outlets',
        loadKind: LoadKind.socket,
        loadW: 2200,
        cosPhi: 0.9,
        demandFactor: 0.7,
        length: Length(28),
      ),
    ],
  );

  const mdp = ElectricalPanel(
    id: 'mdp',
    name: 'Main Distribution Panel',
    tag: 'MDP',
    voltage: Voltage(400),
    diversityFactor: 0.8,
    circuits: [
      ElectricalCircuit(
        id: 'mdp-f1',
        name: 'Feeder to LP-1',
        loadKind: LoadKind.feeder,
        feedsPanelId: 'lp1',
        length: Length(22),
      ),
      ElectricalCircuit(
        id: 'mdp-c1',
        name: 'Chiller / HVAC',
        loadKind: LoadKind.hvac,
        loadW: 18000,
        cosPhi: 0.85,
        demandFactor: 0.9,
        length: Length(30),
      ),
      ElectricalCircuit(
        id: 'mdp-c2',
        name: 'Booster pump',
        loadKind: LoadKind.pump,
        motorKw: 7.5,
        cosPhi: 0.85,
        length: Length(25),
      ),
      ElectricalCircuit(
        id: 'mdp-c3',
        name: 'Power socket ring — workshop',
        loadKind: LoadKind.socket,
        loadW: 4400,
        cosPhi: 0.9,
        demandFactor: 0.7,
        length: Length(18),
      ),
      ElectricalCircuit(
        id: 'mdp-c4',
        name: 'Water heater',
        loadKind: LoadKind.heating,
        loadW: 3000,
        cosPhi: 1.0,
        length: Length(15),
      ),
      ElectricalCircuit(
        id: 'mdp-c5',
        name: 'Fire pump',
        loadKind: LoadKind.motor,
        motorKw: 11,
        cosPhi: 0.85,
        lifeSafety: true,
        length: Length(40),
      ),
    ],
  );

  return const ElectricalProject(
    id: 'sample',
    name: 'Sample building',
    earthingSystem: EarthingSystem.tnCs,
    panels: [mdp, lp1],
  );
}
