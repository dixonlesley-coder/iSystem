import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/electrical_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// The top-level destination chosen in the left navigation rail. `design` shows
/// the workspace area (Plan / Schematic / Electrical, driven by
/// [workspaceViewProvider]); the others show their own screens.
enum ShellSection { design, review, commercial, projects, preferences }

/// Active shell section. Defaults to [ShellSection.design] so a fresh launch
/// (and the golden-screenshot test, which only sets [workspaceViewProvider])
/// lands on the workspace.
final shellSectionProvider =
    NotifierProvider<ShellSectionController, ShellSection>(
  ShellSectionController.new,
);

class ShellSectionController extends Notifier<ShellSection> {
  @override
  ShellSection build() => ShellSection.design;

  void set(ShellSection s) => state = s;
}

/// The kinds of glyph the rail draws. Custom-painted (no icon font) so nothing
/// can render as tofu in the goldens.
enum _Glyph { plan, schematic, electrical, review, commercial, projects, preferences }

/// PanelMaker's left navigation rail, mirrored for iSystem's M+E+P workspaces.
///
/// A fixed-width vertical rail: a DESIGN group (Plan / Schematic / Electrical) →
/// Review → Commercial, a spacer, then pinned Projects + Preferences. The active
/// item is highlighted. Design items drive [workspaceViewProvider]; the rest set
/// [shellSectionProvider].
class NavRail extends ConsumerWidget {
  const NavRail({super.key});

  /// Matches PanelMaker's 248-px navbar.
  static const double width = 248;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final section = ref.watch(shellSectionProvider);
    final view = ref.watch(workspaceViewProvider);

    final sectionCtrl = ref.read(shellSectionProvider.notifier);
    final viewCtrl = ref.read(workspaceViewProvider.notifier);

    // A Design item is active when we're in the design section AND its
    // workspace view is selected — so the highlight tracks the real centre area
    // with no off-by-one.
    bool designActive(WorkspaceView v) =>
        section == ShellSection.design && view == v;

    void openDesign(WorkspaceView v) {
      viewCtrl.set(v);
      sectionCtrl.set(ShellSection.design);
    }

    return Container(
      width: width,
      color: colors.surface,
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GroupLabel('DESIGN', style: type.caption.copyWith(color: colors.textMuted)),
          const SizedBox(height: MechXSpacing.xxs),
          _NavItem(
            glyph: _Glyph.plan,
            label: 'Plan',
            active: designActive(WorkspaceView.plan),
            onTap: () => openDesign(WorkspaceView.plan),
          ),
          _NavItem(
            glyph: _Glyph.schematic,
            label: 'Schematic',
            active: designActive(WorkspaceView.schematic),
            onTap: () => openDesign(WorkspaceView.schematic),
          ),
          _NavItem(
            glyph: _Glyph.electrical,
            label: 'Electrical',
            active: designActive(WorkspaceView.electrical),
            onTap: () => openDesign(WorkspaceView.electrical),
          ),
          const SizedBox(height: MechXSpacing.sm),
          _NavItem(
            glyph: _Glyph.review,
            label: 'Review',
            active: section == ShellSection.review,
            onTap: () => sectionCtrl.set(ShellSection.review),
          ),
          _NavItem(
            glyph: _Glyph.commercial,
            label: 'Commercial',
            active: section == ShellSection.commercial,
            onTap: () => sectionCtrl.set(ShellSection.commercial),
          ),
          const Spacer(),
          _NavItem(
            glyph: _Glyph.projects,
            label: 'Projects',
            active: section == ShellSection.projects,
            onTap: () => sectionCtrl.set(ShellSection.projects),
          ),
          _NavItem(
            glyph: _Glyph.preferences,
            label: 'Preferences',
            active: section == ShellSection.preferences,
            onTap: () => sectionCtrl.set(ShellSection.preferences),
          ),
        ],
      ),
    );
  }
}

/// A small all-caps group heading (e.g. "DESIGN").
class _GroupLabel extends StatelessWidget {
  final String text;
  final TextStyle style;
  const _GroupLabel(this.text, {required this.style});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          MechXSpacing.sm,
          MechXSpacing.xs,
          MechXSpacing.sm,
          MechXSpacing.xxs,
        ),
        child: Text(text, style: style.copyWith(letterSpacing: 0.6)),
      );
}

