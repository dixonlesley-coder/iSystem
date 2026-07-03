import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models/sheet.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mechx_focus_ring.dart';

/// Left rail: multi-sheet navigation, slimmed to a compact tile strip so the
/// canvas gets the real estate. Each sheet is a small page thumbnail stamped
/// with its index and a terse, truncated label; the current one is highlighted
/// (the status bar carries the full sheet name). Clicking switches (restoring
/// that sheet's viewport).
class SheetRail extends ConsumerWidget {
  const SheetRail({super.key});

  /// Narrow — just wide enough for a page thumbnail + a short label. Trimmed
  /// from the old 232-px wide-card list to 76, then to 64 to hand the canvas
  /// the last ~12 px.
  static const double width = 64;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sheetsControllerProvider);
    final colors = context.colors;
    final type = context.type;

    return SizedBox(
      width: width,
      child: GlassSurface(
        // Floats over the canvas; its right edge faces the drawing.
        edge: Border(
            right: BorderSide(
                color: colors.glassEdge, width: MechXGlass.edgeWidth)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Terse header: a count badge (the word "Sheets" doesn't fit the
            // slim rail; the status bar already names the active sheet).
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MechXSpacing.xs,
                MechXSpacing.sm,
                MechXSpacing.xs,
                MechXSpacing.xs,
              ),
              child: Text(
                '${state.sheets.length} SHT',
                textAlign: TextAlign.center,
                style: type.caption.copyWith(
                  color: colors.textMuted,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Container(height: 1, color: colors.border),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xs),
                itemCount: state.sheets.length,
                itemBuilder: (context, i) => _RailItem(
                  index: i,
                  sheet: state.sheets[i],
                  selected: i == state.currentIndex,
                  onTap: () =>
                      ref.read(sheetsControllerProvider.notifier).selectSheet(i),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends ConsumerStatefulWidget {
  final int index;
  final Sheet sheet;
  final bool selected;
  final VoidCallback onTap;

  const _RailItem({
    required this.index,
    required this.sheet,
    required this.selected,
    required this.onTap,
  });

  @override
  ConsumerState<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends ConsumerState<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final project = ref.watch(projectControllerProvider);
    final calibrated = project.calibrationFor(widget.sheet.id) != null;
    // Which building floor this sheet maps to (B7): stamped on the tile so a
    // remap — or a silent pile-up when more sheets than floors default onto the
    // top — is visible at a glance, not invisible. 1-based, ASCII ("F3").
    final mappedFloor = ref
        .watch(sheetsControllerProvider)
        .floorFor(widget.sheet.id, project.building.levelCount);
    final bg = widget.selected
        ? colors.accentMuted
        : (_hover ? colors.surfaceHover : const Color(0x00000000));
    final labelColor =
        widget.selected ? colors.textPrimary : colors.textSecondary;

    return MechXFocusRing(
      onActivated: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          // Ease the hover / selection fill so switching sheets feels smooth.
          child: AnimatedContainer(
            duration: MechXMotion.hover,
            curve: MechXMotion.standard,
            margin: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.xs,
              vertical: MechXSpacing.xxs,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.xxs,
              vertical: MechXSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: MechXRadii.control,
            ),
            child: Column(
              children: [
                // A mini page thumbnail with the sheet index centred on it.
                Container(
                  width: 34,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.canvas,
                    borderRadius: const BorderRadius.all(Radius.circular(3)),
                    border: Border.all(
                      color: widget.selected ? colors.accent : colors.border,
                      width: widget.selected ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    '${widget.index + 1}',
                    style: type.mono.copyWith(
                      color: widget.selected ? colors.accent : colors.textMuted,
                    ),
                  ),
                ),
                const SizedBox(height: MechXSpacing.xxs),
                // Terse label, truncated to fit the slim rail.
                Text(
                  widget.sheet.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: type.caption.copyWith(color: labelColor),
                ),
                const SizedBox(height: MechXSpacing.xxs),
                // Per-sheet calibration status + mapped-floor stamp, on one
                // row: a small glyph pairing colour with shape (a check ring =
                // calibrated/green, a "!" ring = uncalibrated/warning) so the
                // rail reads at a glance which sheets still need a scale,
                // without relying on hue alone; and the building floor this
                // sheet maps to ("F3") so a remap / pile-up is visible.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CustomPaint(
                      size: const Size(9, 9),
                      painter: _CalibrationGlyph(
                        calibrated: calibrated,
                        color: calibrated ? colors.success : colors.warning,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Text(
                      'F${mappedFloor + 1}',
                      style: type.micro.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The per-sheet calibration mark: a check ring when [calibrated], else a "!"
/// ring. A redundant cue (shape + colour) so the status survives without hue
/// alone. Custom-painted (no icon font), so it can never tofu in the goldens.
class _CalibrationGlyph extends CustomPainter {
  final bool calibrated;
  final Color color;

  const _CalibrationGlyph({required this.calibrated, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final c = Offset(w / 2, h / 2);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawCircle(c, w * 0.42, stroke);
    if (calibrated) {
      final path = Path()
        ..moveTo(w * 0.30, h * 0.52)
        ..lineTo(w * 0.45, h * 0.68)
        ..lineTo(w * 0.72, h * 0.34);
      canvas.drawPath(path, stroke);
    } else {
      // An exclamation stem + dot inside the ring.
      canvas.drawLine(
        Offset(w / 2, h * 0.30),
        Offset(w / 2, h * 0.58),
        stroke,
      );
      canvas.drawCircle(Offset(w / 2, h * 0.74), w * 0.07,
          Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_CalibrationGlyph old) =>
      old.calibrated != calibrated || old.color != color;
}
