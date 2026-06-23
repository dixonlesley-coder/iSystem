/// Shared electrical EDIT overlays — the circuit inspector drawer and the
/// panel / circuit right-click context menus — extracted so BOTH the standalone
/// electrical single-line view and the unified Layout canvas drive the same
/// editing surfaces over the one [ElectricalProject].
///
/// Pure presentation: every mutation routes through the supplied
/// [ElectricalProjectController]. Styled with MechXTheme — no Material.
library;

import 'package:flutter/widgets.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

import '../../store/electrical_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

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
    return _ContextMenu(items: [
      _MenuAction('Edit', onEdit),
      _MenuAction('Duplicate', () {
        controller.duplicateCircuit(target.panelId, target.circuitId);
        onDone();
      }),
      _MenuAction('Delete', () {
        controller.deleteCircuit(target.panelId, target.circuitId);
        onDone();
      }, danger: true),
    ]);
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
    return _ContextMenu(items: [
      _MenuAction('Open panel', onOpen),
      _MenuAction(
        panel.essential ? 'Unmark essential' : 'Mark essential',
        () {
          controller.setPanelEssential(panel.id, !panel.essential);
          onDone();
        },
      ),
      _MenuAction(
        panel.upsBacked ? 'Unmark critical (UPS)' : 'Mark critical (UPS)',
        () {
          controller.setPanelUpsBacked(panel.id, !panel.upsBacked);
          onDone();
        },
      ),
      _MenuAction(
        panel.submeter ? 'Remove submeter' : 'Add submeter',
        () {
          controller.setPanelSubmeter(panel.id, !panel.submeter);
          onDone();
        },
      ),
      if (panel.fedByCircuitId != null)
        _MenuAction('Disconnect feeder', () {
          controller.disconnectFeeder(panel.id);
          onDone();
        }),
      _MenuAction('Delete panel', () {
        controller.deletePanel(panel.id);
        onDone();
      }, danger: true),
    ]);
  }
}

class _MenuAction {
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const _MenuAction(this.label, this.onTap, {this.danger = false});
}

class _ContextMenu extends StatelessWidget {
  final List<_MenuAction> items;
  const _ContextMenu({required this.items});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 188,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
        boxShadow: const [
          BoxShadow(
              color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items)
            _MenuItem(label: item.label, onTap: item.onTap, danger: item.danger),
        ],
      ),
    );
  }
}

class _MenuItem extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const _MenuItem(
      {required this.label, required this.onTap, this.danger = false});

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm + 2, vertical: MechXSpacing.xs + 3),
          color: _hover ? colors.surfaceHover : const Color(0x00000000),
          child: Text(widget.label,
              style: type.body.copyWith(
                color: widget.danger ? colors.danger : colors.textPrimary,
              )),
        ),
      ),
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

    return Container(
      width: 340,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.border)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x22000000), blurRadius: 16, offset: Offset(-2, 0)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(MechXSpacing.md, MechXSpacing.md,
                MechXSpacing.sm, MechXSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text('Edit circuit',
                      style:
                          type.subtitle.copyWith(color: colors.textPrimary)),
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
                  _Field(
                    label: 'Name',
                    child: _Text(
                      value: circuit.name,
                      onChanged: (v) =>
                          controller.setCircuit(panel.id, circuit.id, name: v),
                    ),
                  ),
                  _Field(
                    label: 'Load kind',
                    child: _EnumPicker<LoadKind>(
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
                      onChanged: (k) =>
                          controller.setCircuit(panel.id, circuit.id, loadKind: k),
                    ),
                  ),
                  if (_isMotor)
                    _Field(
                      label: 'Motor power (kW)',
                      child: _Num(
                        value: circuit.motorKw ?? 0,
                        onChanged: (v) => controller.setCircuit(
                            panel.id, circuit.id,
                            motorKw: v),
                      ),
                    )
                  else
                    _Field(
                      label: 'Load (W)',
                      child: _Num(
                        value: circuit.loadW,
                        onChanged: (v) => controller.setCircuit(
                            panel.id, circuit.id,
                            loadW: v),
                      ),
                    ),
                  _Field(
                    label: 'cos phi',
                    child: _Num(
                      value: circuit.cosPhi,
                      onChanged: (v) => controller.setCircuit(
                          panel.id, circuit.id,
                          cosPhi: v.clamp(0.0, 1.0)),
                    ),
                  ),
                  _Field(
                    label: 'Demand factor',
                    child: _Num(
                      value: circuit.demandFactor,
                      onChanged: (v) => controller.setCircuit(
                          panel.id, circuit.id,
                          demandFactor: v.clamp(0.0, 1.0)),
                    ),
                  ),
                  _Field(
                    label: 'Run length (m)',
                    child: _Num(
                      value: circuit.length.meters,
                      onChanged: (v) => controller.setCircuit(
                          panel.id, circuit.id,
                          length: Length(v)),
                    ),
                  ),
                  _Field(
                    label: 'Supply phase',
                    child: _EnumPicker<int>(
                      value: circuit.phases ?? 0,
                      options: const [0, 1, 3],
                      label: (p) => switch (p) {
                        1 => '1-phase',
                        3 => '3-phase',
                        _ => 'Auto',
                      },
                      onChanged: (p) => p == 0
                          ? controller.setCircuit(panel.id, circuit.id,
                              clearPhases: true)
                          : controller.setCircuit(panel.id, circuit.id,
                              phases: p),
                    ),
                  ),
                  _Field(
                    label: 'Cable type',
                    child: _EnumPicker<String?>(
                      value: circuit.cableType,
                      options: _cableTypes,
                      label: (t) => t ?? 'Panel default',
                      onChanged: (t) => t == null
                          ? controller.setCircuit(panel.id, circuit.id,
                              clearCableType: true)
                          : controller.setCircuit(panel.id, circuit.id,
                              cableType: t),
                    ),
                  ),
                  _ToggleRow(
                    label: 'Lighting circuit (3% Vd limit)',
                    value: circuit.isLighting,
                    onChanged: (v) => controller.setCircuit(
                        panel.id, circuit.id,
                        isLighting: v),
                  ),
                  _ToggleRow(
                    label: 'Life-safety (no RCD)',
                    value: circuit.lifeSafety,
                    onChanged: (v) => controller.setCircuit(
                        panel.id, circuit.id,
                        lifeSafety: v),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Reused field primitives ─────────────────────────────────────────────────

class _Field extends StatelessWidget {
  final String label;
  final Widget child;
  const _Field({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label.toUpperCase(),
              style: type.caption.copyWith(
                color: colors.textMuted,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w600,
              )),
          const SizedBox(height: MechXSpacing.xs),
          child,
        ],
      ),
    );
  }
}

