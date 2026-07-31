import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/layer_store.dart';
import '../canvas/service_style.dart';
import '../electrical/sld_sheet_painter.dart' show kRailR, kRailS, kRailT;
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

/// One legend row's key: a coloured swatch (solid or the service's dash recipe)
/// and the name it stands for.
@immutable
class _LegendRow {
  final Color color;
  final List<double>? dash;
  final String label;
  const _LegendRow(this.color, this.label, {this.dash});
}

/// A compact, toggleable colour LEGEND chip for the Layout canvas (E5 + J4):
/// the canvas overlays several disciplines that differ mostly by COLOUR alone,
/// yet the only colour key lived in export chrome — so on a busy floor a
/// drafter had no in-context reference.
///
/// It lists the ACTIVE layer's key rows: for a mechanical layer its services
/// (colour + dash + name); for ELECTRICAL — which has no `ServiceType` and so
/// used to render NOTHING at all while the canvas painted phase colours — the
/// R / S / T rails (the same [kRailR]/[kRailS]/[kRailT] palette the board
/// schedule column-heads and the single-line use, so a hue means one thing
/// everywhere), the feeder accent and the essential-supply red.
///
/// Beneath that, a MUTED second group names the other layers that are visible
/// but GHOSTED — the faded geometry on screen belongs to a discipline, and the
/// chip is the only place that says which. Renders nothing when there is
/// genuinely nothing to key.
class ServiceLegendChip extends ConsumerWidget {
  const ServiceLegendChip({super.key});

  /// The active layer's key rows. Mechanical layers key their services;
  /// electrical keys the phase rails + the two role colours the canvas paints.
  static List<_LegendRow> _activeRows(
    DisciplineLayer active,
    MechXColors colors,
    MechXStringsData strings,
  ) {
    if (active != DisciplineLayer.electrical) {
      return [
        for (final s in servicesFor(active))
          _LegendRow(serviceColor(s), serviceLabel(s), dash: serviceDashPattern(s)),
      ];
    }
    return [
      _LegendRow(kRailR, strings(StringKey.canvasLegendPhaseR)),
      _LegendRow(kRailS, strings(StringKey.canvasLegendPhaseS)),
      _LegendRow(kRailT, strings(StringKey.canvasLegendPhaseT)),
      _LegendRow(colors.accent, strings(StringKey.canvasLegendFeeder)),
      _LegendRow(colors.danger, strings(StringKey.canvasLegendEssential)),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeDisciplineProvider);
    final visible = ref.watch(layerVisibilityProvider);
    final colors = context.colors;
    final strings = context.strings;

    final rows = _activeRows(active, colors, strings);
    // The visible-but-inactive layers, in the switcher's own order — what the
    // ghosted geometry on the canvas belongs to.
    final ghosted = [
      for (final l in DisciplineLayer.values)
        if (l != active && visible.contains(l)) l,
    ];
    // Nothing to key at all (no active-layer rows AND no ghosted layers).
    if (rows.isEmpty && ghosted.isEmpty) return const SizedBox.shrink();

    final expanded = ref.watch(serviceLegendExpandedProvider);

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
                    for (final r in rows) _row(context, r),
                    // J4: the ghosted reference layers, quieter than the active
                    // layer's own key — they are context, not the thing you're
                    // drawing.
                    if (ghosted.isNotEmpty) ...[
                      const SizedBox(height: MechXSpacing.xxs),
                      Text(
                        strings(StringKey.canvasLegendGhosted).toUpperCase(),
                        style: context.type.micro
                            .copyWith(color: colors.textMuted),
                      ),
                      for (final l in ghosted) _ghostRow(context, l),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, _LegendRow r) => Padding(
        padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(
              size: const Size(18, 8),
              painter: _SwatchPainter(r.color, r.dash),
            ),
            const SizedBox(width: MechXSpacing.sm),
            // L-4: the swatch label carries the legend's whole informational
            // content (which colour means which service), so it reads at the
            // theme's CAPTION size — one legible step up from the header's
            // dense `micro` chrome-label token — while the chip stays compact.
            Flexible(
              child: Text(
                r.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.caption
                    .copyWith(color: context.colors.textPrimary),
              ),
            ),
          ],
        ),
      );

  /// A ghosted (visible-but-inactive) discipline's row — the layer name in the
  /// muted tier with no swatch, so it can never be mistaken for a colour key of
  /// the layer you are drawing on.
  Widget _ghostRow(BuildContext context, DisciplineLayer layer) => Padding(
        padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
        child: Text(
          layer.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.type.caption.copyWith(color: context.colors.textMuted),
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
