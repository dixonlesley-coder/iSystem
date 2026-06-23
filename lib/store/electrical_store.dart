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
import 'package:mechx_engine/electrical/advanced_study.dart';
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

/// Derived: the bundled A8 advanced study (fault / supply / PF / control /
/// harmonics / arc-flash / containment / enclosure / metering / SPD / lightning
/// / electrode / power-one-line / BOM), recomputed by the pure engine over the
/// live project + its A4 result. Read-only for the UI; never mutates the core.
final electricalAdvancedProvider = Provider<AdvancedStudy>(
  (ref) => computeAdvancedStudy(
    const PuilProfile(),
    ref.watch(electricalProjectProvider),
    ref.watch(electricalResultProvider),
  ),
);

@immutable
class ElectricalProjectController extends Notifier<ElectricalProject> {
  @override
  ElectricalProject build() => sampleElectricalProject();

  /// Replace the whole project (used by A6 persistence / A5 auto-feed later).
  void setProject(ElectricalProject project) => state = project;

  /// Rename the project.
  void setName(String name) => state = _withProject(name: name);

  /// Set the installation earthing system (drives RCD policy + main earthing).
  void setEarthingSystem(EarthingSystem system) =>
      state = _withProject(earthingSystem: system);

  /// Rebuild the project carrying every field through, overriding only those
  /// supplied — so an edit to one field never silently drops the additive A8
  /// fields (sources / sites / dual-transformer / occupancy). A local helper
  /// instead of a model `copyWith` to keep the engine model edit purely additive.
  ElectricalProject _withProject({
    String? name,
    EarthingSystem? earthingSystem,
    List<ElectricalPanel>? panels,
  }) =>
      ElectricalProject(
        id: state.id,
        name: name ?? state.name,
        panels: panels ?? state.panels,
        earthingSystem: earthingSystem ?? state.earthingSystem,
        sources: state.sources,
        dualTransformer: state.dualTransformer,
        occupancy: state.occupancy,
        soilResistivityOhmM: state.soilResistivityOhmM,
        groundFlashDensity: state.groundFlashDensity,
        externalLps: state.externalLps,
        overheadSupply: state.overheadSupply,
        buildingLengthM: state.buildingLengthM,
        buildingWidthM: state.buildingWidthM,
        buildingHeightM: state.buildingHeightM,
      );

  /// Restore the built-in sample project.
  void resetToSample() => state = sampleElectricalProject();

  // ── Edit intents (the interactive editor) ──────────────────────────────────
  // Every method rebuilds the panel list immutably and routes through
  // [_withProject] so the additive A8 project fields (sources / dual-transformer
  // / occupancy / site) are never silently dropped.

  /// Replace one panel within the list (by id), preserving order. No-op when the
  /// id is unknown. The single funnel every per-panel edit routes through.
  void _replacePanel(String panelId, ElectricalPanel Function(ElectricalPanel) f) {
    var changed = false;
    final panels = [
      for (final p in state.panels)
        if (p.id == panelId) (changed = true, f(p)).$2 else p,
    ];
    if (changed) state = _withProject(panels: panels);
  }

  /// Replace one circuit on one panel (by id), preserving order. No-op when
  /// either id is unknown.
  void _replaceCircuit(String panelId, String circuitId,
      ElectricalCircuit Function(ElectricalCircuit) f) {
    _replacePanel(
      panelId,
      (p) => p.copyWith(circuits: [
        for (final c in p.circuits)
          if (c.id == circuitId) f(c) else c,
      ]),
    );
  }

  /// Append a fresh-id circuit of [kind] to [panelId], with standards-derived
  /// defaults (cos φ / demand factor / curve from [loadDefaults]) and a sensible
  /// default load so the engine sizes it immediately.
  void addCircuit(String panelId, {required LoadKind kind, String? name}) {
    final d = loadDefaults[kind];
    final isMotor = kind == LoadKind.motor || kind == LoadKind.pump;
    final circuit = ElectricalCircuit(
      id: _freshId('c'),
      name: name ?? (d?.label ?? 'Circuit'),
      loadKind: kind,
      cosPhi: d?.cosPhi ?? 0.85,
      demandFactor: d?.demandFactor ?? 1,
      isLighting: kind == LoadKind.lighting,
      // A motor-like way carries a kW default; everything else a watt default.
      // A spare way is zero-demand by definition.
      motorKw: isMotor ? 3.0 : null,
      loadW: isMotor || kind == LoadKind.spare || kind == LoadKind.feeder
          ? 0
          : 2000,
      length: const Length(20),
    );
    _replacePanel(panelId, (p) => p.copyWith(circuits: [...p.circuits, circuit]));
  }

