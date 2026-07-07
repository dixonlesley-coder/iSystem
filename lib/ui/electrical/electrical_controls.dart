/// Shared electrical control primitives — the field/input/picker/toggle/menu
/// widgets used by BOTH the standalone single-line view (`electrical_view.dart`)
/// and the extracted inspector surfaces (`electrical_inspector.dart`), so the
/// two electrical entry points render the same controls and can never drift.
/// Styled with MechXTheme — no Material.
library;

import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/context_menu.dart';
import '../widgets/mechx_focus_ring.dart';
import '../widgets/mechx_segment.dart';
import '../widgets/mechx_text_field.dart';

/// A labelled field row: a quiet sentence-case caption over its [child] input.
class ElectricalField extends StatelessWidget {
  final String label;
  final Widget child;
  const ElectricalField({super.key, required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: MechXSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Quiet field label (secondary tier, sentence case) over the input —
          // the weight, not all-caps, carries the emphasis.
          Text(
            label,
            style: type.caption.copyWith(
              color: colors.textSecondary,
              letterSpacing: 0.05,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: MechXSpacing.xs),
          child,
        ],
      ),
    );
  }
}

/// A single-line text input — a thin wrapper over the canonical
/// [MechXTextField] so the focus-border + spread-ring fill style lives in one
/// place. Public API (`value`/`onChanged`) is unchanged.
///
/// COMMIT-ON-BLUR (G3): the edit is propagated to [onChanged] only when the
/// field loses focus or Enter is pressed (Esc cancels) — never per keystroke —
/// so a rename is ONE undo step rather than one per character. An unchanged edit
/// is a no-op (no spurious undo entry).
class ElectricalTextInput extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const ElectricalTextInput({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return MechXTextField(
      value: value,
      onCommitted: (s) {
        if (s != value) onChanged(s);
      },
    );
  }
}

/// A numeric input (mono, decimal keyboard) — the canonical [MechXTextField]
/// with a mono text style, a decimal keyboard, and a parse guard.
///
/// COMMIT-ON-BLUR (G3): the parsed value is propagated only on blur / Enter
/// (Esc cancels, restoring the displayed value), so typing `0.85` never
/// momentarily commits `0` (which would re-size the whole system) and each edit
/// is one undo step. Only a well-formed number that actually differs propagates.
///
/// C6 — 0-1 ratio fields (cos phi, demand/diversity factor) and the 0-100
/// percent field (headroom spare) used to render through this SAME bare
/// textbox with no unit suffix and no range enforcement, so a value typed in
/// the wrong scale (e.g. `85` meaning 85% into a 0-1 field) silently CLAMPED
/// to the boundary (1.0) with no signal the input was rejected. Two additive,
/// opt-in knobs fix this without touching any existing caller:
///  * [suffix] bakes an honest unit onto the at-rest display only (e.g. '%')
///    — never part of the editable text, so the parse guard is unaffected.
///  * [min]/[max], when BOTH set, turn a well-formed but out-of-range commit
///    into a REJECTION (not a clamp): [onChanged] is not called, the field
///    reverts to [value] (the existing MechXTextField blur-revert), and an
///    inline caption names the valid range — the same field-error idiom
///    `offset_dialog.dart` uses for its distance field.
class ElectricalNumInput extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final String? suffix;
  final double? min;
  final double? max;
  const ElectricalNumInput({
    super.key,
    required this.value,
    required this.onChanged,
    this.suffix,
    this.min,
    this.max,
  });

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  State<ElectricalNumInput> createState() => _ElectricalNumInputState();
}

class _ElectricalNumInputState extends State<ElectricalNumInput> {
  String? _error;

  @override
  Widget build(BuildContext context) {
    final type = context.type;
    final colors = context.colors;
    final field = MechXTextField(
      value: ElectricalNumInput._fmt(widget.value),
      textStyle: type.mono,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) {
        // Clear a stale rejection message as soon as the user edits again —
        // it described the PREVIOUS attempt, not the one in progress.
        if (_error != null) setState(() => _error = null);
      },
      onCommitted: (s) {
        final v = double.tryParse(s.trim());
        if (v == null) return;
        if (widget.min != null &&
            widget.max != null &&
            (v < widget.min! || v > widget.max!)) {
          setState(() => _error =
              'Enter a value between ${ElectricalNumInput._fmt(widget.min!)} '
              'and ${ElectricalNumInput._fmt(widget.max!)}');
          return;
        }
        if (v != widget.value) widget.onChanged(v);
      },
    );
    if (widget.suffix == null && _error == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.suffix == null)
          field
        else
          Row(
            children: [
              Expanded(child: field),
              const SizedBox(width: MechXSpacing.xs),
              Text(widget.suffix!,
                  style: type.caption.copyWith(color: colors.textMuted)),
            ],
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: MechXSpacing.xxs),
            child: Text(_error!,
                style: type.caption.copyWith(color: colors.danger)),
          ),
      ],
    );
  }
}

/// A wrap of selectable chips (tinted when selected) — the enum/option picker.
class ElectricalEnumPicker<T> extends StatelessWidget {
  final T value;
  final List<T> options;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  const ElectricalEnumPicker({
    super.key,
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
        // The shared selectable-segment vocabulary — accentMuted fill + accent
        // hairline + textPrimary (w600) when selected; textSecondary + no fill
        // otherwise — so the enum chips speak the same language as the tabs.
        for (final o in options)
          MechXSegment(
            label: label(o),
            selected: o == value,
            selectedWeight: FontWeight.w600,
            onTap: () => onChanged(o),
          ),
      ],
    );
  }
}

/// A labelled row with an iOS-style on/off switch.
class ElectricalToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const ElectricalToggleRow({
    super.key,
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
      // L3: this row drives every essential/UPS-backed/submeter/
      // dual-transformer/advanced-study toggle in the electrical inspectors —
      // wrap it in the shared focus ring so Tab reaches it and Enter/Space
      // fires the same toggle as a tap.
      child: MechXFocusRing(
        onActivated: () => onChanged(!value),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(!value),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: type.body.copyWith(color: colors.textSecondary),
                ),
              ),
              const SizedBox(width: MechXSpacing.sm),
              AnimatedContainer(
                duration: MechXMotion.fast,
                width: 36,
                height: 20,
                padding: const EdgeInsets.all(MechXSpacing.xxs),
                decoration: BoxDecoration(
                  color: value ? colors.accent : colors.border,
                  borderRadius: const BorderRadius.all(Radius.circular(10)),
                ),
                child: Align(
                  alignment:
                      value ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 16,
                    height: 16,
                    // White thumb is the correct iOS switch knob in BOTH modes:
                    // it reads on the accent (on) and on the border grey (off).
                    decoration: BoxDecoration(
                      color: colors.onAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A right-click context menu action.
class ElectricalMenuAction {
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const ElectricalMenuAction(this.label, this.onTap, {this.danger = false});
}

/// A floating context menu of [ElectricalMenuAction]s — the SHARED
/// [MechXContextMenu] chrome (the same panel/rows/entrance the mechanical
/// right-click menus use), at a fixed 188-px width to match the electrical
/// canvas. Each action maps to a [MechXMenuRow]; destructive actions use the
/// danger row variant.
class ElectricalMenu extends StatelessWidget {
  final List<ElectricalMenuAction> items;
  const ElectricalMenu({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 188,
      child: MechXContextMenu(
        children: [
          for (final item in items)
            MechXMenuRow(
              label: item.label,
              onTap: item.onTap,
              danger: item.danger,
            ),
        ],
      ),
    );
  }
}

