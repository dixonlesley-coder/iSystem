import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/standards/sni.dart' show Occupancy;
import 'package:mechx_engine/units.dart';
import 'package:mechx_engine/report/number_format.dart' show signedElevationText;

import '../../store/app_state.dart'
    show
        CoolingLoadMethod,
        coolingLoadMethodProvider,
        drainageSlopeProvider,
        FeedStrategy,
        feedStrategyProvider,
        hotWaterDeltaTProvider,
        hotWaterFlowTempProvider,
        occupancyProvider,
        rainfallIntensityProvider,
        runoffCoefficientProvider,
        statusMessageProvider;
import '../../store/floor_remap.dart'
    show FloorPlacedWorkCount, floorPlacedWorkCount;
import '../../store/history_store.dart';
import '../../store/models/sheet.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../sheets/pdf_page_picker.dart';
import '../strings/app_strings.dart';
import '../strings/occupancy_label.dart';
import '../strings/plural.dart';
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

    // F10 — EVERY sheet (PDF page) mapped to a level, not just the first.
    // A floor may carry several plans (architectural + M&E, or a re-issue), and
    // showing only the first hid exactly the pile-up this page exists to fix:
    // one level silently holding four plans while the levels above hold none.
    List<Sheet> sheetsForFloor(int level) => [
          for (final s in sheetsState.sheets)
            if (sheetsState.floorFor(s.id, building.levelCount) == level) s,
        ];

    return HubScaffold(
      title: 'Building',
      lead: 'Floor-to-floor heights are the single source of truth for every '
          'riser length (vertical run). Rename a level, set its height, assign '
          'its PDF page, or add and remove levels.',
      children: [
        HubStatRow(stats: [
          ('Total height', '${trimmedMetres(building.totalHeight.meters)} m'),
          ('Levels', '${building.levelCount}'),
          // Round 31 (ui-simplicity-4) — without basements the roof elevation
          // IS the total height (ground datum 0.0), so it is shown only when
          // basements make the two differ.
          if (building.groundIndex > 0)
            ('Roof elevation',
                '${signedElevationText(building.roofElevation.meters)} m'),
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
            sheets: sheetsForFloor(i),
            onRename: (name) => ctrl.renameFloor(i, name),
            onHeightMinus: () => ctrl.nudgeFloorHeight(i, -0.1),
            onHeightPlus: () => ctrl.nudgeFloorHeight(i, 0.1),
            onHeightSet: (m) => ctrl.setFloorHeight(i, Length(m)),
            onPickSheet: sheetsState.sheets.isEmpty
                ? null
                : () => _pickSheetForFloor(context, ref, i),
            onRemove: project.floors.length > 1
                ? () => _removeLevel(context, ref, i)
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

  /// C2 — remove the level at [index], CONFIRMING first when it carries drawn
  /// work. Deleting a floor deletes the runs, risers and equipment drawn on it
  /// (they have no physical floor left to sit on), so a level that carries any
  /// must say how much before it goes. A level with nothing drawn on it is
  /// removed straight away — there is nothing to lose and nothing to ask.
  ///
  /// The whole edit (floor stack + the deleted drawing) is ONE structural undo
  /// step, so Ctrl+Z brings both back together.
  Future<void> _removeLevel(
      BuildContext context, WidgetRef ref, int index) async {
    final count =
        ref.read(networkControllerProvider.notifier).elementsOnFloor(index);
    // Round 13 (ui-journey-2) — the level's rooms, tanks, measurements and
    // electrical placements go with it too (floor_remap), so they count: a
    // floor carrying only a room used to vanish with no dialog at all.
    final placed = floorPlacedWorkCount(ref.read, (fi) => fi == index);
    if (count > 0 || !placed.isEmpty) {
      final level = ref.read(projectControllerProvider).floors[index].name;
      final ok = await showDeleteLevelDialog(context,
          level: level, count: count, placed: placed);
      if (ok != true) return;
    }
    ref.read(projectControllerProvider.notifier).removeFloor(index);
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

/// C2 — the destructive-delete guard for a level that carries drawn work.
/// Resolves true when the engineer confirms, false / null on Cancel, a scrim tap
/// or Esc. Same MechXTheme `showGeneralDialog` idiom as the unsaved-changes
/// guard (no Material). Public so a widget test can drive it directly.
Future<bool?> showDeleteLevelDialog(
  BuildContext context, {
  required String level,
  required int count,
  FloorPlacedWorkCount placed = const FloorPlacedWorkCount(),
}) {
  final theme = MechXTheme.of(context);
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Delete level',
    barrierColor: theme.colors.scrim,
    transitionDuration: MechXMotion.appear,
    pageBuilder: (ctx, _, _) => MechXTheme(
      data: theme,
      child: Center(
          child:
              _DeleteLevelDialog(level: level, count: count, placed: placed)),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: MechXMotion.standard,
        reverseCurve: MechXMotion.standard,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _DeleteLevelDialog extends StatelessWidget {
  final String level;
  final int count;
  final FloorPlacedWorkCount placed;
  const _DeleteLevelDialog(
      {required this.level, required this.count, required this.placed});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final strings = MechXStrings.of(context);
    // The count reads as a real phrase ("47 drawn elements" / "1 drawn
    // element"), never the dev-speak "element(s)".
    // Round 13 — every KIND that goes is named with its own count
    // ('3 drawn elements, 1 room, 2 tanks'), never just the network.
    String phrase(int n, StringKey one, StringKey many) =>
        '$n ${plural(n, strings(one), strings(many))}';
    final parts = <String>[
      if (count > 0)
        phrase(count, StringKey.buildingDrawnElementOne,
            StringKey.buildingDrawnElementMany),
      if (placed.rooms > 0)
        phrase(placed.rooms, StringKey.buildingRoomOne,
            StringKey.buildingRoomMany),
      if (placed.tanks > 0)
        phrase(placed.tanks, StringKey.buildingTankOne,
            StringKey.buildingTankMany),
      if (placed.measurements > 0)
        phrase(placed.measurements, StringKey.buildingMeasurementOne,
            StringKey.buildingMeasurementMany),
    ];
    final what = parts.join(', ');
    return Container(
      width: 420,
      padding: const EdgeInsets.all(MechXSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        boxShadow: MechXShadow.popover,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            strings.format(StringKey.buildingDeleteLevelTitle, {'level': level}),
            style: type.title.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: MechXSpacing.xs),
          if (what.isNotEmpty)
            Text(
              strings.format(
                  StringKey.buildingDeleteLevelBody, {'level': level, 'count': what}),
              style: type.caption.copyWith(color: colors.textMuted),
            ),
          if (placed.electrical > 0) ...[
            const SizedBox(height: MechXSpacing.xxs),
            Text(
              strings.format(StringKey.buildingDeleteLevelElectrical,
                  {'count': '${placed.electrical}'}),
              style: type.caption.copyWith(color: colors.textMuted),
            ),
          ],
          const SizedBox(height: MechXSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              MechXButton(
                label: strings(StringKey.buildingDeleteLevelCancel),
                tertiary: true,
                onPressed: () => Navigator.of(context).pop(false),
              ),
              const SizedBox(width: MechXSpacing.sm),
              MechXButton(
                label: strings(StringKey.buildingDeleteLevelConfirm),
                primary: true,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One level's editable card: name, elevation, and floor-to-floor height.
class _LevelCard extends StatelessWidget {
  final Floor floor;
  final Length elevation;

  /// F10 — every plan mapped to this level (empty ⇒ "none"). More than one is
  /// normal and worth SEEING: the count leads, the names follow.
  final List<Sheet> sheets;
  final ValueChanged<String> onRename;
  final VoidCallback onHeightMinus;
  final VoidCallback onHeightPlus;
  final ValueChanged<double> onHeightSet;
  final VoidCallback? onPickSheet;
  final VoidCallback? onRemove;

  const _LevelCard({
    required this.floor,
    required this.elevation,
    required this.sheets,
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
                  // D1: commit on blur / Enter, so renaming a level is ONE undo
                  // step instead of one per keystroke (which evicted real edits
                  // from the 200-entry stack).
                  onCommitted: onRename,
                ),
              ),
              const SizedBox(width: MechXSpacing.sm),
              // B3: the elevation restates itself every time a height below it
              // changes — tabular figures keep the row from shuffling.
              // Round 25 — 2 dp through the SAME formatter the riser / FFL
              // labels use, so a 3.25 m storey never reads 'elev 7.3 m' here
              // beside 'FFL +7.25' on the drawings.
              Text('elev ${signedElevationText(elevation.meters)} m',
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
                // Round 25 — 2 dp (trailing zero trimmed): a typed 3.25 m
                // reads and re-seeds as 3.25, never a rounded '3.3' that a
                // re-commit would silently store.
                display: '${trimmedMetres(floor.height.meters)} m',
                editSeed: trimmedMetres(floor.height.meters),
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
          // The PDF page(s) assigned to this level (F10: the COUNT, then the
          // names — a level holding three plans says so).
          Row(
            children: [
              Expanded(
                child: Text('Floor plan',
                    style: type.body.copyWith(color: colors.textSecondary)),
              ),
              Flexible(
                child: Text(
                  sheets.isEmpty
                      ? context.strings(StringKey.buildingNoPlan)
                      : pluralCount(
                          sheets.length,
                          context.strings(StringKey.buildingPlanOne),
                          context.strings(StringKey.buildingPlanMany)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: MechXTypography.tabular(type.caption).copyWith(
                      color: sheets.isEmpty
                          ? colors.textMuted
                          : colors.textSecondary),
                ),
              ),
              const SizedBox(width: MechXSpacing.sm),
              MechXButton(
                label: sheets.isEmpty ? 'Assign' : 'Change',
                onPressed: onPickSheet,
              ),
            ],
          ),
          // The names themselves, under the count — so the pile-up is visible
          // (and identifiable) without leaving the page. One line per plan; a
          // long sheet name ellipsizes rather than wrapping the card.
          if (sheets.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: MechXSpacing.xxs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final s in sheets)
                    Text(s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style:
                            type.micro.copyWith(color: colors.textMuted)),
                ],
              ),
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
              display: '${trimmedMetres(_height)} m',
              editSeed: trimmedMetres(_height),
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
class _DesignInputsCard extends ConsumerStatefulWidget {
  const _DesignInputsCard();

  @override
  ConsumerState<_DesignInputsCard> createState() => _DesignInputsCardState();
}

class _DesignInputsCardState extends ConsumerState<_DesignInputsCard> {
  /// G7 — one confirmation per burst of edits. A stepper's hold-repeat fires
  /// many commits a second, so the "Sizing updated" pill is DEBOUNCED: it
  /// appears once the engineer stops moving the value, not once per tick.
  Timer? _confirmTimer;
  static const Duration _confirmDelay = Duration(milliseconds: 450);

  @override
  void dispose() {
    _confirmTimer?.cancel();
    super.dispose();
  }

  /// G7 — nothing on this page said the change LANDED: every design input here
  /// silently re-runs the whole sizing, on another screen, with no feedback at
  /// all. Confirm it in the status bar, once the value settles.
  void _confirmSizingUpdated() {
    _confirmTimer?.cancel();
    _confirmTimer = Timer(_confirmDelay, () {
      if (!mounted) return;
      ref
          .read(statusMessageProvider.notifier)
          .showStatus(context.strings(StringKey.buildingSizingUpdated));
    });
  }


  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final feed = ref.watch(feedStrategyProvider);
    final occ = ref.watch(occupancyProvider);
    final rain = ref.watch(rainfallIntensityProvider);
    final runoff = ref.watch(runoffCoefficientProvider);
    final slope = ref.watch(drainageSlopeProvider);
    final hwFlow = ref.watch(hotWaterFlowTempProvider);
    final hwDeltaT = ref.watch(hotWaterDeltaTProvider);
    final acBasis = ref.watch(coolingLoadMethodProvider);
    // F8 — the project's mounting heights, edited here beside the floor stack
    // they act on (a ceiling drop only means anything against a floor height).
    final mounting = ref.watch(mountingProvider);
    final projectCtrl = ref.read(projectControllerProvider.notifier);
    Text label(String s) =>
        Text(s, style: type.body.copyWith(color: colors.textSecondary));
    // G7 — a one-line EFFECT caption under each input. These numbers silently
    // re-run the whole sizing; the page used to state none of that, so the
    // engineer could only learn what a field did by changing it and hunting for
    // what moved.
    Widget caption(String s) => Padding(
          padding: const EdgeInsets.only(
              top: MechXSpacing.xxs, right: MechXSpacing.xxl),
          child: Text(s,
              style: type.micro.copyWith(color: colors.textMuted)),
        );
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
          // 2026-10-17 — the water FEED STRATEGY is a building-wide design
          // input: it decides the whole water solve, so it lives here (the
          // inspectors only report it). `setFeedStrategyUndoable` records the
          // undo step + narrates the change (D3 toast).
          Text(context.strings(StringKey.buildingWaterSupply),
              style: type.caption.copyWith(color: colors.textMuted)),
          const SizedBox(height: MechXSpacing.xs),
          Wrap(
            spacing: MechXSpacing.xs,
            runSpacing: MechXSpacing.xs,
            children: [
              MechXSegment(
                label: context.strings(StringKey.feedUpfeedPump),
                selected: feed == FeedStrategy.upfeed,
                onTap: () =>
                    setFeedStrategyUndoable(ref.read, FeedStrategy.upfeed),
              ),
              MechXSegment(
                label: context.strings(StringKey.feedRoofTankDownfeed),
                selected: feed == FeedStrategy.downfeed,
                onTap: () =>
                    setFeedStrategyUndoable(ref.read, FeedStrategy.downfeed),
              ),
            ],
          ),
          caption(context.strings(StringKey.buildingInputCaptionFeed)),
          const SizedBox(height: MechXSpacing.md),
          Text('Occupancy',
              style: type.caption.copyWith(color: colors.textMuted)),
          const SizedBox(height: MechXSpacing.xs),
          Wrap(
            spacing: MechXSpacing.xs,
            runSpacing: MechXSpacing.xs,
            children: [
              for (final o in Occupancy.values)
                MechXSegment(
                  label: context.strings(occupancyLabelKey(o)),
                  selected: occ == o,
                  onTap: () {
                    setOccupancyUndoable(ref.read, o);
                    _confirmSizingUpdated();
                  },
                ),
            ],
          ),
          caption(context.strings(StringKey.buildingInputCaptionOccupancy)),
          // F8 — the two mounting heights. They turn a floor + role into a TRUE
          // elevation (§10), so they set every riser length and static lift in
          // the project; they were hard-coded engine constants with no UI at
          // all, documented as "editable per project".
          const SizedBox(height: MechXSpacing.md),
          Row(
            children: [
              Expanded(
                  child: label(
                      context.strings(StringKey.buildingMountingCeilingDrop))),
              SteppedValueField(
                display: '${mounting.ceilingDrop.meters.toStringAsFixed(2)} m',
                editSeed: mounting.ceilingDrop.meters.toStringAsFixed(2),
                label: context.strings(StringKey.buildingMountingCeilingDrop),
                gap: MechXSpacing.sm,
                valueWidth: 96,
                valueAlign: TextAlign.center,
                valueColor: colors.textPrimary,
                min: 0.0,
                max: 1.5,
                onDecrement: () {
                  projectCtrl
                      .setCeilingDrop(mounting.ceilingDrop.meters - 0.05);
                  _confirmSizingUpdated();
                },
                onIncrement: () {
                  projectCtrl
                      .setCeilingDrop(mounting.ceilingDrop.meters + 0.05);
                  _confirmSizingUpdated();
                },
                onSubmit: (v) {
                  if (v != null) {
                    projectCtrl.setCeilingDrop(v);
                    _confirmSizingUpdated();
                  }
                },
              ),
            ],
          ),
          caption(context
              .strings(StringKey.buildingMountingCeilingDropCaption)),
          const SizedBox(height: MechXSpacing.sm),
          Row(
            children: [
              Expanded(
                  child: label(context
                      .strings(StringKey.buildingMountingFixtureHeight))),
              SteppedValueField(
                display: '${mounting.fixtureHeight.meters.toStringAsFixed(2)} m',
                editSeed: mounting.fixtureHeight.meters.toStringAsFixed(2),
                label: context.strings(StringKey.buildingMountingFixtureHeight),
                gap: MechXSpacing.sm,
                valueWidth: 96,
                valueAlign: TextAlign.center,
                valueColor: colors.textPrimary,
                min: 0.0,
                max: 2.5,
                onDecrement: () {
                  projectCtrl
                      .setFixtureHeight(mounting.fixtureHeight.meters - 0.05);
                  _confirmSizingUpdated();
                },
                onIncrement: () {
                  projectCtrl
                      .setFixtureHeight(mounting.fixtureHeight.meters + 0.05);
                  _confirmSizingUpdated();
                },
                onSubmit: (v) {
                  if (v != null) {
                    projectCtrl.setFixtureHeight(v);
                    _confirmSizingUpdated();
                  }
                },
              ),
            ],
          ),
          caption(context
              .strings(StringKey.buildingMountingFixtureHeightCaption)),
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
                onDecrement: () {
                  setRainfallUndoable(ref.read, ref.read(rainfallIntensityProvider) - 25);
                  _confirmSizingUpdated();
                },
                onIncrement: () {
                  setRainfallUndoable(ref.read, ref.read(rainfallIntensityProvider) + 25);
                  _confirmSizingUpdated();
                },
                onSubmit: (v) {
                  if (v != null) {
                    setRainfallUndoable(ref.read, v);
                    _confirmSizingUpdated();
                  }
                },
              ),
            ],
          ),
          caption(context.strings(StringKey.buildingInputCaptionRainfall)),
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
                onDecrement: () {
                  setRunoffCoefficientUndoable(ref.read, ref.read(runoffCoefficientProvider) - 0.05);
                  _confirmSizingUpdated();
                },
                onIncrement: () {
                  setRunoffCoefficientUndoable(ref.read, ref.read(runoffCoefficientProvider) + 0.05);
                  _confirmSizingUpdated();
                },
                onSubmit: (v) {
                  if (v != null) {
                    setRunoffCoefficientUndoable(ref.read, v);
                    _confirmSizingUpdated();
                  }
                },
              ),
            ],
          ),
          caption(context.strings(StringKey.buildingInputCaptionRunoff)),
          // M13 — the laid drainage gradient. Typed and displayed as the
          // drafting fraction (1:100), which is how a plumber reads a fall;
          // stored as m/m. Steps of 10 in N (1:100 → 1:90 → 1:80).
          const SizedBox(height: MechXSpacing.sm),
          Row(
            children: [
              Expanded(child: label(context.strings(StringKey.designInputDrainageSlope))),
              SteppedValueField(
                display: _slopeDisplay(slope),
                editSeed: _slopeN(slope).toStringAsFixed(0),
                label: context.strings(StringKey.designInputDrainageSlope),
                gap: MechXSpacing.sm,
                valueWidth: 96,
                valueAlign: TextAlign.center,
                valueColor: colors.textPrimary,
                min: 10,
                max: 1000,
                // A BIGGER N is a FLATTER fall, so "+" steepens (smaller N).
                onDecrement: () {
                  setDrainageSlopeUndoable(ref.read, _slopeFromN(_slopeN(slope) + 10));
                  _confirmSizingUpdated();
                },
                onIncrement: () {
                  setDrainageSlopeUndoable(ref.read, _slopeFromN(_slopeN(slope) - 10));
                  _confirmSizingUpdated();
                },
                onSubmit: (v) {
                  if (v != null && v > 0) {
                    setDrainageSlopeUndoable(ref.read, _slopeFromN(v));
                    _confirmSizingUpdated();
                  }
                },
              ),
            ],
          ),
          caption(context.strings(StringKey.buildingInputCaptionSlope)),
          // G7 — the stepper reads INVERTED (pressing "+" makes the printed
          // number smaller: 1:100 -> 1:90) because the value shown is the
          // DENOMINATOR of the fall. The semantics are right — "+" really is a
          // steeper pipe — so the fix is to SAY so rather than to swap the
          // buttons and make the arithmetic lie instead.
          caption(context.strings(StringKey.buildingSlopeDirectionHint)),
          // M14 — hot-water flow temperature + allowable loop drop. 60 − 5 = 55
          // is exactly the anti-Legionella floor, so the check only speaks once
          // the engineer departs from these defaults.
          const SizedBox(height: MechXSpacing.sm),
          Row(
            children: [
              Expanded(child: label(context.strings(StringKey.designInputHotWaterFlowTemp))),
              SteppedValueField(
                display: '${hwFlow.round()} C',
                editSeed: '${hwFlow.round()}',
                label: context.strings(StringKey.designInputHotWaterFlowTemp),
                gap: MechXSpacing.sm,
                valueWidth: 96,
                valueAlign: TextAlign.center,
                valueColor: colors.textPrimary,
                min: 40,
                max: 90,
                onDecrement: () {
                  setHotWaterFlowTempUndoable(ref.read, ref.read(hotWaterFlowTempProvider) - 1);
                  _confirmSizingUpdated();
                },
                onIncrement: () {
                  setHotWaterFlowTempUndoable(ref.read, ref.read(hotWaterFlowTempProvider) + 1);
                  _confirmSizingUpdated();
                },
                onSubmit: (v) {
                  if (v != null) {
                    setHotWaterFlowTempUndoable(ref.read, v);
                    _confirmSizingUpdated();
                  }
                },
              ),
            ],
          ),
          caption(context.strings(StringKey.buildingInputCaptionHotWaterFlow)),
          const SizedBox(height: MechXSpacing.sm),
          Row(
            children: [
              Expanded(child: label(context.strings(StringKey.designInputHotWaterDeltaT))),
              SteppedValueField(
                display: '${hwDeltaT.round()} K',
                editSeed: '${hwDeltaT.round()}',
                label: context.strings(StringKey.designInputHotWaterDeltaT),
                gap: MechXSpacing.sm,
                valueWidth: 96,
                valueAlign: TextAlign.center,
                valueColor: colors.textPrimary,
                min: 1,
                max: 20,
                onDecrement: () {
                  setHotWaterDeltaTUndoable(ref.read, ref.read(hotWaterDeltaTProvider) - 1);
                  _confirmSizingUpdated();
                },
                onIncrement: () {
                  setHotWaterDeltaTUndoable(ref.read, ref.read(hotWaterDeltaTProvider) + 1);
                  _confirmSizingUpdated();
                },
                onSubmit: (v) {
                  if (v != null) {
                    setHotWaterDeltaTUndoable(ref.read, v);
                    _confirmSizingUpdated();
                  }
                },
              ),
            ],
          ),
          // G7 — "5 K" told the engineer nothing: the caption names the unit in
          // plain terms (and the 55 C floor the check actually enforces).
          caption(
              context.strings(StringKey.buildingInputCaptionHotWaterDeltaT)),
          // M15 — which basis the Rooms AC estimate uses. ONE segment idiom,
          // matching the Occupancy radio above.
          const SizedBox(height: MechXSpacing.md),
          Text(context.strings(StringKey.designInputAcLoadBasis),
              style: type.caption.copyWith(color: colors.textMuted)),
          const SizedBox(height: MechXSpacing.xs),
          Wrap(
            spacing: MechXSpacing.xs,
            runSpacing: MechXSpacing.xs,
            children: [
              MechXSegment(
                label: context.strings(StringKey.designInputAcBasisArea),
                selected: acBasis == CoolingLoadMethod.simple,
                onTap: () {
                  setCoolingLoadMethodUndoable(ref.read, CoolingLoadMethod.simple);
                  _confirmSizingUpdated();
                },
              ),
              MechXSegment(
                label: context.strings(StringKey.designInputAcBasisHeatGain),
                selected: acBasis == CoolingLoadMethod.detailed,
                onTap: () {
                  setCoolingLoadMethodUndoable(ref.read, CoolingLoadMethod.detailed);
                  _confirmSizingUpdated();
                },
              ),
            ],
          ),
          caption(context.strings(StringKey.buildingInputCaptionAcBasis)),
        ],
      ),
    );
  }
}

/// The drafting denominator N of a gradient (0.01 m/m ⇒ 100, read "1:100").
double _slopeN(double slope) => slope > 0 ? 1.0 / slope : 100.0;

/// The gradient (m/m) for a drafting denominator N, guarded against 0.
double _slopeFromN(double n) => n <= 0 ? 0.1 : 1.0 / n;

/// `1:100` — the way a fall is written on a drawing. ASCII only.
String _slopeDisplay(double slope) => '1:${_slopeN(slope).round()}';

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

/// Round 25 — a height in metres at 2 dp with ONE trailing zero trimmed
/// (3.25 → '3.25', 3.50 → '3.5', 3.00 → '3.0'), so whole and half metres read
/// as before while a centimetre value is never rounded away.
String trimmedMetres(double m) {
  final s = m.toStringAsFixed(2);
  return s.endsWith('0') ? s.substring(0, s.length - 1) : s;
}
