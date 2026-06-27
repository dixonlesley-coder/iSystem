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
    return MechXTextField(value: value, onChanged: onChanged);
  }
}

/// A numeric input (mono, decimal keyboard) — the canonical [MechXTextField]
/// with a mono text style, a decimal keyboard, and a parse guard wrapping
/// `onChanged` (only well-formed numbers propagate). Public API
/// (`value`/`onChanged(double)`) and parse behaviour are unchanged.
class ElectricalNumInput extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  const ElectricalNumInput({
    super.key,
    required this.value,
    required this.onChanged,
  });

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    final type = context.type;
    return MechXTextField(
      value: _fmt(value),
      textStyle: type.mono,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (s) {
        final v = double.tryParse(s.trim());
        if (v != null) onChanged(v);
      },
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
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
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

