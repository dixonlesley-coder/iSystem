/// Riverpod store for the N23 equipment-schedule "Model / spec" overrides — a
/// stable equipment tag (`"P-01"`, `"AHU-03"`, …) → free-text datasheet
/// model/spec string the engineer types once so the ISSUED equipment schedule
/// (Markdown / CSV / PDF, `report/equipment_schedule.dart`) carries a real
/// make/model instead of the engine's `'—'` placeholder.
///
/// The map is keyed by TAG, not by row identity: the tag is the one stable
/// handle a schedule row carries across a re-solve (duties change, the
/// procured pump doesn't) — see `PumpScheduleItem.modelSpec` /
/// `FanScheduleItem.modelSpec`, the existing per-item override hooks this
/// store feeds (`project_panel.dart`'s `gatherEquipmentScheduleData`).
///
/// Owned here (mutable) and persisted with the project via
/// `DesignSettings.equipmentModelSpecs` (`applyDocument` calls [set] on load,
/// `buildDocument` reads the state) — mirroring `fixture_library_store.dart`'s
/// shape.
///
/// Default build() ⇒ empty, so a project that never entered a spec is
/// byte-identical to before this feature.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

final equipmentModelSpecProvider =
    NotifierProvider<EquipmentModelSpecController, Map<String, String>>(
  EquipmentModelSpecController.new,
);

class EquipmentModelSpecController extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  /// Replace the whole map (used by `applyDocument` on load).
  void set(Map<String, String> specs) => state = Map.unmodifiable(specs);

  /// Set / clear the model/spec for one equipment [tag]. An empty/whitespace
  /// [value] REMOVES the entry (so clearing a field returns to the engine's
  /// own `'—'` placeholder rather than pinning an empty string).
  void setSpec(String tag, String value) {
    final trimmed = value.trim();
    final next = Map<String, String>.from(state);
    if (trimmed.isEmpty) {
      next.remove(tag);
    } else {
      next[tag] = trimmed;
    }
    state = Map.unmodifiable(next);
  }

  /// The entered spec for [tag], or null when none was entered.
  String? specFor(String tag) => state[tag];
}
