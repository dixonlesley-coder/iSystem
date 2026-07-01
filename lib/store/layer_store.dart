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
