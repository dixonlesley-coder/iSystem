import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/electrical_store.dart';
import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
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
    final type = context.type;

    // Scope the equipment groups to the active discipline on the Layout canvas.
    // On the Schematic view (no layer concept) everything is offered.
    final onLayout = ref.watch(workspaceViewProvider) == WorkspaceView.plan;
    final active = ref.watch(activeDisciplineProvider);

    // Equipment groups scope to the SYSTEM layer they belong to (and the
    // Schematic view, which has no layer concept, shows everything).
    final showAll = !onLayout;
    final showWater = showAll || active == DisciplineLayer.water;
    final showDrains = showAll ||
        active == DisciplineLayer.sanitary ||
        active == DisciplineLayer.storm;
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

    Widget componentCard(NodeComponent c) => Padding(
          padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
          child: PaletteCard<PaletteItem>(
            label: c.label,
            swatch: colors.textSecondary,
            data: PaletteItem(PaletteItemKind.component, component: c),
            fillWidth: true,
            onActivate: () =>
                dropAtCentre(PaletteItem(PaletteItemKind.component, component: c)),
            leading:
                ComponentSymbol(component: c, color: colors.textSecondary, size: 16),
          ),
        );

    Widget equipmentGroup(String title, List<NodeComponent> items) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: MechXSpacing.xs),
            MechXSectionLabel(title),
            const SizedBox(height: MechXSpacing.xs),
            for (final c in items) componentCard(c),
          ],
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MechXSectionLabel('Palette'),
        const SizedBox(height: MechXSpacing.xs),
        Text(
          'Drop a riser where a main starts, then drag the blue outlet out '
          'of it to lay the mainline. Drop a terminal and drag it onto a main '
          'to branch it.',
          style: type.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.sm),

        // ── Start here: the riser (the mainline's origin) ──────────────────
        const MechXSectionLabel('Mainline start'),
        const SizedBox(height: MechXSpacing.xs),
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

        // ── Nodes (generic endpoints) ──────────────────────────────────────
        const SizedBox(height: MechXSpacing.xs),
        const MechXSectionLabel('Nodes'),
        const SizedBox(height: MechXSpacing.xs),
        Padding(
          padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
          child: PaletteCard<PaletteItem>(
            label: 'Fitting',
            swatch: colors.textSecondary,
            data: const PaletteItem(PaletteItemKind.fitting),
            fillWidth: true,
            onActivate: () =>
                dropAtCentre(const PaletteItem(PaletteItemKind.fitting)),
            leading: SegmentSymbol(
                kind: PaletteItemKind.fitting, color: colors.textSecondary,
                size: 16),
          ),
        ),
        PaletteCard<PaletteItem>(
          label: 'Terminal',
          swatch: colors.textSecondary,
          data: const PaletteItem(PaletteItemKind.terminal),
          fillWidth: true,
          onActivate: () =>
              dropAtCentre(const PaletteItem(PaletteItemKind.terminal)),
          leading: SegmentSymbol(
              kind: PaletteItemKind.terminal, color: colors.textSecondary,
              size: 16),
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
      ],
    );
  }
}
