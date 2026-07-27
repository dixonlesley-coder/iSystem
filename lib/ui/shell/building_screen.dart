import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/standards/sni.dart' show Occupancy;
import 'package:mechx_engine/units.dart';

import '../../store/app_state.dart'
    show occupancyProvider, rainfallIntensityProvider, runoffCoefficientProvider;
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
import '../widgets/mechx_segment.dart';
import '../widgets/mechx_text_field.dart';
import '../widgets/section_label.dart';
import '../widgets/stepped_value_field.dart';

/// The minimum tappable square for this page's glyph-only controls (B2). The
/// GLYPH keeps its compact size; only the hit region grows, so aiming at a
/// 26 px `×` in a dense list stops being a test of mouse precision.
const double _kGlyphHitTarget = 40;

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
        // The cards sit on a tight `xs` gap: each carries its own border, so
        // they still read as separate levels, and the stack reads as ONE list
        // (the `lg` gaps below still separate the page's groups).
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
          const SizedBox(height: MechXSpacing.xs),
        ],
        const SizedBox(height: MechXSpacing.xs),
        // ONE add control (the old standalone "+ Add level" was redundant with
        // the count=1 case here): add N identical levels either ON TOP or as
        // BASEMENTS below ground, each in one undo step.
        _AddLevelsRow(
          onAddOnTop: ctrl.addFloorsOnTop,
          onAddBasement: ctrl.addBasement,
        ),

        // Project design inputs (occupancy / storm rainfall + runoff) — the
        // building-wide sizing parameters. They live here on the setup page
        // rather than in the per-selection canvas inspector.
        const SizedBox(height: MechXSpacing.lg),
        const MechXSectionLabel('Design inputs'),
        const SizedBox(height: MechXSpacing.sm),
        const _DesignInputsCard(),
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
              // B3: the elevation restates itself every time a height below it
              // changes — tabular figures keep the row from shuffling.
              Text('elev ${elevation.meters.toStringAsFixed(1)} m',
                  style: MechXTypography.tabular(type.caption)
                      .copyWith(color: colors.textMuted)),
              const SizedBox(width: MechXSpacing.xxs),
              _GlyphButton(glyph: '×', onTap: onRemove, danger: true),
            ],
          ),
          // `xxs`, not `sm`: the header row is taller now that the remove
          // control carries a full-size hit target (B2), so the optical gap
          // below it reads the same at a smaller value — and the card (and
          // with it the whole page) keeps its height.
          const SizedBox(height: MechXSpacing.xxs),
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

/// The consolidated add-levels control: add N levels of height H, either **on
/// top** (typical floors) or as **basements** below ground — each a whole tower
/// of identical floors in ONE undo step. N and H are shared type-in steppers;
/// the two buttons choose the direction. (This subsumes the old standalone
/// single "+ Add level", which was just the count=1 case.)
///
/// B1: it reads as a small FORM — two labelled fields, then the two actions —
/// rather than the old one-line math expression ("− 1 + levels @ − 3.5 m +
/// [Add on top] [Add basement]") that ran the controls together. Same intents,
/// same values, same one-undo behaviour.
class _AddLevelsRow extends StatefulWidget {
  final void Function(int count, double heightM) onAddOnTop;
  final void Function(int count, double heightM) onAddBasement;
  const _AddLevelsRow(
      {required this.onAddOnTop, required this.onAddBasement});

  @override
  State<_AddLevelsRow> createState() => _AddLevelsRowState();
}

