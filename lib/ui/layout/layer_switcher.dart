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
import 'package:mechx_engine/network/network.dart' show ServiceType;
import 'package:mechx_engine/report/riser_tags.dart' show riserServiceCode;

import '../../store/layer_store.dart';
import '../canvas/service_style.dart' show serviceColor;
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_segment.dart';
import '../widgets/mechx_tooltip.dart';

/// A compact "Layers" panel: a segmented active-layer picker + a per-discipline
/// eye (visibility) and padlock (F1 reference-layer lock), plus an optional
/// per-SERVICE view filter for the active layer (F4). Sits in the canvas top
/// bar. At rest (nothing locked, filter collapsed, all services shown) the
/// canvas render is byte-identical — the switcher only gains the small padlock /
/// filter affordances.
class LayerSwitcher extends ConsumerStatefulWidget {
  const LayerSwitcher({super.key});

  @override
  ConsumerState<LayerSwitcher> createState() => _LayerSwitcherState();
}

class _LayerSwitcherState extends ConsumerState<LayerSwitcher> {
  /// F4 — whether the active layer's per-service view filter is expanded.
  /// Transient chrome, collapsed by default: the idle switcher gains only a
  /// small filter glyph, not the whole service-chip row.
  bool _filterOpen = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final active = ref.watch(activeDisciplineProvider);
    final visible = ref.watch(layerVisibilityProvider);
    final locked = ref.watch(lockedDisciplinesProvider);
    final hidden = ref.watch(hiddenServicesProvider);
    final activeCtrl = ref.read(activeDisciplineProvider.notifier);
    final visCtrl = ref.read(layerVisibilityProvider.notifier);
    final lockCtrl = ref.read(lockedDisciplinesProvider.notifier);
    final hideCtrl = ref.read(hiddenServicesProvider.notifier);

    // F4 — the active layer's own services, offered as an inline per-service
    // filter only when the layer folds MORE THAN ONE service (plumbing 5,
    // HVAC 3; fire 2). Electrical has none, so the filter never shows there.
    final activeServices = servicesFor(active);
    final canFilter = activeServices.length > 1;

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
              locked: locked.contains(layer),
              onSelect: () => activeCtrl.set(layer),
              onToggleVisible: () => visCtrl.toggle(layer),
              onToggleLock: () => lockCtrl.toggle(layer),
            ),
          if (canFilter) ...[
            const SizedBox(width: MechXSpacing.xxs),
            _ServiceFilterToggle(
              open: _filterOpen,
              onTap: () => setState(() => _filterOpen = !_filterOpen),
            ),
            if (_filterOpen)
              for (final s in activeServices)
                _ServiceChip(
                  service: s,
                  hidden: hidden.contains(s),
                  onTap: () => hideCtrl.toggle(s),
                ),
          ],
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
  final bool locked;
  final VoidCallback onSelect;
  final VoidCallback onToggleVisible;
  final VoidCallback onToggleLock;

  const _LayerSegment({
    required this.layer,
    required this.active,
    required this.visible,
    required this.locked,
    required this.onSelect,
    required this.onToggleVisible,
    required this.onToggleLock,
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
          // F1 — the reference-layer LOCK. Shown only for a NON-active layer
          // (the active layer is the one you edit and can never be locked); a
          // locked layer still renders (faded) but is inert to clicks/drags.
          if (!active)
            _LockToggle(
              locked: locked,
              onTap: onToggleLock,
            ),
        ],
      ),
    );
  }
}

