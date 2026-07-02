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
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

import '../../store/electrical_store.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import 'electrical_controls.dart';

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
        ElectricalMenuAction(
            context.strings(StringKey.electricalMenuEdit), onEdit),
        ElectricalMenuAction(context.strings(StringKey.electricalMenuDuplicate),
            () {
          controller.duplicateCircuit(target.panelId, target.circuitId);
          onDone();
        }),
        ElectricalMenuAction(context.strings(StringKey.electricalMenuDelete),
            () {
          controller.deleteCircuit(target.panelId, target.circuitId);
          onDone();
        }, danger: true),
      ],
    );
  }
}

/// Panel right-click menu: properties / open / essential / critical / submeter /
/// disconnect / delete. Mirrors the electrical single-line canvas's panel menu.
class ElectricalPanelMenu extends StatelessWidget {
  final ElectricalPanel panel;
  final ElectricalProjectController controller;
  final VoidCallback onProperties;
  final VoidCallback onOpen;
  final VoidCallback onDone;
  const ElectricalPanelMenu({
    super.key,
    required this.panel,
    required this.controller,
    required this.onProperties,
    required this.onOpen,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return ElectricalMenu(
      items: [
        ElectricalMenuAction(
            context.strings(StringKey.electricalPanelProperties), onProperties),
        ElectricalMenuAction(
            context.strings(StringKey.electricalMenuOpenPanel), onOpen),
        ElectricalMenuAction(
          context.strings(panel.essential
              ? StringKey.electricalMenuUnmarkEssential
              : StringKey.electricalMenuMarkEssential),
          () {
            controller.setPanelEssential(panel.id, !panel.essential);
            onDone();
          },
        ),
        ElectricalMenuAction(
          context.strings(panel.upsBacked
              ? StringKey.electricalMenuUnmarkCritical
              : StringKey.electricalMenuMarkCritical),
          () {
            controller.setPanelUpsBacked(panel.id, !panel.upsBacked);
            onDone();
          },
        ),
        ElectricalMenuAction(
            context.strings(panel.submeter
                ? StringKey.electricalMenuRemoveSubmeter
                : StringKey.electricalMenuAddSubmeter), () {
          controller.setPanelSubmeter(panel.id, !panel.submeter);
          onDone();
        }),
        // Duplicate the whole board (fresh ids, undoable — I5).
        ElectricalMenuAction(
            context.strings(StringKey.electricalMenuDuplicatePanel), () {
          controller.duplicatePanel(panel.id);
          onDone();
        }),
        if (panel.fedByCircuitId != null)
          ElectricalMenuAction(
              context.strings(StringKey.electricalMenuDisconnectFeeder), () {
            controller.disconnectFeeder(panel.id);
            onDone();
          }),
        ElectricalMenuAction(
            context.strings(StringKey.electricalMenuDeletePanel), () {
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
                      context.strings(StringKey.electricalCircuitEditTitle),
                      style: type.title.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  MechXButton(
                    label: context.strings(StringKey.electricalClose),
                    tertiary: true,
                    onPressed: onClose,
                  ),
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
                      label: context.strings(StringKey.electricalFieldName),
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
                      label: context.strings(StringKey.electricalFieldLoadKind),
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
                        label:
                            context.strings(StringKey.electricalFieldMotorPower),
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
                        label: context.strings(StringKey.electricalFieldLoadW),
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
                      label: context.strings(StringKey.electricalFieldCosPhi),
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
                      label:
                          context.strings(StringKey.electricalFieldDemandFactor),
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
                      label: context.strings(StringKey.electricalFieldRunLength),
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
                      label:
                          context.strings(StringKey.electricalFieldSupplyPhase),
                      child: ElectricalEnumPicker<int>(
                        value: circuit.phases ?? 0,
                        options: const [0, 1, 3],
                        label: (p) => switch (p) {
                          1 => context.strings(StringKey.electricalPhase1),
                          3 => context.strings(StringKey.electricalPhase3),
                          _ => context.strings(StringKey.electricalPhaseAuto),
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
                      label: context.strings(StringKey.electricalFieldCableType),
                      child: ElectricalEnumPicker<String?>(
                        value: circuit.cableType,
                        options: _cableTypes,
                        label: (t) =>
                            t ?? context.strings(StringKey.electricalCablePanelDefault),
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
                      label: context.strings(StringKey.electricalToggleLighting),
                      value: circuit.isLighting,
                      onChanged: (v) => controller.setCircuit(
                        panel.id,
                        circuit.id,
                        isLighting: v,
                      ),
                    ),
                    ElectricalToggleRow(
                      label:
                          context.strings(StringKey.electricalToggleLifeSafety),
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

// ── Panel inspector (the I3 properties drawer) ───────────────────────────────

/// The panel PROPERTIES drawer — name / tag / diversity / headroom (spare % +
/// CADANGAN spare ways) / supply flags — opened on panel double-click or the
/// 'Panel properties' context-menu row. Same 340-px right-drawer idiom as
/// [ElectricalCircuitInspector]; every edit routes through the controller's
/// undoable intents.
class ElectricalPanelInspector extends StatelessWidget {
  final ElectricalPanel panel;
  final ElectricalProjectController controller;
  final VoidCallback onClose;

  const ElectricalPanelInspector({
    super.key,
    required this.panel,
    required this.controller,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final headroom = panel.headroom ?? HeadroomSpec.none;

    // Slide-in from the right + fade on open (host keys this by panel), the
    // same iOS sheet idiom as the circuit inspector.
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
                      context.strings(StringKey.electricalPanelProperties),
                      style: type.title.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  MechXButton(
                    label: context.strings(StringKey.electricalClose),
                    tertiary: true,
                    onPressed: onClose,
                  ),
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
                      label: context.strings(StringKey.electricalFieldName),
                      child: ElectricalTextInput(
                        value: panel.name,
                        onChanged: (v) => controller.renamePanel(panel.id, v),
                      ),
                    ),
                    ElectricalField(
                      label: context.strings(StringKey.electricalFieldTag),
                      child: ElectricalTextInput(
                        value: panel.tag ?? '',
                        onChanged: (v) => controller.setPanelTag(panel.id, v),
                      ),
                    ),
                    ElectricalField(
                      label: context.strings(StringKey.electricalFieldDiversity),
                      child: ElectricalNumInput(
                        value: panel.diversityFactor,
                        onChanged: (v) => controller.setPanelDiversity(
                          panel.id,
                          v.clamp(0.0, 1.0),
                        ),
                      ),
                    ),
                    ElectricalField(
                      label: context
                          .strings(StringKey.electricalFieldHeadroomSpare),
                      child: ElectricalNumInput(
                        value: headroom.sparePercentage,
                        onChanged: (v) => controller.setPanelHeadroom(
                          panel.id,
                          HeadroomSpec(
                            sparePercentage: v.clamp(0.0, 100.0),
                            spareWays: headroom.spareWays,
                          ),
                        ),
                      ),
                    ),
                    ElectricalField(
                      label: context.strings(StringKey.electricalFieldSpareWays),
                      child: ElectricalNumInput(
                        value: headroom.spareWays.toDouble(),
                        onChanged: (v) => controller.setPanelHeadroom(
                          panel.id,
                          HeadroomSpec(
                            sparePercentage: headroom.sparePercentage,
                            spareWays: v.round().clamp(0, 60),
                          ),
                        ),
                      ),
                    ),
                    ElectricalToggleRow(
                      label:
                          context.strings(StringKey.electricalToggleEssential),
                      value: panel.essential,
                      onChanged: (v) =>
                          controller.setPanelEssential(panel.id, v),
                    ),
                    ElectricalToggleRow(
                      label: context.strings(StringKey.electricalToggleCritical),
                      value: panel.upsBacked,
                      onChanged: (v) =>
                          controller.setPanelUpsBacked(panel.id, v),
                    ),
                    ElectricalToggleRow(
                      label: context.strings(StringKey.electricalToggleSubmeter),
                      value: panel.submeter,
                      onChanged: (v) =>
                          controller.setPanelSubmeter(panel.id, v),
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
