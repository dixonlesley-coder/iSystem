import 'package:flutter/foundation.dart' show immutable, setEquals;
import 'package:flutter/widgets.dart' show Offset;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'annotation_store.dart' show measureModeProvider, roomModeProvider, tankModeProvider;
import 'calibration_store.dart';
import 'layer_store.dart';
import 'network_store.dart';
import 'sheets_store.dart';
import 'snap_settings_store.dart' show refLineModeProvider;

/// M8 — the AutoCAD base-point commands on the Layout canvas.
///
///   * [move]   — MOVE: pick a base point, then a target (click or typed
///                `@dx,dy` / `len<ang` / `len`); the selection moves by
///                target − base, one undo step, and the command ends.
///   * [copy]   — COPY (multiple): the same two picks, but every target places
///                a fresh-id copy of the ORIGINAL selection and the command
///                stays armed for more targets until Esc / Enter.
///   * [rotate] — ROTATE: pick a base point (the pivot), then type an angle or
///                click to set it from the cursor bearing; one undo step.
enum BasePointCommandKind { move, copy, rotate }

/// The live base-point command (null when none is armed). Transient UI state —
/// never persisted, so an idle canvas is byte-identical.
@immutable
class BasePointCommand {
  final BasePointCommandKind kind;

  /// The selection the command acts on, captured (and scoped to the current
  /// sheet / visible services) when it was armed.
  final Set<String> nodeIds;
  final Set<String> edgeIds;

  /// The sheet / floor the command was armed on (its picks are in this sheet's
  /// world px).
  final String sheetId;
  final int floorIndex;

  /// The picked base point (world px), or null while it is being picked.
  final Offset? base;

  /// How many copies a [BasePointCommandKind.copy] has placed so far.
  final int placed;

  const BasePointCommand({
    required this.kind,
    required this.nodeIds,
    required this.edgeIds,
    required this.sheetId,
    required this.floorIndex,
    this.base,
    this.placed = 0,
  });

  /// Whether the base point is still to be picked.
  bool get pickingBase => base == null;

  BasePointCommand _withBase(Offset b) => BasePointCommand(
        kind: kind,
        nodeIds: nodeIds,
        edgeIds: edgeIds,
        sheetId: sheetId,
        floorIndex: floorIndex,
        base: b,
        placed: placed,
      );

  BasePointCommand _placedOneMore() => BasePointCommand(
        kind: kind,
        nodeIds: nodeIds,
        edgeIds: edgeIds,
        sheetId: sheetId,
        floorIndex: floorIndex,
        base: base,
        placed: placed + 1,
      );

  @override
  bool operator ==(Object other) =>
      other is BasePointCommand &&
      other.kind == kind &&
      setEquals(other.nodeIds, nodeIds) &&
      setEquals(other.edgeIds, edgeIds) &&
      other.sheetId == sheetId &&
      other.floorIndex == floorIndex &&
      other.base == base &&
      other.placed == placed;

  @override
  int get hashCode => Object.hash(kind, Object.hashAllUnordered(nodeIds),
      Object.hashAllUnordered(edgeIds), sheetId, floorIndex, base, placed);
}

/// The base-point command state machine. The geometry itself is the network
/// store's ([NetworkController.translateSelection] / [copySelectionBy] /
/// [rotateSelectionAbout]) — one undo step per placement; this controller only
/// sequences the picks. It disarms itself when a draw tool is armed or the
/// current sheet changes (its picks would belong to another sheet).
class BasePointCommandController extends Notifier<BasePointCommand?> {
  @override
  BasePointCommand? build() {
    ref.listen<bool>(
        networkControllerProvider.select((d) => d.tool != DrawTool.select),
        (_, drawing) {
      if (drawing) cancel();
    });
    // An annotation mode (measure / tank / room / reference line) owns the
    // clicks too — arming one backs out of the command.
    for (final mode in [
      measureModeProvider,
      tankModeProvider,
      roomModeProvider,
      refLineModeProvider,
    ]) {
      ref.listen<bool>(mode, (_, on) {
        if (on) cancel();
      });
    }
    // Leaving the mechanical layer (its keys / overlay / pill are mechanical-
    // gated) or starting a calibration (which owns the clicks) backs out —
    // an armed command must never silently resume later (review).
    ref.listen<bool>(
        activeDisciplineProvider.select((d) => d.isMechanical), (_, mech) {
      if (!mech) cancel();
    });
    ref.listen<bool>(
        calibrationControllerProvider.select((c) => c.isActive), (_, on) {
      if (on) cancel();
    });
    ref.listen<String?>(sheetsContentProvider.select((s) => s.current?.id),
        (_, id) {
      final c = state;
      if (c != null && id != c.sheetId) cancel();
    });
    return null;
  }

  /// Arm [kind] on the given selection. Returns false (nothing armed) when the
  /// selection is empty.
  bool start(
    BasePointCommandKind kind, {
    required Set<String> nodeIds,
    required Set<String> edgeIds,
    required String sheetId,
    required int floorIndex,
  }) {
    if (nodeIds.isEmpty && edgeIds.isEmpty) return false;
    state = BasePointCommand(
      kind: kind,
      nodeIds: Set.unmodifiable(nodeIds),
      edgeIds: Set.unmodifiable(edgeIds),
      sheetId: sheetId,
      floorIndex: floorIndex,
    );
    return true;
  }

  /// Fix the base point (the first pick).
  void setBase(Offset base) {
    final c = state;
    if (c == null || !base.dx.isFinite || !base.dy.isFinite) return;
    state = c._withBase(base);
  }

  /// Place the target at [target] (world px): Move moves the selection by
  /// target − base and ENDS; Copy places one copy and stays armed. Returns
  /// whether anything was placed. No-op before the base is picked.
  bool placeTarget(Offset target) {
    final c = state;
    final base = c?.base;
    if (c == null || base == null) return false;
    return placeDisplacement(target - base);
  }

  /// As [placeTarget], with the displacement given directly (a typed entry).
  bool placeDisplacement(Offset delta) {
    final c = state;
    if (c == null || c.base == null) return false;
    final net = ref.read(networkControllerProvider.notifier);
    switch (c.kind) {
      case BasePointCommandKind.move:
        final ok = net.translateSelection(c.nodeIds, c.edgeIds, delta);
        if (ok) state = null;
        return ok;
      case BasePointCommandKind.copy:
        final made = net.copySelectionBy(c.nodeIds, c.edgeIds, delta);
        final ok = made.nodeIds.isNotEmpty;
        if (ok) state = c._placedOneMore();
        return ok;
      case BasePointCommandKind.rotate:
        return false;
    }
  }

  /// Rotate the selection by [angleDeg] (AutoCAD sense: CCW positive on the
  /// plan) about the base point, ending the command. Returns whether anything
  /// turned.
  bool rotateBy(double angleDeg) {
    final c = state;
    final base = c?.base;
    if (c == null || base == null || c.kind != BasePointCommandKind.rotate) {
      return false;
    }
    final ok = ref
        .read(networkControllerProvider.notifier)
        .rotateSelectionAbout(c.nodeIds, c.edgeIds, base, angleDeg);
    if (ok) state = null;
    return ok;
  }

  /// Disarm (Esc / Enter / right-click / Done).
  void cancel() {
    if (state != null) state = null;
  }
}

final basePointCommandProvider =
    NotifierProvider<BasePointCommandController, BasePointCommand?>(
        BasePointCommandController.new);
