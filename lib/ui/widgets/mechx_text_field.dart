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

  /// Fired when Enter is pressed (additive, I3). Distinct from [onCommitted]:
  /// this is an explicit ACTION trigger for a live per-keystroke field (which
  /// keeps [onChanged]) — e.g. the calibration card's "Set scale" or the offset
  /// dialog's "Create offset" — so typing a number + Enter works without a mouse
  /// trip to the primary button. It does NOT commit on blur (a Cancel/blur must
  /// not fire the action). Null ⇒ Enter has no effect (byte-identical).
  final VoidCallback? onSubmitted;

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

  /// Take the keyboard as soon as the field is mounted (F1, additive). The
  /// calibration card's "Known distance" field sets it so the two reference
  /// clicks flow straight into typing the length — and, because a focused
  /// field is what `isTextEntryFocused()` reports, the canvas's bare-digit
  /// tool/service shortcuts stand down for free while the number is typed.
  /// Defaults false ⇒ every existing caller is byte-identical.
  final bool autofocus;

  /// An externally owned focus node (additive). Supply it when the HOST needs
  /// to hand the keyboard back to this field after something else took it —
  /// the calibration card does, because every click on the canvas beneath it
  /// (re-placing a reference marker) pulls focus to the canvas. Null ⇒ the
  /// field owns and disposes its own node, exactly as before.
  final FocusNode? focusNode;

  const MechXTextField({
    super.key,
    required this.value,
    this.onChanged,
    this.onCommitted,
    this.onSubmitted,
    this.hint,
    this.textStyle,
    this.keyboardType,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  State<MechXTextField> createState() => _MechXTextFieldState();
}

class _MechXTextFieldState extends State<MechXTextField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);
  /// Created (and disposed) only when the caller supplied no
  /// [MechXTextField.focusNode] — a host-owned node is the host's to dispose.
  FocusNode? _ownFocusNode;
  bool _focused = false;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownFocusNode ??= FocusNode());

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
    // F1 — take the keyboard on mount. Deliberately an explicit post-frame
    // requestFocus rather than EditableText's own `autofocus`: a FocusScope
    // ignores an autofocus candidate when it ALREADY has a focused descendant,
    // and the field this exists for (the calibration card) mounts on a canvas
    // that grabs focus on every pointer-down — the click that placed the second
    // reference point. So the honest behaviour is "claim it", not "claim it if
    // nobody else did".
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
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
    widget.onSubmitted?.call();
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
    // A host swapping the external node re-homes the bookkeeping (no caller
    // does today; this keeps the additive param honest rather than silently
    // listening to a node that is no longer in use).
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _ownFocusNode)?.removeListener(_onFocusChange);
      _focusNode.addListener(_onFocusChange);
      if (widget.onCommitted != null) _focusNode.onKeyEvent = _onKeyEvent;
    }
    // Sync external value when we're not actively editing.
    if (widget.value != _controller.text && !_focusNode.hasFocus) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    // Only a node this state created is ours to dispose.
    _ownFocusNode?.dispose();
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
              onSubmitted:
                  (widget.onCommitted != null || widget.onSubmitted != null)
                      ? _onSubmitted
                      : null,
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
