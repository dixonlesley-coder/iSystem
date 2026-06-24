/// Shared electrical EDIT overlays — the circuit inspector drawer and the
/// panel / circuit right-click context menus — extracted so BOTH the standalone
/// electrical single-line view and the unified Layout canvas drive the same
/// editing surfaces over the one [ElectricalProject].
///
/// Pure presentation: every mutation routes through the supplied
/// [ElectricalProjectController]. The control primitives live in
/// `electrical_controls.dart` (shared with the single-line view). Styled with
/// MechXTheme — no Material.
library;

import 'package:flutter/widgets.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

import '../../store/electrical_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'electrical_controls.dart';

export 'electrical_controls.dart' show ElectricalTextButton;

/// Identifies a circuit being edited / menu'd (panel + circuit id).
class ElectricalEditTarget {
  final String panelId;
  final String circuitId;
  const ElectricalEditTarget(this.panelId, this.circuitId);
}

/// Identifies a panel right-click menu.
class ElectricalPanelMenuTarget {
  final String panelId;
  const ElectricalPanelMenuTarget(this.panelId);
}

// ── Context menus ─────────────────────────────────────────────────────────────

/// Circuit right-click menu: Edit / Duplicate / Delete.
class ElectricalCircuitMenu extends StatelessWidget {
  final ElectricalEditTarget target;
  final ElectricalProjectController controller;
  final VoidCallback onEdit;
  final VoidCallback onDone;
  const ElectricalCircuitMenu({
    super.key,
    required this.target,
    required this.controller,
    required this.onEdit,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return ElectricalMenu(
      items: [
        ElectricalMenuAction('Edit', onEdit),
        ElectricalMenuAction('Duplicate', () {
          controller.duplicateCircuit(target.panelId, target.circuitId);
          onDone();
        }),
        ElectricalMenuAction('Delete', () {
          controller.deleteCircuit(target.panelId, target.circuitId);
          onDone();
        }, danger: true),
      ],
    );
  }
}

/// Panel right-click menu: Open / essential / critical / submeter / disconnect /
/// delete. Mirrors the electrical single-line canvas's panel menu.
class ElectricalPanelMenu extends StatelessWidget {
  final ElectricalPanel panel;
  final ElectricalProjectController controller;
  final VoidCallback onOpen;
  final VoidCallback onDone;
  const ElectricalPanelMenu({
    super.key,
    required this.panel,
    required this.controller,
    required this.onOpen,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return ElectricalMenu(
      items: [
        ElectricalMenuAction('Open panel', onOpen),
        ElectricalMenuAction(
          panel.essential ? 'Unmark essential' : 'Mark essential',
          () {
            controller.setPanelEssential(panel.id, !panel.essential);
            onDone();
          },
        ),
        ElectricalMenuAction(
          panel.upsBacked ? 'Unmark critical (UPS)' : 'Mark critical (UPS)',
          () {
            controller.setPanelUpsBacked(panel.id, !panel.upsBacked);
            onDone();
          },
        ),
        ElectricalMenuAction(
            panel.submeter ? 'Remove submeter' : 'Add submeter', () {
          controller.setPanelSubmeter(panel.id, !panel.submeter);
          onDone();
        }),
        if (panel.fedByCircuitId != null)
          ElectricalMenuAction('Disconnect feeder', () {
            controller.disconnectFeeder(panel.id);
            onDone();
          }),
        ElectricalMenuAction('Delete panel', () {
          controller.deletePanel(panel.id);
          onDone();
        }, danger: true),
      ],
    );
  }
}

// ── Circuit inspector (the Wave-4 drawer) ───────────────────────────────────

class ElectricalCircuitInspector extends StatelessWidget {
  final ElectricalPanel panel;
  final ElectricalCircuit circuit;
  final ElectricalProjectController controller;
  final VoidCallback onClose;

  const ElectricalCircuitInspector({
    super.key,
    required this.panel,
    required this.circuit,
    required this.controller,
    required this.onClose,
  });

  static const _cableTypes = <String?>[
    null,
    'NYY',
    'NYM',
    'NYA',
    'NYAF',
    'FRC',
  ];

