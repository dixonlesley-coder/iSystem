import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'network_store.dart';
import 'project_store.dart';

/// Which domain controller owns a recorded action. Each domain keeps its own
/// snapshot stack; this enum is the global timeline's record of *which* domain
/// acted, so undo/redo can revert the genuinely most-recent edit regardless of
/// domain (the previous "all network, then all project" ordering was wrong).
enum UndoDomain { network, project }

/// A single, global undo/redo timeline across every domain. Domain controllers
/// call [HistoryController.record] from their forward mutations; undo/redo here
/// pop the timeline and drive the owning controller's local revert. The state
/// is a monotonically increasing revision so widgets can rebuild on change.
class HistoryController extends Notifier<int> {
  final List<UndoDomain> _past = [];
  final List<UndoDomain> _future = [];

  @override
  int build() => 0;

  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  /// Record that [domain] just performed a forward (undoable) action. Clears the
  /// redo timeline — a new action forks history.
  void record(UndoDomain domain) {
    _past.add(domain);
    _future.clear();
    if (_past.length > 1000) _past.removeAt(0);
    state++;
  }

  /// Undo the most recent action across all domains.
  void undo() {
    if (_past.isEmpty) return;
    final domain = _past.removeLast();
    _revert(domain, redo: false);
    _future.add(domain);
    state++;
  }

  /// Redo the most recently undone action.
  void redo() {
    if (_future.isEmpty) return;
    final domain = _future.removeLast();
    _revert(domain, redo: true);
    _past.add(domain);
    state++;
  }

  void _revert(UndoDomain domain, {required bool redo}) {
    switch (domain) {
      case UndoDomain.network:
        final c = ref.read(networkControllerProvider.notifier);
        redo ? c.redo() : c.undo();
      case UndoDomain.project:
        final c = ref.read(projectControllerProvider.notifier);
        redo ? c.redo() : c.undo();
    }
  }

  /// Drop the whole timeline — call when a document is opened/restored (a fresh
  /// baseline, like each domain controller clears its own stacks on load).
  void reset() {
    _past.clear();
    _future.clear();
    state++;
  }
}

final historyProvider =
    NotifierProvider<HistoryController, int>(HistoryController.new);
