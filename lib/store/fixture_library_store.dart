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

final fixtureLibraryProvider =
    NotifierProvider<FixtureLibraryController, List<CustomFixture>>(
  FixtureLibraryController.new,
);

class FixtureLibraryController extends Notifier<List<CustomFixture>> {
  @override
  List<CustomFixture> build() => const [];

  /// Replace the whole library (used by `applyDocument` on load).
  void set(List<CustomFixture> fixtures) => state = List.unmodifiable(fixtures);

  /// Add a fixture. If one with the same id already exists it is replaced
  /// (treated as an upsert), so a duplicate id never appears twice.
  void add(CustomFixture fixture) {
    final next = [
      for (final f in state)
        if (f.id != fixture.id) f,
      fixture,
    ];
    state = List.unmodifiable(next);
  }

  /// Replace the fixture with the same id in-place (no-op if it is gone).
  void update(CustomFixture fixture) {
    if (!state.any((f) => f.id == fixture.id)) return;
    state = List.unmodifiable([
      for (final f in state)
        if (f.id == fixture.id) fixture else f,
    ]);
  }

  /// Remove the fixture with [id] (no-op if absent).
  void remove(String id) {
    if (!state.any((f) => f.id == id)) return;
    state = List.unmodifiable(state.where((f) => f.id != id));
  }

  /// Look up a fixture by [id], or null if it is not in the library.
  CustomFixture? byId(String id) {
    for (final f in state) {
      if (f.id == id) return f;
    }
    return null;
  }
}
