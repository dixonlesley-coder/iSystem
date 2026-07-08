import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../data/project_document.dart' show SavedAssembly;
import '../../store/assemblies_store.dart';
import '../../store/electrical_store.dart';
import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../inspector/disclosure_header.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/palette_card.dart';
import '../widgets/section_label.dart';
import 'segment_symbols.dart';

/// What a palette card drops onto the canvas. The drop overlay reads [kind] to
/// pick the matching store add-action; [service] (a pipe segment) carries the
/// service so a duct vs water segment lands correctly; [component] (a
/// [PaletteItemKind.component]) carries which piece of equipment to drop.
enum PaletteItemKind { pipeSegment, ductSegment, fitting, terminal, component }

@immutable
class PaletteItem {
  final PaletteItemKind kind;

  /// For [PaletteItemKind.pipeSegment]/[PaletteItemKind.ductSegment] — the
  /// service the dropped segment carries. Null ⇒ use the active draw service.
  final ServiceType? service;

  /// For [PaletteItemKind.component] — which equipment node to drop.
  final NodeComponent? component;

  const PaletteItem(this.kind, {this.service, this.component});

  // VALUE equality (F5): the armed-placement provider compares the currently
  // armed item against each card's item to draw the armed tint; a non-const
  // component card rebuilds a fresh instance each frame, so identity equality
  // would never match.
  @override
  bool operator ==(Object other) =>
      other is PaletteItem &&
      other.kind == kind &&
      other.service == service &&
      other.component == component;

  @override
  int get hashCode => Object.hash(kind, service, component);
}

/// F5 — the palette card ARMED for click-to-place-repeatedly. Non-null means
/// each canvas click drops another instance of this item (through the SAME
/// merge/snap add-actions a drag uses, in `drop_overlay.dart`); null is normal
/// single-drag placement. Esc / a canvas right-click / re-clicking the armed
/// card / picking another card disarms. Transient UI state — never persisted.
///
/// (Kept in the UI layer beside [PaletteItem], its payload type, rather than in
/// the pure `network_store`: routing a UI type through the engine-typed store
/// would invert the store↔UI layering.)
final armedPlacementProvider =
    NotifierProvider<ArmedPlacementController, PaletteItem?>(
  ArmedPlacementController.new,
);

class ArmedPlacementController extends Notifier<PaletteItem?> {
  @override
  PaletteItem? build() => null;

  /// Toggle: arming the already-armed item disarms it; a different item re-arms.
  void toggle(PaletteItem item) => state = (state == item) ? null : item;

  void disarm() => state = null;
}

