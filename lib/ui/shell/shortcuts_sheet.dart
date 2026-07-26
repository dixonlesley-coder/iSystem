/// The Keyboard-shortcuts reference sheet (F1) — a read-only cheat sheet of
/// every binding the app answers to: the global accelerators from
/// [kShellShortcutGroups] AND the canvas bindings from [kCanvasShortcutGroups],
/// so the keyboard is learnable in one place instead of half-hidden in the
/// command palette's keycap column.
///
/// App-shell-local, exactly like the command palette: hosted as a non-layout
/// [Stack] layer in `app_shell.dart`, gated on [shortcutsSheetOpenProvider], so
/// it renders NOTHING when closed and the goldens are unchanged at rest. Custom
/// design system only (no Material): a tinted scrim over a [GlassSurface] card.
/// Esc (or a click outside / the Close button) dismisses it.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/command_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_scrollbar.dart';
import 'shell_shortcuts.dart';

/// The non-layout overlay layer hosted at app-shell level.
class ShortcutsSheetOverlay extends ConsumerWidget {
  const ShortcutsSheetOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(shortcutsSheetOpenProvider)) return const SizedBox.shrink();
    final colors = context.colors;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(shortcutsSheetOpenProvider.notifier).close(),
        child: ColoredBox(
          color: colors.scrim,
          child: Center(
            // Swallow taps on the card itself (don't dismiss).
            child: GestureDetector(
              onTap: () {},
              child: const _ShortcutsCard(),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShortcutsCard extends ConsumerWidget {
  const _ShortcutsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    // Two columns: the global accelerators beside the canvas bindings, so the
    // whole keyboard fits one screen at the app's 1024x700 minimum window.
    return SizedBox(
      width: 720,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 560),
        child: GlassSurface(
          borderRadius: MechXRadii.card,
          blurSigma: MechXGlass.blurSigmaLight,
          shadow: MechXShadow.popover,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(MechXSpacing.md,
                    MechXSpacing.md, MechXSpacing.md, MechXSpacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Keyboard shortcuts',
                        style:
                            type.title.copyWith(color: colors.textPrimary),
                      ),
                    ),
                    MechXButton(
                      label: 'Close',
                      onPressed: () =>
                          ref.read(shortcutsSheetOpenProvider.notifier).close(),
                    ),
                  ],
                ),
              ),
              Container(height: 1, color: colors.border),
              const Flexible(child: _ShortcutColumns()),
              Container(height: 1, color: colors.border),
              Padding(
                padding: const EdgeInsets.all(MechXSpacing.md),
                child: Text(
                  // Windows-first labels; the same combos work with Cmd on a Mac
                  // keyboard. Plain ASCII so nothing renders as tofu.
                  'On a Mac keyboard, use Cmd wherever Ctrl is shown. '
                  'Press Esc to close.',
                  style: type.caption.copyWith(color: colors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The two scrolling columns of grouped bindings.
class _ShortcutColumns extends StatefulWidget {
  const _ShortcutColumns();

  @override
  State<_ShortcutColumns> createState() => _ShortcutColumnsState();
}

class _ShortcutColumnsState extends State<_ShortcutColumns> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MechXScrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.all(MechXSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final g in kShellShortcutGroups) _GroupBlock(group: g),
                ],
              ),
            ),
            const SizedBox(width: MechXSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final g in kCanvasShortcutGroups) _GroupBlock(group: g),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupBlock extends StatelessWidget {
  final ShortcutGroup group;
  const _GroupBlock({required this.group});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
            child: Text(
              group.title,
              style: type.micro.copyWith(
                color: colors.textMuted,
                letterSpacing: 0.6,
              ),
            ),
          ),
          for (final s in group.shortcuts) _ShortcutRow(doc: s),
        ],
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  final ShortcutDoc doc;
  const _ShortcutRow({required this.doc});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              doc.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: type.body.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: MechXSpacing.sm),
          // The keycap, mirroring the command palette's right-aligned hint.
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.xs, vertical: 1),
            decoration: BoxDecoration(
              color: colors.surfaceHover,
              borderRadius: MechXRadii.small,
              border: Border.all(color: colors.border),
            ),
            child: Text(
              doc.keys,
              style: type.micro.copyWith(
                fontFamily: MechXTypography.monoFamily,
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
