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

import 'network_store.dart' show networkControllerProvider;

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
  /// E3 — the draw SERVICE each mechanical layer was last drawing with, so a
  /// round-trip through another discipline doesn't silently reset Exhaust to
  /// Supply. Transient session state (never persisted): a reopened project
  /// starts from each layer's first service, exactly as before.
  final Map<DisciplineLayer, ServiceType> _lastService = {};

  @override
  DisciplineLayer build() {
    _lastService.clear();
    return DisciplineLayer.plumbing;
  }

  /// The service [layer] should draw with when it becomes active: the one it
  /// was last drawing with (if still one of its own services), else its first.
  /// Null for a layer with no `ServiceType` services (electrical).
  ServiceType? rememberedService(DisciplineLayer layer) {
    final scoped = servicesFor(layer);
    if (scoped.isEmpty) return null;
    final last = _lastService[layer];
    return (last != null && scoped.contains(last)) ? last : scoped.first;
  }

  void set(DisciplineLayer layer) {
    if (state == layer) return;
    final previous = state;
    // E3: bank the OUTGOING layer's current draw service before switching.
    final drawing = ref.read(networkControllerProvider).service;
    if (servicesFor(previous).contains(drawing)) {
      _lastService[previous] = drawing;
    }
    state = layer;
    // The active layer is always visible — you can't edit a hidden layer.
    final vis = ref.read(layerVisibilityProvider);
    if (!vis.contains(layer)) {
      ref.read(layerVisibilityProvider.notifier).show(layer);
    }
    // F1: the layer you now EDIT can't remain a locked reference layer.
    ref.read(lockedDisciplinesProvider.notifier).unlock(layer);
    // J5: an isolate belongs to the layer whose control raised it — park the
    // outgoing layer's hidden services and restore the incoming layer's, so a
    // filter can never keep applying while its funnel is off-screen.
    ref.read(hiddenServicesProvider.notifier).parkOnLayerSwitch(previous, layer);
    // E3: restore the incoming layer's draw service. Doing it HERE (rather than
    // leaving the inspector's out-of-scope fallback to fire) means the fallback
    // never sees an out-of-scope service, so it never resets to `scoped.first`.
    final next = rememberedService(layer);
    if (next != null && ref.read(networkControllerProvider).service != next) {
      ref.read(networkControllerProvider.notifier).setService(next);
    }
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
  /// J5 — each layer's PARKED isolate: the services it had hidden when it
  /// stopped being the active layer. Restored verbatim when that layer becomes
  /// active again, so an isolate is never lost — but never applies while its
  /// funnel (which only renders for the active layer) is off-screen either.
  final Map<DisciplineLayer, Set<ServiceType>> _parked = {};

  @override
  Set<ServiceType> build() {
    _parked.clear();
    return const {};
  }

  bool isHidden(ServiceType s) => state.contains(s);

  void toggle(ServiceType s) {
    if (state.contains(s)) {
      state = {...state}..remove(s);
    } else {
      state = {...state, s};
    }
  }

  /// The services [layer] currently has parked (empty when it has none) —
  /// exposed so a caller can tell "no isolate" from "an isolate waiting".
  Set<ServiceType> parkedFor(DisciplineLayer layer) =>
      _parked[layer] ?? const {};

  /// J5 — move the isolate with its layer: park every hidden service belonging
  /// to [from] (they stop filtering the moment their control disappears) and
  /// restore any [to] had parked earlier (AUTO-RESTORE, so switching away and
  /// back is a round trip, not a silent loss of the drafter's isolate).
  ///
  /// Services that belong to neither layer are left exactly as they are.
  void parkOnLayerSwitch(DisciplineLayer from, DisciplineLayer to) {
    if (from == to) return;
    final fromServices = servicesFor(from).toSet();
    final parked = {
      for (final s in state)
        if (fromServices.contains(s)) s,
    };
    if (parked.isEmpty) {
      _parked.remove(from);
    } else {
      _parked[from] = parked;
    }
    final restored = _parked.remove(to) ?? const <ServiceType>{};
    final next = {
      for (final s in state)
        if (!fromServices.contains(s)) s,
      ...restored,
    };
    if (next.length != state.length || !next.containsAll(state)) {
      state = next;
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