/// The mechanical node palette — a full, grouped, draggable node palette built
/// to mirror the electrical Loads column ([ElectricalPalette]) so both canvases
/// speak ONE node language: each service gets its own pipe/duct node card with a
/// leading schematic symbol, and there's a Nodes group for the generic fitting /
/// terminal endpoints. Drag a card onto the calibrated canvas to place it.
/// Styled with MechXTheme (no Material).
class SegmentPalette extends ConsumerWidget {
  const SegmentPalette({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;

    // F5 — the card ARMED for click-to-place-repeatedly (null = none). A card is
    // armed by a plain CLICK (a drag still drags, unchanged); the armed card
    // shows an accent ring, and each canvas click drops another instance.
    final armedItem = ref.watch(armedPlacementProvider);

    // Scope the equipment groups to the active discipline on the Layout canvas.
    // On the Schematic view (no layer concept) everything is offered.
    final onLayout = ref.watch(workspaceViewProvider) == WorkspaceView.plan;
    final active = ref.watch(activeDisciplineProvider);

    // Saved assemblies / blocks (E5). Rendered ONLY when the user has saved at
    // least one, so a fresh project's palette is byte-identical (goldens carry
    // no saved assembly).
    final assemblies = ref.watch(assembliesProvider);

    // Equipment groups scope to the SYSTEM layer they belong to (and the
    // Schematic view, which has no layer concept, shows everything).
    final showAll = !onLayout;
    // Plumbing is one layer (water + sanitary + storm), so its water plant shows
    // whenever plumbing is active.
    final showWater = showAll || active == DisciplineLayer.plumbing;
    // Drains (roof/floor drain, cleanout) belong to the GRAVITY drainage family
    // (drainage / vent / rainwater), not pressurized water — within the one
    // plumbing layer, gate them on the ACTIVE draw service's regime so they don't
    // clutter the palette while a cold/hot-water run is selected. (The Schematic
    // view has no service concept ⇒ showAll still shows them.)
    final drawService = ref.watch(networkControllerProvider).service;
    final showDrains = showAll ||
        (active == DisciplineLayer.plumbing &&
            drawService.regime == FlowRegime.gravity);
    // Clean-water outlets are a PRESSURIZED-water (cold/hot) placement — the
    // mirror of drains — so they show only while a water run is selected.
    final showWaterOutlet = showAll ||
        (active == DisciplineLayer.plumbing &&
            drawService.regime == FlowRegime.pressurized);
    final showFire = showAll || active == DisciplineLayer.fire;
    final showAir = showAll || active == DisciplineLayer.hvac;

    // Keyboard activation (Enter/Space on a focused card): drop the item at the
    // CENTRE of the current sheet (world coords, viewport-independent) via the
    // same store add-actions a drag uses. No-op if no sheet is loaded.
    void dropAtCentre(PaletteItem item) {
      final sheet = ref.read(sheetsControllerProvider).current;
      if (sheet == null) return;
      final levelCount = ref.read(projectControllerProvider).building.levelCount;
      final floorIndex =
          ref.read(sheetsControllerProvider).floorFor(sheet.id, levelCount);
      final world = sheet.sizePx.center(Offset.zero);
      final ctrl = ref.read(networkControllerProvider.notifier);
      switch (item.kind) {
        case PaletteItemKind.pipeSegment:
        case PaletteItemKind.ductSegment:
          ctrl.addSegment(sheet.id, floorIndex, world, service: item.service);
        case PaletteItemKind.fitting:
          ctrl.addFitting(sheet.id, floorIndex, world);
        case PaletteItemKind.terminal:
          ctrl.addTerminal(sheet.id, floorIndex, world);
        case PaletteItemKind.component:
          final c = item.component;
          if (c != null) ctrl.addComponentNode(sheet.id, floorIndex, world, c);
      }
    }

    // F5 — wrap a palette card so a plain CLICK arms/disarms it for
    // click-to-place-repeatedly (a drag is untouched — tap and drag are
    // distinct gesture recognizers). The armed card gains an accent ring.
    Widget armable(PaletteItem item, Widget card) => GestureDetector(
          onTap: () {
            ref.read(armedPlacementProvider.notifier).toggle(item);
            // Placement is a Select-mode canvas gesture — make sure a draw tool
            // isn't holding the clicks when we arm.
            if (ref.read(armedPlacementProvider) != null) {
              ref
                  .read(networkControllerProvider.notifier)
                  .setTool(DrawTool.select);
            }
          },
          child: armedItem == item
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: MechXRadii.control,
                    border: Border.all(color: colors.accent, width: 1.5),
                    color: colors.accentMuted,
                  ),
                  child: card,
                )
              : card,
        );

    Widget componentCard(NodeComponent c) {
      final item = PaletteItem(PaletteItemKind.component, component: c);
      return Padding(
        padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
        child: armable(
          item,
          PaletteCard<PaletteItem>(
            label: c.label,
            swatch: colors.textSecondary,
            data: item,
            fillWidth: true,
            onActivate: () => dropAtCentre(item),
            leading: ComponentSymbol(
                component: c, color: colors.textSecondary, size: 16),
          ),
        ),
      );
    }

