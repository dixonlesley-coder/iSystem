/// Discipline-LAYER state for the unified Layout canvas — the convergence piece
/// that puts the MEP systems on ONE shared PDF substrate ("same PDF, work on it
/// at different layers").
///
/// Each layer is an engineering DISCIPLINE (the MEP+FP breakdown), mapped onto
/// the EXISTING model with no new copy. PLUMBING is ONE unified layer — you draw
/// all the plumbing pipework on a single canvas, and the elements stay separated
/// by their `ServiceType` for the riser / sizing / reports downstream:
///  • [DisciplineLayer.plumbing]  — ALL plumbing pipework: domestic water (cold
///    + hot), sanitary (drainage + vent), and storm (rainwater) — drawn together,
///    separated by service later;
///  • [DisciplineLayer.fire]      — fire protection (sprinkler, hydrant);
///  • [DisciplineLayer.hvac]      — the mechanical air services (supply / return
///    / exhaust), via the engine's `ServiceType.isAir`;
///  • [DisciplineLayer.electrical] — the electrical panels / loads / feeders
///    placed on the sheet (`ElectricalPanel.layoutPos` / `Circuit.loadPos`).
///
/// Two pieces of state drive the canvas:
///  • [activeDisciplineProvider] — the ONE layer being edited (its overlays are
///    interactive; the others render faded for coordination);
///  • [layerVisibilityProvider] — which disciplines are drawn at all (a layer
///    that is off is hidden entirely, active or not).
///
/// Pure Riverpod + a pure `ServiceType → discipline` mapping; no Flutter UI here
/// (it's imported by both the store-test and the widgets).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

/// A design discipline shown as a layer on the unified Layout canvas. PLUMBING
/// is one bucket for all pipework (water + sanitary + storm); FIRE / HVAC /
/// ELECTRICAL are their own disciplines.
enum DisciplineLayer { plumbing, fire, hvac, electrical }

extension DisciplineLayerInfo on DisciplineLayer {
  /// Short label for the layer switcher / chips.
  String get label => switch (this) {
        DisciplineLayer.plumbing => 'Plumbing',
        DisciplineLayer.fire => 'Fire',
        DisciplineLayer.hvac => 'HVAC',
        DisciplineLayer.electrical => 'Electrical',
      };

  /// True for the MECHANICAL disciplines (drawn from the `network` model); false
  /// for electrical (drawn from the `ElectricalProject` placements).
  bool get isMechanical => this != DisciplineLayer.electrical;
}

/// The discipline a mechanical [ServiceType] belongs to. All the plumbing
/// pipework — water, sanitary (drainage/vent), and storm — maps to the ONE
/// [DisciplineLayer.plumbing] layer (drawn together; the elements keep their
/// own `ServiceType` so the riser/sizing/reports still separate them).
/// (Electrical has no `ServiceType` — it's a separate model.)
DisciplineLayer disciplineOf(ServiceType service) => switch (service) {
      ServiceType.coldWater ||
      ServiceType.hotWater ||
      ServiceType.drainage ||
      ServiceType.vent ||
      ServiceType.rainwater =>
        DisciplineLayer.plumbing,
      ServiceType.fireSprinkler ||
      ServiceType.fireHydrant =>
        DisciplineLayer.fire,
      ServiceType.duct ||
      ServiceType.returnAir ||
      ServiceType.exhaust =>
        DisciplineLayer.hvac,
    };

/// The mechanical services that belong to [layer]. Empty for electrical (which
/// is not a `ServiceType`-based discipline). Derived from [disciplineOf] so the
/// two never drift.
List<ServiceType> servicesFor(DisciplineLayer layer) => layer ==
        DisciplineLayer.electrical
    ? const <ServiceType>[]
    : ServiceType.values
        .where((s) => disciplineOf(s) == layer)
        .toList(growable: false);

/// The active (editable) discipline layer. Defaults to plumbing — the canvas's
/// first drawing discipline. Setting it leaves visibility untouched (a
/// layer can be active without being toggled off, and the switcher keeps the
/// active layer visible).
final activeDisciplineProvider =
    NotifierProvider<ActiveDisciplineController, DisciplineLayer>(
  ActiveDisciplineController.new,
);

class ActiveDisciplineController extends Notifier<DisciplineLayer> {
  @override
  DisciplineLayer build() => DisciplineLayer.plumbing;

  void set(DisciplineLayer layer) {
    if (state == layer) return;
    state = layer;
    // The active layer is always visible — you can't edit a hidden layer.
    final vis = ref.read(layerVisibilityProvider);
    if (!vis.contains(layer)) {
      ref.read(layerVisibilityProvider.notifier).show(layer);
    }
    // F1: the layer you now EDIT can't remain a locked reference layer.
    ref.read(lockedDisciplinesProvider.notifier).unlock(layer);
  }
}

