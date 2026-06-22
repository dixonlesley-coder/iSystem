import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models/sheet.dart';
import '../../store/sheets_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// Left rail: multi-sheet navigation. Lists every sheet; the current one is
/// highlighted; clicking switches (restoring that sheet's viewport).
class SheetRail extends ConsumerWidget {
  const SheetRail({super.key});

  static const double width = 232;

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
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MechXSpacing.md,
                MechXSpacing.md,
                MechXSpacing.md,
                MechXSpacing.sm,
              ),
              child: Row(
                children: [
                  Text(
                    'Sheets',
                    style: type.subtitle.copyWith(color: colors.textPrimary),
                  ),
                  const Spacer(),
                  Text(
                    '${state.sheets.length}',
                    style: type.caption.copyWith(color: colors.textMuted),
                  ),
                ],
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

class _RailItem extends StatefulWidget {
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
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final bg = widget.selected
        ? colors.accentMuted
        : (_hover ? colors.surfaceHover : const Color(0x00000000));
    final nameColor =
        widget.selected ? colors.textPrimary : colors.textSecondary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm,
            vertical: MechXSpacing.xxs,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm,
            vertical: MechXSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: MechXRadii.control,
          ),
          child: Row(
            children: [
              // page glyph
              Container(
                width: 26,
                height: 34,
                decoration: BoxDecoration(
                  color: colors.canvas,
                  borderRadius: const BorderRadius.all(Radius.circular(3)),
                  border: Border.all(
                    color: widget.selected ? colors.accent : colors.border,
                  ),
                ),
              ),
              const SizedBox(width: MechXSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.sheet.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.body.copyWith(color: nameColor),
                    ),
                    Text(
                      'Sheet ${widget.index + 1}',
                      style: type.caption.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
