/// Shared electrical control primitives — the field/input/picker/toggle/menu
/// widgets used by BOTH the standalone single-line view (`electrical_view.dart`)
/// and the extracted inspector surfaces (`electrical_inspector.dart`), so the
/// two electrical entry points render the same controls and can never drift.
/// Styled with MechXTheme — no Material.
library;

import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

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

/// A single-line text input with the shared focus-border + spread-ring.
class ElectricalTextInput extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const ElectricalTextInput({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  State<ElectricalTextInput> createState() => _ElectricalTextInputState();
}

class _ElectricalTextInputState extends State<ElectricalTextInput> {
  late final TextEditingController _ctl = TextEditingController(
    text: widget.value,
  );
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
      child: AnimatedContainer(
        duration: MechXMotion.hover,
        curve: MechXMotion.standard,
        padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.sm,
          vertical: MechXSpacing.xs + 2,
        ),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: MechXRadii.control,
          border: Border.all(
            color: _focused ? colors.accent : colors.border,
            width: _focused ? 1.5 : 1.0,
          ),
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: colors.accent.withAlpha(60),
                    blurRadius: 0,
                    spreadRadius: 2,
                  ),
                ]
              : null,
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

/// A numeric input (mono, decimal keyboard) with the shared focus treatment.
class ElectricalNumInput extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;
  const ElectricalNumInput({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  State<ElectricalNumInput> createState() => _ElectricalNumInputState();
}

class _ElectricalNumInputState extends State<ElectricalNumInput> {
  late final TextEditingController _ctl = TextEditingController(
    text: _fmt(widget.value),
  );
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
      child: AnimatedContainer(
        duration: MechXMotion.hover,
        curve: MechXMotion.standard,
        padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.sm,
          vertical: MechXSpacing.xs + 2,
        ),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: MechXRadii.control,
          border: Border.all(
            color: _focused ? colors.accent : colors.border,
            width: _focused ? 1.5 : 1.0,
          ),
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: colors.accent.withAlpha(60),
                    blurRadius: 0,
                    spreadRadius: 2,
                  ),
                ]
              : null,
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
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    // Selected = the iOS tinted-fill chip (accentMuted + accent hairline +
    // textPrimary label), matching the tab + button selected language. This
    // keeps the label on a light tint at well above 4.5:1, instead of small
    // white text on the systemBlue accent (which is borderline for AA).
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: MechXMotion.hover,
          curve: MechXMotion.standard,
          padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm,
            vertical: MechXSpacing.xs + 1,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.accentMuted : colors.background,
            borderRadius: MechXRadii.control,
            border: Border.all(color: selected ? colors.accent : colors.border),
          ),
          child: Text(
            label,
            style: type.label.copyWith(
              color: selected ? colors.textPrimary : colors.textSecondary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
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

/// A floating context menu (grow-from-top-left on open) of [ElectricalMenuAction]s.
class ElectricalMenu extends StatelessWidget {
  final List<ElectricalMenuAction> items;
  const ElectricalMenu({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // Grow-from-top-left scale + fade on open, like a native context menu.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: MechXMotion.dismiss,
      curve: MechXMotion.standard,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(
          scale: 0.94 + 0.06 * t,
          alignment: Alignment.topLeft,
          child: child,
        ),
      ),
      child: Container(
        width: 188,
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: MechXRadii.control,
          border: Border.all(color: colors.border),
          boxShadow: MechXShadow.popover,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in items)
              _MenuItem(
                label: item.label,
                onTap: item.onTap,
                danger: item.danger,
              ),
          ],
        ),
      ),
    );
  }
}

class _MenuItem extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const _MenuItem({
    required this.label,
    required this.onTap,
    this.danger = false,
  });

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
        child: AnimatedContainer(
          duration: MechXMotion.hover,
          curve: MechXMotion.standard,
          padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm + 2,
            vertical: MechXSpacing.xs + 3,
          ),
          color: _hover ? colors.surfaceHover : const Color(0x00000000),
          child: Text(
            widget.label,
            style: type.body.copyWith(
              color: widget.danger ? colors.danger : colors.textPrimary,
            ),
          ),
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
  const ElectricalTextButton({
    super.key,
    required this.label,
    required this.onTap,
  });

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
            horizontal: MechXSpacing.sm + 2,
            vertical: MechXSpacing.xs + 1,
          ),
          decoration: BoxDecoration(
            color: _hover ? colors.surfaceHover : const Color(0x00000000),
            borderRadius: MechXRadii.control,
            border: Border.all(color: colors.border),
          ),
          child: Text(
            widget.label,
            style: type.label.copyWith(color: colors.textSecondary),
          ),
        ),
      ),
    );
  }
}
