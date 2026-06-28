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
import 'package:mechx_engine/electrical/load_kind.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/glass_surface.dart';
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

  const PaletteLoad(this.kind, {this.phases, this.loadW = 0, this.motorKw});
}

/// A palette card descriptor.
class _Card {
  final String label;
  final PaletteLoad load;
  const _Card(this.label, this.load);
}

/// A palette group (a faint header + its cards).
class _Group {
  final String title;
  final List<_Card> cards;
  const _Group(this.title, this.cards);
}

// The groups + cards, transcribed from PanelMaker (sub-panel = the feeder kind,
// which the canvas turns into a new board on a blank drop).
const List<_Group> _groups = [
  _Group('Loads', [
    _Card('Lighting', PaletteLoad(LoadKind.lighting, loadW: 1200)),
    _Card('Sockets', PaletteLoad(LoadKind.socket, loadW: 2000)),
    _Card('Air-con (1φ)', PaletteLoad(LoadKind.hvac, phases: 1, loadW: 2500)),
    _Card('Air-con (3φ)', PaletteLoad(LoadKind.hvac, phases: 3, loadW: 5500)),
    _Card(
      'Water heater (1φ)',
      PaletteLoad(LoadKind.heating, phases: 1, loadW: 3000),
    ),
    _Card(
      'Water heater (3φ)',
      PaletteLoad(LoadKind.heating, phases: 3, loadW: 9000),
    ),
    _Card(
      'EV charger (1φ)',
      PaletteLoad(LoadKind.evCharger, phases: 1, loadW: 7400),
    ),
    _Card(
      'EV charger (3φ)',
      PaletteLoad(LoadKind.evCharger, phases: 3, loadW: 22000),
    ),
    _Card(
      'Industrial socket (3φ)',
      PaletteLoad(LoadKind.socket, phases: 3, loadW: 7500),
    ),
    _Card('UPS / IT load', PaletteLoad(LoadKind.ups, loadW: 3000)),
    _Card(
      'Welding set (3φ)',
      PaletteLoad(LoadKind.welding, phases: 3, loadW: 8000),
    ),
    _Card(
      'Custom load (1φ)',
      PaletteLoad(LoadKind.general, phases: 1, loadW: 2000),
    ),
    _Card(
      'Custom load (3φ)',
      PaletteLoad(LoadKind.general, phases: 3, loadW: 7500),
    ),
  ]),
  _Group('Motors & pumps', [
    _Card('Motor (DOL)', PaletteLoad(LoadKind.motor, motorKw: 5.5)),
    _Card('Motor (large)', PaletteLoad(LoadKind.motor, motorKw: 15)),
    _Card('Pump (1φ)', PaletteLoad(LoadKind.pump, phases: 1, motorKw: 0.75)),
    _Card('Pump (3φ)', PaletteLoad(LoadKind.pump, phases: 3, motorKw: 4)),
    _Card('Fire pump', PaletteLoad(LoadKind.pump, motorKw: 15)),
  ]),
  _Group('Distribution', [
    _Card('Spare MCB way', PaletteLoad(LoadKind.spare)),
    _Card('Sub-panel', PaletteLoad(LoadKind.feeder)),
  ]),
];

/// The scrollable palette column.
class ElectricalPalette extends StatelessWidget {
  const ElectricalPalette({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GlassSurface(
      // Floats over the electrical canvas; its left edge faces the diagram.
      edge: Border(
          left: BorderSide(color: colors.glassEdge, width: MechXGlass.edgeWidth)),
      child: SizedBox(
      width: 188,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
              MechXSpacing.md,
              MechXSpacing.md,
              MechXSpacing.md,
              MechXSpacing.xs,
            ),
            child: MechXSectionLabel('Loads'),
          ),
          const SizedBox(height: MechXSpacing.sm),
          Expanded(
            child: SingleChildScrollView(
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
                        child: MechXSectionLabel(_groups[i].title),
                      ),
                    for (final c in _groups[i].cards)
                      Padding(
                        padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
                        child: PaletteCard<PaletteLoad>(
                          label: c.label,
                          swatch: c.load.kind == LoadKind.feeder
                              ? colors.success
                              : colors.accent,
                          data: c.load,
                          fillWidth: true,
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
        ],
      ),
      ),
    );
  }
}
