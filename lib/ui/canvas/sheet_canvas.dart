import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/calibration_store.dart';
import '../../store/history_store.dart';
import '../../store/models/sheet.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/sheets_store.dart';
import '../../store/solve_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'calibration_overlay.dart';
import 'canvas_view.dart';
import 'drawing_overlay.dart';
import 'drop_overlay.dart';
import 'heatmap_layer.dart';
import 'network_layer.dart';
import 'selection_overlay.dart';

/// Builds the content widget for a sheet. This is the seam where pdfrx (PDFium)
/// rendering slots in: a future provider override returns a PDF-page widget for
/// sheets with a `pdfPath`. For P0 every sheet shows a placeholder page so the
/// canvas, navigation, and viewport logic are fully exercised without native
/// dependencies.
typedef SheetContentBuilder = Widget Function(BuildContext context, Sheet sheet);

final sheetContentBuilderProvider = Provider<SheetContentBuilder>(
  (ref) => (context, sheet) => PlaceholderSheetPage(sheet: sheet),
);

/// The current sheet rendered inside the pannable/zoomable [CanvasView], with
/// per-sheet viewport restore wired to the store.
class SheetCanvas extends ConsumerWidget {
  const SheetCanvas({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sheetsControllerProvider);
    final colors = context.colors;
    final sheet = state.current;

    if (sheet == null) {
      return ColoredBox(
        color: colors.canvas,
        child: Center(
          child: Text(
            'No sheet loaded',
            style: context.type.body.copyWith(color: colors.textMuted),
          ),
        ),
      );
    }

    final content = ref.watch(sheetContentBuilderProvider)(context, sheet);
    final calibrating = ref.watch(calibrationControllerProvider).isActive;
    final drawing = ref.watch(networkControllerProvider).isDrawing;
    final showHeatmap = ref.watch(showHeatmapProvider);
    final calibrated =
        ref.watch(projectControllerProvider).calibrationFor(sheet.id) != null;

    // Map the current sheet to a building floor (explicit override or
    // positional default).
    final levelCount = ref.watch(projectControllerProvider).building.levelCount;
    final floorIndex = state.floorFor(sheet.id, levelCount);

    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) => _onKey(ref, event, sheet.id, floorIndex),
      child: Stack(
      children: [
        Positioned.fill(
          child: CanvasView(
            // Fresh CanvasView per sheet, seeded from its stored viewport.
            key: ValueKey(sheet.id),
            contentSize: sheet.sizePx,
            initialTransform: state.viewportFor(sheet.id),
            background: colors.canvas,
            onTransformChanged: (vt) => ref
                .read(sheetsControllerProvider.notifier)
                .setViewport(sheet.id, vt),
            child: content,
          ),
        ),
        if (showHeatmap)
          Positioned.fill(
            child: HeatmapLayer(
              sheetId: sheet.id,
              floorIndex: floorIndex,
              contentSize: sheet.sizePx,
            ),
          ),
        Positioned.fill(
          child: NetworkLayer(sheetId: sheet.id, floorIndex: floorIndex),
        ),
        if (drawing)
          Positioned.fill(
            child: DrawingOverlay(
              sheetId: sheet.id,
              floorIndex: floorIndex,
              levelCount: levelCount,
            ),
          ),
        // Palette drop target: maps a dropped card to world coords and adds the
        // matching element. Pointer-translucent when idle, so taps/drags still
        // reach the selection overlay + canvas; sits UNDER the selection overlay
        // so its handles win. Active only while editing (not drawing/calibrating).
        if (!drawing && !calibrating)
          Positioned.fill(
            child: DropOverlay(sheetId: sheet.id, floorIndex: floorIndex),
          ),
        if (!drawing && !calibrating)
          Positioned.fill(
            child: NetworkSelectionOverlay(
              sheetId: sheet.id,
              floorIndex: floorIndex,
            ),
          ),
        if (calibrating)
          Positioned.fill(child: CalibrationOverlay(sheetId: sheet.id)),
        // First-run nudge: until the sheet has a scale, horizontal runs measure
        // zero length, so guide the user to set one (one tap starts calibrate).
        if (!calibrated && !calibrating)
          const Positioned(
            top: MechXSpacing.md,
            left: 0,
            right: 0,
            child: Center(child: _CalibrateHint()),
          ),
      ],
      ),
    );
  }

  /// Delete removes the current selection; Escape cancels a pending action or
  /// clears the selection; Ctrl/Cmd+C / +V copy & paste the selection. Bubbled
  /// up from the focused canvas (which ignores these keys). Text fields live
  /// outside this subtree, so editing is safe.
  KeyEventResult _onKey(
      WidgetRef ref, KeyEvent event, String sheetId, int floorIndex) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final mod = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    // Single global undo/redo timeline across all domains (Ctrl/Cmd+Z,
    // Ctrl+Shift+Z or Ctrl+Y to redo) — reverts the genuinely most-recent edit.
    if (mod && key == LogicalKeyboardKey.keyZ && !shift) {
      ref.read(historyProvider.notifier).undo();
      return KeyEventResult.handled;
    }
    if (mod &&
        ((key == LogicalKeyboardKey.keyZ && shift) ||
            key == LogicalKeyboardKey.keyY)) {
      ref.read(historyProvider.notifier).redo();
      return KeyEventResult.handled;
    }

    // Copy / paste the selection.
    if (mod && key == LogicalKeyboardKey.keyC) {
      final sel = ref.read(selectionProvider);
      final nodeIds =
          sel.nodeIds.isEmpty ? {if (sel.nodeId != null) sel.nodeId!} : sel.nodeIds;
      final edgeIds =
          sel.edgeIds.isEmpty ? {if (sel.edgeId != null) sel.edgeId!} : sel.edgeIds;
      if (nodeIds.isEmpty && edgeIds.isEmpty) return KeyEventResult.ignored;
      ref.read(networkControllerProvider.notifier).copySelection(nodeIds, edgeIds);
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.keyV) {
      ref
          .read(networkControllerProvider.notifier)
          .paste(sheetId: sheetId, floorIndex: floorIndex);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      final sel = ref.read(selectionProvider);
      if (sel.isEmpty) return KeyEventResult.ignored;
      final net = ref.read(networkControllerProvider.notifier);
      if (sel.isMulti) {
        net.deleteMany(sel.nodeIds, sel.edgeIds);
      } else if (sel.isNode) {
        net.deleteNode(sel.nodeId!);
      } else if (sel.isEdge) {
        net.deleteEdge(sel.edgeId!);
      }
      ref.read(selectionProvider.notifier).clear();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (ref.read(calibrationControllerProvider).isActive) {
        ref.read(calibrationControllerProvider.notifier).cancel();
        return KeyEventResult.handled;
      }
      if (ref.read(networkControllerProvider).pendingPoint != null) {
        ref.read(networkControllerProvider.notifier).cancelPending();
        return KeyEventResult.handled;
      }
      if (!ref.read(selectionProvider).isEmpty) {
        ref.read(selectionProvider.notifier).clear();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }
}

