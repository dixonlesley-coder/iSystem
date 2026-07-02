import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/annotation_store.dart';
import '../../store/network_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mechx_focus_ring.dart';
import 'service_style.dart';

/// A floating on-canvas MODE pill (top-centre): makes the active tool visible
/// on the canvas itself — the only other cue is the highlighted button inside
/// the (twice-collapsible) inspector, so the mode could be entirely invisible.
/// Shows the mode name (+ the service swatch for draw modes), an 'Esc' hint,
/// and a tappable Done that returns to Select. Renders NOTHING in plain Select
/// mode, so the at-rest canvas (and every golden) is unchanged.
class ModePill extends ConsumerWidget {
  const ModePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drawing = ref.watch(networkControllerProvider);
    final measure = ref.watch(measureModeProvider);
    final tank = ref.watch(tankModeProvider);
    final room = ref.watch(roomModeProvider);

    // The modes are mutually exclusive by the toolbar's design; resolve in
    // the same priority order the overlays mount.
    String? label;
    Color? swatch;
    void Function()? done;
    if (drawing.tool == DrawTool.drawRun) {
      label = 'Run · ${serviceLabel(drawing.service)}';
      swatch = serviceColor(drawing.service);
      done = () => ref
          .read(networkControllerProvider.notifier)
          .setTool(DrawTool.select);
    } else if (drawing.tool == DrawTool.drawRiser) {
      label = 'Riser · ${serviceLabel(drawing.service)}';
      swatch = serviceColor(drawing.service);
      done = () => ref
          .read(networkControllerProvider.notifier)
          .setTool(DrawTool.select);
    } else if (measure) {
      label = 'Measure';
      done = () => ref.read(measureModeProvider.notifier).set(false);
    } else if (tank) {
      label = 'Tank';
      done = () => ref.read(tankModeProvider.notifier).set(false);
    } else if (room) {
      label = 'Room';
      done = () => ref.read(roomModeProvider.notifier).set(false);
    }
    if (label == null) return const SizedBox.shrink();

    final colors = context.colors;
    final type = context.type;
    return GlassSurface(
      borderRadius: MechXRadii.control,
      blurSigma: MechXGlass.blurSigmaLight,
      shadow: MechXShadow.card,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm + 2, vertical: MechXSpacing.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (swatch != null) ...[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: swatch,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: MechXSpacing.xs + 2),
            ],
            Text(label,
                style: type.caption.copyWith(
                    color: colors.textPrimary, fontWeight: FontWeight.w600)),
            const SizedBox(width: MechXSpacing.xs + 2),
            Text('Esc', style: type.micro.copyWith(color: colors.textMuted)),
            const SizedBox(width: MechXSpacing.sm),
            Container(width: 1, height: 16, color: colors.border),
            const SizedBox(width: MechXSpacing.sm),
            MechXFocusRing(
              onActivated: done,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: done,
                  child: Text('Done',
                      style: type.caption.copyWith(
                          color: colors.accent, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