/// One rail row: a custom-drawn glyph + a label, with hover + active states.
class _NavItem extends StatefulWidget {
  final _Glyph glyph;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _NavItem({
    required this.glyph,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    final bg = widget.active
        ? colors.accentMuted
        : (_hover ? colors.surfaceHover : const Color(0x00000000));
    final fg = widget.active ? colors.accent : colors.textSecondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.xxs),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: MechXMotion.fast,
            curve: MechXMotion.standard,
            padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm,
              vertical: MechXSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: MechXRadii.control,
            ),
            child: Row(
              children: [
                CustomPaint(
                  size: const Size(18, 18),
                  painter: _GlyphPainter(widget.glyph, fg),
                ),
                const SizedBox(width: MechXSpacing.sm + 2),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.label.copyWith(
                      color: fg,
                      fontWeight:
                          widget.active ? FontWeight.w600 : FontWeight.w500,
                    ),
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

/// Draws the small rail glyphs from primitives — no icon font, so they can
/// never render as tofu. Each is a simple, legible mark sized to an 18×18 box.
class _GlyphPainter extends CustomPainter {
  final _Glyph glyph;
  final Color color;

  _GlyphPainter(this.glyph, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final w = size.width;
    final h = size.height;

    switch (glyph) {
      case _Glyph.plan:
        // A drawing sheet with a folded corner + a couple of rule lines.
        final r = Rect.fromLTWH(w * 0.18, h * 0.12, w * 0.64, h * 0.76);
        canvas.drawRRect(
            RRect.fromRectAndRadius(r, const Radius.circular(2)), stroke);
        canvas.drawLine(
            Offset(w * 0.30, h * 0.40), Offset(w * 0.70, h * 0.40), stroke);
        canvas.drawLine(
            Offset(w * 0.30, h * 0.58), Offset(w * 0.62, h * 0.58), stroke);
      case _Glyph.schematic:
        // A riser node tree: a trunk with two branches and end dots.
        canvas.drawLine(
            Offset(w * 0.5, h * 0.14), Offset(w * 0.5, h * 0.86), stroke);
        canvas.drawLine(
            Offset(w * 0.5, h * 0.40), Offset(w * 0.82, h * 0.40), stroke);
        canvas.drawLine(
            Offset(w * 0.5, h * 0.66), Offset(w * 0.20, h * 0.66), stroke);
        canvas.drawCircle(Offset(w * 0.5, h * 0.14), 1.8, fill);
        canvas.drawCircle(Offset(w * 0.82, h * 0.40), 1.8, fill);
        canvas.drawCircle(Offset(w * 0.20, h * 0.66), 1.8, fill);
      case _Glyph.electrical:
        // A lightning bolt.
        final p = Path()
          ..moveTo(w * 0.56, h * 0.10)
          ..lineTo(w * 0.30, h * 0.54)
          ..lineTo(w * 0.48, h * 0.54)
          ..lineTo(w * 0.42, h * 0.90)
          ..lineTo(w * 0.72, h * 0.42)
          ..lineTo(w * 0.52, h * 0.42)
          ..close();
        canvas.drawPath(p, fill);
      case _Glyph.review:
        // A simple bar chart (three columns of different heights).
        canvas.drawLine(
            Offset(w * 0.16, h * 0.84), Offset(w * 0.84, h * 0.84), stroke);
        void bar(double cx, double top) => canvas.drawLine(
            Offset(cx, h * 0.84), Offset(cx, top), stroke);
        bar(w * 0.30, h * 0.56);
        bar(w * 0.50, h * 0.32);
        bar(w * 0.70, h * 0.48);
      case _Glyph.commercial:
        // A receipt / document with a torn lower edge + lines.
        final r = Rect.fromLTWH(w * 0.24, h * 0.12, w * 0.52, h * 0.62);
        canvas.drawRect(r, stroke);
        canvas.drawLine(
            Offset(w * 0.33, h * 0.30), Offset(w * 0.67, h * 0.30), stroke);
        canvas.drawLine(
            Offset(w * 0.33, h * 0.46), Offset(w * 0.67, h * 0.46), stroke);
        // zig-zag torn edge
        final torn = Path()..moveTo(w * 0.24, h * 0.74);
        for (var i = 0; i < 4; i++) {
          final x0 = w * (0.24 + 0.13 * i);
          torn.lineTo(x0 + w * 0.065, h * 0.86);
          torn.lineTo(x0 + w * 0.13, h * 0.74);
        }
        canvas.drawPath(torn, stroke);
      case _Glyph.projects:
        // A folder.
        final body = Path()
          ..moveTo(w * 0.16, h * 0.34)
          ..lineTo(w * 0.16, h * 0.80)
          ..lineTo(w * 0.84, h * 0.80)
          ..lineTo(w * 0.84, h * 0.34);
        canvas.drawPath(body, stroke);
        final tab = Path()
          ..moveTo(w * 0.16, h * 0.34)
          ..lineTo(w * 0.16, h * 0.22)
          ..lineTo(w * 0.42, h * 0.22)
          ..lineTo(w * 0.50, h * 0.34);
        canvas.drawPath(tab, stroke);
      case _Glyph.preferences:
        // A gear: a hub ring with eight radial teeth.
        final c = Offset(w * 0.5, h * 0.5);
        final rOuter = w * 0.32;
        final rInner = w * 0.20;
        for (var i = 0; i < 8; i++) {
          final a = i * math.pi / 4;
          final dir = Offset(math.cos(a), math.sin(a));
          canvas.drawLine(c + dir * rInner, c + dir * rOuter, stroke);
        }
        canvas.drawCircle(c, rInner, stroke);
        canvas.drawCircle(c, w * 0.07, fill);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
