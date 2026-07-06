/// Riverpod store for the electrical ("E") domain — the single source of truth
/// for the [ElectricalProject] the A7 UI renders. The project is sized live by
/// the pure A4 engine (`computeSystem`), exposed as a derived [Provider].
///
/// A fresh launch starts from an EMPTY project (A2 — a fictional demo
/// switchboard must never ride into a real `.mechx` / BOM / quotation). The
/// built-in SAMPLE project (one 3-phase MDP with mixed final circuits plus a
/// single-phase lighting sub-panel) stays available behind the empty-state
/// card's explicit "Load sample project" action ([resetToSample]).
///
/// Riverpod: a [Notifier] for the mutable project, a [Provider] for the derived
/// result (recomputed whenever the project changes), mirroring the app's other
/// stores (`solve_store.dart`).
library;

import 'package:flutter/widgets.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart' show StarterType;
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart' show defaultLvUtilityFaultKa;
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';

import 'electrical_feed.dart';
import 'history_store.dart';
import 'inspector_store.dart';
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

/// The fixed id of the machine-owned "MEP Equipment" panel — the board
/// auto-synced from the motorised equipment placed on the plan
/// (`syncMepEquipment`). Exposed so the canvas can badge it "auto — from plan"
/// and guard palette drops onto it (a user-dropped way there would be wiped).
const String kMepEquipmentPanelId = 'mep-equipment';

/// Which whole-area workspace the center of the shell shows. Generalises the old
/// binary plan/schematic toggle into a three-way selection (plan / schematic /
/// electrical).
enum WorkspaceView { plan, schematic, electrical }

