/// The Loads palette for the electrical single-line canvas — grouped
/// draggable cards ported from PanelMaker's `SLD_PALETTE`. Drag a card onto a
/// panel to add a way, or onto blank canvas to add a floating load / sub-panel.
///
/// Borderless: the placement owns the separator (the canvas-side hairline in
/// `ElectricalView`, the [CollapsibleInspector] border in the unified Layout),
/// so the column sits flush on the right like every other inspector.
///
/// Each card carries a [PaletteLoad] payload (kind + optional phase + default
/// power). cos φ / demand factor come from `loadDefaults` so the palette never
/// drifts from the engine. Styled with MechXTheme (no Material).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/load_kind.dart';

import '../../store/app_state.dart';
import '../../store/electrical_store.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mechx_scrollbar.dart';
import '../widgets/palette_card.dart';
import '../widgets/section_label.dart';
import 'load_symbols.dart';

/// The drag payload — what a palette card drops.
@immutable
class PaletteLoad {
  final LoadKind kind;

  /// Explicit phase (1 or 3), or null to let the engine infer.
  final int? phases;

  /// Default connected power (W) seeded on drop (0 = use the store default).
  final double loadW;

  /// Default motor rating (kW), for motor/pump kinds.
  final double? motorKw;

  /// Panel template ID for feeder-kind cards (lighting/power/mixed).
  final String? panelTemplateId;

  const PaletteLoad(this.kind, {this.phases, this.loadW = 0, this.motorKw, this.panelTemplateId});
}

/// A palette card descriptor (its label is a [StringKey] so the palette is
/// localised — I6; new cards may use plain EN strings).
class _Card {
  final Object label;  // StringKey or String (plain EN for new cards)
  final PaletteLoad load;
  const _Card(this.label, this.load);
}

/// A palette group (a faint header + its cards).
class _Group {
  final StringKey title;
  final List<_Card> cards;
  const _Group(this.title, this.cards);
}

// The groups + cards, transcribed from PanelMaker (sub-panel = the feeder kind,
// which the canvas turns into a new board on a blank drop).
const List<_Group> _groups = [
  _Group(StringKey.electricalPaletteLoads, [
    _Card(StringKey.electricalLoadLighting,
        PaletteLoad(LoadKind.lighting, loadW: 1200)),
    _Card(StringKey.electricalLoadSockets,
        PaletteLoad(LoadKind.socket, loadW: 2000)),
    _Card(StringKey.electricalLoadAircon1,
        PaletteLoad(LoadKind.hvac, phases: 1, loadW: 2500)),
    _Card(StringKey.electricalLoadAircon3,
        PaletteLoad(LoadKind.hvac, phases: 3, loadW: 5500)),
    _Card(
      StringKey.electricalLoadWaterHeater1,
      PaletteLoad(LoadKind.heating, phases: 1, loadW: 3000),
    ),
    _Card(
      StringKey.electricalLoadWaterHeater3,
      PaletteLoad(LoadKind.heating, phases: 3, loadW: 9000),
    ),
    _Card(
      StringKey.electricalLoadEv1,
      PaletteLoad(LoadKind.evCharger, phases: 1, loadW: 7400),
    ),
    _Card(
      StringKey.electricalLoadEv3,
      PaletteLoad(LoadKind.evCharger, phases: 3, loadW: 22000),
    ),
    _Card(
      StringKey.electricalLoadIndustrialSocket3,
      PaletteLoad(LoadKind.socket, phases: 3, loadW: 7500),
    ),
    _Card(StringKey.electricalLoadUpsIt, PaletteLoad(LoadKind.ups, loadW: 3000)),
    _Card(
      StringKey.electricalLoadWelding3,
      PaletteLoad(LoadKind.welding, phases: 3, loadW: 8000),
    ),
    _Card(
      StringKey.electricalLoadCustom1,
      PaletteLoad(LoadKind.general, phases: 1, loadW: 2000),
    ),
    _Card(
      StringKey.electricalLoadCustom3,
      PaletteLoad(LoadKind.general, phases: 3, loadW: 7500),
    ),
    _Card(
      StringKey.electricalCapacitorBank,
      PaletteLoad(LoadKind.capacitor, phases: 3, loadW: 0),
    ),
  ]),
  _Group(StringKey.electricalPaletteMotorsPumps, [
    _Card(StringKey.electricalLoadMotorDol,
        PaletteLoad(LoadKind.motor, motorKw: 5.5)),
    _Card(StringKey.electricalLoadMotorLarge,
        PaletteLoad(LoadKind.motor, motorKw: 15)),
    _Card(StringKey.electricalLoadPump1,
        PaletteLoad(LoadKind.pump, phases: 1, motorKw: 0.75)),
    _Card(StringKey.electricalLoadPump3,
        PaletteLoad(LoadKind.pump, phases: 3, motorKw: 4)),
    _Card(StringKey.electricalLoadFirePump,
        PaletteLoad(LoadKind.pump, motorKw: 15)),
  ]),
  _Group(StringKey.electricalPaletteDistribution, [
    _Card(StringKey.electricalLoadSpareMcb, PaletteLoad(LoadKind.spare)),
    _Card(StringKey.electricalLoadSubPanel, PaletteLoad(LoadKind.feeder)),
    _Card(StringKey.electricalLightingPanel,
        PaletteLoad(LoadKind.feeder, panelTemplateId: 'lighting')),
    _Card(StringKey.electricalPowerPanel,
        PaletteLoad(LoadKind.feeder, panelTemplateId: 'power')),
    _Card(StringKey.electricalMixedPanel,
        PaletteLoad(LoadKind.feeder, panelTemplateId: 'mixed')),
  ]),
];

