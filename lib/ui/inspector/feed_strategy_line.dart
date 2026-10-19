import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mechx_engine/report/riser_tags.dart'
    show drawnWaterFeedEquipment;

import '../../store/app_state.dart';
import '../../store/network_store.dart';
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
///
/// Round 29 (ui-journeys-3-feed-shown-three-ways) — the value follows the
/// DRAWN feed, on the same evidence as the riser sheet's `riserFeedNote`: a
/// downfeed setting with no roof tank reads 'Booster pump (no roof tank)' or
/// 'Direct mains (water meter)', and an upfeed setting with no pump drawn
/// reads 'Upfeed pump (assumed, not drawn)' — the inspector, the riser notes
/// and Review tell one story.
class FeedStrategyLine extends ConsumerWidget {
  const FeedStrategyLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final strategy = ref.watch(feedStrategyProvider);
    // Round 30 — only WATER-network equipment is feed evidence (a fire pump
    // on the hydrant line is not a water booster); nothing drawn on the water
    // services ⇒ the setting as chosen.
    final eq = drawnWaterFeedEquipment(
        ref.watch(networkControllerProvider).network);
    final hasPump = eq.hasPump;
    final StringKey key;
    if (strategy == FeedStrategy.upfeed) {
      key = hasPump || !eq.anyWaterNode
          ? StringKey.feedUpfeedPump
          : StringKey.feedUpfeedPumpAssumed;
    } else if (eq.hasRoofTank || !eq.anyWaterNode) {
      key = StringKey.feedRoofTankDownfeed;
    } else if (hasPump) {
      key = StringKey.feedBoosterNoRoofTank;
    } else {
      key = eq.hasWaterMeter
          ? StringKey.feedDirectMainsMeter
          : StringKey.feedDirectMains;
    }
    final value = context.strings(key);
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