extension WorkspaceViewInfo on WorkspaceView {
  /// Short top-bar control label.
  String get label => switch (this) {
        WorkspaceView.plan => 'Plan',
        WorkspaceView.schematic => 'Riser SLD',
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

/// A selected element on the unified Layout's electrical layer (I5) — a whole
/// panel, or one circuit within a panel. Drives the marker selection ring, and
/// Delete removes it via the existing [ElectricalProjectController] intents.
@immutable
class ElectricalSelection {
  final String panelId;
  final String? circuitId;
  const ElectricalSelection.panel(this.panelId) : circuitId = null;
  const ElectricalSelection.circuit(this.panelId, String this.circuitId);

  bool get isCircuit => circuitId != null;

  @override
  bool operator ==(Object other) =>
      other is ElectricalSelection &&
      other.panelId == panelId &&
      other.circuitId == circuitId;

  @override
  int get hashCode => Object.hash(panelId, circuitId);
}

/// The selected element on the Layout electrical layer (null = nothing). Kept in
/// a provider (not local widget state) because the layer widget is rebuilt as
/// the active discipline / opacity changes; a marker tap sets it, a blank-canvas
/// tap or a delete clears it.
final electricalSelectionProvider =
    NotifierProvider<ElectricalSelectionController, ElectricalSelection?>(
  ElectricalSelectionController.new,
);

class ElectricalSelectionController extends Notifier<ElectricalSelection?> {
  @override
  ElectricalSelection? build() => null;

  void selectPanel(String id) => state = ElectricalSelection.panel(id);
  void selectCircuit(String panelId, String circuitId) =>
      state = ElectricalSelection.circuit(panelId, circuitId);
  void clear() {
    if (state != null) state = null;
  }
}

/// The editor target driving the STANDALONE electrical workspace's inline,
/// selection-first inspector column (C1/C4): a single way (circuit), a whole
/// panel's properties, or (null) nothing — in which case the column shows the
/// Loads palette. Lifted out of `ElectricalView`'s local `State` so the sibling
/// inspector column, rendered by the SHARED shell scaffold, can read + drive the
/// same target the canvas opens. Mutually exclusive (one editor at a time).
///
/// Distinct from [electricalSelectionProvider] (the Layout electrical LAYER's
/// marker selection) on purpose: this drives the abstract single-line
/// workspace's inspector, so lifting it here never disturbs the Layout layer.
/// Transient UI state — NEVER persisted to `.mechx`.
@immutable
sealed class ElectricalInspectorTarget {
  const ElectricalInspectorTarget();
}

/// Edit one way (circuit) on a panel — the circuit inspector body.
@immutable
class ElectricalCircuitTarget extends ElectricalInspectorTarget {
  final String panelId;
  final String circuitId;
  const ElectricalCircuitTarget(this.panelId, this.circuitId);

  @override
  bool operator ==(Object other) =>
      other is ElectricalCircuitTarget &&
      other.panelId == panelId &&
      other.circuitId == circuitId;

  @override
  int get hashCode => Object.hash(panelId, circuitId);
}

/// Edit a whole panel's properties — the panel inspector body.
@immutable
class ElectricalPanelTarget extends ElectricalInspectorTarget {
  final String panelId;
  const ElectricalPanelTarget(this.panelId);

  @override
  bool operator ==(Object other) =>
      other is ElectricalPanelTarget && other.panelId == panelId;

  @override
  int get hashCode => panelId.hashCode;
}

/// The active inline-inspector edit target (null = nothing → the Loads palette
/// shows). A `Notifier` (not local widget state) so the electrical canvas and
/// the sibling inspector column drive one shared target.
final electricalInspectorTargetProvider = NotifierProvider<
    ElectricalInspectorTargetController, ElectricalInspectorTarget?>(
  ElectricalInspectorTargetController.new,
);

class ElectricalInspectorTargetController
    extends Notifier<ElectricalInspectorTarget?> {
  @override
  ElectricalInspectorTarget? build() => null;

  void editCircuit(String panelId, String circuitId) {
    _revealInspector();
    state = ElectricalCircuitTarget(panelId, circuitId);
  }

  void editPanel(String panelId) {
    _revealInspector();
    state = ElectricalPanelTarget(panelId);
  }

  void clear() {
    if (state != null) state = null;
  }

  /// Opening an editor un-collapses the inspector column, mirroring the
  /// mechanical canvas's double-click ("opens the thing" — `selection_overlay`).
  /// The inline editor now lives INSIDE the shared `CollapsibleInspector`, so
  /// without this an edit on a collapsed inspector would set an invisible target.
  void _revealInspector() =>
      ref.read(inspectorCollapsedProvider.notifier).set(false);
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
  // Local snapshot stacks (the house undo pattern — mirrors NetworkController /
  // ProjectController): the state is an immutable [ElectricalProject], so a
  // snapshot is just the previous state reference. Every USER mutation funnels
  // through [_commit], which pushes a snapshot AND records
  // [UndoDomain.electrical] on the single global timeline (`history_store`);
  // `historyProvider.undo()` pops the timeline and drives [undo] here, so
  // Ctrl+Z reverts the genuinely most-recent edit across domains.
  final List<ElectricalProject> _undo = [];
  final List<ElectricalProject> _redo = [];

  @override
  ElectricalProject build() {
    // Keep the "MEP Equipment" panel in sync with the MEP equipment the app has
    // sized. This is the inter-discipline payoff: a pump drawn on the plumbing
    // layer appears here as an electrical circuit. The feed is the placed
    // equipment NODES always, PLUS the solved system DUTIES (pump/fan/fire-pump)
    // once the engineer opts in (G1, [mepDutyFeedEnabledProvider]) — the
    // [mepAutoFeedCircuitsProvider] gates that. Default is placed-only, so an
    // untouched project with nothing placed has no MEP panel and is byte-
    // identical to before. The listener fires on every change after build; a
    // microtask does the initial sync (state can't be set during build()).
    ref.listen(
        mepAutoFeedCircuitsProvider, (_, next) => syncMepEquipment(next));
    Future.microtask(
        () => syncMepEquipment(ref.read(mepAutoFeedCircuitsProvider)));
    // A2 — a fresh project is EMPTY: the fictional sample switchboard must
    // never leak into a real `.mechx` / BOM / quotation. The sample stays one
    // explicit click away ([resetToSample], the empty-state action).
    return const ElectricalProject();
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// The single forward-mutation funnel: snapshot the current project onto the
  /// undo stack, record this domain on the global timeline (which clears the
  /// global redo branch), clear the local redo stack, and apply [next]. Every
  /// USER edit intent routes through here — programmatic replacements
  /// ([setProject] loads, [syncMepEquipment] derived syncs) deliberately don't.
  void _commit(ElectricalProject next) {
    _undo.add(state);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    ref.read(historyProvider.notifier).record(UndoDomain.electrical);
    state = next;
  }

  /// Snapshot the current project onto the undo stack WITHOUT changing state —
  /// call once at the start of a drag (or before a non-recording placement) so
  /// the whole move collapses into a single undo step. Mirrors
  /// `NetworkController.pushUndoSnapshot`.
  void pushUndoSnapshot() {
    _undo.add(state);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    ref.read(historyProvider.notifier).record(UndoDomain.electrical);
  }

  /// Revert the most recent committed edit. Driven by the global
  /// [historyProvider] (which owns cross-domain ordering) — not called
  /// directly by widgets.
  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(state);
    state = _undo.removeLast();
  }

  /// Replay the most recently undone edit (see [undo]).
  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(state);
    state = _redo.removeLast();
  }

  /// Replace the whole project (A6 persistence load / crash recovery). A loaded
  /// document is a fresh baseline, so BOTH local stacks clear — the caller
  /// (`applyDocument`) resets the global timeline to match, like the other
  /// domain controllers clearing their stacks on load. Never records undo.
  void setProject(ElectricalProject project) {
    _undo.clear();
    _redo.clear();
    state = project;
  }

  /// Rename the project.
  void setName(String name) => _commit(_withProject(name: name));

  /// Set the installation earthing system (drives RCD policy + main earthing).
  void setEarthingSystem(EarthingSystem system) =>
      _commit(_withProject(earthingSystem: system));

  /// Set the prospective origin fault level (Fold-1 busbar short-circuit
  /// withstand). Null resets to the app default (16 kA). Non-positive values are
  /// ignored (the engine guards faultKa ≤ 0, but we avoid persisting garbage).
  void setOriginFaultLevel(Current? a) {
    if (a != null && a.amperes <= 0) return;
    _commit(a == null
        ? _withProject(clearOriginFaultLevelA: true)
        : _withProject(originFaultLevelA: a));
  }

  /// Set the busbar clearing time (s) for the Fold-1 withstand thermal check.
  /// Null resets to the app default (0.1 s). Non-positive values are ignored.
  void setBusbarClearingTime(double? s) {
    if (s != null && s <= 0) return;
    _commit(s == null
        ? _withProject(clearBusbarClearingTimeS: true)
        : _withProject(busbarClearingTimeS: s));
  }

  // ── Source-spine intents (genset / capacitor / transformer / dual-tx) ───────
  // Edit the SOURCE chain drawn above the panel tree (the overview / riser /
  // interactive-canvas head + the PDF / DXF export, one `_buildSourceSpine`
  // geometry). All immutable, all through [_withProject] so the additive A8
  // fields survive. The capacitor / transformer are DRAWING inputs only (they
  // never feed a sizing path) — // VERIFY engineer-supplied values.

  /// Rebuild [ElectricalSources] off the current project, replacing only the
  /// generator (or clearing it). When the result has no generator / solar /
  /// battery and no hybrid flag, collapses to null so an emptied editor leaves
  /// no phantom `sources` map.
  ElectricalSources? _sourcesWith({
    GeneratorSource? generator,
    bool clearGenerator = false,
  }) {
    final cur = state.sources;
    final gen = clearGenerator ? null : (generator ?? cur?.generator);
    final solar = cur?.solar;
    final battery = cur?.battery;
    final hybrid = cur?.hybridInverter;
    if (gen == null && solar == null && battery == null && hybrid == null) {
      return null;
    }
    return ElectricalSources(
      generator: gen,
      solar: solar,
      battery: battery,
      hybridInverter: hybrid,
    );
  }

  /// Set (or clear) the standby/prime generator on the source spine.
  void setGenerator(GeneratorSource? gen) {
    final next = _sourcesWith(generator: gen, clearGenerator: gen == null);
    _commit(next == null
        ? _withProject(clearSources: true)
        : _withProject(sources: next));
  }

  /// Set the genset rating (kVA). Null ⇒ auto-size from demand (the ladder
  /// snap); non-positive ignored. Preserves the genset's mode / transfer.
  void setGeneratorKva(ApparentPower? kva) {
    if (kva != null && kva.voltAmperes <= 0) return;
    final cur = state.sources?.generator ?? const GeneratorSource();
    setGenerator(GeneratorSource(
      kva: kva,
      backupFraction: cur.backupFraction,
      mode: cur.mode,
      transfer: cur.transfer,
    ));
  }

  /// Set the genset duty mode (standby / prime).
  void setGeneratorMode(GeneratorMode mode) {
    final cur = state.sources?.generator ?? const GeneratorSource();
    setGenerator(GeneratorSource(
      kva: cur.kva,
      backupFraction: cur.backupFraction,
      mode: mode,
      transfer: cur.transfer,
    ));
  }

  /// Set the genset transfer arrangement (ATS / manual).
  void setGeneratorTransfer(GeneratorTransfer transfer) {
    final cur = state.sources?.generator ?? const GeneratorSource();
    setGenerator(GeneratorSource(
      kva: cur.kva,
      backupFraction: cur.backupFraction,
      mode: cur.mode,
      transfer: transfer,
    ));
  }

  /// Set the installed PF-correction capacitor bank (kvar). Null / non-positive
  /// ⇒ clear (falls back to the advanced study's recommended kvar caption).
  void setCapacitorBankKvar(double? kvar) {
    _commit((kvar == null || kvar <= 0)
        ? _withProject(clearCapacitorBankKvar: true)
        : _withProject(capacitorBankKvar: kvar));
  }

  /// Set the explicit transformer rating (kVA). Null / non-positive ⇒ clear
  /// (falls back to the demand-derived ladder snap).
  void setTransformerKva(ApparentPower? kva) {
    _commit((kva == null || kva.voltAmperes <= 0)
        ? _withProject(clearTransformerKva: true)
        : _withProject(transformerKva: kva));
  }

  /// Force / clear the dual-transformer (split-bus) MV supply.
  void setDualTransformer(bool value) =>
      _commit(_withProject(dualTransformer: value));

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
    ElectricalSources? sources,
    bool clearSources = false,
    bool? dualTransformer,
    double? capacitorBankKvar,
    bool clearCapacitorBankKvar = false,
    ApparentPower? transformerKva,
    bool clearTransformerKva = false,
  }) =>
      ElectricalProject(
        id: state.id,
        name: name ?? state.name,
        panels: panels ?? state.panels,
        earthingSystem: earthingSystem ?? state.earthingSystem,
        sources: clearSources ? null : (sources ?? state.sources),
        dualTransformer: dualTransformer ?? state.dualTransformer,
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
        capacitorBankKvar: clearCapacitorBankKvar
            ? null
            : (capacitorBankKvar ?? state.capacitorBankKvar),
        transformerKva: clearTransformerKva
            ? null
            : (transformerKva ?? state.transformerKva),
      );

  /// Load the built-in sample project (a user action — undoable, so one
  /// Ctrl+Z returns to the pre-sample project). Surfaced as the empty-state
  /// card's "Load sample project" action.
  void resetToSample() => _commit(sampleElectricalProject());

  // ── Edit intents (the interactive editor) ──────────────────────────────────
  // Every method rebuilds the panel list immutably and routes through
  // [_withProject] so the additive A8 project fields (sources / dual-transformer
  // / occupancy / site) are never silently dropped.

  /// Replace one panel within the list (by id), preserving order. No-op when the
  /// id is unknown. The single funnel every per-panel edit routes through.
  /// [record] = false skips the undo snapshot (LIVE-DRAG intents only — pair
  /// with [pushUndoSnapshot] at drag start, like the mechanical `moveNode`).
  void _replacePanel(String panelId, ElectricalPanel Function(ElectricalPanel) f,
      {bool record = true}) {
    var changed = false;
    final panels = <ElectricalPanel>[];
    for (final p in state.panels) {
      if (p.id == panelId) {
        // Commit only when [f] actually produced a DIFFERENT panel — a no-op
        // transform (an intent whose guard returns the same instance, e.g.
        // `setPanelSystem` when the system is unchanged) must not record a
        // phantom undo step. copyWith always returns a fresh instance, so real
        // edits are byte-identical to before.
        final np = f(p);
        if (!identical(np, p)) changed = true;
        panels.add(np);
      } else {
        panels.add(p);
      }
    }
    if (!changed) return;
    final next = _withProject(panels: panels);
    if (record) {
      _commit(next);
    } else {
      state = next;
    }
  }

  /// Replace one circuit on one panel (by id), preserving order. No-op when
  /// either id is unknown.
  void _replaceCircuit(String panelId, String circuitId,
      ElectricalCircuit Function(ElectricalCircuit) f,
      {bool record = true}) {
    _replacePanel(
      panelId,
      (p) => p.copyWith(circuits: [
        for (final c in p.circuits)
          if (c.id == circuitId) f(c) else c,
      ]),
      record: record,
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
    StarterType? starterType,
    bool clearStarterType = false,
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
        starterType: starterType,
        clearStarterType: clearStarterType,
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
    _commit(_withProject(panels: panels));
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
    _commit(_withProject(panels: panels));
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
    _commit(_withProject(panels: [...state.panels, panel]));
  }

  /// Delete a panel by id.
  void deletePanel(String id) {
    _commit(_withProject(
      panels: [
        for (final p in state.panels)
          if (p.id != id) p,
      ],
    ));
  }

  /// Duplicate a panel (I5): a fresh-id copy of the board + every circuit, a
  /// "(copy)" name, and the tag DROPPED (an issued drawing must not carry two
  /// identical panel designations). A copied FEEDER way drops its target (a
  /// feeder supplies exactly one panel), and the copy starts UTILITY-fed (the
  /// original's incoming feeder still points at the original). Both position
  /// spaces (the abstract single-line `x,y` and the geo `layoutPos`) are nudged
  /// so the copy doesn't land exactly on top. Undoable in one step; no-op when
  /// the id is unknown.
  void duplicatePanel(String id) {
    final src = state.panels.where((p) => p.id == id).firstOrNull;
    if (src == null) return;
    const off = 40.0;
    final circuits = [
      for (final c in src.circuits)
        c.copyWith(
          id: _freshId('c'),
          // Drop a feeder's target (mirrors duplicateCircuit's sentinel).
          feedsPanelId: c.feedsPanelId == null ? null : '',
        ),
    ];
    final copy = src.copyWith(
      id: _freshId('panel'),
      name: '${src.name} (copy)',
      clearTag: true,
      sourceType: PanelSource.utility,
      clearFedByCircuitId: true,
      x: src.x == null ? null : src.x! + off,
      y: src.y == null ? null : src.y! + off,
      layoutPos: src.layoutPos
          ?.copyWith(x: src.layoutPos!.x + off, y: src.layoutPos!.y + off),
      circuits: circuits,
    );
    _commit(_withProject(panels: [...state.panels, copy]));
  }

  /// Rename a panel.
  void renamePanel(String id, String name) =>
      _replacePanel(id, (p) => p.copyWith(name: name));

  /// Set (or clear, with null/empty) a panel's short designation tag
  /// ("LP-1", "MDP") — the id printed on the issued drawings.
  void setPanelTag(String id, String? tag) => _replacePanel(
      id,
      (p) => (tag == null || tag.isEmpty)
          ? p.copyWith(clearTag: true)
          : p.copyWith(tag: tag));

  /// Set a panel's diversity factor (clamped 0–1).
  void setPanelDiversity(String id, double factor) => _replacePanel(
      id, (p) => p.copyWith(diversityFactor: factor.clamp(0.0, 1.0)));

  /// Set (or clear, with null / a no-op spec) a panel's spare-ways /
  /// future-load headroom — the CADANGAN rows + the incomer/busbar future
  /// uplift. A 0 %-0-way spec collapses to null so an emptied editor leaves
  /// the sizing byte-identical.
  void setPanelHeadroom(String id, HeadroomSpec? spec) => _replacePanel(
      id,
      (p) => (spec == null ||
              (spec.sparePercentage <= 0 && spec.spareWays <= 0))
          ? p.copyWith(clearHeadroom: true)
          : p.copyWith(headroom: spec));

  /// Toggle the essential (genset-backed) flag.
  void setPanelEssential(String id, bool value) =>
      _replacePanel(id, (p) => p.copyWith(essential: value));

  /// Toggle the UPS / critical-backed flag.
  void setPanelUpsBacked(String id, bool value) =>
      _replacePanel(id, (p) => p.copyWith(upsBacked: value));

  /// Toggle the tenant sub-metered flag.
  void setPanelSubmeter(String id, bool value) =>
      _replacePanel(id, (p) => p.copyWith(submeter: value));

  /// Set a panel's electrical system (1-phase / 3-phase), snapping its nominal
  /// voltage to the conventional value for that system (220 V single / 400 V
  /// three) — so a board created as a 1φ stub (the drop-a-floating-load flow)
  /// can become the 3φ sub-board a design needs WITHOUT delete-and-recreate,
  /// which would lose every way (G7). Undoable in one step; no-op when the id is
  /// unknown or the system is unchanged. The paired 220/400 V convention mirrors
  /// [addPanel] / [addFloatingLoad].
  void setPanelSystem(String id, ElectricalSystem system) => _replacePanel(
        id,
        (p) => p.system == system
            ? p
            : p.copyWith(
                system: system,
                voltage: system == ElectricalSystem.singlePhase
                    ? const Voltage(220)
                    : const Voltage(400),
              ),
      );

  // ── Spatial-canvas intents (Wave 5) ────────────────────────────────────────
  // Layout positions + feeder topology edits for the single-line canvas. All
  // additive (only `x`/`y` + the existing feeder fields move) and funnelled
  // through the per-panel/per-project replacers.

  /// Set a panel's canvas position (world px) — the live-drag intent (mirrors
  /// the mechanical canvas `moveNode`: no undo recording — pair with
  /// [pushUndoSnapshot] at drag start so the whole move is ONE undo step).
  /// No-op when the id is unknown.
  void setPanelPosition(String id, double x, double y) =>
      _replacePanel(id, (p) => p.copyWith(x: x, y: y), record: false);

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
    _commit(_withProject(panels: [...state.panels, panel]));
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
    _commit(_withProject(panels: panels));
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
    _commit(_withProject(panels: panels));
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
    _commit(_withProject(panels: [...state.panels, panel]));
  }

  // ── Geo-layout intents (Wave 6) ────────────────────────────────────────────
  // The Layout view places panels + loads on the calibrated PDF substrate. These
  // edit the GEO placement (`layoutPos` / `loadPos`) — a SEPARATE space from the
  // abstract single-line `x`/`y` above (a node can carry both). All additive and
  // funnelled through the per-panel/per-circuit replacers; the engine derives the
  // cable run length from the placement (`resolveCircuitLength`).

  /// Place / move a panel on the calibrated layout (or clear with a null [pos]).
  /// No-op when the id is unknown. A LIVE-DRAG intent (called per pan-update),
  /// so it never records undo itself — callers [pushUndoSnapshot] at drag start
  /// / before a one-shot placement so the move is ONE undo step.
  void setPanelLayoutPos(String panelId, LayoutPos? pos) => _replacePanel(
        panelId,
        (p) => pos == null
            ? p.copyWith(clearLayoutPos: true)
            : p.copyWith(layoutPos: pos),
        record: false,
      );

  /// Place / move one circuit's LOAD on the calibrated layout (or clear with a
  /// null [pos]). No-op when either id is unknown. A LIVE-DRAG intent — see
  /// [setPanelLayoutPos] for the undo pairing.
  void setLoadPos(String panelId, String circuitId, LayoutPos? pos) =>
      _replaceCircuit(
        panelId,
        circuitId,
        (c) => pos == null
            ? c.copyWith(clearLoadPos: true)
            : c.copyWith(loadPos: pos),
        record: false,
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
    _commit(_withProject(panels: [...state.panels, panel]));
  }

  /// Monotonic id source for new panels / circuits (deterministic per process,
  /// distinct across calls — sufficient for in-memory editing).
  static int _idSeq = 0;
  String _freshId(String prefix) => '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_idSeq++}';

  /// Fold the MechX-sized MEP equipment (A5) into the dedicated "MEP Equipment"
  /// panel — an UPSERT keyed by `sourceEquipmentId`, NOT a wholesale rebuild
  /// (G2). This is the unified payoff: a pump/fan/fire-pump the mechanical engine
  /// sized appears here as a sized electrical circuit, no re-entry — WITHOUT
  /// nuking the engineer's work every time the plan changes:
  ///
  ///   * a derived way whose source equipment still exists is REFRESHED in place
  ///     — only the machine-owned load fields (`flaOverrideA`, `loadW`, `motorKw`)
  ///     are re-derived; the user-set name / cableType / length / starterType /
  ///     phases / life-safety are PRESERVED;
  ///   * a derived way whose source node is GONE is dropped;
  ///   * a user-ADDED way on the panel (no `sourceEquipmentId`) is preserved;
  ///   * a newly-placed piece of equipment is appended;
  ///   * the panel's own name / tag / diversity / headroom / position / flags
  ///     are preserved once the board exists.
  ///
  /// An empty result with no existing panel is a strict no-op; a merge that ends
  /// with no ways removes the panel.
  ///
  /// UNDO-EXEMPT: a DERIVED MEP-feed sync, not a user edit — it neither pushes a
  /// snapshot nor records a timeline entry, and it leaves both stacks intact (an
  /// undo to a pre-sync snapshot simply predates the synced panel; the reactive
  /// listener re-asserts it on the next equipment change).
  void syncMepEquipment(List<ElectricalCircuit> derived) {
    final existing =
        state.panels.where((p) => p.id == kMepEquipmentPanelId).firstOrNull;
    // Strict no-op when there is nothing to sync AND no MEP panel to touch — so
    // the reactive listener can never resurrect a panel on an empty project: a
    // fresh launch stays `const ElectricalProject()`.
    if (derived.isEmpty && existing == null) return;

    // Index the freshly-derived circuits by their source-equipment id.
    final derivedBySource = <String, ElectricalCircuit>{
      for (final c in derived)
        if (c.sourceEquipmentId != null) c.sourceEquipmentId!: c,
    };

    final merged = <ElectricalCircuit>[];
    final refreshed = <String>{};
    if (existing != null) {
      for (final c in existing.circuits) {
        final src = c.sourceEquipmentId;
        if (src == null) {
          // A user-ADDED way (not machine-derived) — preserve verbatim.
          merged.add(c);
          continue;
        }
        final fresh = derivedBySource[src];
        if (fresh == null) continue; // source equipment removed → drop the way.
        // Source still present → refresh ONLY the derived load fields, keeping
        // the user's name / cableType / length / starterType / phases / flags.
        merged.add(c.copyWith(
          loadW: fresh.loadW,
          motorKw: fresh.motorKw,
          flaOverrideA: fresh.flaOverrideA,
        ));
        refreshed.add(src);
      }
    }
    // Append any newly-placed equipment not already on the board.
    for (final c in derived) {
      final src = c.sourceEquipmentId;
      if (src == null || refreshed.contains(src)) continue;
      merged.add(c);
      refreshed.add(src);
    }

    final others =
        state.panels.where((p) => p.id != kMepEquipmentPanelId).toList();
    if (merged.isEmpty) {
      // Nothing left to distribute — remove the (now-empty) panel.
      if (existing == null) return;
      state = _withProject(panels: others);
      return;
    }
    final panel = existing == null
        ? ElectricalPanel(
            id: kMepEquipmentPanelId,
            name: 'MEP Equipment',
            tag: 'MEP',
            voltage: const Voltage(400),
            circuits: merged,
          )
        : existing.copyWith(circuits: merged);
    state = _withProject(panels: [...others, panel]);
  }
}