    // Accessory groups (valves, meters, dampers) collapse by default so the
    // palette reads as a short list of primary equipment instead of a long
    // scroll — the long tail is one tap away. Primary equipment for each
    // discipline (plant, terminals, units, AC, drains, fire) stays open.
    const collapsedByDefault = <String>{'Valves', 'Meters & misc', 'Dampers'};
    Widget equipmentGroup(String title, List<NodeComponent> items) => Padding(
          padding: const EdgeInsets.only(top: MechXSpacing.xs),
          child: DisclosureSection(
            name: title,
            defaultExpanded: !collapsedByDefault.contains(title),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final c in items) componentCard(c)],
            ),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Start here: the riser (the mainline's origin) ──────────────────
        const MechXSectionLabel('Mainline start'),
        const SizedBox(height: MechXSpacing.xs),
        armable(
          const PaletteItem(PaletteItemKind.component,
              component: NodeComponent.riser),
          PaletteCard<PaletteItem>(
            label: 'Riser node',
            swatch: context.colors.accent,
            data: const PaletteItem(PaletteItemKind.component,
                component: NodeComponent.riser),
            fillWidth: true,
            onActivate: () => dropAtCentre(const PaletteItem(
                PaletteItemKind.component,
                component: NodeComponent.riser)),
            leading: ComponentSymbol(
                component: NodeComponent.riser,
                color: context.colors.accent,
                size: 16),
          ),
        ),

        // ── Nodes (generic endpoints) ──────────────────────────────────────
        const SizedBox(height: MechXSpacing.xs),
        const MechXSectionLabel('Nodes'),
        const SizedBox(height: MechXSpacing.xs),
        Padding(
          padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
          child: armable(
            const PaletteItem(PaletteItemKind.fitting),
            PaletteCard<PaletteItem>(
              label: 'Fitting',
              swatch: colors.textSecondary,
              data: const PaletteItem(PaletteItemKind.fitting),
              fillWidth: true,
              onActivate: () =>
                  dropAtCentre(const PaletteItem(PaletteItemKind.fitting)),
              leading: SegmentSymbol(
                  kind: PaletteItemKind.fitting,
                  color: colors.textSecondary,
                  size: 16),
            ),
          ),
        ),
        armable(
          const PaletteItem(PaletteItemKind.terminal),
          PaletteCard<PaletteItem>(
            label: 'Terminal',
            swatch: colors.textSecondary,
            data: const PaletteItem(PaletteItemKind.terminal),
            fillWidth: true,
            onActivate: () =>
                dropAtCentre(const PaletteItem(PaletteItemKind.terminal)),
            leading: SegmentSymbol(
                kind: PaletteItemKind.terminal,
                color: colors.textSecondary,
                size: 16),
          ),
        ),

        // ── Water-supply equipment (Water layer) ───────────────────────────
        if (showWater) ...[
          equipmentGroup('Plant', const [
            NodeComponent.pump,
            NodeComponent.roofTank,
            NodeComponent.groundTank,
            NodeComponent.boosterSet,
          ]),
          equipmentGroup('Valves', const [
            NodeComponent.gateValve,
            NodeComponent.checkValve,
            NodeComponent.prv,
            NodeComponent.balancingValve,
          ]),
          equipmentGroup('Meters & misc', const [
            NodeComponent.waterMeter,
            NodeComponent.strainer,
            NodeComponent.expansionTank,
            NodeComponent.airVent,
          ]),
        ],

        // ── Clean-water outlets (pressurized water service) ─────────────────
        if (showWaterOutlet)
          equipmentGroup('Water outlets', const [
            NodeComponent.waterOutlet,
          ]),

        // ── Drains (Sanitary + Storm layers) ───────────────────────────────
        if (showDrains)
          equipmentGroup('Drains', const [
            NodeComponent.roofDrain,
            NodeComponent.floorDrain,
            NodeComponent.cleanout,
          ]),

        // ── Fire protection (Fire layer) ───────────────────────────────────
        if (showFire)
          equipmentGroup('Fire protection', const [
            NodeComponent.sprinklerHead,
            NodeComponent.fireExtinguisher,
            NodeComponent.hydrantBox,
            NodeComponent.hoseReel,
            NodeComponent.fireDeptConnection,
          ]),

        // ── HVAC / ducting equipment ───────────────────────────────────────
        if (showAir) ...[
          equipmentGroup('Air terminals', const [
            NodeComponent.supplyDiffuser,
            NodeComponent.returnGrille,
            NodeComponent.exhaustGrille,
            NodeComponent.linearDiffuser,
          ]),
          equipmentGroup('Dampers', const [
            NodeComponent.volumeDamper,
            NodeComponent.fireDamper,
            NodeComponent.motorizedDamper,
            NodeComponent.vavBox,
          ]),
          equipmentGroup('Air units', const [
            NodeComponent.ahu,
            NodeComponent.fcu,
            NodeComponent.supplyFan,
            NodeComponent.exhaustFan,
          ]),
          equipmentGroup('Air conditioning', const [
            NodeComponent.acCassette,
            NodeComponent.acSplitWall,
            NodeComponent.acDucted,
          ]),
        ],

        // ── Saved assemblies / blocks (E5) — re-stampable groups ─────────────
        // A drag re-instantiates the block's nodes/edges with fresh ids at the
        // drop point: `drop_overlay.dart` accepts the `DragTarget<SavedAssembly>`
        // and routes it to `NetworkController.stampAssembly` (centroid→cursor,
        // fresh ids, one undo step, the stamped elements left selected).
        if (assemblies.isNotEmpty) ...[
          const SizedBox(height: MechXSpacing.xs),
          const MechXSectionLabel('Assemblies'),
          const SizedBox(height: MechXSpacing.xs),
          for (final a in assemblies)
            Padding(
              padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
              child: Row(
                children: [
                  Expanded(
                    child: PaletteCard<SavedAssembly>(
                      label: a.name,
                      swatch: colors.accent,
                      data: a,
                      fillWidth: true,
                    ),
                  ),
                  const SizedBox(width: MechXSpacing.xs),
                  _AssemblyDeleteButton(
                    onTap: () =>
                        ref.read(assembliesProvider.notifier).remove(a.id),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// A tiny "remove this saved block" affordance beside an assembly card. Custom
/// (no Material) to match the palette's MechXTheme idiom.
class _AssemblyDeleteButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AssemblyDeleteButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(MechXSpacing.xxs),
          child: Text(
            '×',
            style: context.type.body.copyWith(color: colors.textMuted),
          ),
        ),
      ),
    );
  }
}
