/// The left Loads palette for the electrical single-line canvas — grouped
/// draggable cards ported from PanelMaker's `SLD_PALETTE`. Drag a card onto a
/// panel to add a way, or onto blank canvas to add a floating load / sub-panel.
///
/// Each card carries a [PaletteLoad] payload (kind + optional phase + default
/// power). cos φ / demand factor come from `loadDefaults` so the palette never
/// drifts from the engine. Styled with MechXTheme (no Material).
library;

import 'package:flutter/widgets.dart';
import 'package:mechx_engine/electrical/load_kind.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

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
    _Card('Water heater (1φ)',
        PaletteLoad(LoadKind.heating, phases: 1, loadW: 3000)),
    _Card('Water heater (3φ)',
        PaletteLoad(LoadKind.heating, phases: 3, loadW: 9000)),
    _Card('EV charger (1φ)',
        PaletteLoad(LoadKind.evCharger, phases: 1, loadW: 7400)),
    _Card('EV charger (3φ)',
        PaletteLoad(LoadKind.evCharger, phases: 3, loadW: 22000)),
    _Card('Industrial socket (3φ)',
        PaletteLoad(LoadKind.socket, phases: 3, loadW: 7500)),
    _Card('UPS / IT load', PaletteLoad(LoadKind.ups, loadW: 3000)),
    _Card('Welding set (3φ)',
        PaletteLoad(LoadKind.welding, phases: 3, loadW: 8000)),
    _Card('Custom load (1φ)',
        PaletteLoad(LoadKind.general, phases: 1, loadW: 2000)),
    _Card('Custom load (3φ)',
        PaletteLoad(LoadKind.general, phases: 3, loadW: 7500)),
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
    final type = context.type;
    return Container(
      width: 188,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(right: BorderSide(color: colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(MechXSpacing.md, MechXSpacing.md,
                MechXSpacing.md, MechXSpacing.xs),
            child: Text('Loads',
                style: type.subtitle.copyWith(color: colors.textPrimary)),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: MechXSpacing.md),
            child: Text('Onto a panel to add a way; onto blank canvas to add it',
                style: type.caption.copyWith(color: colors.textMuted)),
          ),
          const SizedBox(height: MechXSpacing.sm),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(MechXSpacing.sm, 0,
                  MechXSpacing.sm, MechXSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final g in _groups) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(MechXSpacing.xs,
                          MechXSpacing.sm, 0, MechXSpacing.xs),
                      child: Text(g.title.toUpperCase(),
                          style: type.caption.copyWith(
                            color: colors.textMuted,
                            letterSpacing: 0.8,
                            fontWeight: FontWeight.w600,
                          )),
                    ),
                    for (final c in g.cards) _PaletteCard(card: c),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PaletteCard extends StatelessWidget {
  final _Card card;
  const _PaletteCard({required this.card});

  @override
  Widget build(BuildContext context) {
    final chrome = _chrome(context, dragging: false);
    return Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.xs),
      child: Draggable<PaletteLoad>(
        data: card.load,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _chrome(context, dragging: true),
        childWhenDragging: Opacity(opacity: 0.4, child: chrome),
        child: MouseRegion(cursor: SystemMouseCursors.grab, child: chrome),
      ),
    );
  }

  Widget _chrome(BuildContext context, {required bool dragging}) {
    final colors = context.colors;
    final type = context.type;
    final isSource = card.load.kind == LoadKind.feeder;
    final dot = isSource ? colors.success : colors.accent;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs + 1),
      decoration: BoxDecoration(
        color: dragging ? colors.surfaceHover : colors.background,
        borderRadius: MechXRadii.control,
        border: Border.all(color: dragging ? colors.accent : colors.border),
        boxShadow: dragging
            ? const [
                BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 10,
                    offset: Offset(0, 3)),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: MechXSpacing.xs + 2),
          Flexible(
            child: Text(card.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.label.copyWith(color: colors.textSecondary)),
          ),
        ],
      ),
    );
  }
}