/// The machine-minted new-board designations ('Sub-panel N' name / 'SP-N' tag).
final RegExp _kSubPanelNamePattern =
    RegExp(r'^sub-panel\s+(\d+)$', caseSensitive: false);
final RegExp _kSpTagPattern = RegExp(r'^sp-(\d+)$', caseSensitive: false);

/// The first FREE ordinal for a freshly minted 'Sub-panel N' / 'SP-N' board
/// (G8): max+1 across BOTH the existing panel NAMES and TAGS, so deleting
/// SP-2 of three then adding never re-mints a designation an issued schedule
/// already carries (collision-proof by construction — simpler than hole
/// filling, and a designation is never reused). Shared by both mint sites
/// (the toolbar Add-panel and the blank-canvas feeder drop).
int nextSubPanelOrdinal(List<ElectricalPanel> panels) {
  var maxSeen = 0;
  for (final p in panels) {
    for (final match in [
      _kSubPanelNamePattern.firstMatch(p.name.trim()),
      if (p.tag != null) _kSpTagPattern.firstMatch(p.tag!.trim()),
    ]) {
      final n = match == null ? null : int.tryParse(match.group(1)!);
      if (n != null && n > maxSeen) maxSeen = n;
    }
  }
  return maxSeen + 1;
}

/// A small, representative built-in project: a 3-phase main distribution panel
/// (MDP) fed from the utility, with a mix of lighting, socket, HVAC, motor and
/// feeder ways, feeding a single-phase lighting panel (LP-1). Demonstrates the
/// schedule, phase balancing, the feeder tree and the supply summary.
/// NOT auto-seeded (A2) — loaded only by the explicit [ElectricalProjectController.resetToSample]
/// user action (the empty-state "Load sample project" button) and by tests.
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
