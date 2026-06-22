import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/units.dart';

import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_text_field.dart';

/// Right inspector: project details, per-floor heights (the vertical
/// length source of truth, §10), and the per-sheet scale-calibration status.
class ProjectPanel extends ConsumerWidget {
  const ProjectPanel({super.key});

  static const double width = 296;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final project = ref.watch(projectControllerProvider);
    final ctrl = ref.read(projectControllerProvider.notifier);
    final building = project.building;
    final currentSheet = ref.watch(sheetsControllerProvider).current;
    final calibration =
        currentSheet == null ? null : project.calibrationFor(currentSheet.id);

    return SizedBox(
      width: width,
      child: ColoredBox(
        color: colors.surface,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(MechXSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SectionLabel('Project'),
              const SizedBox(height: MechXSpacing.sm),
              MechXTextField(
                value: project.name,
                onChanged: ctrl.setName,
              ),
              const SizedBox(height: MechXSpacing.lg),

              // ── Building / floor heights ──────────────────────────────────
              Row(
                children: [
                  Expanded(child: _SectionLabel('Building')),
                  Text(
                    '${building.totalHeight.meters.toStringAsFixed(1)} m · '
                    '${building.levelCount} levels',
                    style: type.caption.copyWith(color: colors.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: MechXSpacing.sm),
              // Top floor first.
              for (var i = project.floors.length - 1; i >= 0; i--)
                _FloorRow(
                  name: project.floors[i].name,
                  height: project.floors[i].height,
                  elevation: building.elevationOf(i),
                  onMinus: () => ctrl.nudgeFloorHeight(i, -0.1),
                  onPlus: () => ctrl.nudgeFloorHeight(i, 0.1),
                  onRemove: project.floors.length > 1
                      ? () => ctrl.removeFloor(i)
                      : null,
                ),
              const SizedBox(height: MechXSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: MechXButton(label: '+  Add level', onPressed: ctrl.addFloor),
              ),
              const SizedBox(height: MechXSpacing.lg),

              // ── Scale calibration ─────────────────────────────────────────
              _SectionLabel('Scale'),
              const SizedBox(height: MechXSpacing.sm),
              Container(
                padding: const EdgeInsets.all(MechXSpacing.sm),
                decoration: BoxDecoration(
                  color: colors.background,
                  borderRadius: MechXRadii.control,
                  border: Border.all(color: colors.border),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.only(right: MechXSpacing.sm),
                      decoration: BoxDecoration(
                        color: calibration == null
                            ? colors.warning
                            : colors.success,
                        borderRadius: const BorderRadius.all(Radius.circular(4)),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        calibration == null
                            ? 'Not calibrated — calibrate after PDF import'
                            : '1 px = ${calibration.metersPerPixel.toStringAsExponential(2)} m',
                        style: type.caption.copyWith(color: colors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: context.type.caption.copyWith(
          color: context.colors.textMuted,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      );
}

class _FloorRow extends StatelessWidget {
  final String name;
  final Length height;
  final Length elevation;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback? onRemove;

  const _FloorRow({
    required this.name,
    required this.height,
    required this.elevation,
    required this.onMinus,
    required this.onPlus,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.body.copyWith(color: colors.textPrimary)),
                Text('elev ${elevation.meters.toStringAsFixed(1)} m',
                    style: type.caption.copyWith(color: colors.textMuted)),
              ],
            ),
          ),
          _GlyphButton(glyph: '−', onTap: onMinus),
          SizedBox(
            width: 56,
            child: Text(
              '${height.meters.toStringAsFixed(1)} m',
              textAlign: TextAlign.center,
              style: type.mono.copyWith(color: colors.textPrimary),
            ),
          ),
          _GlyphButton(glyph: '+', onTap: onPlus),
          const SizedBox(width: MechXSpacing.xs),
          _GlyphButton(
            glyph: '×',
            onTap: onRemove,
            danger: true,
          ),
        ],
      ),
    );
  }
}

class _GlyphButton extends StatefulWidget {
  final String glyph;
  final VoidCallback? onTap;
  final bool danger;
  const _GlyphButton({required this.glyph, required this.onTap, this.danger = false});

  @override
  State<_GlyphButton> createState() => _GlyphButtonState();
}

class _GlyphButtonState extends State<_GlyphButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = widget.onTap != null;
    final fg = !enabled
        ? colors.textMuted.withAlpha(90)
        : widget.danger
            ? (_hover ? colors.danger : colors.textMuted)
            : (_hover ? colors.textPrimary : colors.textSecondary);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hover && enabled ? colors.surfaceHover : const Color(0x00000000),
            borderRadius: MechXRadii.control,
          ),
          child: Text(
            widget.glyph,
            style: TextStyle(fontSize: 16, height: 1.0, color: fg),
          ),
        ),
      ),
    );
  }
}
