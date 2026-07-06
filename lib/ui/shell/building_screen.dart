import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/units.dart';

import '../../store/models/sheet.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../sheets/pdf_page_picker.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/hub_scaffold.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_focus_ring.dart';
import '../widgets/mechx_text_field.dart';
import '../widgets/stepped_value_field.dart';

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
    final sheetsState = ref.watch(sheetsControllerProvider);

    // The sheet (PDF page) assigned to each level — the first sheet whose
    // floor mapping lands on it (a floor may carry more than one sheet).
    Sheet? sheetForFloor(int level) {
      for (final s in sheetsState.sheets) {
        if (sheetsState.floorFor(s.id, building.levelCount) == level) return s;
      }
      return null;
    }

    return HubScaffold(
      title: 'Building',
      lead: 'Floor-to-floor heights are the single source of truth for every '
          'riser length (vertical run). Rename a level, set its height, assign '
          'its PDF page, or add and remove levels.',
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
            sheet: sheetForFloor(i),
            onRename: (name) => ctrl.renameFloor(i, name),
            onHeightMinus: () => ctrl.nudgeFloorHeight(i, -0.1),
            onHeightPlus: () => ctrl.nudgeFloorHeight(i, 0.1),
            onHeightSet: (m) => ctrl.setFloorHeight(i, Length(m)),
            onPickSheet: sheetsState.sheets.isEmpty
                ? null
                : () => _pickSheetForFloor(context, ref, i),
            onRemove: project.floors.length > 1
                ? () => ctrl.removeFloor(i)
                : null,
          ),
          const SizedBox(height: MechXSpacing.sm),
        ],
        const SizedBox(height: MechXSpacing.xs),
        Row(
          children: [
            MechXButton(label: '+  Add level', onPressed: ctrl.addFloor),
            const SizedBox(width: MechXSpacing.sm),
            // Bulk add — a whole tower of identical typical floors in one undo
            // step (D4) via a single setFloors call.
            Expanded(
              child: _AddLevelsRow(
                onAdd: (count, heightM) {
                  final base = project.floors.length;
                  ctrl.setFloors([
                    ...project.floors,
                    for (var k = 0; k < count; k++)
                      Floor('Level ${base + k}', Length(heightM)),
                  ]);
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Open the sheet picker for [floorIndex] and assign the chosen PDF page to
  /// this level (mapping it via the sheets store).
  Future<void> _pickSheetForFloor(
      BuildContext context, WidgetRef ref, int floorIndex) async {
    final sheets = ref.read(sheetsControllerProvider).sheets;
    final id = await showSheetPicker(context, sheets);
    if (id == null) return;
    ref.read(sheetsControllerProvider.notifier).setSheetFloor(id, floorIndex);
  }
}

/// One level's editable card: name, elevation, and floor-to-floor height.
class _LevelCard extends StatelessWidget {
  final Floor floor;
  final Length elevation;
  final Sheet? sheet;
  final ValueChanged<String> onRename;
  final VoidCallback onHeightMinus;
  final VoidCallback onHeightPlus;
  final ValueChanged<double> onHeightSet;
  final VoidCallback? onPickSheet;
  final VoidCallback? onRemove;

  const _LevelCard({
    required this.floor,
    required this.elevation,
    required this.sheet,
    required this.onRename,
    required this.onHeightMinus,
    required this.onHeightPlus,
    required this.onHeightSet,
    required this.onPickSheet,
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
          // Floor-to-floor height — the §10 source of truth for riser length.
          // A shared type-in stepper (D4): click the value to type, or ±0.1 m
          // with hold-repeat; commit via setFloorHeight.
          Row(
            children: [
              Expanded(
                child: Text('Floor-to-floor height',
                    style: type.body.copyWith(color: colors.textSecondary)),
              ),
              SteppedValueField(
                display: '${floor.height.meters.toStringAsFixed(1)} m',
                editSeed: floor.height.meters.toStringAsFixed(1),
                label: context.strings(StringKey.a11yFieldFloorToFloorHeight),
                gap: MechXSpacing.sm,
                valueWidth: 84,
                valueAlign: TextAlign.center,
                valueColor: colors.textPrimary,
                min: 0.5,
                max: 20.0,
                onDecrement: onHeightMinus,
                onIncrement: onHeightPlus,
                onSubmit: (v) {
                  if (v != null) onHeightSet(v);
                },
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.xs),
          // The PDF page assigned to this level.
          Row(
            children: [
              Expanded(
                child: Text('Floor plan',
                    style: type.body.copyWith(color: colors.textSecondary)),
              ),
              Flexible(
                child: Text(
                  sheet?.name ?? 'none',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: type.caption.copyWith(
                      color: sheet == null
                          ? colors.textMuted
                          : colors.textSecondary),
                ),
              ),
              const SizedBox(width: MechXSpacing.sm),
              MechXButton(
                label: sheet == null ? 'Assign' : 'Change',
                onPressed: onPickSheet,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Bulk-add row (D4): "Add N levels @ H m" — a whole tower of identical typical
/// floors added on top in ONE undo step (a single `setFloors` call). N and H are
/// shared type-in steppers; the button appends N floors at height H.
class _AddLevelsRow extends StatefulWidget {
  final void Function(int count, double heightM) onAdd;
  const _AddLevelsRow({required this.onAdd});

  @override
  State<_AddLevelsRow> createState() => _AddLevelsRowState();
}

class _AddLevelsRowState extends State<_AddLevelsRow> {
  int _count = 1;
  double _height = 3.5;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    Text label(String s) =>
        Text(s, style: type.body.copyWith(color: colors.textSecondary));
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.md, vertical: MechXSpacing.sm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: MechXSpacing.sm,
        runSpacing: MechXSpacing.xs,
        children: [
          SteppedValueField(
            display: '$_count',
            editSeed: '$_count',
            label: context.strings(StringKey.a11yFieldNumberOfLevels),
            gap: MechXSpacing.xs,
            min: 1,
            max: 50,
            onDecrement: () =>
                setState(() => _count = (_count - 1).clamp(1, 50)),
            onIncrement: () =>
                setState(() => _count = (_count + 1).clamp(1, 50)),
            onSubmit: (v) => setState(
                () => _count = v == null ? _count : v.round().clamp(1, 50)),
          ),
          label('levels @'),
          SteppedValueField(
            display: '${_height.toStringAsFixed(1)} m',
            editSeed: _height.toStringAsFixed(1),
            label: context.strings(StringKey.a11yFieldFloorHeight),
            gap: MechXSpacing.xs,
            min: 0.5,
            max: 20.0,
            onDecrement: () => setState(
                () => _height = (_height - 0.5).clamp(0.5, 20.0)),
            onIncrement: () => setState(
                () => _height = (_height + 0.5).clamp(0.5, 20.0)),
            onSubmit: (v) => setState(
                () => _height = v == null ? _height : v.clamp(0.5, 20.0)),
          ),
          MechXButton(
            label: 'Add levels',
            onPressed: () => widget.onAdd(_count, _height),
          ),
        ],
      ),
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
