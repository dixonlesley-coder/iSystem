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
import 'package:mechx_engine/electrical/fault.dart' show defaultLvUtilityFaultKa;
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';

import 'electrical_feed.dart';
import 'project_store.dart';

/// The outcome of a [ElectricalProjectController.connectFeeder] attempt — a
/// success, or a refusal carrying a plain-language reason to surface (mirrors
/// PanelMaker's `connectPanelAsFeeder` 'connected' | 'has-parent' | 'cycle').
class ConnectFeederResult {
  final bool connected;
  final String? reason;
  const ConnectFeederResult.connected()
      : connected = true,
        reason = null;
  const ConnectFeederResult.refused(String this.reason) : connected = false;
}

/// Which whole-area workspace the center of the shell shows. Generalises the old
/// binary plan/schematic toggle into a three-way selection (plan / schematic /
/// electrical).
enum WorkspaceView { plan, schematic, electrical }

extension WorkspaceViewInfo on WorkspaceView {
  /// Short top-bar control label.
  String get label => switch (this) {
        WorkspaceView.plan => 'Plan',
        WorkspaceView.schematic => 'Riser',
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
/// whenever the project (or the shared geometry it is placed on) changes.
/// Read-only for the UI.
///
/// GEO WIRING (the W6 Layout payoff): the live per-sheet calibration + building
/// floors from the MECHANICAL `projectControllerProvider` (the ONE shared
/// calibrated PDF substrate — §10 geometry-is-truth) are threaded into
/// `computeSystem`, so a circuit whose panel + load are PLACED on the calibrated
/// layout sizes on its real geometric run length (`resolveCircuitLength`).
/// Unplaced circuits keep their manual `length` (the engine falls back per
/// circuit), so a project with no layout placements is byte-identical to before.
/// This cross-store dependency is intentional: the electrical Layout view is a
/// projection onto the same substrate the mechanical canvas calibrates.
/// The protective clearing time (seconds) the live app assumes when sizing
/// busbars for short-circuit WITHSTAND (Fold 1). The engine default (1 s) is the
/// rated-`Icw` basis; for actual conductor withstand sizing the *disconnection*
/// time governs, and ~0.1 s is a realistic, conservative LV figure (a high fault
/// is cleared by the incomer's instantaneous trip in tens of ms). At 1 s the
/// adiabatic floor over-sizes every utility-fed bus (~200 mm² at 16 kA); 0.1 s
/// upsizes only where genuinely needed. This is now the FALLBACK default — the
/// fault level + clearing time are project settings (Service & Earthing
/// inspector); a project that leaves them unset uses this 0.1 s and the 16 kA
/// origin default below, preserving the prior byte-identical behaviour.
/// // VERIFY against the assembly's declared Icw / the upstream device let-through.
/// // VERIFY — the 0.1 s adequacy is valid ONLY if the upstream device clears in
/// // ≤ 0.1 s (an instantaneous / current-limiting trip). A bar DECLARED on a 1 s
/// // Icw, or fed by a selective time-delayed incomer, must be re-checked on its
/// // real clearing time — do not mix the 1 s declaration basis with this 0.1 s
/// // disconnection basis silently.
const double _liveBusbarClearingTimeS = 0.1;

final electricalResultProvider = Provider<ElectricalSystemResult>(
  (ref) {
    final geo = ref.watch(projectControllerProvider);
    final project = ref.watch(electricalProjectProvider);
    return computeSystem(
      const PuilProfile(),
      project,
      calibrationBySheet: geo.calibrations,
      building: geo.building,
      // Fold 1 — busbar short-circuit withstand: floor each bus to survive the
      // prospective fault for the clearing time, not merely to carry the load
      // current. The fault level + clearing time are project settings (Service &
      // Earthing inspector); when unset they fall back to the app defaults
      // (16 kA / 0.1 s), so an untouched project sizes byte-identically.
      originFaultLevel: project.originFaultLevelA ??
          const Current(defaultLvUtilityFaultKa * 1000),
      busbarClearingTimeS:
          project.busbarClearingTimeS ?? _liveBusbarClearingTimeS,
    );
  },
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
  ElectricalProject build() {
    // Keep the "MEP Equipment" panel in sync with the motorised equipment NODES
    // placed on the plan (pumps/fans/AHUs/FCUs). This is the inter-discipline
    // payoff: a pump drawn on the plumbing layer appears here as an electrical
    // circuit. We sync the PLACED equipment only (not the always-on sized-duty
    // feed), so an untouched project with nothing placed has no MEP panel and is
    // unchanged. The listener fires on every change after build; a microtask
    // does the initial sync (state can't be set during build()).
    ref.listen(
        placedEquipmentCircuitsProvider, (_, next) => syncMepEquipment(next));
    Future.microtask(
        () => syncMepEquipment(ref.read(placedEquipmentCircuitsProvider)));
    return sampleElectricalProject();
  }

  /// Replace the whole project (used by A6 persistence / A5 auto-feed later).
  void setProject(ElectricalProject project) => state = project;

  /// Rename the project.
  void setName(String name) => state = _withProject(name: name);

  /// Set the installation earthing system (drives RCD policy + main earthing).
  void setEarthingSystem(EarthingSystem system) =>
      state = _withProject(earthingSystem: system);

  /// Set the prospective origin fault level (Fold-1 busbar short-circuit
  /// withstand). Null resets to the app default (16 kA). Non-positive values are
  /// ignored (the engine guards faultKa ≤ 0, but we avoid persisting garbage).
  void setOriginFaultLevel(Current? a) {
    if (a != null && a.amperes <= 0) return;
    state = a == null
        ? _withProject(clearOriginFaultLevelA: true)
        : _withProject(originFaultLevelA: a);
  }

  /// Set the busbar clearing time (s) for the Fold-1 withstand thermal check.
  /// Null resets to the app default (0.1 s). Non-positive values are ignored.
  void setBusbarClearingTime(double? s) {
    if (s != null && s <= 0) return;
    state = s == null
        ? _withProject(clearBusbarClearingTimeS: true)
        : _withProject(busbarClearingTimeS: s);
  }

  /// Rebuild the project carrying every field through, overriding only those
  /// supplied — so an edit to one field never silently drops the additive A8
  /// fields (sources / sites / dual-transformer / occupancy). A local helper
  /// instead of a model `copyWith` to keep the engine model edit purely additive.
  ElectricalProject _withProject({
    String? name,
    EarthingSystem? earthingSystem,
    List<ElectricalPanel>? panels,
    Current? originFaultLevelA,
    bool clearOriginFaultLevelA = false,
    double? busbarClearingTimeS,
    bool clearBusbarClearingTimeS = false,
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
        originFaultLevelA: clearOriginFaultLevelA
            ? null
            : (originFaultLevelA ?? state.originFaultLevelA),
        busbarClearingTimeS: clearBusbarClearingTimeS
            ? null
            : (busbarClearingTimeS ?? state.busbarClearingTimeS),
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
  void addCircuit(
    String panelId, {
    required LoadKind kind,
    String? name,
    int? phases,
    double? loadW,
    double? motorKw,
  }) {
    final d = loadDefaults[kind];
    final isMotor = kind == LoadKind.motor || kind == LoadKind.pump;
    final circuit = ElectricalCircuit(
      id: _freshId('c'),
      name: name ?? (d?.label ?? 'Circuit'),
      loadKind: kind,
      cosPhi: d?.cosPhi ?? 0.85,
      demandFactor: d?.demandFactor ?? 1,
      isLighting: kind == LoadKind.lighting,
      phases: phases,
      // A motor-like way carries a kW default; everything else a watt default.
      // A spare way is zero-demand by definition. Palette cards may seed an
      // explicit power; otherwise the kind's sensible default applies.
      motorKw: isMotor ? (motorKw ?? 3.0) : null,
      loadW: isMotor || kind == LoadKind.spare || kind == LoadKind.feeder
          ? 0
          : (loadW ?? 2000),
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

  /// Move (re-parent) a circuit from [fromPanelId] to [toPanelId], preserving
  /// the way's settings — drag a load node onto another panel to assign it
  /// there. No-op when an id is unknown, the panels are the same, or the circuit
  /// is a feeder that targets the destination (a panel can't feed itself).
  void moveCircuit(String fromPanelId, String circuitId, String toPanelId) {
    if (fromPanelId == toPanelId) return;
    ElectricalPanel? from, to;
    for (final p in state.panels) {
      if (p.id == fromPanelId) from = p;
      if (p.id == toPanelId) to = p;
    }
    if (from == null || to == null) return;
    ElectricalCircuit? circuit;
    for (final c in from.circuits) {
      if (c.id == circuitId) circuit = c;
    }
    if (circuit == null) return;
    if (circuit.feedsPanelId == toPanelId) return; // would feed itself
    final moved = circuit;
    final panels = [
      for (final p in state.panels)
        if (p.id == fromPanelId)
          p.copyWith(circuits: [
            for (final c in p.circuits)
              if (c.id != circuitId) c,
          ])
        else if (p.id == toPanelId)
          p.copyWith(circuits: [...p.circuits, moved])
        else
          p,
    ];
    state = _withProject(panels: panels);
  }

  /// CHAIN one load onto another on the SAME panel — the [sourceId] circuit's
  /// load is folded into [targetId] (one breaker now carries both, e.g. two
  /// sockets next to each other) and the source way is removed. Both loads' watts
  /// (and motor kW, if any) sum onto the target; the target keeps its identity,
  /// cable type, phase and accessories. No-op when the two are the same, on
  /// different panels, missing, or either is a feeder (feeders aren't loads).
  void mergeCircuit(String panelId, String sourceId, String targetId) {
    if (sourceId == targetId) return;
    ElectricalPanel? panel;
    for (final p in state.panels) {
      if (p.id == panelId) panel = p;
    }
    if (panel == null) return;
    ElectricalCircuit? source, target;
    for (final c in panel.circuits) {
      if (c.id == sourceId) source = c;
      if (c.id == targetId) target = c;
    }
    if (source == null || target == null) return;
    if (source.isFeeder || target.isFeeder) return; // feeders aren't loads

    final src = source;
    final tgt = target;
    final mergedMotorKw = (tgt.motorKw == null && src.motorKw == null)
        ? null
        : (tgt.motorKw ?? 0) + (src.motorKw ?? 0);
    final merged = tgt.copyWith(
      loadW: tgt.loadW + src.loadW,
      points: tgt.points + src.points, // chained outlet points add up
      motorKw: mergedMotorKw,
    );
    final panels = [
      for (final p in state.panels)
        if (p.id == panelId)
          p.copyWith(circuits: [
            // Drop the source; replace the target with the merged way.
            for (final c in p.circuits)
              if (c.id != sourceId) (c.id == targetId ? merged : c),
          ])
        else
          p,
    ];
    state = _withProject(panels: panels);
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

  // ── Spatial-canvas intents (Wave 5) ────────────────────────────────────────
  // Layout positions + feeder topology edits for the single-line canvas. All
  // additive (only `x`/`y` + the existing feeder fields move) and funnelled
  // through the per-panel/per-project replacers.

  /// Set a panel's canvas position (world px) — the live-drag intent (mirrors
  /// the mechanical canvas `moveNode`). No-op when the id is unknown.
  void setPanelPosition(String id, double x, double y) =>
      _replacePanel(id, (p) => p.copyWith(x: x, y: y));

  /// Add a new panel at a canvas position. When [fedByCircuitId] is given it is
  /// a fed sub-board; otherwise a utility-fed board.
  void addPanelAt({
    required String name,
    required double x,
    required double y,
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
      x: x,
      y: y,
    );
    state = _withProject(panels: [...state.panels, panel]);
  }

  /// Connect [fromPanelId] → [toPanelId] as a feeder: append a feeder way on the
  /// source panel and point the target's incomer at it. Mirrors PanelMaker's
  /// `connectPanelAsFeeder` refusal logic (no self-feed, no second parent, no
  /// cycle) and returns a [ConnectFeederResult] explaining a refusal.
  ConnectFeederResult connectFeeder(String fromPanelId, String toPanelId) {
    if (fromPanelId == toPanelId) {
      return const ConnectFeederResult.refused('A panel cannot feed itself.');
    }
    final from = state.panels.where((p) => p.id == fromPanelId).firstOrNull;
    final to = state.panels.where((p) => p.id == toPanelId).firstOrNull;
    if (from == null || to == null) {
      return const ConnectFeederResult.refused('Panel not found.');
    }
    if (to.fedByCircuitId != null) {
      return ConnectFeederResult.refused(
          '${to.tag ?? to.name} is already fed by another panel. '
          'Disconnect it first.');
    }
    // A cycle results if the source is reachable downstream of the target.
    if (_isDescendant(target: fromPanelId, of: toPanelId)) {
      return const ConnectFeederResult.refused(
          'That would create a feeder loop (the target already feeds this panel).');
    }
    final feederId = _freshId('c');
    final feeder = ElectricalCircuit(
      id: feederId,
      name: 'Feeder to ${to.tag ?? to.name}',
      loadKind: LoadKind.feeder,
      feedsPanelId: toPanelId,
      length: const Length(20),
    );
    final panels = [
      for (final p in state.panels)
        if (p.id == fromPanelId)
          p.copyWith(circuits: [...p.circuits, feeder])
        else if (p.id == toPanelId)
          p.copyWith(
            sourceType: PanelSource.feeder,
            fedByCircuitId: feederId,
          )
        else
          p,
    ];
    state = _withProject(panels: panels);
    return const ConnectFeederResult.connected();
  }

  /// True when [target] is reachable by following feeders downstream from [of]
  /// (used to reject a feeder that would close a loop).
  bool _isDescendant({required String target, required String of}) {
    final seen = <String>{};
    final stack = <String>[of];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (!seen.add(id)) continue;
      final panel = state.panels.where((p) => p.id == id).firstOrNull;
      if (panel == null) continue;
      for (final c in panel.circuits) {
        final fed = c.feedsPanelId;
        if (fed == null) continue;
        if (fed == target) return true;
        stack.add(fed);
      }
    }
    return false;
  }

  /// Disconnect the feeder into [panelId]: drop the parent's feeder way and make
  /// the panel utility-fed again. No-op when the panel isn't fed.
  void disconnectFeeder(String panelId) {
    final to = state.panels.where((p) => p.id == panelId).firstOrNull;
    if (to == null || to.fedByCircuitId == null) return;
    final feederId = to.fedByCircuitId;
    final panels = [
      for (final p in state.panels)
        if (p.id == panelId)
          p.copyWith(
            sourceType: PanelSource.utility,
            clearFedByCircuitId: true,
          )
        else
          p.copyWith(circuits: [
            for (final c in p.circuits)
              if (c.id != feederId) c,
          ]),
    ];
    state = _withProject(panels: panels);
  }

  /// Add a floating load (a final circuit) as a one-way sub-panel placed at a
  /// canvas position. Mirrors PanelMaker's drop-on-blank-canvas: a standalone
  /// load becomes its own (utility-fed) tiny board until wired to a feeder.
  void addFloatingLoad({
    required LoadKind kind,
    required double x,
    required double y,
    String? name,
    int? phases,
    double? loadW,
    double? motorKw,
  }) {
    final d = loadDefaults[kind];
    final panelId = _freshId('panel');
    final isMotor = kind == LoadKind.motor || kind == LoadKind.pump;
    final threePhase = phases == 3;
    final circuit = ElectricalCircuit(
      id: _freshId('c'),
      name: name ?? (d?.label ?? 'Load'),
      loadKind: kind,
      cosPhi: d?.cosPhi ?? 0.85,
      demandFactor: d?.demandFactor ?? 1,
      isLighting: kind == LoadKind.lighting,
      phases: phases,
      motorKw: isMotor ? (motorKw ?? 3.0) : null,
      loadW: isMotor || kind == LoadKind.spare ? 0 : (loadW ?? 2000),
      length: const Length(20),
    );
    final panel = ElectricalPanel(
      id: panelId,
      name: name ?? (d?.label ?? 'Load'),
      tag: null,
      // The drop-on-blank gesture makes a tiny standalone board; its system
      // follows the dropped load's phase (default 1φ) until the user wires it.
      system:
          threePhase ? ElectricalSystem.threePhase : ElectricalSystem.singlePhase,
      voltage: threePhase ? const Voltage(400) : const Voltage(220),
      x: x,
      y: y,
      circuits: [circuit],
    );
    state = _withProject(panels: [...state.panels, panel]);
  }

  // ── Geo-layout intents (Wave 6) ────────────────────────────────────────────
  // The Layout view places panels + loads on the calibrated PDF substrate. These
  // edit the GEO placement (`layoutPos` / `loadPos`) — a SEPARATE space from the
  // abstract single-line `x`/`y` above (a node can carry both). All additive and
  // funnelled through the per-panel/per-circuit replacers; the engine derives the
  // cable run length from the placement (`resolveCircuitLength`).

  /// Place / move a panel on the calibrated layout (or clear with a null [pos]).
  /// No-op when the id is unknown.
  void setPanelLayoutPos(String panelId, LayoutPos? pos) => _replacePanel(
        panelId,
        (p) => pos == null
            ? p.copyWith(clearLayoutPos: true)
            : p.copyWith(layoutPos: pos),
      );

  /// Place / move one circuit's LOAD on the calibrated layout (or clear with a
  /// null [pos]). No-op when either id is unknown.
  void setLoadPos(String panelId, String circuitId, LayoutPos? pos) =>
      _replaceCircuit(
        panelId,
        circuitId,
        (c) => pos == null
            ? c.copyWith(clearLoadPos: true)
            : c.copyWith(loadPos: pos),
      );

  /// Add a new way to [panelId] already PLACED on the layout at [pos] — the
  /// drag-a-palette-card-onto-the-sheet-near-a-panel gesture. Same standards
  /// defaults as [addCircuit]; the circuit is created with its `loadPos` so its
  /// run length is geo-derived immediately.
  void addLoadAtLayout(
    String panelId, {
    required LoadKind kind,
    required LayoutPos pos,
    String? name,
    int? phases,
    double? loadW,
    double? motorKw,
  }) {
    final d = loadDefaults[kind];
    final isMotor = kind == LoadKind.motor || kind == LoadKind.pump;
    final circuit = ElectricalCircuit(
      id: _freshId('c'),
      name: name ?? (d?.label ?? 'Circuit'),
      loadKind: kind,
      cosPhi: d?.cosPhi ?? 0.85,
      demandFactor: d?.demandFactor ?? 1,
      isLighting: kind == LoadKind.lighting,
      phases: phases,
      motorKw: isMotor ? (motorKw ?? 3.0) : null,
      loadW: isMotor || kind == LoadKind.spare || kind == LoadKind.feeder
          ? 0
          : (loadW ?? 2000),
      length: const Length(20),
      loadPos: pos,
    );
    _replacePanel(panelId, (p) => p.copyWith(circuits: [...p.circuits, circuit]));
  }

  /// Drop a load onto blank plan with NO panel to attach to: it becomes a
  /// floating LOAD (a one-way utility-fed stub) placed at [pos] — so it renders
  /// as its load icon on the sheet, NOT a generic panel. The stub board has no
  /// `layoutPos` (only the circuit's `loadPos` is placed), so the layer draws
  /// just the load symbol; wire it to a feeder later to fold it into a board.
  void addFloatingLoadAtLayout({
    required LoadKind kind,
    required LayoutPos pos,
    String? name,
    int? phases,
    double? loadW,
    double? motorKw,
  }) {
    final d = loadDefaults[kind];
    final isMotor = kind == LoadKind.motor || kind == LoadKind.pump;
    final threePhase = phases == 3;
    final circuit = ElectricalCircuit(
      id: _freshId('c'),
      name: name ?? (d?.label ?? 'Load'),
      loadKind: kind,
      cosPhi: d?.cosPhi ?? 0.85,
      demandFactor: d?.demandFactor ?? 1,
      isLighting: kind == LoadKind.lighting,
      phases: phases,
      motorKw: isMotor ? (motorKw ?? 3.0) : null,
      loadW: isMotor || kind == LoadKind.spare || kind == LoadKind.feeder
          ? 0
          : (loadW ?? 2000),
      length: const Length(20),
      loadPos: pos,
    );
    final panel = ElectricalPanel(
      id: _freshId('panel'),
      name: name ?? (d?.label ?? 'Load'),
      tag: null,
      system: threePhase
          ? ElectricalSystem.threePhase
          : ElectricalSystem.singlePhase,
      voltage: threePhase ? const Voltage(400) : const Voltage(220),
      x: pos.x,
      y: pos.y,
      circuits: [circuit],
    );
    state = _withProject(panels: [...state.panels, panel]);
  }

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
