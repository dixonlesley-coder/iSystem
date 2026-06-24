import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// A minimal single-line text field built on [EditableText] (no Material).
class MechXTextField extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;

  /// Optional placeholder shown (in the muted tier) when the field is empty and
  /// unfocused — an Apple-style affordance for what belongs here.
  final String? hint;

  const MechXTextField({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
  });

  @override
  State<MechXTextField> createState() => _MechXTextFieldState();
}

class _MechXTextFieldState extends State<MechXTextField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() => setState(() => _focused = _focusNode.hasFocus);

  @override
  void didUpdateWidget(MechXTextField old) {
    super.didUpdateWidget(old);
    // Sync external value when we're not actively editing.
    if (widget.value != _controller.text && !_focusNode.hasFocus) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final showHint =
        widget.hint != null && _controller.text.isEmpty && !_focused;
    return GestureDetector(
      onTap: _focusNode.requestFocus,
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
            // Soft accent tint at rest of focus, full accent when focused.
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
        child: Stack(
          children: [
            EditableText(
              controller: _controller,
              focusNode: _focusNode,
              onChanged: widget.onChanged,
              maxLines: 1,
              style: type.body.copyWith(color: colors.textPrimary),
              cursorColor: colors.accent,
              backgroundCursorColor: colors.textMuted,
              cursorWidth: 1.5,
              selectionColor: colors.accentMuted,
            ),
            if (showHint)
              IgnorePointer(
                child: Text(
                  widget.hint!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.body.copyWith(color: colors.textMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
