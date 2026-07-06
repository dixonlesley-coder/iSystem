/// Reference-line construction annotations (B12) — a two-point traced line on
/// a calibrated sheet that a raster (PDF) plan can offer as a SNAP SURFACE even
/// though it carries no importable vector geometry of its own (a DXF/DWG sheet
/// snaps to its already-cached parsed geometry directly; a PDF has none, so the
/// engineer traces one manually along e.g. a shaft wall). Mirrors the
/// [Measurement] annotation pattern in `annotation_store.dart`: a plain,
/// engine-free data class + a `Notifier` list provider, round-tripped in the
/// `.mechx` project as plain data. This file is the MODEL + persistence only —
/// the drawing/tracing tool and the snapping consumer are separate work.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'history_store.dart';

/// A two-point construction line on a sheet, in sheet (world) pixels — like
/// [Measurement] but purely a snap/reference aid, not a dimension: it carries
/// no floor index (a sheet's own reference geometry doesn't move between
/// floors) and an optional descriptive [label] instead of a measured length
/// readout. Never feeds the network solve; never appears in a calc report.
@immutable
class ReferenceLine {
  final String id;
  final String sheetId;
  final double x1;
  final double y1;
  final double x2;
  final double y2;

  /// Optional user label (e.g. "Shaft wall") — purely descriptive.
  final String? label;

  const ReferenceLine({
    required this.id,
    required this.sheetId,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    this.label,
  });

  /// Straight-line length in sheet pixels (convert to metres with the sheet's
  /// `ScaleCalibration.lengthForPixels`, same convention as
  /// [Measurement.pixelLength]).
  double get pixelLength {
    final dx = x2 - x1;
    final dy = y2 - y1;
    return math.sqrt(dx * dx + dy * dy);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sheetId': sheetId,
        'x1': x1,
        'y1': y1,
        'x2': x2,
        'y2': y2,
        if (label != null) 'label': label,
      };

  /// Tolerant decode — returns null for a non-map or one missing a coordinate,
  /// so a malformed entry is dropped rather than throwing.
  static ReferenceLine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final sheetId = raw['sheetId'];
    final x1 = raw['x1'], y1 = raw['y1'], x2 = raw['x2'], y2 = raw['y2'];
    if (id is! String ||
        sheetId is! String ||
        x1 is! num ||
        y1 is! num ||
        x2 is! num ||
        y2 is! num) {
      return null;
    }
    return ReferenceLine(
      id: id,
      sheetId: sheetId,
      x1: x1.toDouble(),
      y1: y1.toDouble(),
      x2: x2.toDouble(),
      y2: y2.toDouble(),
      label: raw['label'] is String ? raw['label'] as String : null,
    );
  }
}

/// The project's traced reference lines. Mutated by the (separately
/// integrated) canvas trace tool; read by the snapping layer and the
/// persistence layer.
final referenceLinesProvider =
    NotifierProvider<ReferenceLineController, List<ReferenceLine>>(
  ReferenceLineController.new,
);

class ReferenceLineController extends Notifier<List<ReferenceLine>> {
  int _seq = 0;

  // Local snapshot stacks — mirrors NetworkController / ElectricalProjectController
  // (a single flat list is the whole domain here, unlike the three annotation
  // lists which share one coordinator because an undo must revert whichever of
  // them changed most recently). Every USER mutation ([add]/[removeById])
  // records [UndoDomain.referenceLine] on the single global timeline
  // (`history_store`) BEFORE changing state; `historyProvider.undo()` pops the
  // timeline and drives [undo] here, so Ctrl+Z reverts the genuinely
  // most-recent edit across every domain.
  final List<List<ReferenceLine>> _undo = [];
  final List<List<ReferenceLine>> _redo = [];

  @override
  List<ReferenceLine> build() => const [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void _record() {
    _undo.add(state);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    ref.read(historyProvider.notifier).record(UndoDomain.referenceLine);
  }

  /// Add a reference line between two world points on [sheetId]. Ignores a
  /// degenerate (zero-length) span.
  void add({
    required String sheetId,
    required double x1,
    required double y1,
    required double x2,
    required double y2,
    String? label,
  }) {
    if (x1 == x2 && y1 == y2) return;
    _record();
    state = [
      ...state,
      ReferenceLine(
        id: 'rl${_seq++}',
        sheetId: sheetId,
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2,
        label: label,
      ),
    ];
  }

  void removeById(String id) {
    if (!state.any((r) => r.id == id)) return;
    _record();
    state = [for (final r in state) if (r.id != id) r];
  }

  void clear() => state = const [];

  /// Revert the most recent add/remove. Driven by the global [historyProvider]
  /// (which owns cross-domain ordering) — not called directly by widgets.
  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(state);
    state = _undo.removeLast();
  }

  /// Replay the most recently undone edit (see [undo]).
  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(state);
    state = _redo.removeLast();
  }

  /// Replace the whole set (used when loading a `.mechx` document). A loaded
  /// document is a fresh baseline, so both local stacks clear (mirrors
  /// `NetworkController.loadNetwork` / `ElectricalProjectController.setProject`);
  /// never records undo. Advances the fresh-id counter past any loaded ids so
  /// new ids never collide.
  void set(List<ReferenceLine> lines) {
    _undo.clear();
    _redo.clear();
    state = List.unmodifiable(lines);
    for (final r in lines) {
      final n = int.tryParse(r.id.replaceFirst('rl', ''));
      if (n != null && n >= _seq) _seq = n + 1;
    }
  }
}