/// The scrollable palette column.
///
/// [enabled] gates interactivity (D6): on the read-only Building-riser / Power
/// one-line tabs the palette has no drop target, so it renders dimmed + inert
/// (no drag, no keyboard activation) with a one-line hint replacing the header.
class ElectricalPalette extends ConsumerStatefulWidget {
  final bool enabled;
  const ElectricalPalette({super.key, this.enabled = true});

  @override
  ConsumerState<ElectricalPalette> createState() => _ElectricalPaletteState();
}

class _ElectricalPaletteState extends ConsumerState<ElectricalPalette> {
  // Owned so the themed scroll indicator (J1) can be dragged, not just shown.
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// L1 — the keyboard alternative to dragging a card onto a panel: adds the
  /// load as a new way on the currently selected panel (either workspace's
  /// selection provider — the standalone single-line's inspector target, or
  /// the unified Layout electrical layer's marker selection), falling back to
  /// the project's first panel when nothing is selected. When a feeder-kind
  /// card is activated AND a panel is explicitly selected, creates a fed
  /// sub-panel via addFedPanelAt instead. When no panel is selected, a feeder
  /// degrades to a general load. No-op when the project has no panel at all —
  /// there's nothing to add a way to.
  void _addLoad(_Card card) {
    final project = ref.read(electricalProjectProvider);
    if (project.panels.isEmpty) return;

    final inspectorTarget = ref.read(electricalInspectorTargetProvider);
    final layoutSelection = ref.read(electricalSelectionProvider);
    String? panelId;
    if (inspectorTarget is ElectricalPanelTarget) {
      panelId = inspectorTarget.panelId;
    } else if (inspectorTarget is ElectricalCircuitTarget) {
      panelId = inspectorTarget.panelId;
    } else {
      panelId = layoutSelection?.panelId;
    }
    final selectedPanelId = panelId;
    final panel = (panelId == null
            ? null
            : project.panels.where((p) => p.id == panelId).firstOrNull) ??
        project.panels.first;

    // Guard the machine-owned MEP board the same way the canvas drop target
    // does — a hand-added way there would be silently wiped on the next plan
    // re-sync.
    if (panel.id == kMepEquipmentPanelId) {
      ref.read(statusMessageProvider.notifier).showStatus(
            context.strings(StringKey.electricalMepEquipmentHint),
          );
      return;
    }

    final load = card.load;
    final cardLabel = card.label is String
        ? card.label as String
        : context.strings(card.label as StringKey);

    // If this is a feeder card and a panel is explicitly selected, create
    // a fed sub-panel with the optional template.
    if (load.kind == LoadKind.feeder && selectedPanelId != null) {
      ref.read(electricalProjectProvider.notifier).addFedPanelAt(
        fromPanelId: selectedPanelId,
        x: 80,
        y: 80,
        templateId: load.panelTemplateId,
      );
      final templateDesc =
          load.panelTemplateId != null
              ? context.strings(StringKey.electricalPopulated)
              : '';
      ref.read(statusMessageProvider.notifier).showStatus(
        context.strings.format(
          StringKey.electricalCreatedSubpanelTemplate,
          {'templateDesc': templateDesc, 'panel': panel.name},
        ),
      );
    } else {
      // Non-feeder cards or feeder with no panel selected: add as a way
      // (feeder degrades to general load when no panel is selected).
      ref.read(electricalProjectProvider.notifier).addCircuit(
            panel.id,
            kind: load.kind == LoadKind.feeder ? LoadKind.general : load.kind,
            phases: load.phases,
            loadW: load.loadW > 0 ? load.loadW : null,
            motorKw: load.motorKw,
          );
      ref.read(statusMessageProvider.notifier).showStatus(
          context.strings.format(
            StringKey.electricalAddedLoadTemplate,
            {'load': cardLabel, 'panel': panel.name},
          ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final enabled = widget.enabled;
    return GlassSurface(
      // Floats over the electrical canvas; its left edge faces the diagram.
      edge: Border(
          left: BorderSide(color: colors.glassEdge, width: MechXGlass.edgeWidth)),
      child: SizedBox(
      width: 188,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MechXSpacing.md,
              MechXSpacing.md,
              MechXSpacing.md,
              MechXSpacing.xs,
            ),
            // D6: on a read-only projection the header is a plain hint (no drop
            // target here); otherwise the "Loads" section label.
            child: enabled
                ? MechXSectionLabel(
                    context.strings(StringKey.electricalPaletteLoads))
                : Text(
                    context.strings(StringKey.electricalPaletteReadOnly),
                    style: type.caption.copyWith(color: colors.textMuted),
                  ),
          ),
          const SizedBox(height: MechXSpacing.sm),
          Expanded(
            // D6: dim + inert (no drag / no keyboard activation) when disabled.
            child: IgnorePointer(
              ignoring: !enabled,
              child: ExcludeFocus(
                excluding: !enabled,
                child: Opacity(
                  opacity: enabled ? 1.0 : 0.4,
                  child: MechXScrollbar(
              controller: _scrollController,
              child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(
                MechXSpacing.md,
                0,
                MechXSpacing.md,
                MechXSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < _groups.length; i++) ...[
                    // The first group's items sit under the "Loads" header
                    // above; later groups get their own section label.
                    if (i > 0)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: MechXSpacing.sm,
                          bottom: MechXSpacing.xs,
                        ),
                        child: MechXSectionLabel(
                            context.strings(_groups[i].title)),
                      ),
                    for (final c in _groups[i].cards)
                      Padding(
                        padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
                        child: PaletteCard<PaletteLoad>(
                          label: c.label is String
                              ? c.label as String
                              : context.strings(c.label as StringKey),
                          swatch: c.load.kind == LoadKind.feeder
                              ? colors.success
                              : colors.accent,
                          data: c.load,
                          fillWidth: true,
                          // L1: a keyboard alternative to dragging — Enter/Space
                          // on a focused card adds the way to the selected (or
                          // first) panel, mirroring the mechanical
                          // SegmentPalette's dropAtCentre. Null when read-only.
                          onActivate: enabled ? () => _addLoad(c) : null,
                          // Show the load's industry-standard symbol so the
                          // palette matches how it'll appear on the plan.
                          leading: LoadSymbol(
                            kind: c.load.kind,
                            color: c.load.kind == LoadKind.feeder
                                ? colors.success
                                : colors.accent,
                            size: 16,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            ),
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}
