import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models/sheet.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_focus_ring.dart';

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

    return SizedBox(
      width: width,
      child: ColoredBox(
        color: colors.surface,
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
          ],
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

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final calibrated = ref.watch(projectControllerProvider)
            .calibrationFor(widget.sheet.id) !=
        null;
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
                // A mini page thumbnail with the sheet index centred on it.
                Container(
                  width: 34,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.canvas,
                    borderRadius: const BorderRadius.all(Radius.circular(3)),
                    border: Border.all(
                      color: widget.selected ? colors.accent : colors.border,
                      width: widget.selected ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    '${widget.index + 1}',
                    style: type.mono.copyWith(
                      color: widget.selected ? colors.accent : colors.textMuted,
                    ),
                  ),
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
                // Per-sheet calibration status: a small dot (green = calibrated,
                // warning = not) so the rail shows at a glance which sheets still
                // need a scale.
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: calibrated ? colors.success : colors.warning,
                    shape: BoxShape.circle,
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
