import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'mechx_scrollbar.dart';

/// A calm, centred page used by the non-canvas shell sections (Review,
/// Commercial, Projects, Preferences). A titled column on the app background,
/// width-capped for readability. Custom MechXTheme styling — no Material.
///
/// Stateful only to own the [ScrollController] shared with [MechXScrollbar] so
/// the scroll thumb is draggable (J1); the thumb is idle-invisible so a static
/// frame is byte-identical.
class HubScaffold extends StatefulWidget {
  final String title;
  final String lead;
  final List<Widget> children;

  const HubScaffold({
    super.key,
    required this.title,
    required this.lead,
    this.children = const [],
  });

  @override
  State<HubScaffold> createState() => _HubScaffoldState();
}

class _HubScaffoldState extends State<HubScaffold> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return ColoredBox(
      color: colors.background,
      child: MechXScrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.all(MechXSpacing.xl),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.title,
                      style: type.display.copyWith(color: colors.textPrimary)),
                  const SizedBox(height: MechXSpacing.sm),
                  Text(widget.lead,
                      style: type.body.copyWith(color: colors.textSecondary)),
                  const SizedBox(height: MechXSpacing.lg),
                  ...widget.children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of labelled figures used at the top of a hub.
class HubStatRow extends StatelessWidget {
  final List<(String, String)> stats;
  const HubStatRow({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in stats)
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(right: MechXSpacing.sm),
              padding: const EdgeInsets.all(MechXSpacing.md),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: MechXRadii.card,
                border: Border.all(color: colors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style:
                          type.display.copyWith(color: colors.textPrimary)),
                  const SizedBox(height: MechXSpacing.xxs),
                  Text(label,
                      style:
                          type.caption.copyWith(color: colors.textMuted)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A quiet informational note card.
class HubNote extends StatelessWidget {
  final String text;
  const HubNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(MechXSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      child: Text(text,
          style: type.body.copyWith(color: colors.textSecondary)),
    );
  }
}
