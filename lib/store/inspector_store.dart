import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the right-side inspector (the [ProjectPanel] / electrical Loads
/// column) is collapsed to a thin toggle strip, freeing the canvas to dominate
/// the workspace. Defaults to EXPANDED (the full panel) so a fresh launch — and
/// the golden-screenshot test, which does not touch this — keeps the inspector
/// visible.
final inspectorCollapsedProvider =
    NotifierProvider<InspectorCollapsedController, bool>(
  InspectorCollapsedController.new,
);

class InspectorCollapsedController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void set(bool collapsed) => state = collapsed;
}

/// Per-section EXPANDED/collapsed state for the dense [ProjectPanel] inspector,
/// keyed by section name ('Draw', 'Results', 'HVAC', …). A section absent from
/// the map has never been toggled, so its caller-supplied default applies; a
/// present entry is the user's explicit choice. This is transient UI state — it
/// is intentionally NOT persisted to `.mechx`, so reopening a project starts
/// from the defaults again (a simple UI preference, no migration surface).
final sectionVisibilityProvider =
    NotifierProvider<SectionVisibilityController, Map<String, bool>>(
  SectionVisibilityController.new,
);

class SectionVisibilityController extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  /// Flip [name]. If it has never been seen, [defaultExpanded] is its current
  /// (implicit) state, so the toggle lands on its opposite.
  void toggle(String name, bool defaultExpanded) {
    final current = state[name] ?? defaultExpanded;
    set(name, !current);
  }

  /// Set [name] to [expanded] explicitly.
  void set(String name, bool expanded) {
    state = {...state, name: expanded};
  }
}

/// Identity key for [sectionExpandedProvider]: the section [name] plus the
/// [defaultExpanded] seed used when it has never been toggled. Two keys with the
/// same name+default share one derived provider, so the lookup is memoized and a
/// header only rebuilds when its own section's expansion changes (not on every
/// map mutation elsewhere).
class SectionKey {
  final String name;
  final bool defaultExpanded;
  const SectionKey(this.name, this.defaultExpanded);

  @override
  bool operator ==(Object other) =>
      other is SectionKey &&
      other.name == name &&
      other.defaultExpanded == defaultExpanded;

  @override
  int get hashCode => Object.hash(name, defaultExpanded);
}

/// Whether one section is expanded — the user's toggle if present, else the
/// caller's [SectionKey.defaultExpanded]. Derived so a disclosure header watches
/// only its own boolean.
final sectionExpandedProvider = Provider.family<bool, SectionKey>((ref, key) {
  final map = ref.watch(sectionVisibilityProvider);
  return map[key.name] ?? key.defaultExpanded;
});
