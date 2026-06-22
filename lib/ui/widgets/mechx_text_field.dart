import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// A minimal single-line text field built on [EditableText] (no Material).
class MechXTextField extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const MechXTextField({super.key, required this.value, required this.onChanged});

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
    return GestureDetector(
      onTap: _focusNode.requestFocus,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.sm,
          vertical: MechXSpacing.xs + 2,
        ),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: MechXRadii.control,
          border: Border.all(
            color: _focused ? colors.accent : colors.border,
          ),
        ),
        child: EditableText(
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
      ),
    );
  }
}
