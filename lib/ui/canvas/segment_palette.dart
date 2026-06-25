import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/electrical_store.dart';
import '../../store/layer_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/palette_card.dart';
import '../widgets/section_label.dart';
import 'service_style.dart';
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

  // The services offered as draggable segment cards (the same set the DRAW
  // chips expose), split into pipe vs duct (air) at render time by regime.
  static const List<ServiceType> _services = [
    ServiceType.coldWater,
    ServiceType.hotWater,
    ServiceType.drainage,
    ServiceType.vent,
    ServiceType.rainwater,
    ServiceType.duct,
    ServiceType.returnAir,
    ServiceType.exhaust,
    ServiceType.fireSprinkler,
    ServiceType.fireHydrant,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;

    // Scope the offered services to the active discipline on the Layout canvas
    // (plumbing services under Plumbing, air services under HVAC) — matching the
    // DRAW chips, so the palette never offers a service the active layer hides.
    // On the Schematic view (no layer concept) all services are offered.
    final onLayout = ref.watch(workspaceViewProvider) == WorkspaceView.plan;
    final active = ref.watch(activeDisciplineProvider);
    final scoped = (onLayout && active.isMechanical)
        ? servicesFor(active)
        : _services;
    final services = _services.where(scoped.contains).toList();

    final pipes = services.where((s) => !s.isAir).toList();
    final ducts = services.where((s) => s.isAir).toList();

    // Equipment groups scope to the SYSTEM layer they belong to (and the
    // Schematic view, which has no layer concept, shows everything).
    final showAll = !onLayout;
    final showWater = showAll || active == DisciplineLayer.water;
    final showDrains = showAll ||
        active == DisciplineLayer.sanitary ||
        active == DisciplineLayer.storm;
    final showFire = showAll || active == DisciplineLayer.fire;
    final showAir = showAll || active == DisciplineLayer.hvac;

    Widget componentCard(NodeComponent c) => Padding(
          padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
          child: PaletteCard<PaletteItem>(
            label: c.label,
            swatch: colors.textSecondary,
            data: PaletteItem(PaletteItemKind.component, component: c),
            fillWidth: true,
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

    Widget serviceCard(ServiceType s) {
      final isAir = s.isAir;
      final kind =
          isAir ? PaletteItemKind.ductSegment : PaletteItemKind.pipeSegment;
      return Padding(
        padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
        child: PaletteCard<PaletteItem>(
          label: serviceLabel(s),
          swatch: serviceColor(s),
          data: PaletteItem(kind, service: s),
          fillWidth: true,
          leading: SegmentSymbol(kind: kind, color: serviceColor(s), size: 16),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MechXSectionLabel('Palette'),
        const SizedBox(height: MechXSpacing.xs),
        Text(
          'Drag a node onto the canvas to place it.',
          style: type.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: MechXSpacing.sm),

        // ── Pipes ──────────────────────────────────────────────────────────
        if (pipes.isNotEmpty) ...[
          const MechXSectionLabel('Pipes'),
          const SizedBox(height: MechXSpacing.xs),
          for (final s in pipes) serviceCard(s),
        ],

        // ── Ducts ──────────────────────────────────────────────────────────
        if (ducts.isNotEmpty) ...[
          const SizedBox(height: MechXSpacing.xs),
          const MechXSectionLabel('Ducts'),
          const SizedBox(height: MechXSpacing.xs),
          for (final s in ducts) serviceCard(s),
        ],

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
          leading: SegmentSymbol(
              kind: PaletteItemKind.terminal, color: colors.textSecondary,
              size: 16),
        ),
        // A riser-start marker (any system): place it where the riser meets the
        // main, then connect runs from it.
        Padding(
          padding: const EdgeInsets.only(top: MechXSpacing.xs),
          child: PaletteCard<PaletteItem>(
            label: 'Riser node',
            swatch: colors.textSecondary,
            data: const PaletteItem(PaletteItemKind.component,
                component: NodeComponent.riser),
            fillWidth: true,
            leading: ComponentSymbol(
                component: NodeComponent.riser,
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
        ],
      ],
    );
  }
}
