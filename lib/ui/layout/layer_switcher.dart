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
import '../widgets/mechx_segment.dart';

/// A compact "Layers" panel: a segmented active-layer picker + an eye toggle per
/// discipline. Sits in the canvas top bar.
class LayerSwitcher extends ConsumerWidget {
  const LayerSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
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

/// One layer entry — a RADIO select (the discipline name, which makes the layer
/// ACTIVE/editable) paired with an independent visibility TOGGLE (the eye).
///
/// C2 (one segment idiom · radio vs toggle must LOOK different): the name reuses
/// the shared [MechXSegment] tinted selected-segment idiom — the very same
/// widget the Riser Auto/Edit tabs and the draw-tool pills use — instead of
/// forking it, so "the active layer" reads exactly like every other "pick one
/// of N" in the app. The eye stays a DISTINCT on/off glyph (never the accent
/// pill), so a viewer can tell "pick one" (active layer) from "flip each"
/// (show/hide). The eye is a no-op for the active layer, which is always shown.
class _LayerSegment extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(right: MechXSpacing.xxs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The RADIO select — the shared tinted selected-segment idiom
          // (keyboard focus + Enter/Space come free from MechXSegment).
          MechXSegment(
            label: layer.label,
            selected: active,
            onTap: onSelect,
            selectedWeight: FontWeight.w700,
          ),
          // The visibility TOGGLE — a distinct eye glyph the accent pill never
          // touches. Colour carries the layer's on/off/active state (the label
          // stays identity-only).
          _EyeToggle(
            visible: visible,
            color: active
                ? colors.textPrimary
                : (visible ? colors.textSecondary : colors.textMuted),
            onTap: onToggleVisible,
          ),
        ],
      ),
    );
  }
}

/// The visibility toggle: a tappable [_EyeDot] — a pointer affordance (the
/// keyboard path selects the layer via the name segment). Distinct from the
/// radio tint by construction — it is never filled with the accent.
class _EyeToggle extends StatelessWidget {
  final bool visible;
  final Color color;
  final VoidCallback onTap;
  const _EyeToggle(
      {required this.visible, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.xs, vertical: MechXSpacing.xs),
          child: _EyeDot(visible: visible, color: color),
        ),
      ),
    );
  }
}

/// The show/hide control: a clear almond eye with a pupil when the layer is
/// shown, struck through when hidden. Custom-painted (no icon font), so it
/// never tofus. Larger than a dot so it reads as a real toggle.
class _EyeDot extends StatelessWidget {
  final bool visible;
  final Color color;
  const _EyeDot({required this.visible, required this.color});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(18, 14), painter: _EyePainter(visible, color));
}

class _EyePainter extends CustomPainter {
  final bool visible;
  final Color color;
  _EyePainter(this.visible, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cy = h / 2;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // Almond eye outline (upper + lower lid).
    final eye = Path()
      ..moveTo(w * 0.08, cy)
      ..quadraticBezierTo(cx, h * 0.02, w * 0.92, cy)
      ..quadraticBezierTo(cx, h * 0.98, w * 0.08, cy)
      ..close();
    canvas.drawPath(eye, stroke);
    // Pupil — filled when shown, hollow when hidden.
    canvas.drawCircle(
      Offset(cx, cy),
      h * 0.22,
      visible
          ? (Paint()..color = color)
          : (Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2),
    );
    if (!visible) {
      // Strike-through for the hidden state.
      canvas.drawLine(Offset(w * 0.1, h * 0.92), Offset(w * 0.9, h * 0.08), stroke);
    }
  }

  @override
  bool shouldRepaint(_EyePainter old) =>
      old.visible != visible || old.color != color;
}
