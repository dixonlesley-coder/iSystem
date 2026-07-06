import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/layer_store.dart';
import '../canvas/service_style.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mechx_tooltip.dart';

/// Whether the on-canvas service-colour legend chip (E5) is expanded. Default ON
/// so a drafter always has the plumbing colour key while drawing; toggling it is
/// transient canvas state (never persisted to `.mechx`).
final serviceLegendExpandedProvider =
    NotifierProvider<ServiceLegendExpandedController, bool>(
  ServiceLegendExpandedController.new,
);

class ServiceLegendExpandedController extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;
}

/// A compact, toggleable service-colour LEGEND chip for the Layout canvas (E5):
/// the Plumbing layer overlays cold/hot water + drainage/vent/rainwater that
/// differ mostly by COLOUR alone (only vent dashes), yet the only colour key
/// lived in export chrome — so on a busy multi-service floor a drafter had no
/// in-context reference. This lists the ACTIVE layer's services with their
/// swatch (colour + dash) + name, in Liquid-Glass chrome at the canvas
/// bottom-left. Electrical (no `ServiceType` colours) renders nothing.
class ServiceLegendChip extends ConsumerWidget {
  const ServiceLegendChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeDisciplineProvider);
    final services = servicesFor(active);
    // Electrical (or any serviceless layer) has no colour key to show.
    if (services.isEmpty) return const SizedBox.shrink();

    final expanded = ref.watch(serviceLegendExpandedProvider);
    final colors = context.colors;
    final strings = context.strings;

    return GlassSurface(
      borderRadius: MechXRadii.control,
      blurSigma: MechXGlass.blurSigmaLight,
      shadow: MechXShadow.card,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 176),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header — tapping it toggles the swatch list (the on-canvas toggle).
            MechXTooltip(
              message: strings(expanded
                  ? StringKey.tooltipHideLegend
                  : StringKey.tooltipShowLegend),
              semanticLabel: strings(expanded
                  ? StringKey.tooltipHideLegend
                  : StringKey.tooltipShowLegend),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    ref.read(serviceLegendExpandedProvider.notifier).toggle(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        strings(StringKey.canvasLegendTitle).toUpperCase(),
                        style: context.type.micro
                            .copyWith(color: colors.textSecondary),
                      ),
                      const SizedBox(width: MechXSpacing.xs),
                      CustomPaint(
                        size: const Size(9, 9),
                        painter: _ChevronPainter(
                            expanded: expanded, color: colors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    MechXSpacing.sm, 0, MechXSpacing.sm, MechXSpacing.xs),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final s in services) _row(context, s),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, ServiceType s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(
              size: const Size(18, 8),
              painter:
                  _SwatchPainter(serviceColor(s), serviceDashPattern(s)),
            ),
            const SizedBox(width: MechXSpacing.sm),
            Text(
              serviceLabel(s),
              style: context.type.micro
                  .copyWith(color: context.colors.textPrimary),
            ),
          ],
        ),
      );
}

/// A horizontal line swatch in the service colour, drawn solid or as the
/// service's dash recipe so a dashed service (vent) reads dashed in the key too.
class _SwatchPainter extends CustomPainter {
  final Color color;
  final List<double>? dash;
  const _SwatchPainter(this.color, this.dash);

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    final d = dash;
    if (d == null || d.isEmpty) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }
    var x = 0.0;
    var i = 0;
    var on = true;
    while (x < size.width) {
      final seg = d[i % d.length];
      final end = (x + seg).clamp(0.0, size.width);
      if (on && end > x) canvas.drawLine(Offset(x, y), Offset(end, y), paint);
      x = end;
      i++;
      on = !on;
    }
  }

  @override
  bool shouldRepaint(_SwatchPainter old) =>
      old.color != color || old.dash != dash;
}

/// A tiny disclosure chevron — points DOWN when expanded, RIGHT when collapsed.
class _ChevronPainter extends CustomPainter {
  final bool expanded;
  final Color color;
  const _ChevronPainter({required this.expanded, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final w = size.width, h = size.height;
    final path = Path();
    if (expanded) {
      // v
      path.moveTo(w * 0.2, h * 0.35);
      path.lineTo(w * 0.5, h * 0.65);
      path.lineTo(w * 0.8, h * 0.35);
    } else {
      // >
      path.moveTo(w * 0.35, h * 0.2);
      path.lineTo(w * 0.65, h * 0.5);
      path.lineTo(w * 0.35, h * 0.8);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ChevronPainter old) =>
      old.expanded != expanded || old.color != color;
}
