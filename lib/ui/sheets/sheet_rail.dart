import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/app_state.dart';
import '../../store/calibration_store.dart';
import '../../store/electrical_store.dart';
import '../../store/models/sheet.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../shell/duplicate_floor_dialog.dart';
import '../shell/nav_rail.dart';
import '../shell/project_io.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/context_menu.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_focus_ring.dart';
import '../widgets/mechx_text_field.dart';
import '../widgets/mechx_tooltip.dart';
import 'pdf_page_picker.dart';

/// Left rail: multi-sheet navigation, slimmed to a compact tile strip so the
/// canvas gets the real estate. Each sheet is a small page thumbnail stamped
/// with its index and a terse, truncated label; the current one is highlighted
/// (the status bar carries the full sheet name). Clicking switches (restoring
/// that sheet's viewport).
class SheetRail extends ConsumerWidget {
  const SheetRail({super.key});

  /// Narrow — just wide enough for a page thumbnail + a short label. Trimmed
  /// from the old 232-px wide-card list to 76, then to 64 to hand the canvas
  /// the last ~12 px.
  static const double width = 64;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sheetsControllerProvider);
    final colors = context.colors;
    final type = context.type;
    // A6: an "Add sheets…" footer to append more plan files, shown only for a
    // REAL project (any non-placeholder sheet). The golden/demo project seeds
    // placeholder sheets only, so the footer stays hidden there and goldens are
    // byte-identical; a production project (A1: always imported, never
    // placeholder) always shows it.
    final hasRealSheet = state.sheets.any((s) => !s.isPlaceholder);

    return SizedBox(
      width: width,
      child: GlassSurface(
        // Floats over the canvas; its right edge faces the drawing.
        edge: Border(
            right: BorderSide(
                color: colors.glassEdge, width: MechXGlass.edgeWidth)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Terse header: a count badge (the word "Sheets" doesn't fit the
            // slim rail; the status bar already names the active sheet).
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MechXSpacing.xs,
                MechXSpacing.sm,
                MechXSpacing.xs,
                MechXSpacing.xs,
              ),
              child: Text(
                '${state.sheets.length} SHT',
                textAlign: TextAlign.center,
                style: type.caption.copyWith(
                  color: colors.textMuted,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Container(height: 1, color: colors.border),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xs),
                itemCount: state.sheets.length,
                itemBuilder: (context, i) => _RailItem(
                  index: i,
                  sheet: state.sheets[i],
                  selected: i == state.currentIndex,
                  onTap: () =>
                      ref.read(sheetsControllerProvider.notifier).selectSheet(i),
                ),
              ),
            ),
            if (hasRealSheet) ...[
              Container(height: 1, color: colors.border),
              Padding(
                padding: const EdgeInsets.all(MechXSpacing.xs),
                child: _AddSheetsButton(
                  onTap: () => addSheetsFromFiles(context, ref),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The slim "+ Add" footer affordance (A6) — appends more plan files via
/// [addSheetsFromFiles]. A compact custom control (no Material) sized to the
/// narrow rail; a "+" glyph over a terse label.
class _AddSheetsButton extends StatefulWidget {
  final VoidCallback onTap;
  const _AddSheetsButton({required this.onTap});

  @override
  State<_AddSheetsButton> createState() => _AddSheetsButtonState();
}

class _AddSheetsButtonState extends State<_AddSheetsButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MechXFocusRing(
      borderRadius: MechXRadii.control,
      onActivated: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xs),
            decoration: BoxDecoration(
              color: _hover ? colors.surfaceHover : const Color(0x00000000),
              borderRadius: MechXRadii.control,
              border: Border.all(color: colors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '+',
                  style: type.body.copyWith(
                    color: colors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Add',
                  style: type.micro.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RailItem extends ConsumerStatefulWidget {
  final int index;
  final Sheet sheet;
  final bool selected;
  final VoidCallback onTap;

  const _RailItem({
    required this.index,
    required this.sheet,
    required this.selected,
    required this.onTap,
  });

  @override
  ConsumerState<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends ConsumerState<_RailItem> {
  bool _hover = false;

  /// The per-sheet right-click menu — a positioned [MechXContextMenu] in the
  /// root overlay behind a full-screen dismiss barrier (same idiom as the
  /// canvas menus; no Material). The root overlay sits ABOVE the app's
  /// [MechXTheme], so the captured theme is re-provided inside the entry.
  void _showContextMenu(Offset globalPosition) {
    final overlay = Overlay.of(context, rootOverlay: true);
    final theme = MechXTheme.of(context);
    final sheetId = widget.sheet.id;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => MechXTheme(
        data: theme,
        child: _SheetMenuLayer(
          anchor: globalPosition,
          onRename: () {
            entry.remove();
            _rename();
          },
          onAssignFloor: () {
            entry.remove();
            _assignFloor();
          },
          onCalibrate: () {
            entry.remove();
            _calibrate();
          },
          onReplacePlan: () {
            entry.remove();
            replaceSheetPlan(context, ref, sheetId);
          },
          onDuplicateTo: () {
            entry.remove();
            showDuplicateFloorDialog(context);
          },
          onRemove: () {
            entry.remove();
            _remove();
          },
          onDismiss: entry.remove,
        ),
      ),
    );
    overlay.insert(entry);
  }

  /// A6: rename the sheet — a themed prompt, keeping the id so calibration and
  /// drawn work stay married to the plan.
  Future<void> _rename() async {
    final name = await showRenameSheetDialog(context, widget.sheet.name);
    if (name == null || !mounted) return;
    ref.read(sheetsControllerProvider.notifier).renameSheet(widget.sheet.id, name);
  }

  /// A6: map this sheet to a building floor (explicit override) — undo-safe via
  /// [SheetsController.setSheetFloor] (the drawn work moves with the mapping).
  Future<void> _assignFloor() async {
    final project = ref.read(projectControllerProvider);
    final levelCount = project.building.levelCount;
    final labels = <String>[
      for (var i = 0; i < levelCount; i++)
        i < project.floors.length ? project.floors[i].name : 'Floor ${i + 1}',
    ];
    final current = ref
        .read(sheetsControllerProvider)
        .floorFor(widget.sheet.id, levelCount);
    final chosen = await showAssignFloorDialog(
      context,
      floorLabels: labels,
      current: current,
    );
    if (chosen == null || !mounted) return;
    ref.read(sheetsControllerProvider.notifier).setSheetFloor(widget.sheet.id, chosen);
  }

  /// A6: jump to this sheet on the Layout canvas and start the mark-a-known-
  /// distance calibration flow (mirrors the command palette's Start calibration).
  void _calibrate() {
    ref.read(sheetsControllerProvider.notifier).selectSheetById(widget.sheet.id);
    ref.read(shellSectionProvider.notifier).set(ShellSection.design);
    ref.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
    ref.read(calibrationControllerProvider.notifier).start();
  }

  /// A6: remove this sheet — undo-safe, pruning its orphaned nodes in one step
  /// (see [SheetsController.removeSheet]); a status pill confirms (undoable via
  /// Ctrl+Z).
  void _remove() {
    ref.read(sheetsControllerProvider.notifier).removeSheet(widget.sheet.id);
    ref.read(statusMessageProvider.notifier).showStatus('Sheet removed');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final project = ref.watch(projectControllerProvider);
    final calibrated = project.calibrationFor(widget.sheet.id) != null;
    // Which building floor this sheet maps to (B7): stamped on the tile so a
    // remap — or a silent pile-up when more sheets than floors default onto the
    // top — is visible at a glance, not invisible. 1-based, ASCII ("F3").
    final mappedFloor = ref
        .watch(sheetsControllerProvider)
        .floorFor(widget.sheet.id, project.building.levelCount);
    final bg = widget.selected
        ? colors.accentMuted
        : (_hover ? colors.surfaceHover : const Color(0x00000000));
    final labelColor =
        widget.selected ? colors.textPrimary : colors.textSecondary;

    return MechXFocusRing(
      onActivated: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          // Right-click a tile for the per-sheet actions (currently "Replace
          // plan…" — swap the source PDF/DXF/DWG while keeping the sheet id, so
          // calibration + drawn work survive: the plan-revision workflow, A5).
          onSecondaryTapDown: (d) => _showContextMenu(d.globalPosition),
          // Ease the hover / selection fill so switching sheets feels smooth.
          child: AnimatedContainer(
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            margin: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.xs,
              vertical: MechXSpacing.xxs,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.xxs,
              vertical: MechXSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: MechXRadii.control,
            ),
            child: Column(
              children: [
                // A mini page thumbnail with the sheet index. For a PDF-backed
                // sheet it renders the actual page (A8) with the index as a small
                // corner badge; a DXF/placeholder sheet keeps the numbered tile
                // — so the golden/demo (placeholder-only) state is byte-identical.
                _MiniPage(
                  index: widget.index,
                  sheet: widget.sheet,
                  selected: widget.selected,
                ),
                const SizedBox(height: MechXSpacing.xxs),
                // Terse label, truncated to fit the slim rail.
                Text(
                  widget.sheet.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: type.caption.copyWith(color: labelColor),
                ),
                const SizedBox(height: MechXSpacing.xxs),
                // Per-sheet calibration status + mapped-floor stamp, on one
                // row: a small glyph pairing colour with shape (a check ring =
                // calibrated/green, a "!" ring = uncalibrated/warning) so the
                // rail reads at a glance which sheets still need a scale,
                // without relying on hue alone; and the building floor this
                // sheet maps to ("F3") so a remap / pile-up is visible.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // L5/M4: the glyph's meaning (calibrated vs not) was
                    // colour + shape only — a hover tooltip now spells it out.
                    MechXTooltip(
                      edge: MechXTooltipEdge.right,
                      message: context.strings(calibrated
                          ? StringKey.shellCalibrated
                          : StringKey.shellUncalibrated),
                      child: CustomPaint(
                        size: const Size(9, 9),
                        painter: _CalibrationGlyph(
                          calibrated: calibrated,
                          color: calibrated ? colors.success : colors.warning,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Text(
                      'F${mappedFloor + 1}',
                      style: type.micro.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The rail tile's mini page (A8). For a DXF/placeholder sheet it is the
/// numbered tile, kept byte-identical (so the goldens — whose demo sheets are
/// all placeholders — don't shift). For a PDF-backed sheet it renders the actual
/// page as the tile fill with the index as a small corner badge.
class _MiniPage extends StatelessWidget {
  final int index;
  final Sheet sheet;
  final bool selected;

  const _MiniPage({
    required this.index,
    required this.sheet,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final border = Border.all(
      color: selected ? colors.accent : colors.border,
      width: selected ? 1.5 : 1,
    );

    // The fallback numbered tile — the exact tile drawn before A8.
    Widget numbered() => Container(
          width: 34,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.canvas,
            borderRadius: const BorderRadius.all(Radius.circular(3)),
            border: border,
          ),
          child: Text(
            '${index + 1}',
            style: type.mono.copyWith(
              color: selected ? colors.accent : colors.textMuted,
            ),
          ),
        );

    if (sheet.pdfPath == null) return numbered();

    return Container(
      width: 34,
      height: 42,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        border: border,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          SheetThumbnail(
            sheet: sheet,
            // While the page renders, show the index so the tile is never blank.
            placeholder: Center(
              child: Text(
                '${index + 1}',
                style: type.mono.copyWith(
                  color: selected ? colors.accent : colors.textMuted,
                ),
              ),
            ),
          ),
          // A small legible index badge, so the rendered thumbnail is still
          // numbered for quick reference.
          Positioned(
            left: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              decoration: BoxDecoration(
                color: colors.surface.withAlpha(210),
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(3),
                ),
              ),
              child: Text(
                '${index + 1}',
                style: type.micro.copyWith(
                  color: selected ? colors.accent : colors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The per-sheet calibration mark: a check ring when [calibrated], else a "!"
/// ring. A redundant cue (shape + colour) so the status survives without hue
/// alone. Custom-painted (no icon font), so it can never tofu in the goldens.
class _CalibrationGlyph extends CustomPainter {
  final bool calibrated;
  final Color color;

  const _CalibrationGlyph({required this.calibrated, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final c = Offset(w / 2, h / 2);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawCircle(c, w * 0.42, stroke);
    if (calibrated) {
      final path = Path()
        ..moveTo(w * 0.30, h * 0.52)
        ..lineTo(w * 0.45, h * 0.68)
        ..lineTo(w * 0.72, h * 0.34);
      canvas.drawPath(path, stroke);
    } else {
      // An exclamation stem + dot inside the ring.
      canvas.drawLine(
        Offset(w / 2, h * 0.30),
        Offset(w / 2, h * 0.58),
        stroke,
      );
      canvas.drawCircle(Offset(w / 2, h * 0.74), w * 0.07,
          Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_CalibrationGlyph old) =>
      old.calibrated != calibrated || old.color != color;
}

/// The floating per-sheet context menu: a dismiss barrier + a positioned
/// [MechXContextMenu] anchored at the click point (clamped on-screen). Holds the
/// per-sheet actions — Rename / Assign floor / Calibrate (A6), Replace plan (A5),
/// Duplicate to (E4), and the destructive Remove (A6).
class _SheetMenuLayer extends StatelessWidget {
  final Offset anchor;
  final VoidCallback onRename;
  final VoidCallback onAssignFloor;
  final VoidCallback onCalibrate;
  final VoidCallback onReplacePlan;
  final VoidCallback onDuplicateTo;
  final VoidCallback onRemove;
  final VoidCallback onDismiss;

  const _SheetMenuLayer({
    required this.anchor,
    required this.onRename,
    required this.onAssignFloor,
    required this.onCalibrate,
    required this.onReplacePlan,
    required this.onDuplicateTo,
    required this.onRemove,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    const menuWidth = 180.0;
    // Tall enough for the seven rows + divider — clamp so it never hangs off the
    // bottom of the window.
    const menuHeight = 300.0;
    final left =
        anchor.dx.clamp(0.0, (size.width - menuWidth).clamp(0.0, size.width));
    final top = anchor.dy
        .clamp(0.0, (size.height - menuHeight).clamp(0.0, size.height));

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            onSecondaryTap: onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: menuWidth,
          child: MechXContextMenu(
            children: [
              MechXMenuRow(label: 'Rename…', onTap: onRename),
              MechXMenuRow(label: 'Assign floor…', onTap: onAssignFloor),
              MechXMenuRow(label: 'Calibrate…', onTap: onCalibrate),
              MechXMenuRow(label: 'Replace plan…', onTap: onReplacePlan),
              // E4: copy this floor's runs onto a range of floors (the dialog
              // defaults its source to the current sheet's floor).
              MechXMenuRow(label: 'Duplicate to…', onTap: onDuplicateTo),
              const MechXMenuDivider(),
              MechXMenuRow(label: 'Remove sheet', danger: true, onTap: onRemove),
            ],
          ),
        ),
      ],
    );
  }
}

/// A6: prompt for a new sheet name. Resolves to the trimmed name, or null when
/// cancelled/dismissed. A themed [showGeneralDialog] card (no Material), the same
/// idiom as the page picker / import-choice dialogs.
Future<String?> showRenameSheetDialog(BuildContext context, String current) {
  final theme = MechXTheme.of(context);
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Rename sheet',
    barrierColor: theme.colors.scrim,
    transitionDuration: MechXMotion.appear,
    pageBuilder: (ctx, _, _) => MechXTheme(
      data: theme,
      child: Center(child: _RenameSheetDialog(initial: current)),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: MechXMotion.standard,
        reverseCurve: MechXMotion.standard,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _RenameSheetDialog extends StatefulWidget {
  final String initial;
  const _RenameSheetDialog({required this.initial});

  @override
  State<_RenameSheetDialog> createState() => _RenameSheetDialogState();
}

class _RenameSheetDialogState extends State<_RenameSheetDialog> {
  late String _name = widget.initial;

  void _save() {
    final trimmed = _name.trim();
    Navigator.of(context).pop(trimmed.isEmpty ? null : trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      width: 400,
      padding: const EdgeInsets.all(MechXSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        boxShadow: MechXShadow.popover,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Rename sheet',
              style: type.title.copyWith(color: colors.textPrimary)),
          const SizedBox(height: MechXSpacing.md),
          MechXTextField(
            value: widget.initial,
            hint: 'Sheet name',
            onChanged: (v) => _name = v,
            onSubmitted: _save,
          ),
          const SizedBox(height: MechXSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              MechXButton(
                label: 'Cancel',
                tertiary: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: MechXSpacing.sm),
              MechXButton(label: 'Rename', primary: true, onPressed: _save),
            ],
          ),
        ],
      ),
    );
  }
}

/// A6: pick a building floor to map this sheet to. Resolves to the chosen floor
/// index, or null when cancelled. Rows are the project's floor names (index
/// [current] pre-marked).
Future<int?> showAssignFloorDialog(
  BuildContext context, {
  required List<String> floorLabels,
  required int current,
}) {
  final theme = MechXTheme.of(context);
  return showGeneralDialog<int>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Assign floor',
    barrierColor: theme.colors.scrim,
    transitionDuration: MechXMotion.appear,
    pageBuilder: (ctx, _, _) => MechXTheme(
      data: theme,
      child: Center(
        child: _AssignFloorDialog(floorLabels: floorLabels, current: current),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: MechXMotion.standard,
        reverseCurve: MechXMotion.standard,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _AssignFloorDialog extends StatelessWidget {
  final List<String> floorLabels;
  final int current;
  const _AssignFloorDialog({required this.floorLabels, required this.current});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      width: 400,
      constraints: const BoxConstraints(maxHeight: 560),
      padding: const EdgeInsets.all(MechXSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        boxShadow: MechXShadow.popover,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Assign to floor',
                    style: type.title.copyWith(color: colors.textPrimary)),
              ),
              MechXButton(
                label: 'Cancel',
                tertiary: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.xs),
          Text('Which building level does this plan show?',
              style: type.caption.copyWith(color: colors.textMuted)),
          const SizedBox(height: MechXSpacing.sm),
          Flexible(
            child: Container(
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: MechXRadii.control,
                border: Border.all(color: colors.border),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.all(MechXSpacing.xxs),
                itemCount: floorLabels.length,
                itemBuilder: (ctx, i) => _FloorRow(
                  label: floorLabels[i],
                  selected: i == current,
                  onTap: () => Navigator.of(context).pop(i),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One tappable floor row: the floor name, with a trailing accent dot on the
/// currently-mapped floor.
class _FloorRow extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FloorRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_FloorRow> createState() => _FloorRowState();
}

class _FloorRowState extends State<_FloorRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MechXFocusRing(
      borderRadius: MechXRadii.control,
      onActivated: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs),
            margin: const EdgeInsets.all(MechXSpacing.xxs),
            decoration: BoxDecoration(
              color: widget.selected
                  ? colors.accentMuted
                  : (_hover ? colors.surfaceHover : const Color(0x00000000)),
              borderRadius: MechXRadii.control,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.body.copyWith(
                        color: colors.textPrimary,
                        fontWeight: widget.selected ? FontWeight.w600 : null,
                      )),
                ),
                if (widget.selected)
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: colors.accent,
                      borderRadius: MechXRadii.small,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
