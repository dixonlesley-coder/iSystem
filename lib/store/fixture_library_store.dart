/// Riverpod store for the user-defined fixture library — the list of
/// [CustomFixture] types an engineer can assign to nodes when the built-in SNI
/// [PlumbingFixture] set does not cover a fixture they need.
///
/// The library is owned here (mutable) and persisted with the project via
/// `DesignSettings.fixtureLibrary` (`applyDocument` calls [set] on load,
/// `buildDocument` reads the state). A node references a library entry by id
/// (`NetNode.customFixtureId`); the sizing layer (`sizing_store`) resolves the
/// id to the entry's UBAP / DFU loads.
///
/// Default build() ⇒ empty, so a project that never defined a custom fixture is
/// byte-identical to before this feature.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/standards/custom_fixture.dart';

import '../ui/strings/app_strings.dart';
import 'app_state.dart' show localeProvider;
import 'history_store.dart' show SettingsUndoEntry, settingsHistoryProvider;

final fixtureLibraryProvider =
    NotifierProvider<FixtureLibraryController, List<CustomFixture>>(
  FixtureLibraryController.new,
);

class FixtureLibraryController extends Notifier<List<CustomFixture>> {
  @override
  List<CustomFixture> build() => const [];

  /// Replace the whole library (used by `applyDocument` on load).
  void set(List<CustomFixture> fixtures) => state = List.unmodifiable(fixtures);

  /// Round 28 (persist-undo-2-2) — a library edit changes the UBAP / DFU the
  /// sizer reads (it resizes pipes) and is persisted, so every add / update /
  /// remove records ONE [UndoDomain.settings] step on the global timeline;
  /// an edit that changes nothing records nothing. Ctrl+Z used to revert the
  /// previous unrelated network edit and leave the new loads in place.
  void _commit(List<CustomFixture> next) {
    final previous = state;
    final applied = List<CustomFixture>.unmodifiable(next);
    if (_same(previous, applied)) return;
    state = applied;
    ref.read(settingsHistoryProvider.notifier).record(SettingsUndoEntry(
          label: MechXStringsData(ref.read(localeProvider))(
              StringKey.undoLabelFixtureLibrary),
          undo: () => state = previous,
          redo: () => state = applied,
        ));
  }

  static bool _same(List<CustomFixture> a, List<CustomFixture> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].toJson().toString() != b[i].toJson().toString()) return false;
    }
    return true;
  }

  /// Add a fixture. If one with the same id already exists it is replaced
  /// (treated as an upsert), so a duplicate id never appears twice.
  void add(CustomFixture fixture) {
    final next = [
      for (final f in state)
        if (f.id != fixture.id) f,
      fixture,
    ];
    _commit(next);
  }

  /// Replace the fixture with the same id in-place (no-op if it is gone).
  void update(CustomFixture fixture) {
    if (!state.any((f) => f.id == fixture.id)) return;
    _commit([
      for (final f in state)
        if (f.id == fixture.id) fixture else f,
    ]);
  }

  /// Remove the fixture with [id] (no-op if absent).
  void remove(String id) {
    if (!state.any((f) => f.id == id)) return;
    _commit(state.where((f) => f.id != id).toList());
  }

  /// Look up a fixture by [id], or null if it is not in the library.
  CustomFixture? byId(String id) {
    for (final f in state) {
      if (f.id == id) return f;
    }
    return null;
  }
}
