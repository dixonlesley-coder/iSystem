/// Riverpod store for the user's reusable assemblies / blocks (E5) — named
/// groups of drawn nodes + edges (the WC toilet group, the pump-room hookup, a
/// shaft riser set) an engineer saves once and re-stamps across projects.
///
/// The list is owned here (mutable) and persisted with the project via
/// `DesignSettings.savedAssemblies` (`applyDocument` calls [set] on load,
/// `buildDocument` reads the state) — mirroring `fixture_library_store.dart`'s
/// shape. Each [SavedAssembly] carries value-copies of the captured nodes/edges
/// serialized with the SAME network encoding a drawn node/edge uses, so a stamp
/// re-instantiates them with fresh ids via the existing clone path.
///
/// Default build() ⇒ empty, so a project that never saved a block is
/// byte-identical to before this feature.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../data/project_document.dart' show SavedAssembly;

final assembliesProvider =
    NotifierProvider<AssembliesController, List<SavedAssembly>>(
  AssembliesController.new,
);

class AssembliesController extends Notifier<List<SavedAssembly>> {
  /// Monotonic id counter for `asm-<n>` ids. Advanced past any loaded ids on
  /// [set] so a saved-then-loaded project never re-issues a colliding id.
  int _seq = 0;

  @override
  List<SavedAssembly> build() => const [];

  /// Replace the whole list (used by `applyDocument` on load). Advances the id
  /// counter past the loaded ids so a subsequent save never collides.
  void set(List<SavedAssembly> list) {
    state = List.unmodifiable(list);
    _seq = _seqAfter(list);
  }

  /// Add (or upsert by id) an assembly.
  void add(SavedAssembly assembly) {
    state = List.unmodifiable([
      for (final a in state)
        if (a.id != assembly.id) a,
      assembly,
    ]);
  }

  /// Remove the assembly with [id] (no-op if absent).
  void remove(String id) {
    if (!state.any((a) => a.id == id)) return;
    state = List.unmodifiable(state.where((a) => a.id != id));
  }

  /// Capture the current [nodeIds]/[edgeIds] selection of [net] into a NEW named
  /// assembly and add it. The captured node set is the chosen nodes PLUS both
  /// endpoints of each chosen edge; only edges whose BOTH endpoints fall in that
  /// set are kept (danglers dropped) — mirroring the clipboard copy keep-logic.
  /// Deep value-copies are stored so later edits don't mutate the saved block.
  /// Returns the new assembly, or null when [name] is blank or nothing captures.
  SavedAssembly? saveSelection(
    String name,
    Network net,
    Set<String> nodeIds,
    Set<String> edgeIds,
  ) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final keptIds = <String>{...nodeIds};
    for (final e in net.edges) {
      if (!edgeIds.contains(e.id)) continue;
      keptIds.add(e.fromId);
      keptIds.add(e.toId);
    }
    final keptEdges = <NetEdge>[
      for (final e in net.edges)
        if (edgeIds.contains(e.id) &&
            keptIds.contains(e.fromId) &&
            keptIds.contains(e.toId))
          e.copyWith(),
    ];
    final keptNodes = <NetNode>[
      for (final n in net.nodes)
        if (keptIds.contains(n.id)) n.copyWith(),
    ];
    if (keptNodes.isEmpty) return null;
    final assembly = SavedAssembly(
      id: 'asm-${_seq++}',
      name: trimmed,
      nodes: keptNodes,
      edges: keptEdges,
    );
    add(assembly);
    return assembly;
  }

  /// One past the largest numeric suffix of the loaded ids (so `saveSelection`
  /// never re-issues an id already in the list).
  static int _seqAfter(List<SavedAssembly> list) {
    var max = -1;
    for (final a in list) {
      final v = int.tryParse(a.id.replaceAll(RegExp(r'[^0-9]'), ''));
      if (v != null && v > max) max = v;
    }
    return max + 1;
  }
}