  /// Field-wise edit of one circuit — only the supplied fields change. Pass the
  /// `clear*` flags to null an optional field.
  void setCircuit(
    String panelId,
    String circuitId, {
    String? name,
    LoadKind? loadKind,
    double? loadW,
    double? motorKw,
    bool clearMotorKw = false,
    double? cosPhi,
    double? demandFactor,
    Length? length,
    int? phases,
    bool clearPhases = false,
    bool? lifeSafety,
    bool? isLighting,
    String? cableType,
    bool clearCableType = false,
  }) {
    _replaceCircuit(
      panelId,
      circuitId,
      (c) => c.copyWith(
        name: name,
        loadKind: loadKind,
        loadW: loadW,
        motorKw: motorKw,
        clearMotorKw: clearMotorKw,
        cosPhi: cosPhi,
        demandFactor: demandFactor,
        length: length,
        phases: phases,
        clearPhases: clearPhases,
        lifeSafety: lifeSafety,
        isLighting: isLighting,
        cableType: cableType,
        clearCableType: clearCableType,
      ),
    );
  }

  /// Delete one circuit from a panel.
  void deleteCircuit(String panelId, String circuitId) {
    _replacePanel(
      panelId,
      (p) => p.copyWith(circuits: [
        for (final c in p.circuits)
          if (c.id != circuitId) c,
      ]),
    );
  }

  /// Duplicate one circuit (fresh id, "(copy)" name), inserted just after it.
  /// A duplicated feeder drops its `feedsPanelId` (a feeder targets one panel).
  void duplicateCircuit(String panelId, String circuitId) {
    _replacePanel(panelId, (p) {
      final out = <ElectricalCircuit>[];
      for (final c in p.circuits) {
        out.add(c);
        if (c.id == circuitId) {
          out.add(c.copyWith(
            id: _freshId('c'),
            name: '${c.name} (copy)',
            feedsPanelId: c.feedsPanelId == null ? null : '',
          ));
        }
      }
      return p.copyWith(circuits: out);
    });
  }

  /// Add a new (empty) panel. When [fedByCircuitId] is given it is a fed
  /// sub-board; otherwise a utility-fed board.
  void addPanel({
    required String name,
    String? tag,
    ElectricalSystem system = ElectricalSystem.threePhase,
    Voltage voltage = const Voltage(400),
    String? fedByCircuitId,
  }) {
    final panel = ElectricalPanel(
      id: _freshId('panel'),
      name: name,
      tag: tag,
      system: system,
      voltage: voltage,
      sourceType:
          fedByCircuitId != null ? PanelSource.feeder : PanelSource.utility,
      fedByCircuitId: fedByCircuitId,
    );
    state = _withProject(panels: [...state.panels, panel]);
  }

  /// Delete a panel by id.
  void deletePanel(String id) {
    state = _withProject(
      panels: [
        for (final p in state.panels)
          if (p.id != id) p,
      ],
    );
  }

  /// Rename a panel.
  void renamePanel(String id, String name) =>
      _replacePanel(id, (p) => p.copyWith(name: name));

  /// Set a panel's diversity factor (clamped 0–1).
  void setPanelDiversity(String id, double factor) => _replacePanel(
      id, (p) => p.copyWith(diversityFactor: factor.clamp(0.0, 1.0)));

  /// Toggle the essential (genset-backed) flag.
  void setPanelEssential(String id, bool value) =>
      _replacePanel(id, (p) => p.copyWith(essential: value));

  /// Toggle the UPS / critical-backed flag.
  void setPanelUpsBacked(String id, bool value) =>
      _replacePanel(id, (p) => p.copyWith(upsBacked: value));

  /// Toggle the tenant sub-metered flag.
  void setPanelSubmeter(String id, bool value) =>
      _replacePanel(id, (p) => p.copyWith(submeter: value));

  /// Monotonic id source for new panels / circuits (deterministic per process,
  /// distinct across calls — sufficient for in-memory editing).
  static int _idSeq = 0;
  String _freshId(String prefix) => '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_idSeq++}';

  /// Fold the MechX-sized MEP equipment (A5) into a dedicated "MEP Equipment"
  /// panel, upserted by a fixed id so re-syncing replaces it cleanly (the
  /// circuits already carry `sourceEquipmentId`). Empty [circuits] removes the
  /// panel. This is the unified payoff: a pump/fan/fire-pump the mechanical
  /// engine sized appears here as a sized electrical circuit, no re-entry.
  void syncMepEquipment(List<ElectricalCircuit> circuits) {
    const mepPanelId = 'mep-equipment';
    final others = state.panels.where((p) => p.id != mepPanelId).toList();
    state = _withProject(
      panels: circuits.isEmpty
          ? others
          : [
              ...others,
              ElectricalPanel(
                id: mepPanelId,
                name: 'MEP Equipment',
                tag: 'MEP',
                voltage: const Voltage(400),
                circuits: circuits,
              ),
            ],
    );
  }
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
