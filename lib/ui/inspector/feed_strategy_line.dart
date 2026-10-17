import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/app_state.dart';
import '../shell/nav_rail.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_focus_ring.dart';

/// The water FEED STRATEGY as a read-only inspector line (2026-10-17).
///
/// The strategy is a building-wide design input edited on the Building page's
/// Design inputs card; the Layout + Riser inspectors only REPORT it — a
/// `Feed  Upfeed pump  Change` key/value row whose accent 'Change' link jumps to
/// the Building page. (The what-if flip stays one keystroke away via the
/// command palette's 'Switch feed strategy'.)
class FeedStrategyLine extends ConsumerWidget {
  const FeedStrategyLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final strategy = ref.watch(feedStrategyProvider);
    final value = context.strings(strategy == FeedStrategy.upfeed
        ? StringKey.feedUpfeedPump
        : StringKey.feedRoofTankDownfeed);
    void open() =>
        ref.read(shellSectionProvider.notifier).set(ShellSection.building);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(context.strings(StringKey.inspectorFeedLabel),
              style: type.caption.copyWith(color: colors.textMuted)),
          const SizedBox(width: MechXSpacing.xs),
          // The value takes the remaining width (soft-wrapping on a narrow
          // inspector) so the 'Change' link is never pushed off the row.
          Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: type.caption.copyWith(color: colors.textSecondary)),
          ),
          const SizedBox(width: MechXSpacing.sm),
          Semantics(
            button: true,
            label: context.strings(StringKey.inspectorFeedChangeSemantics),
            excludeSemantics: true,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: MechXFocusRing(
                onActivated: open,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: open,
                  child: Text(context.strings(StringKey.inspectorFeedChange),
                      style: type.caption.copyWith(color: colors.accent)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
