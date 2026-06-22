import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/app_state.dart';
import '../store/sheets_store.dart';
import 'canvas/sheet_canvas.dart';
import 'inspector/project_panel.dart';
import 'sheets/sheet_rail.dart';
import 'theme/design_tokens.dart';
import 'theme/mechx_theme.dart';
import 'widgets/mechx_button.dart';

/// Top-level P0 layout: top bar · (sheet rail | canvas) · status bar.
/// No Material Scaffold — a restrained, custom shell (§4).
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ColoredBox(
      color: colors.background,
      child: SafeArea(
        child: Column(
          children: [
            const _TopBar(),
            Container(height: 1, color: colors.border),
            Expanded(
              child: Row(
                children: [
                  const SheetRail(),
                  Container(width: 1, color: colors.border),
                  const Expanded(child: SheetCanvas()),
                  Container(width: 1, color: colors.border),
                  const ProjectPanel(),
                ],
              ),
            ),
            Container(height: 1, color: colors.border),
            const _StatusBar(),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final state = ref.watch(sheetsControllerProvider);
    final brightness = ref.watch(brightnessProvider);

    final current = state.current;
    final vt = current == null ? null : state.viewportFor(current.id);
    final zoom = vt == null ? '—' : '${(vt.scale * 100).round()}%';

    return ColoredBox(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.md,
          vertical: MechXSpacing.sm,
        ),
        child: Row(
          children: [
            Text('MechX', style: type.title.copyWith(color: colors.textPrimary)),
            const SizedBox(width: MechXSpacing.sm),
            Text(
              'Untitled project',
              style: type.body.copyWith(color: colors.textMuted),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.sm,
                vertical: MechXSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: MechXRadii.control,
                border: Border.all(color: colors.border),
              ),
              child: Text(
                zoom,
                style: type.mono.copyWith(color: colors.textSecondary),
              ),
            ),
            const SizedBox(width: MechXSpacing.sm),
            MechXButton(
              label: brightness == Brightness.dark ? 'Dark' : 'Light',
              onPressed: () => ref.read(brightnessProvider.notifier).toggle(),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final sheet = ref.watch(sheetsControllerProvider).current;

    final caption = type.caption;

    return ColoredBox(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.md,
          vertical: MechXSpacing.xs + 1,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Left group: current sheet info (truncates first).
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      sheet?.name ?? 'No sheet',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: caption.copyWith(color: colors.textSecondary),
                    ),
                  ),
                  if (sheet != null) ...[
                    _dot(colors.textMuted),
                    Text(
                      '${sheet.sizePx.width.round()} × ${sheet.sizePx.height.round()} px',
                      style: caption.copyWith(color: colors.textMuted),
                    ),
                    _dot(colors.textMuted),
                    Text(
                      'Uncalibrated',
                      style: caption.copyWith(color: colors.textMuted),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: MechXSpacing.md),
            // Right group: standards provenance + input hints.
            Flexible(
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
                  Flexible(
                    child: Text(
                      'SNI 8153:2015 (draft)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: caption.copyWith(color: colors.textMuted),
                    ),
                  ),
                  _dot(colors.textMuted),
                  Flexible(
                    child: Text(
                      'scroll zoom · drag pan · F fit · Ctrl+0 100%',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: caption.copyWith(color: colors.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot(Color color) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: MechXSpacing.sm),
        child: Text('·', style: TextStyle(color: color)),
      );
}