class _Text extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _Text({required this.value, required this.onChanged});

  @override
  State<_Text> createState() => _TextState();
}

class _TextState extends State<_Text> {
  late final TextEditingController _ctl =
      TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return GestureDetector(
      onTap: _focus.requestFocus,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs + 2),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: MechXRadii.control,
          border: Border.all(color: _focused ? colors.accent : colors.border),
        ),
        child: EditableText(
          controller: _ctl,
          focusNode: _focus,
          onChanged: widget.onChanged,
          maxLines: 1,
          style: type.body.copyWith(color: colors.textPrimary),
          cursorColor: colors.accent,
          backgroundCursorColor: colors.textMuted,
          cursorWidth: 1.5,
          selectionColor: colors.accentMuted,
        ),
      ),
    );
  }
}

class _Num extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;
  const _Num({required this.value, required this.onChanged});

  @override
  State<_Num> createState() => _NumState();
}

class _NumState extends State<_Num> {
  late final TextEditingController _ctl =
      TextEditingController(text: _fmt(widget.value));
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return GestureDetector(
      onTap: _focus.requestFocus,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs + 2),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: MechXRadii.control,
          border: Border.all(color: _focused ? colors.accent : colors.border),
        ),
        child: EditableText(
          controller: _ctl,
          focusNode: _focus,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (s) {
            final v = double.tryParse(s.trim());
            if (v != null) widget.onChanged(v);
          },
          maxLines: 1,
          style: type.mono.copyWith(color: colors.textPrimary),
          cursorColor: colors.accent,
          backgroundCursorColor: colors.textMuted,
          cursorWidth: 1.5,
          selectionColor: colors.accentMuted,
        ),
      ),
    );
  }
}

class _EnumPicker<T> extends StatelessWidget {
  final T value;
  final List<T> options;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  const _EnumPicker({
    required this.value,
    required this.options,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: MechXSpacing.xs,
      runSpacing: MechXSpacing.xs,
      children: [
        for (final o in options)
          _Chip(
            label: label(o),
            selected: o == value,
            onTap: () => onChanged(o),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs + 1),
          decoration: BoxDecoration(
            color: selected ? colors.accent : colors.background,
            borderRadius: MechXRadii.control,
            border: Border.all(color: selected ? colors.accent : colors.border),
          ),
          child: Text(label,
              style: type.label.copyWith(
                color: selected ? const Color(0xFFFFFFFF) : colors.textSecondary,
              )),
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.md),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: type.body.copyWith(color: colors.textSecondary)),
            ),
            const SizedBox(width: MechXSpacing.sm),
            AnimatedContainer(
              duration: MechXMotion.fast,
              width: 36,
              height: 20,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: value ? colors.accent : colors.border,
                borderRadius: const BorderRadius.all(Radius.circular(10)),
              ),
              child: Align(
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFFFFF),
                    shape: BoxShape.circle,
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

/// A small bordered text button (Close, etc.). Shared by the inspector + the
/// electrical view's drawers.
class ElectricalTextButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const ElectricalTextButton({super.key, required this.label, required this.onTap});

  @override
  State<ElectricalTextButton> createState() => _ElectricalTextButtonState();
}

class _ElectricalTextButtonState extends State<ElectricalTextButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: MechXMotion.fast,
          padding: const EdgeInsets.symmetric(
              horizontal: MechXSpacing.sm + 2, vertical: MechXSpacing.xs + 1),
          decoration: BoxDecoration(
            color: _hover ? colors.surfaceHover : const Color(0x00000000),
            borderRadius: MechXRadii.control,
            border: Border.all(color: colors.border),
          ),
          child: Text(widget.label,
              style: type.label.copyWith(color: colors.textSecondary)),
        ),
      ),
    );
  }
}
