import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart' show ServiceType;

import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mechx_focus_ring.dart';
import 'service_style.dart';

/// A compact on-canvas TOOL CLUSTER (G3): a small floating glass strip that lets
/// an engineer switch the primary draw tools (Select / Run / Riser) and the
/// active layer's service WITHOUT the inspector — the canvas-focus state the app
/// encourages.
///
/// The host mounts it ONLY while the inspector is collapsed and a mechanical
/// layer is active (see [inspectorCollapsedProvider]), so an inspector-open
/// workspace — and every golden — is byte-identical. It reflects the live tool /
/// service (the tinted selected-segment idiom, F1) and drives the store; the
/// three tool taps route through the host's `_armTool` (so they honour the same
/// mutual exclusion as the single-key shortcuts).
class CanvasToolCluster extends ConsumerWidget {
  /// Arm the pointer / Select tool (clears any draw / annotation mode).
  final VoidCallback onSelect;

  /// Arm the Run tool.
  final VoidCallback onRun;

  /// Arm the Riser tool.
  final VoidCallback onRiser;

  const CanvasToolCluster({
    super.key,
    required this.onSelect,
    required this.onRun,
    required this.onRiser,
  });

  /// Fixed width so the chips + swatches stretch to a tidy column.
  static const double _width = 104;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final drawing = ref.watch(networkControllerProvider);
    final active = ref.watch(activeDisciplineProvider);
    final services = servicesFor(active);
    final tool = drawing.tool;

    return GlassSurface(
      borderRadius: MechXRadii.control,
      blurSigma: MechXGlass.blurSigmaLight,
      shadow: MechXShadow.card,
      child: Padding(
        padding: const EdgeInsets.all(MechXSpacing.xs),
        child: SizedBox(
          width: _width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ToolChip(
                label: 'Select',
                keyHint: 'V',
                selected: tool == DrawTool.select,
                onTap: onSelect,
              ),
              const SizedBox(height: MechXSpacing.xxs),
              _ToolChip(
                label: 'Run',
                keyHint: 'R',
                selected: tool == DrawTool.drawRun,
                onTap: onRun,
              ),
              const SizedBox(height: MechXSpacing.xxs),
              _ToolChip(
                label: 'Riser',
                keyHint: 'E',
                selected: tool == DrawTool.drawRiser,
                onTap: onRiser,
              ),
              if (services.isNotEmpty) ...[
                const SizedBox(height: MechXSpacing.xs),
                Container(height: 1, color: colors.border),
                const SizedBox(height: MechXSpacing.xs),
                for (final s in services)
                  Padding(
                    padding: const EdgeInsets.only(bottom: MechXSpacing.xxs),
                    child: _ServiceSwatch(
                      service: s,
                      selected: drawing.service == s,
                      onTap: () => ref
                          .read(networkControllerProvider.notifier)
                          .setService(s),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One tool chip: a tappable row of the tool name + its single-key hint, using
/// the tinted selected-segment idiom (accent-muted fill + accent border/text
/// when active; a soft hover fill otherwise).
class _ToolChip extends StatefulWidget {
  final String label;
  final String keyHint;
  final bool selected;
  final VoidCallback onTap;
  const _ToolChip({
    required this.label,
    required this.keyHint,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_ToolChip> createState() => _ToolChipState();
}

class _ToolChipState extends State<_ToolChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final selected = widget.selected;
    final bg = selected
        ? colors.accentMuted
        : (_hover ? colors.surfaceHover : const Color(0x00000000));
    final fg = selected ? colors.accent : colors.textSecondary;
    return MechXFocusRing(
      onActivated: widget.onTap,
      borderRadius: MechXRadii.small,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.xs + 2, vertical: MechXSpacing.xs + 1),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: MechXRadii.small,
              border: Border.all(
                  color: selected ? colors.accent : const Color(0x00000000)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    style: type.label.copyWith(
                        color: fg,
                        fontFamily: 'Roboto',
                        fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  widget.keyHint,
                  style: type.micro.copyWith(
                      color: selected ? colors.accent : colors.textMuted,
                      fontFamily: 'Roboto'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One service swatch: a coloured square + the service name, using the same
/// tinted selected idiom to show the ACTIVE draw service.
class _ServiceSwatch extends StatefulWidget {
  final ServiceType service;
  final bool selected;
  final VoidCallback onTap;
  const _ServiceSwatch({
    required this.service,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_ServiceSwatch> createState() => _ServiceSwatchState();
}

class _ServiceSwatchState extends State<_ServiceSwatch> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final selected = widget.selected;
    final bg = selected
        ? colors.accentMuted
        : (_hover ? colors.surfaceHover : const Color(0x00000000));
    return MechXFocusRing(
      onActivated: widget.onTap,
      borderRadius: MechXRadii.small,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.xs + 1, vertical: MechXSpacing.xxs + 1),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: MechXRadii.small,
              border: Border.all(
                  color: selected ? colors.accent : const Color(0x00000000)),
            ),
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: serviceColor(widget.service),
                    borderRadius: MechXRadii.small,
                  ),
                ),
                const SizedBox(width: MechXSpacing.xs),
                Expanded(
                  child: Text(
                    serviceLabel(widget.service),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.micro.copyWith(
                        color: selected
                            ? colors.accent
                            : colors.textSecondary,
                        fontFamily: 'Roboto'),
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
