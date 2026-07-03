/// The "Duplicate floor to…" dialog (E4) — replicate one floor's drawn runs
/// onto a chosen RANGE of target floors in one action, instead of the palette's
/// single 'Duplicate floor up' (which could only reach the floor immediately
/// above and failed silently three ways).
///
/// Pick a SOURCE floor (only floors that carry a sheet can be a source — their
/// runs live on a plan) and CHECK the target floors to copy onto; Apply loops
/// the existing [NetworkController.duplicateFloor] once per target (each its own
/// undo step — the store commits one snapshot per call, which is as few as the
/// public API allows) and confirms via the status pill. A target floor with no
/// sheet can't receive a copy, so it is shown disabled with a "no plan" note —
/// the honest answer to the old silent no-op.
///
/// No Material: a [showGeneralDialog]-driven floating card themed with
/// [MechXTheme], the same idiom as `templates_dialog.dart` /
/// `confirm_discard_dialog.dart`. All text is Roboto-backed [context.type] so it
/// renders in goldens; EN literals (Wave 5 localizes).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/app_state.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';

/// Open the duplicate-floor picker as a modal over the current [MechXTheme].
Future<void> showDuplicateFloorDialog(BuildContext context) {
  final theme = MechXTheme.of(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Duplicate floor to a range',
    barrierColor: theme.colors.scrim,
    transitionDuration: MechXMotion.appear,
    pageBuilder: (ctx, _, _) => MechXTheme(
      data: theme,
      child: const Center(child: _DuplicateFloorDialog()),
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

/// Count the run edges that live entirely on ([sheetId], [floor]) — exactly the
/// set [NetworkController.duplicateFloor] clones (same filter), so this is what
/// one copy adds. Pure over the live [net].
int runsOnFloor(Network net, String sheetId, int floor) {
  var n = 0;
  for (final e in net.edges) {
    if (e.kind != EdgeKind.run) continue;
    final a = net.nodeById(e.fromId);
    final b = net.nodeById(e.toId);
    if (a == null || b == null) continue;
    if (a.sheetId == sheetId &&
        a.floorIndex == floor &&
        b.sheetId == sheetId &&
        b.floorIndex == floor) {
      n++;
    }
  }
  return n;
}

class _DuplicateFloorDialog extends ConsumerStatefulWidget {
  const _DuplicateFloorDialog();

  @override
  ConsumerState<_DuplicateFloorDialog> createState() =>
      _DuplicateFloorDialogState();
}

class _DuplicateFloorDialogState extends ConsumerState<_DuplicateFloorDialog> {
  /// The floor index the runs are copied FROM (must carry a sheet). Chosen in
  /// [initState] from the current sheet, refined once the state resolves.
  int? _source;

  /// The target floor indices ticked to receive a copy.
  final Set<int> _targets = <int>{};

  bool _initialised = false;

  /// The first sheet mapped to [floor], or null when no plan sits on it.
  String? _sheetForFloor(SheetsState sheets, int levelCount, int floor) {
    for (final s in sheets.sheets) {
      if (sheets.floorFor(s.id, levelCount) == floor) return s.id;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final project = ref.watch(projectControllerProvider);
    final sheets = ref.watch(sheetsControllerProvider);
    final levelCount = project.building.levelCount;
    final floors = project.floors;

    // Floors that carry a sheet can be a source (their runs live on a plan).
    final sheetByFloor = <int, String>{};
    for (var f = 0; f < levelCount; f++) {
      final id = _sheetForFloor(sheets, levelCount, f);
      if (id != null) sheetByFloor[f] = id;
    }

    // Default the source to the current sheet's floor once, else the lowest
    // sheet-bearing floor.
    if (!_initialised) {
      _initialised = true;
      final current = sheets.current;
      final currentFloor =
          current == null ? null : sheets.floorFor(current.id, levelCount);
      if (currentFloor != null && sheetByFloor.containsKey(currentFloor)) {
        _source = currentFloor;
      } else if (sheetByFloor.isNotEmpty) {
        _source = sheetByFloor.keys.first;
      }
    }
    // Keep the source valid if the project changed under us.
    if (_source != null && !sheetByFloor.containsKey(_source)) {
      _source = sheetByFloor.isEmpty ? null : sheetByFloor.keys.first;
    }

    final net = ref.watch(networkControllerProvider).network;
    final source = _source;
    final sourceRuns = (source != null && sheetByFloor.containsKey(source))
        ? runsOnFloor(net, sheetByFloor[source]!, source)
        : 0;

    final validTargets =
        _targets.where((f) => f != source && sheetByFloor.containsKey(f)).toSet();
    final canApply = source != null && sourceRuns > 0 && validTargets.isNotEmpty;

    String floorLabel(int f) =>
        f < floors.length ? floors[f].name : 'Floor ${f + 1}';

    return Container(
      width: 460,
      constraints: const BoxConstraints(maxHeight: 640),
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
                child: Text('Duplicate floor to…',
                    style: type.title.copyWith(color: colors.textPrimary)),
              ),
              MechXButton(
                label: 'Close',
                tertiary: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.xs),
          Text(
            "Copy one floor's drawn runs onto other floors. Each target keeps "
            'its own plan and calibration; only the runs are replicated.',
            style: type.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: MechXSpacing.md),
          if (sheetByFloor.isEmpty)
            Text(
              'No floor has a plan yet — import a sheet before duplicating runs.',
              style: type.caption.copyWith(color: colors.warning),
            )
          else ...[
            // — Source —
            Text('Copy from',
                style: type.caption.copyWith(
                    color: colors.textMuted, letterSpacing: 0.5)),
            const SizedBox(height: MechXSpacing.xs),
            Wrap(
              spacing: MechXSpacing.xs,
              runSpacing: MechXSpacing.xs,
              children: [
                for (final f in sheetByFloor.keys)
                  _FloorChip(
                    label: floorLabel(f),
                    selected: f == source,
                    onTap: () => setState(() {
                      _source = f;
                      _targets.remove(f);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: MechXSpacing.xs),
            Text(
              sourceRuns == 0
                  ? 'This floor has no drawn runs to copy.'
                  : '$sourceRuns ${sourceRuns == 1 ? 'run' : 'runs'} on this floor.',
              style: type.caption.copyWith(
                  color:
                      sourceRuns == 0 ? colors.warning : colors.textSecondary),
            ),
            const SizedBox(height: MechXSpacing.md),
            // — Targets —
            Row(
              children: [
                Expanded(
                  child: Text('To floors',
                      style: type.caption.copyWith(
                          color: colors.textMuted, letterSpacing: 0.5)),
                ),
                MechXButton(
                  label: 'All',
                  tertiary: true,
                  onPressed: () => setState(() {
                    for (final f in sheetByFloor.keys) {
                      if (f != source) _targets.add(f);
                    }
                  }),
                ),
                MechXButton(
                  label: 'None',
                  tertiary: true,
                  onPressed:
                      _targets.isEmpty ? null : () => setState(_targets.clear),
                ),
              ],
            ),
            const SizedBox(height: MechXSpacing.xs),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: levelCount,
                itemBuilder: (ctx, f) {
                  if (f == source) return const SizedBox.shrink();
                  final hasSheet = sheetByFloor.containsKey(f);
                  return _TargetRow(
                    label: floorLabel(f),
                    checked: _targets.contains(f),
                    enabled: hasSheet,
                    // The honest answer to the old silent no-op: a floor with no
                    // plan can't receive runs, and we say so inline.
                    note: hasSheet ? null : 'no plan',
                    onToggle: () => setState(() {
                      if (_targets.contains(f)) {
                        _targets.remove(f);
                      } else {
                        _targets.add(f);
                      }
                    }),
                  );
                },
              ),
            ),
          ],
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
              MechXButton(
                label: 'Duplicate',
                primary: true,
                onPressed: canApply
                    ? () => _apply(source, sheetByFloor, sourceRuns, floorLabel)
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _apply(
    int source,
    Map<int, String> sheetByFloor,
    int sourceRuns,
    String Function(int) floorLabel,
  ) {
    final net = ref.read(networkControllerProvider.notifier);
    final fromSheet = sheetByFloor[source]!;
    // Deterministic order: low floor first, so the range reads naturally.
    final targets = _targets
        .where((f) => f != source && sheetByFloor.containsKey(f))
        .toList()
      ..sort();
    final done = <int>[];
    for (final f in targets) {
      net.duplicateFloor(
        fromSheetId: fromSheet,
        fromFloor: source,
        toSheetId: sheetByFloor[f]!,
        toFloor: f,
      );
      done.add(f);
    }
    Navigator.of(context).pop();
    if (done.isEmpty) return;
    final total = sourceRuns * done.length;
    final runWord = total == 1 ? 'run' : 'runs';
    final String where;
    if (done.length == 1) {
      where = floorLabel(done.first);
    } else if (done.last - done.first == done.length - 1) {
      // Contiguous — read as a range.
      where = 'floors ${floorLabel(done.first)}–${floorLabel(done.last)}';
    } else {
      where = '${done.length} floors';
    }
    ref
        .read(statusMessageProvider.notifier)
        .showStatus('Copied $total $runWord to $where');
  }
}

/// A single-select source-floor chip (selected = accent-tinted, like the
/// LAYER-switcher / draw pills).
class _FloorChip extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FloorChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_FloorChip> createState() => _FloorChipState();
}

class _FloorChipState extends State<_FloorChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final bg = widget.selected
        ? colors.accentMuted
        : (_hover ? colors.surfaceHover : const Color(0x00000000));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: MechXRadii.control,
            border: Border.all(
                color: widget.selected ? colors.accent : colors.border),
          ),
          child: Text(
            widget.label,
            style: type.label.copyWith(
              color: widget.selected ? colors.accent : colors.textSecondary,
              fontWeight: widget.selected ? FontWeight.w600 : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// One target-floor row: a custom checkbox + label, dimmed with a note when the
/// floor carries no plan (so it can't be a target).
class _TargetRow extends StatefulWidget {
  final String label;
  final bool checked;
  final bool enabled;
  final String? note;
  final VoidCallback onToggle;

  const _TargetRow({
    required this.label,
    required this.checked,
    required this.enabled,
    required this.onToggle,
    this.note,
  });

  @override
  State<_TargetRow> createState() => _TargetRowState();
}

class _TargetRowState extends State<_TargetRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final labelColor =
        widget.enabled ? colors.textPrimary : colors.textMuted;
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onToggle : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.xs, vertical: MechXSpacing.xs),
          decoration: BoxDecoration(
            color: (widget.enabled && _hover)
                ? colors.surfaceHover
                : const Color(0x00000000),
            borderRadius: MechXRadii.control,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CustomPaint(
                  painter: _CheckBoxPainter(
                    checked: widget.checked,
                    box: widget.enabled ? colors.border : colors.textMuted,
                    fill: colors.accent,
                    tick: colors.onAccent,
                  ),
                ),
              ),
              const SizedBox(width: MechXSpacing.sm),
              Expanded(
                child: Text(widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.body.copyWith(color: labelColor)),
              ),
              if (widget.note != null)
                Text(widget.note!,
                    style: type.caption.copyWith(color: colors.warning)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A custom-painted checkbox mark (no Material, no icon font — never tofus):
/// an empty rounded square, filled with a check when [checked].
class _CheckBoxPainter extends CustomPainter {
  final bool checked;
  final Color box;
  final Color fill;
  final Color tick;

  const _CheckBoxPainter({
    required this.checked,
    required this.box,
    required this.fill,
    required this.tick,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(3),
    );
    if (checked) {
      canvas.drawRRect(rect, Paint()..color = fill);
      final w = size.width;
      final h = size.height;
      final path = Path()
        ..moveTo(w * 0.26, h * 0.52)
        ..lineTo(w * 0.44, h * 0.70)
        ..lineTo(w * 0.76, h * 0.30);
      canvas.drawPath(
        path,
        Paint()
          ..color = tick
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    } else {
      canvas.drawRRect(
        rect,
        Paint()
          ..color = box
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(_CheckBoxPainter old) =>
      old.checked != checked ||
      old.box != box ||
      old.fill != fill ||
      old.tick != tick;
}