class _AddLevelsRowState extends State<_AddLevelsRow> {
  int _count = 1;
  double _height = 3.5;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.md, vertical: MechXSpacing.sm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      // The two named inputs, then — after a gap that separates inputs from
      // actions — the two direction buttons, sitting on the same baseline as
      // the steppers they act on. Kept to ONE run at every supported window
      // width: a second run would push the actions under the status bar on a
      // three-level project.
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: MechXSpacing.lg,
        runSpacing: MechXSpacing.sm,
        children: [
          _StepperField(
            label: 'Levels',
            child: SteppedValueField(
              display: '$_count',
              editSeed: '$_count',
              label: context.strings(StringKey.a11yFieldNumberOfLevels),
              gap: MechXSpacing.xs,
              valueWidth: 32,
              valueAlign: TextAlign.center,
              valueColor: colors.textPrimary,
              min: 1,
              max: 50,
              onDecrement: () =>
                  setState(() => _count = (_count - 1).clamp(1, 50)),
              onIncrement: () =>
                  setState(() => _count = (_count + 1).clamp(1, 50)),
              onSubmit: (v) => setState(
                  () => _count = v == null ? _count : v.round().clamp(1, 50)),
            ),
          ),
          _StepperField(
            label: 'Height',
            child: SteppedValueField(
              display: '${_height.toStringAsFixed(1)} m',
              editSeed: _height.toStringAsFixed(1),
              label: context.strings(StringKey.a11yFieldFloorHeight),
              gap: MechXSpacing.xs,
              valueWidth: 56,
              valueAlign: TextAlign.center,
              valueColor: colors.textPrimary,
              min: 0.5,
              max: 20.0,
              onDecrement: () =>
                  setState(() => _height = (_height - 0.5).clamp(0.5, 20.0)),
              onIncrement: () =>
                  setState(() => _height = (_height + 0.5).clamp(0.5, 20.0)),
              onSubmit: (v) => setState(
                  () => _height = v == null ? _height : v.clamp(0.5, 20.0)),
            ),
          ),
          // The direction the new levels go. Paired in their own Wrap so the
          // two actions always stay together on a narrow page.
          Wrap(
            spacing: MechXSpacing.sm,
            runSpacing: MechXSpacing.xs,
            children: [
              MechXButton(
                label: 'Add on top',
                onPressed: () => widget.onAddOnTop(_count, _height),
              ),
              MechXButton(
                label: 'Add basement',
                onPressed: () => widget.onAddBasement(_count, _height),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A labelled numeric field: a quiet caption naming its stepper, so a form of
/// several steppers reads as named inputs instead of a run of bare numbers
/// joined by operator-ish connective text ("1 levels @ 3.5 m").
class _StepperField extends StatelessWidget {
  final String label;
  final Widget child;
  const _StepperField({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: type.caption.copyWith(color: colors.textMuted)),
        const SizedBox(height: MechXSpacing.xs),
        child,
      ],
    );
  }
}

/// The project design-input card (moved off the canvas inspector): occupancy
/// class (fixture demand), storm rainfall intensity + runoff coefficient (storm
/// sizing). These are building-wide sizing parameters, so they belong on the
/// setup page beside the floor stack rather than in the per-selection inspector.
class _DesignInputsCard extends ConsumerWidget {
  const _DesignInputsCard();

  static String _occupancyLabel(Occupancy o) => switch (o) {
        Occupancy.private => 'Residential',
        Occupancy.public => 'Office / public',
        Occupancy.assembly => 'Assembly / mall',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final occ = ref.watch(occupancyProvider);
    final rain = ref.watch(rainfallIntensityProvider);
    final runoff = ref.watch(runoffCoefficientProvider);
    Text label(String s) =>
        Text(s, style: type.body.copyWith(color: colors.textSecondary));
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
          Text('Occupancy',
              style: type.caption.copyWith(color: colors.textMuted)),
          const SizedBox(height: MechXSpacing.xs),
          Wrap(
            spacing: MechXSpacing.xs,
            runSpacing: MechXSpacing.xs,
            children: [
              for (final o in Occupancy.values)
                MechXSegment(
                  label: _occupancyLabel(o),
                  selected: occ == o,
                  onTap: () => ref.read(occupancyProvider.notifier).set(o),
                ),
            ],
          ),
          const SizedBox(height: MechXSpacing.md),
          Row(
            children: [
              Expanded(child: label('Rainfall (storm)')),
              SteppedValueField(
                display: '${rain.round()} mm/hr',
                editSeed: '${rain.round()}',
                label: 'Rainfall (storm)',
                gap: MechXSpacing.sm,
                valueWidth: 96,
                valueAlign: TextAlign.center,
                valueColor: colors.textPrimary,
                min: 50,
                max: 600,
                onDecrement: () =>
                    ref.read(rainfallIntensityProvider.notifier).nudge(-25),
                onIncrement: () =>
                    ref.read(rainfallIntensityProvider.notifier).nudge(25),
                onSubmit: (v) {
                  if (v != null) {
                    ref.read(rainfallIntensityProvider.notifier).set(v);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.sm),
          Row(
            children: [
              Expanded(child: label('Runoff coefficient')),
              SteppedValueField(
                display: runoff.toStringAsFixed(2),
                editSeed: runoff.toStringAsFixed(2),
                label: 'Runoff coefficient',
                gap: MechXSpacing.sm,
                valueWidth: 96,
                valueAlign: TextAlign.center,
                valueColor: colors.textPrimary,
                min: 0.5,
                max: 1.0,
                onDecrement: () =>
                    ref.read(runoffCoefficientProvider.notifier).nudge(-0.05),
                onIncrement: () =>
                    ref.read(runoffCoefficientProvider.notifier).nudge(0.05),
                onSubmit: (v) {
                  if (v != null) {
                    ref.read(runoffCoefficientProvider.notifier).set(v);
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A compact square ghost button drawing a single glyph (−/+/×). Mirrors the
/// inspector's affordance so the page reads as the same app.
///
/// B2: the GLYPH stays 26 px (the visual is unchanged), but the tappable region
/// is a [_kGlyphHitTarget]-square box around it, so removing a level no longer
/// demands pixel-accurate aim. The hit box is laid out as an ordinary row
/// child, so it can never overlap a neighbouring control's own hit area.
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
      duration: MechXMotion.resolve(context, MechXMotion.press),
      curve: MechXMotion.standard,
      child: AnimatedContainer(
        duration: MechXMotion.resolve(context, MechXMotion.hover),
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
      child: GestureDetector(
        // The enlarged, opaque hit area (B2). The focus RING stays wrapped
        // around the 26 px glyph so it still hugs the visual control.
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: enabled ? () => setState(() => _down = false) : null,
        child: SizedBox(
          width: _kGlyphHitTarget,
          height: _kGlyphHitTarget,
          child: Center(
            child: MechXFocusRing(
              enabled: enabled,
              onActivated: widget.onTap,
              child: glyph,
            ),
          ),
        ),
      ),
    );
  }
}
