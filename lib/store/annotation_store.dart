/// Measurement annotations — a dimension line drawn on the calibrated sheet
/// whose real-world length comes from the per-sheet scale (§10 geometry is the
/// single source of truth). Annotations are NOT part of the drawn network: they
/// never affect sizing/solve; they round-trip in the `.mechx` project as plain
/// data.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A two-point dimension annotation on a sheet/floor, in sheet (world) pixels.
@immutable
class Measurement {
  final String id;
  final String sheetId;
  final int floorIndex;
  final double ax;
  final double ay;
  final double bx;
  final double by;

  const Measurement({
    required this.id,
    required this.sheetId,
    required this.floorIndex,
    required this.ax,
    required this.ay,
    required this.bx,
    required this.by,
  });

  /// Straight-line length in sheet pixels (convert to metres with the sheet's
  /// [ScaleCalibration.lengthForPixels]).
  double get pixelLength {
    final dx = bx - ax;
    final dy = by - ay;
    return math.sqrt(dx * dx + dy * dy);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sheetId': sheetId,
        'floor': floorIndex,
        'ax': ax,
        'ay': ay,
        'bx': bx,
        'by': by,
      };

  /// Tolerant decode — returns null for a non-map or one missing a coordinate,
  /// so a malformed entry is dropped rather than throwing.
  static Measurement? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final sheetId = raw['sheetId'];
    final ax = raw['ax'], ay = raw['ay'], bx = raw['bx'], by = raw['by'];
    if (id is! String ||
        sheetId is! String ||
        ax is! num ||
        ay is! num ||
        bx is! num ||
        by is! num) {
      return null;
    }
    return Measurement(
      id: id,
      sheetId: sheetId,
      floorIndex: (raw['floor'] as num?)?.toInt() ?? 0,
      ax: ax.toDouble(),
      ay: ay.toDouble(),
      bx: bx.toDouble(),
      by: by.toDouble(),
    );
  }
}

/// The project's measurement annotations. Mutated by the canvas measure tool;
/// read by the measurement overlay and the persistence layer.
final measurementsProvider =
    NotifierProvider<MeasurementController, List<Measurement>>(
  MeasurementController.new,
);

class MeasurementController extends Notifier<List<Measurement>> {
  int _seq = 0;

  @override
  List<Measurement> build() => const [];

  /// Add a measurement between two world points on [sheetId]/[floorIndex].
  /// Ignores a degenerate (zero-length) span.
  void add({
    required String sheetId,
    required int floorIndex,
    required double ax,
    required double ay,
    required double bx,
    required double by,
  }) {
    if (ax == bx && ay == by) return;
    state = [
      ...state,
      Measurement(
        id: 'm${_seq++}',
        sheetId: sheetId,
        floorIndex: floorIndex,
        ax: ax,
        ay: ay,
        bx: bx,
        by: by,
      ),
    ];
  }

  void removeById(String id) =>
      state = [for (final m in state) if (m.id != id) m];

  void clear() => state = const [];

  /// Replace the whole set (used when loading a `.mechx` document). Advances the
  /// fresh-id counter past any loaded ids so new ids never collide.
  void set(List<Measurement> measurements) {
    state = List.unmodifiable(measurements);
    for (final m in measurements) {
      final n = int.tryParse(m.id.replaceFirst('m', ''));
      if (n != null && n >= _seq) _seq = n + 1;
    }
  }
}

/// Whether the canvas measure tool is active (two-click to place a dimension).
/// Mutually exclusive with the network draw tools — the toolbar collapses the
/// draw tool to select when this turns on, and clears this when a draw tool is
/// chosen.
final measureModeProvider =
    NotifierProvider<MeasureModeController, bool>(MeasureModeController.new);

class MeasureModeController extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
  void toggle() => state = !state;
}