/// A small, tappable nudge shown over an uncalibrated sheet. Tapping starts the
/// two-point scale calibration — the same action as the inspector's SCALE
/// button, surfaced where the user is already looking.
class _CalibrateHint extends ConsumerWidget {
  const _CalibrateHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => ref.read(calibrationControllerProvider.notifier).start(),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm + 2,
            vertical: MechXSpacing.xs + 1,
          ),
          decoration: BoxDecoration(
            color: colors.surface.withAlpha(240),
            borderRadius: MechXRadii.control,
            border: Border.all(color: colors.warning),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: MechXSpacing.xs),
                decoration: BoxDecoration(
                  color: colors.warning,
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                ),
              ),
              Text(
                'Set drawing scale to measure runs',
                style: type.label.copyWith(color: colors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A placeholder "paper" page for a sheet without a PDF (P0). Paper stays light
/// in both themes — like a real drawing — so its ink colour is fixed.
class PlaceholderSheetPage extends StatelessWidget {
  final Sheet sheet;

  const PlaceholderSheetPage({super.key, required this.sheet});

  static const Color _ink = Color(0xFF9AA1AC);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.sheetPaper,
        border: Border.all(color: colors.border),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 8)),
        ],
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              sheet.name,
              style: const TextStyle(
                fontFamily: 'Roboto',
                fontSize: 40,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: _ink,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${sheet.sizePx.width.round()} × ${sheet.sizePx.height.round()} px'
              '   ·   PDF import in P1',
              style: const TextStyle(fontFamily: 'Roboto', fontSize: 18, color: _ink),
            ),
          ],
        ),
      ),
    );
  }
}