/// F1 — the reference-layer lock toggle: a tappable padlock (distinct from the
/// eye), open+muted when unlocked and closed+accent when locked. Wrapped in a
/// MechXTheme tooltip (EN+ID). Custom-painted (no icon font), so it never tofus.
class _LockToggle extends StatelessWidget {
  final bool locked;
  final VoidCallback onTap;
  const _LockToggle({required this.locked, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = context.strings(
        locked ? StringKey.tooltipUnlockLayer : StringKey.tooltipLockLayer);
    return MechXTooltip(
      message: label,
      semanticLabel: label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.xxs + 1, vertical: MechXSpacing.xs),
            child: CustomPaint(
              size: const Size(13, 15),
              painter: _LockPainter(
                locked: locked,
                color: locked ? colors.accent : colors.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws a small padlock: a rounded body with a shackle above it. Locked → a
/// closed shackle (a full arch seated on the body) + a filled body; unlocked →
/// an OPEN shackle (the right leg lifted clear) + a hollow body, so the two
/// states read differently at a glance.
class _LockPainter extends CustomPainter {
  final bool locked;
  final Color color;
  _LockPainter({required this.locked, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // Body: a rounded rectangle in the lower ~55% of the glyph.
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.12, h * 0.46, w * 0.76, h * 0.5),
      const Radius.circular(2),
    );
    canvas.drawRRect(
        body, locked ? (Paint()..color = color) : stroke);
    // Keyhole pip on a filled (locked) body for a touch of detail.
    if (locked) {
      canvas.drawCircle(Offset(w / 2, h * 0.68), 1.3,
          Paint()..color = const Color(0xFFFFFFFF));
    }
    // Shackle: a half-arch from the body's top-left up and over to the top-right.
    final left = w * 0.28;
    final right = w * 0.72;
    final seat = h * 0.48; // where a closed shackle meets the body
    final path = Path()
      ..moveTo(left, seat)
      ..lineTo(left, h * 0.30)
      ..arcToPoint(Offset(right, h * 0.30),
          radius: Radius.circular((right - left) / 2), clockwise: true);
    // Closed → the right leg seats onto the body; open → it lifts clear.
    path.lineTo(right, locked ? seat : h * 0.34);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(_LockPainter old) =>
      old.locked != locked || old.color != color;
}

/// F4 — the per-service filter toggle: a small funnel glyph that expands the
/// active layer's service chips. Accent-tinted when open, muted when closed.
class _ServiceFilterToggle extends StatelessWidget {
  final bool open;
  final VoidCallback onTap;
  const _ServiceFilterToggle({required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MechXTooltip(
      message: context.strings(StringKey.tooltipFilterServices),
      semanticLabel: context.strings(StringKey.tooltipFilterServices),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.xs, vertical: MechXSpacing.xs),
            child: CustomPaint(
              size: const Size(14, 12),
              painter: _FunnelPainter(open ? colors.accent : colors.textMuted),
            ),
          ),
        ),
      ),
    );
  }
}

/// A funnel glyph (wide top tapering to a stem) — the "filter" affordance.
class _FunnelPainter extends CustomPainter {
  final Color color;
  _FunnelPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final p = Path()
      ..moveTo(w * 0.06, h * 0.12)
      ..lineTo(w * 0.94, h * 0.12)
      ..lineTo(w * 0.58, h * 0.52)
      ..lineTo(w * 0.58, h * 0.92)
      ..lineTo(w * 0.42, h * 0.92)
      ..lineTo(w * 0.42, h * 0.52)
      ..close();
    canvas.drawPath(
      p,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_FunnelPainter old) => old.color != color;
}

/// F4 — one per-service view-filter chip: the service code (CW / HW / D / …) in
/// its service colour, shown when the service is visible and dimmed + struck
/// when hidden. Tapping toggles the service in/out of the canvas view.
class _ServiceChip extends StatelessWidget {
  final ServiceType service;
  final bool hidden;
  final VoidCallback onTap;
  const _ServiceChip({
    required this.service,
    required this.hidden,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final base = serviceColor(service);
    final code = riserServiceCode(service);
    final ink = hidden ? colors.textMuted : base;
    return Padding(
      padding: const EdgeInsets.only(left: MechXSpacing.xxs),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: MechXSpacing.xs, vertical: MechXSpacing.xxs),
            decoration: BoxDecoration(
              borderRadius: MechXRadii.small,
              border: Border.all(
                  color: hidden ? colors.border : base.withAlpha(140)),
              color: hidden ? const Color(0x00000000) : base.withAlpha(28),
            ),
            child: Text(
              code,
              style: type.micro.copyWith(
                color: ink,
                fontWeight: FontWeight.w700,
                decoration:
                    hidden ? TextDecoration.lineThrough : TextDecoration.none,
                decorationColor: ink,
              ),
            ),
          ),
        ),
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
    // L4 (a11y): the eye is icon-only with no caption — name the show/hide
    // action for a screen reader (the label reflects the action, i.e. what a tap
    // does next: hide when currently shown, show when hidden).
    return Semantics(
      button: true,
      label: context.strings(
          visible ? StringKey.a11yHideLayer : StringKey.a11yShowLayer),
      child: MouseRegion(
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
