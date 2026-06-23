/// The discipline LAYER SWITCHER for the unified Layout canvas — an iOS-styled
/// segmented control that picks the ACTIVE (editable) layer plus a per-layer
/// visibility toggle. The active layer is what you edit; the others render
/// faded for coordination (or hidden when toggled off).
///
/// Reads/writes `activeDisciplineProvider` + `layerVisibilityProvider`. Styled
/// with MechXTheme — no Material. Roboto-safe ASCII labels.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/layer_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// A compact "Layers" panel: a segmented active-layer picker + an eye toggle per
/// discipline. Sits in the canvas top bar.
class LayerSwitcher extends ConsumerWidget {
  const LayerSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final active = ref.watch(activeDisciplineProvider);
    final visible = ref.watch(layerVisibilityProvider);
    final activeCtrl = ref.read(activeDisciplineProvider.notifier);
    final visCtrl = ref.read(layerVisibilityProvider.notifier);

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.xs + 1, vertical: MechXSpacing.xxs + 1),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('LAYER',
              style: type.caption.copyWith(
                color: colors.textMuted,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w600,
              )),
          const SizedBox(width: MechXSpacing.sm),
          for (final layer in DisciplineLayer.values)
            _LayerSegment(
              layer: layer,
              active: layer == active,
              visible: visible.contains(layer),
              onSelect: () => activeCtrl.set(layer),
              onToggleVisible: () => visCtrl.toggle(layer),
            ),
        ],
      ),
    );
  }
}

/// One segment: the discipline name (taps to make it the ACTIVE layer) + a small
/// eye dot that toggles its visibility (a no-op for the active layer, which is
/// always shown). The active segment is filled; a hidden layer reads muted.
class _LayerSegment extends StatefulWidget {
  final DisciplineLayer layer;
  final bool active;
  final bool visible;
  final VoidCallback onSelect;
  final VoidCallback onToggleVisible;

  const _LayerSegment({
    required this.layer,
    required this.active,
    required this.visible,
    required this.onSelect,
    required this.onToggleVisible,
  });

  @override
  State<_LayerSegment> createState() => _LayerSegmentState();
}

class _LayerSegmentState extends State<_LayerSegment> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final fg = widget.active
        ? const Color(0xFFFFFFFF)
        : (widget.visible ? colors.textSecondary : colors.textMuted);
    final bg = widget.active
        ? colors.accent
        : (_hover ? colors.surfaceHover : const Color(0x00000000));

    return Padding(
      padding: const EdgeInsets.only(right: MechXSpacing.xxs),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: MechXRadii.control,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Name — selects the active layer.
              GestureDetector(
                onTap: widget.onSelect,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      MechXSpacing.sm, MechXSpacing.xs, MechXSpacing.xs,
                      MechXSpacing.xs),
                  child: Text(widget.layer.label,
                      style: type.label.copyWith(
                        color: fg,
                        fontWeight:
                            widget.active ? FontWeight.w700 : FontWeight.w500,
                      )),
                ),
              ),
              // Visibility eye dot — toggles draw on/off (active stays on).
              GestureDetector(
                onTap: widget.onToggleVisible,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      2, MechXSpacing.xs, MechXSpacing.sm, MechXSpacing.xs),
                  child: _EyeDot(visible: widget.visible, color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tiny visibility indicator: a filled ring when visible, a hollow ring with a
/// slash when hidden. Custom-painted (no icon font), so it never tofus.
class _EyeDot extends StatelessWidget {
  final bool visible;
  final Color color;
  const _EyeDot({required this.visible, required this.color});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(13, 13), painter: _EyePainter(visible, color));
}

class _EyePainter extends CustomPainter {
  final bool visible;
  final Color color;
  _EyePainter(this.visible, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    if (visible) {
      canvas.drawCircle(c, size.width * 0.34, stroke);
      canvas.drawCircle(c, size.width * 0.12, Paint()..color = color);
    } else {
      canvas.drawCircle(c, size.width * 0.34,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0);
      // A slash through it.
      canvas.drawLine(
        Offset(size.width * 0.18, size.height * 0.82),
        Offset(size.width * 0.82, size.height * 0.18),
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_EyePainter old) =>
      old.visible != visible || old.color != color;
}
