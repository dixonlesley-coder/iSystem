import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/units.dart';

import '../../store/project_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/hub_scaffold.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_focus_ring.dart';
import '../widgets/mechx_text_field.dart';

/// The dedicated **Building** page — the floor/level model on its own screen
/// (lifted out of the right inspector so the canvas isn't crowded). Each level
/// shows its true elevation and lets you rename it and set its floor-to-floor
/// height; add / remove levels here too. (The per-fixture/outlet mounting
/// height — "how high on the wall" — is set on each node in the canvas
/// inspector, since it drives that fixture's own vertical run.)
class BuildingScreen extends ConsumerWidget {
  const BuildingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final project = ref.watch(projectControllerProvider);
    final ctrl = ref.read(projectControllerProvider.notifier);
    final building = project.building;

    return HubScaffold(
      title: 'Building',
      lead: 'Floor-to-floor heights are the single source of truth for every '
          'riser length (vertical run). Rename a level, set its height, or add '
          'and remove levels.',
      children: [
        HubStatRow(stats: [
          ('Total height', '${building.totalHeight.meters.toStringAsFixed(1)} m'),
          ('Levels', '${building.levelCount}'),
          ('Roof elevation',
              '${building.roofElevation.meters.toStringAsFixed(1)} m'),
        ]),
        const SizedBox(height: MechXSpacing.lg),
        // Top floor first, matching how a building reads on an elevation.
        for (var i = project.floors.length - 1; i >= 0; i--) ...[
          _LevelCard(
            floor: project.floors[i],
            elevation: building.elevationOf(i),
            onRename: (name) => ctrl.renameFloor(i, name),
            onHeightMinus: () => ctrl.nudgeFloorHeight(i, -0.1),
            onHeightPlus: () => ctrl.nudgeFloorHeight(i, 0.1),
            onRemove: project.floors.length > 1
                ? () => ctrl.removeFloor(i)
                : null,
          ),
          const SizedBox(height: MechXSpacing.sm),
        ],
        const SizedBox(height: MechXSpacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: MechXButton(label: '+  Add level', onPressed: ctrl.addFloor),
        ),
      ],
    );
  }
}

/// One level's editable card: name, elevation, and floor-to-floor height.
class _LevelCard extends StatelessWidget {
  final Floor floor;
  final Length elevation;
  final ValueChanged<String> onRename;
  final VoidCallback onHeightMinus;
  final VoidCallback onHeightPlus;
  final VoidCallback? onRemove;

  const _LevelCard({
    required this.floor,
    required this.elevation,
    required this.onRename,
    required this.onHeightMinus,
    required this.onHeightPlus,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(MechXSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: MechXTextField(
                  value: floor.name,
                  onChanged: onRename,
                ),
              ),
              const SizedBox(width: MechXSpacing.sm),
              Text('elev ${elevation.meters.toStringAsFixed(1)} m',
                  style: type.caption.copyWith(color: colors.textMuted)),
              const SizedBox(width: MechXSpacing.xs),
              _GlyphButton(glyph: '×', onTap: onRemove, danger: true),
            ],
          ),
          const SizedBox(height: MechXSpacing.sm),
          _StepperRow(
            label: 'Floor-to-floor height',
            value: '${floor.height.meters.toStringAsFixed(1)} m',
            onMinus: onHeightMinus,
            onPlus: onHeightPlus,
          ),
        ],
      ),
    );
  }
}

/// A labelled −/value/+ stepper row.
class _StepperRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  const _StepperRow({
    required this.label,
    required this.value,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: type.body.copyWith(color: colors.textSecondary)),
        ),
        _GlyphButton(glyph: '−', onTap: onMinus),
        SizedBox(
          width: 84,
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: type.mono.copyWith(color: colors.textPrimary),
          ),
        ),
        _GlyphButton(glyph: '+', onTap: onPlus),
      ],
    );
  }
}

/// A compact square ghost button drawing a single glyph (−/+/×). Mirrors the
/// inspector's affordance so the page reads as the same app.
class _GlyphButton extends StatefulWidget {
  final String glyph;
  final VoidCallback? onTap;
  final bool danger;
  const _GlyphButton(
      {required this.glyph, required this.onTap, this.danger = false});

  @override
  State<_GlyphButton> createState() => _GlyphButtonState();
}

class _GlyphButtonState extends State<_GlyphButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = widget.onTap != null;
    final fg = !enabled
        ? colors.textMuted.withAlpha(90)
        : widget.danger
            ? (_hover ? colors.danger : colors.textMuted)
            : (_hover ? colors.textPrimary : colors.textSecondary);
    final glyph = AnimatedScale(
      scale: _down && enabled ? 0.9 : 1.0,
      duration: MechXMotion.press,
      curve: MechXMotion.standard,
      child: AnimatedContainer(
        duration: MechXMotion.hover,
        curve: MechXMotion.standard,
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              _hover && enabled ? colors.surfaceHover : const Color(0x00000000),
          borderRadius: MechXRadii.control,
        ),
        child: Text(
          widget.glyph,
          style: TextStyle(
              fontFamily: 'Roboto', fontSize: 16, height: 1.0, color: fg),
        ),
      ),
    );
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: MechXFocusRing(
        enabled: enabled,
        onActivated: widget.onTap,
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTapCancel: enabled ? () => setState(() => _down = false) : null,
          child: glyph,
        ),
      ),
    );
  }
}