  bool get _isMotor =>
      circuit.loadKind == LoadKind.motor || circuit.loadKind == LoadKind.pump;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    // Slide-in from the right + fade on open (and on switching circuits, since
    // the host keys this by panel/circuit), matching the iOS sheet idiom.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: MechXMotion.appear,
      curve: MechXMotion.standard,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(340 * (1 - t), 0),
          child: child,
        ),
      ),
      child: Container(
        width: 340,
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(left: BorderSide(color: colors.border)),
          boxShadow: MechXShadow.popover,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MechXSpacing.md,
                MechXSpacing.md,
                MechXSpacing.sm,
                MechXSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Edit circuit',
                      style: type.subtitle.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  ElectricalTextButton(label: 'Close', onTap: onClose),
                ],
              ),
            ),
            Container(height: 1, color: colors.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(MechXSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ElectricalField(
                      label: 'Name',
                      child: ElectricalTextInput(
                        value: circuit.name,
                        onChanged: (v) => controller.setCircuit(
                          panel.id,
                          circuit.id,
                          name: v,
                        ),
                      ),
                    ),
                    ElectricalField(
                      label: 'Load kind',
                      child: ElectricalEnumPicker<LoadKind>(
                        value: circuit.loadKind,
                        options: const [
                          LoadKind.general,
                          LoadKind.lighting,
                          LoadKind.socket,
                          LoadKind.hvac,
                          LoadKind.motor,
                          LoadKind.pump,
                          LoadKind.heating,
                          LoadKind.ups,
                          LoadKind.evCharger,
                          LoadKind.welding,
                          LoadKind.spare,
                        ],
                        label: (k) => loadDefaults[k]?.label ?? k.name,
                        onChanged: (k) => controller.setCircuit(
                          panel.id,
                          circuit.id,
                          loadKind: k,
                        ),
                      ),
                    ),
                    if (_isMotor)
                      ElectricalField(
                        label: 'Motor power (kW)',
                        child: ElectricalNumInput(
                          value: circuit.motorKw ?? 0,
                          onChanged: (v) => controller.setCircuit(
                            panel.id,
                            circuit.id,
                            motorKw: v,
                          ),
                        ),
                      )
                    else
                      ElectricalField(
                        label: 'Load (W)',
                        child: ElectricalNumInput(
                          value: circuit.loadW,
                          onChanged: (v) => controller.setCircuit(
                            panel.id,
                            circuit.id,
                            loadW: v,
                          ),
                        ),
                      ),
                    ElectricalField(
                      label: 'cos phi',
                      child: ElectricalNumInput(
                        value: circuit.cosPhi,
                        onChanged: (v) => controller.setCircuit(
                          panel.id,
                          circuit.id,
                          cosPhi: v.clamp(0.0, 1.0),
                        ),
                      ),
                    ),
                    ElectricalField(
                      label: 'Demand factor',
                      child: ElectricalNumInput(
                        value: circuit.demandFactor,
                        onChanged: (v) => controller.setCircuit(
                          panel.id,
                          circuit.id,
                          demandFactor: v.clamp(0.0, 1.0),
                        ),
                      ),
                    ),
                    ElectricalField(
                      label: 'Run length (m)',
                      child: ElectricalNumInput(
                        value: circuit.length.meters,
                        onChanged: (v) => controller.setCircuit(
                          panel.id,
                          circuit.id,
                          length: Length(v),
                        ),
                      ),
                    ),
                    ElectricalField(
                      label: 'Supply phase',
                      child: ElectricalEnumPicker<int>(
                        value: circuit.phases ?? 0,
                        options: const [0, 1, 3],
                        label: (p) => switch (p) {
                          1 => '1-phase',
                          3 => '3-phase',
                          _ => 'Auto',
                        },
                        onChanged: (p) => p == 0
                            ? controller.setCircuit(
                                panel.id,
                                circuit.id,
                                clearPhases: true,
                              )
                            : controller.setCircuit(
                                panel.id,
                                circuit.id,
                                phases: p,
                              ),
                      ),
                    ),
                    ElectricalField(
                      label: 'Cable type',
                      child: ElectricalEnumPicker<String?>(
                        value: circuit.cableType,
                        options: _cableTypes,
                        label: (t) => t ?? 'Panel default',
                        onChanged: (t) => t == null
                            ? controller.setCircuit(
                                panel.id,
                                circuit.id,
                                clearCableType: true,
                              )
                            : controller.setCircuit(
                                panel.id,
                                circuit.id,
                                cableType: t,
                              ),
                      ),
                    ),
                    ElectricalToggleRow(
                      label: 'Lighting circuit (3% Vd limit)',
                      value: circuit.isLighting,
                      onChanged: (v) => controller.setCircuit(
                        panel.id,
                        circuit.id,
                        isLighting: v,
                      ),
                    ),
                    ElectricalToggleRow(
                      label: 'Life-safety (no RCD)',
                      value: circuit.lifeSafety,
                      onChanged: (v) => controller.setCircuit(
                        panel.id,
                        circuit.id,
                        lifeSafety: v,
                      ),
                    ),
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