/// Which discipline layers are currently DRAWN on the canvas. Default: all
/// three visible (so the engineer sees the coordination context). A hidden
/// layer is omitted entirely; visible-but-not-active layers render faded.
final layerVisibilityProvider =
    NotifierProvider<LayerVisibilityController, Set<DisciplineLayer>>(
  LayerVisibilityController.new,
);

class LayerVisibilityController extends Notifier<Set<DisciplineLayer>> {
  @override
  Set<DisciplineLayer> build() => DisciplineLayer.values.toSet();

  bool isVisible(DisciplineLayer layer) => state.contains(layer);

  void show(DisciplineLayer layer) {
    if (state.contains(layer)) return;
    state = {...state, layer};
  }

  /// Toggle a layer's visibility. The ACTIVE layer can't be hidden (you edit
  /// it), so toggling the active layer off is a no-op.
  void toggle(DisciplineLayer layer) {
    if (state.contains(layer)) {
      if (layer == ref.read(activeDisciplineProvider)) return;
      state = {...state}..remove(layer);
    } else {
      state = {...state, layer};
    }
  }
}

/// F1 — reference-layer LOCK. A locked discipline still RENDERS exactly as
/// before (faded when it isn't the active layer), but its elements are excluded
/// from ALL canvas hit-testing / selection / drag / marquee — so a drafter
/// routing one trade can never accidentally grab, move or delete another
/// trade's faded coordination geometry. The ACTIVE layer can never be locked
/// (you edit it): [toggle] refuses to lock the active layer, and making a layer
/// active [unlock]s it. Default: nothing locked ⇒ every element hittable
/// (byte-identical to before). Transient UI state — not persisted to `.mechx`.
final lockedDisciplinesProvider =
    NotifierProvider<LockedDisciplinesController, Set<DisciplineLayer>>(
  LockedDisciplinesController.new,
);

class LockedDisciplinesController extends Notifier<Set<DisciplineLayer>> {
  @override
  Set<DisciplineLayer> build() => const {};

  bool isLocked(DisciplineLayer layer) => state.contains(layer);

  /// Toggle a layer's lock. The ACTIVE layer can't be locked (it's the one you
  /// edit), so locking the active layer is a no-op; unlocking always works.
  void toggle(DisciplineLayer layer) {
    if (state.contains(layer)) {
      state = {...state}..remove(layer);
    } else {
      if (layer == ref.read(activeDisciplineProvider)) return;
      state = {...state, layer};
    }
  }

  /// Drop a layer's lock — called when it becomes the active/edited layer so
  /// the lock never blocks editing the very layer you switched to.
  void unlock(DisciplineLayer layer) {
    if (!state.contains(layer)) return;
    state = {...state}..remove(layer);
  }
}

/// F4 — per-SERVICE view filter WITHIN a discipline layer. Plumbing folds five
/// services (cold/hot water, drainage, vent, rainwater) onto one layer and HVAC
/// three (supply/return/exhaust air); this hides individual services so a
/// drafter can isolate, say, cold water on a dense corridor. A hidden service is
/// omitted from the canvas RENDER and hit-test ONLY — a pure VIEW filter, so the
/// riser / sizing / reports still read the full model. Transient (NOT persisted
/// to `.mechx`). Default empty ⇒ every service shown ⇒ byte-identical.
final hiddenServicesProvider =
    NotifierProvider<HiddenServicesController, Set<ServiceType>>(
  HiddenServicesController.new,
);

class HiddenServicesController extends Notifier<Set<ServiceType>> {
  @override
  Set<ServiceType> build() => const {};

  bool isHidden(ServiceType s) => state.contains(s);

  void toggle(ServiceType s) {
    if (state.contains(s)) {
      state = {...state}..remove(s);
    } else {
      state = {...state, s};
    }
  }
}

/// The services whose elements are currently INERT to canvas interaction — the
/// union of every LOCKED discipline's services (F1) and the individually HIDDEN
/// services (F4). An element carrying one of these services is excluded from
/// hit-testing / selection / drag / marquee. Empty by default ⇒ byte-identical.
final inertServicesProvider = Provider<Set<ServiceType>>((ref) {
  final locked = ref.watch(lockedDisciplinesProvider);
  final hidden = ref.watch(hiddenServicesProvider);
  final out = <ServiceType>{...hidden};
  for (final l in locked) {
    out.addAll(servicesFor(l));
  }
  return out;
});
