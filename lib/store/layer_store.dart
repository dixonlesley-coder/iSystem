/// Discipline-LAYER state for the unified Layout canvas — the convergence piece
/// that puts plumbing, HVAC and electrical on ONE shared PDF substrate ("same
/// PDF, work on it at different layers").
///
/// The disciplines map onto the EXISTING model with no new copy:
///  • [DisciplineLayer.plumbing] — the mechanical non-air services (cold/hot
///    water, drainage, vent, rainwater, sprinkler, hydrant);
///  • [DisciplineLayer.hvac] — the mechanical air services (supply / return /
///    exhaust), via the engine's `ServiceType.isAir`;
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

/// A design discipline shown as a layer on the unified Layout canvas.
enum DisciplineLayer { plumbing, hvac, electrical }

extension DisciplineLayerInfo on DisciplineLayer {
  /// Short label for the layer switcher / chips.
  String get label => switch (this) {
        DisciplineLayer.plumbing => 'Plumbing',
        DisciplineLayer.hvac => 'HVAC',
        DisciplineLayer.electrical => 'Electrical',
      };

  /// True for the two MECHANICAL disciplines (drawn from the `network` model);
  /// false for electrical (drawn from the `ElectricalProject` placements).
  bool get isMechanical =>
      this == DisciplineLayer.plumbing || this == DisciplineLayer.hvac;
}

/// The discipline a mechanical [ServiceType] belongs to: air → HVAC, else
/// plumbing. (Electrical has no `ServiceType` — it's a separate model.)
DisciplineLayer disciplineOf(ServiceType service) =>
    service.isAir ? DisciplineLayer.hvac : DisciplineLayer.plumbing;

/// The mechanical services that belong to [layer]. Empty for electrical (which
/// is not a `ServiceType`-based discipline).
List<ServiceType> servicesFor(DisciplineLayer layer) => switch (layer) {
      DisciplineLayer.plumbing =>
        ServiceType.values.where((s) => !s.isAir).toList(growable: false),
      DisciplineLayer.hvac =>
        ServiceType.values.where((s) => s.isAir).toList(growable: false),
      DisciplineLayer.electrical => const <ServiceType>[],
    };

/// The active (editable) discipline layer. Defaults to plumbing — the canvas's
/// historical drawing discipline. Setting it leaves visibility untouched (a
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
