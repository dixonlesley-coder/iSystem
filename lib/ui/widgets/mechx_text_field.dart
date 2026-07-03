import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

/// A minimal single-line text field built on [EditableText] (no Material).
class MechXTextField extends StatefulWidget {
  final String value;

  /// Called live on every keystroke (the default edit mode). Optional so a
  /// commit-on-blur field (see [onCommitted]) can omit it. Existing callers pass
  /// it and are unaffected.
  final ValueChanged<String>? onChanged;

  /// COMMIT-ON-BLUR / -SUBMIT mode (additive). When non-null the edit is
  /// propagated ONLY when the field loses focus or Enter is pressed — never per
  /// keystroke — so a rename is one undo step and a partially-typed number never
  /// commits an intermediate value. Esc cancels the pending edit (reverting to
  /// [value]). Leaving it null keeps the original live per-keystroke behaviour,
  /// so every existing caller is byte-identical.
  final ValueChanged<String>? onCommitted;

  /// Optional placeholder shown (in the muted tier) when the field is empty and
  /// unfocused — an Apple-style affordance for what belongs here.
  final String? hint;

  /// Optional override for the editing text style. Defaults to `type.body`
  /// (the standard field text); pass `type.mono` for a numeric field. The
  /// colour is applied to whatever is given.
  final TextStyle? textStyle;

  /// Optional keyboard type (e.g. decimal numeric). Defaults to null (the
  /// platform default text keyboard) so unspecified callers are unaffected.
  final TextInputType? keyboardType;

  const MechXTextField({
    super.key,
    required this.value,
    this.onChanged,
    this.onCommitted,
    this.hint,
    this.textStyle,
    this.keyboardType,
  });

  @override
  State<MechXTextField> createState() => _MechXTextFieldState();
}

class _MechXTextFieldState extends State<MechXTextField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;

  /// Commit-on-blur bookkeeping: has the text been edited since the last commit
  /// / external value? Only consulted when [MechXTextField.onCommitted] is set.
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    // Esc cancels a pending commit-on-blur edit. Installed ONLY in commit mode
    // so a live per-keystroke field's focus node stays untouched (byte-identical
    // — a null onKeyEvent, exactly as before).
    if (widget.onCommitted != null) {
      _focusNode.onKeyEvent = _onKeyEvent;
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      // Discard the pending edit, restore the last committed value, and blur.
      _controller.text = widget.value;
      _dirty = false;
      node.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _commitIfDirty() {
    if (widget.onCommitted != null && _dirty) {
      _dirty = false;
      widget.onCommitted!(_controller.text);
    }
  }

  void _onSubmitted(String _) {
    _commitIfDirty();
    _focusNode.unfocus();
  }

  void _onFocusChange() {
    final hasFocus = _focusNode.hasFocus;
    if (!hasFocus && widget.onCommitted != null) {
      _commitIfDirty();
      // Always re-display the canonical value on blur: a rejected/partial edit
      // reverts, and a valid commit re-supplies the new value via
      // didUpdateWidget on the next build.
      if (_controller.text != widget.value) {
        _controller.text = widget.value;
      }
    }
    setState(() => _focused = hasFocus);
  }

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
    final baseStyle = widget.textStyle ?? type.body;
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
              onChanged: (s) {
                // In commit mode we defer propagation to blur/submit; still
                // track that the text changed so an unedited blur is a no-op.
                if (widget.onCommitted != null) _dirty = true;
                widget.onChanged?.call(s);
              },
              onSubmitted: widget.onCommitted != null ? _onSubmitted : null,
              keyboardType: widget.keyboardType,
              maxLines: 1,
              style: baseStyle.copyWith(color: colors.textPrimary),
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
