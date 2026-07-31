import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'mechx_focus_ring.dart';

/// A shared numeric stepper: a `−` / `+` glyph-button pair flanking a mono
/// value, with two ergonomics the hand-rolled inspector rows lacked —
///
///  * **Type-in** — clicking (or keyboard-activating) the value swaps it for an
///    inline editor seeded with [editSeed]; it parses on commit, clamps to
///    [min]/[max], commits on Enter **or** blur, and cancels on Esc (reverting
///    to the prior value). An empty field commits `null` via [onSubmit] so the
///    caller can reset to a default.
///  * **Hold-to-repeat** — press-and-holding a glyph fires [onDecrement] /
///    [onIncrement] repeatedly (a [Timer] started on long-press, then every
///    [repeatInterval]); a quick tap fires exactly once.
///
/// **At rest it renders exactly like the hand-rolled `_GlyphButton` row it
/// replaces** (same glyphs, spacing, typography). The layout knobs ([gap],
/// [valueWidth], [valueAlign], [valueColor]) let each call site reproduce its
/// original row pixel-for-pixel, so the goldens are unchanged. The inline editor
/// only appears while the user is actively typing (never in the golden state).
class SteppedValueField extends StatefulWidget {
  /// The formatted, at-rest display string (unit + any suffix), e.g.
  /// `'3.00 m'`, `'1500 L'`, `'default'`, `'—'`.
  final String display;

  /// The bare number to seed the inline editor when the value is clicked (no
  /// unit / suffix), e.g. `'3.00'`, `'1500'`. Empty ⇒ the editor starts blank.
  final String editSeed;

  /// Fired once per tap on `−`, and repeatedly while it is held. Null ⇒ the
  /// `−` glyph is disabled (dimmed, no repeat), matching `_GlyphButton`.
  final VoidCallback? onDecrement;

  /// Fired once per tap on `+`, and repeatedly while it is held. Null ⇒ disabled.
  final VoidCallback? onIncrement;

  /// Commits a typed value, or `null` when the field was left empty (the caller
  /// decides what a reset means). NOT called when the text fails to parse or
  /// falls outside [min]/[max] — the edit is REJECTED with an inline message
  /// (G7) and the editor stays open on the engineer's own text.
  final ValueChanged<double?> onSubmit;

  /// Optional inclusive bounds for a TYPED value. A typed value outside them is
  /// rejected with a message (G7 — it used to be silently clamped, so "600"
  /// could be typed and "1000" read back with nothing said). The `−`/`+`
  /// steppers keep their own contract: they clamp silently, because a stepper
  /// walking into its own limit is the limit doing its job, not a rejected
  /// input (the caller does that clamping in [onDecrement]/[onIncrement]).
  final double? min;
  final double? max;

  /// Horizontal spacing between each glyph and the value. Match the original
  /// row: `xs` (rainfall/runoff), `sm` (capacity/load/height/airflow/roof), or
  /// `0` (the fixed-width ceiling/ACH/depth rows).
  final double gap;

  /// Fixed width of the value slot (the `SizedBox(width: 56)` centred rows). Null
  /// ⇒ the value sizes to its content (the inline rows).
  final double? valueWidth;

  /// Text alignment of the value (centre for the fixed-width rows, else start).
  final TextAlign valueAlign;

  /// Colour of the at-rest value. Null ⇒ `colors.textSecondary` (the common
  /// case); the fixed-width rows pass `colors.textPrimary`.
  final Color? valueColor;

  /// Interval between repeated fires while a glyph is held down.
  final Duration repeatInterval;

  /// L4 (a11y): the field's own human name (e.g. `'Ceiling height'`), used ONLY
  /// to name the `−` / `+` glyph buttons for a screen reader — a dense inspector
  /// otherwise announces an undifferentiated run of "minus, plus" with no way to
  /// tell which numeric row each belongs to. When set, the buttons announce
  /// "Decrease {label}" / "Increase {label}"; null ⇒ the generic "Decrease" /
  /// "Increase". Visual layout is untouched (the glyph's own char is hidden from
  /// semantics), so goldens are unaffected.
  final String? label;

  const SteppedValueField({
    super.key,
    required this.display,
    required this.editSeed,
    required this.onDecrement,
    required this.onIncrement,
    required this.onSubmit,
    this.min,
    this.max,
    this.gap = MechXSpacing.sm,
    this.valueWidth,
    this.valueAlign = TextAlign.start,
    this.valueColor,
    this.repeatInterval = const Duration(milliseconds: 120),
    this.label,
  });

  @override
  State<SteppedValueField> createState() => _SteppedValueFieldState();
}

class _SteppedValueFieldState extends State<SteppedValueField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _editFocus = FocusNode();
  bool _editing = false;
  bool _cancelled = false;

  /// G7 — the rejection message for the LAST commit attempt, shown beneath the
  /// editor while the engineer's own text stays put. Null at rest (and at every
  /// successful commit), so the at-rest layout is byte-identical.
  String? _error;

  /// The same compact number formatting the electrical fields use, so the two
  /// reject messages read identically ('between 0.5 and 10', not '0.5 and
  /// 10.0').
  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  /// The bounds message for a typed value outside [min]/[max]. Mirrors
  /// ElectricalNumInput's wording when both bounds exist; a one-sided bound
  /// names the side it violated rather than pretending there is a range.
  String _rangeMessage() {
    final min = widget.min;
    final max = widget.max;
    if (min != null && max != null) {
      return 'Enter a value between ${_fmt(min)} and ${_fmt(max)}';
    }
    if (min != null) return 'Enter a value of ${_fmt(min)} or more';
    return 'Enter a value of ${_fmt(max!)} or less';
  }

  @override
  void initState() {
    super.initState();
    _editFocus.addListener(_onEditFocusChange);
  }

  @override
  void dispose() {
    _editFocus.removeListener(_onEditFocusChange);
    _controller.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _onEditFocusChange() {
    // Commit on blur (unless the edit was cancelled via Esc, which already
    // tore down the editor).
    if (!_editFocus.hasFocus && _editing && !_cancelled) _commit();
  }

  void _beginEdit() {
    setState(() {
      _editing = true;
      _cancelled = false;
      _error = null;
      _controller.text = widget.editSeed;
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _editFocus.requestFocus();
    });
  }

  void _commit() {
    if (!_editing) return;
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _editing = false;
        _error = null;
      });
      widget.onSubmit(null);
      return;
    }
    final parsed = double.tryParse(raw);
    // Unparseable OR non-finite ⇒ REJECT with a message (G7); it used to revert
    // silently, so a typo read as "the app ate my number". double.tryParse
    // accepts 'NaN'/'Infinity'/'1e999', and NaN slips through a `< min / > max`
    // comparison (both are false) — it must never reach a store.
    if (parsed == null || !parsed.isFinite) {
      setState(() => _error = 'Enter a number');
      return;
    }
    // Out of range ⇒ REJECT, don't clamp: the silent clamp changed the
    // engineer's number behind their back (type 999 into a max-600 field and
    // the sizing ran on 600 with nothing said).
    if ((widget.min != null && parsed < widget.min!) ||
        (widget.max != null && parsed > widget.max!)) {
      setState(() => _error = _rangeMessage());
      return;
    }
    setState(() {
      _editing = false;
      _error = null;
    });
    widget.onSubmit(parsed);
  }

  void _cancel() {
    if (!_editing) return;
    setState(() {
      _cancelled = true;
      _editing = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final valueStyle =
        type.mono.copyWith(color: widget.valueColor ?? colors.textSecondary);

    Widget valueSlot;
    if (_editing) {
      final editor = Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _cancel();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: MechXSpacing.xxs),
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: MechXRadii.small,
            // A rejected commit tints the editor's own border so the message
            // below is not the only cue.
            border: Border.all(
                color: _error == null ? colors.accent : colors.danger,
                width: 1.5),
          ),
          child: EditableText(
            controller: _controller,
            focusNode: _editFocus,
            maxLines: 1,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign:
                widget.valueWidth != null ? widget.valueAlign : TextAlign.start,
            onChanged: (_) {
              // Clear a stale rejection as soon as the user edits again — it
              // described the PREVIOUS attempt, not the one in progress.
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _commit(),
            style: valueStyle,
            cursorColor: colors.accent,
            backgroundCursorColor: colors.textMuted,
            cursorWidth: 1.5,
            selectionColor: colors.accentMuted,
          ),
        ),
      );
      valueSlot = SizedBox(width: widget.valueWidth ?? 64, child: editor);
    } else {
      final text = Text(
        widget.display,
        textAlign: widget.valueAlign,
        style: valueStyle,
      );
      final tappable = MouseRegion(
        cursor: SystemMouseCursors.text,
        child: MechXFocusRing(
          onActivated: _beginEdit,
          child: GestureDetector(
            onTap: _beginEdit,
            behavior: HitTestBehavior.opaque,
            child: text,
          ),
        ),
      );
      valueSlot =
          widget.valueWidth != null
              ? SizedBox(width: widget.valueWidth, child: tappable)
              : tappable;
    }

    final strings = context.strings;
    String stepLabel(StringKey k) => widget.label == null
        ? strings(k)
        : '${strings(k)} ${widget.label}';

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepperGlyphButton(
          glyph: '−',
          onTap: widget.onDecrement,
          repeatInterval: widget.repeatInterval,
          semanticLabel: stepLabel(StringKey.a11yDecrease),
        ),
        SizedBox(width: widget.gap),
        valueSlot,
        SizedBox(width: widget.gap),
        _StepperGlyphButton(
          glyph: '+',
          onTap: widget.onIncrement,
          repeatInterval: widget.repeatInterval,
          semanticLabel: stepLabel(StringKey.a11yIncrease),
        ),
      ],
    );
    // The Column is ALWAYS present, even with no message: swapping between a
    // bare Row and a wrapped one would re-create the editor's element mid-edit
    // (dropping its focus + text-input connection the instant a rejection was
    // cleared). With no message it holds one min-sized child, so its size is
    // the row's own — the at-rest layout, and the goldens, are unchanged.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: MechXSpacing.xxs),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                _error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: type.caption.copyWith(color: colors.danger),
              ),
            ),
          ),
      ],
    );
  }
}

/// The `−` / `+` glyph button. Pixel-identical at rest to the inspector's
/// hand-rolled `_GlyphButton` (same 24×24 hit target, hover fill, press-scale,
/// focus ring, glyph typography), with press-and-hold repeat added: a quick tap
/// fires [onTap] once; holding past the long-press threshold fires it
/// immediately and then every [repeatInterval] until release.
class _StepperGlyphButton extends StatefulWidget {
  final String glyph;
  final VoidCallback? onTap;
  final Duration repeatInterval;

  /// L4 (a11y): the field-specific accessible name for this glyph button; the
  /// glyph char itself is hidden from semantics so only this reads out.
  final String? semanticLabel;

  const _StepperGlyphButton({
    required this.glyph,
    required this.onTap,
    required this.repeatInterval,
    this.semanticLabel,
  });

  @override
  State<_StepperGlyphButton> createState() => _StepperGlyphButtonState();
}

class _StepperGlyphButtonState extends State<_StepperGlyphButton> {
  bool _hover = false;
  bool _down = false;
  Timer? _repeat;

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  void _startRepeat() {
    _repeat?.cancel();
    // The long-press threshold already served as the initial delay, so fire
    // once now, then keep firing at the repeat cadence until release.
    widget.onTap?.call();
    _repeat = Timer.periodic(widget.repeatInterval, (_) => widget.onTap?.call());
  }

  void _stopRepeat() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = widget.onTap != null;
    final fg = !enabled
        ? colors.textMuted.withAlpha(90)
        : (_hover ? colors.textPrimary : colors.textSecondary);
    final glyph = AnimatedScale(
      scale: _down && enabled ? 0.9 : 1.0,
      duration: MechXMotion.press,
      curve: MechXMotion.standard,
      child: AnimatedContainer(
        duration: MechXMotion.hover,
        curve: MechXMotion.standard,
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              _hover && enabled ? colors.surfaceHover : const Color(0x00000000),
          borderRadius: MechXRadii.control,
        ),
        child: ExcludeSemantics(
          // The bare "−"/"+" is decorative once the button carries a real
          // field-specific label (`semanticLabel`); hide it so a screen reader
          // announces "Decrease Ceiling height", not "minus".
          child: Text(
            widget.glyph,
            style: TextStyle(
                fontFamily: 'Roboto', fontSize: 16, height: 1.0, color: fg),
          ),
        ),
      ),
    );
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: MechXFocusRing(
        enabled: enabled,
        onActivated: widget.onTap,
        semanticLabel: enabled ? widget.semanticLabel : null,
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTapCancel: enabled ? () => setState(() => _down = false) : null,
          onLongPressStart: enabled
              ? (_) {
                  setState(() => _down = true);
                  _startRepeat();
                }
              : null,
          onLongPressEnd: enabled
              ? (_) {
                  setState(() => _down = false);
                  _stopRepeat();
                }
              : null,
          onLongPressCancel: enabled
              ? () {
                  setState(() => _down = false);
                  _stopRepeat();
                }
              : null,
          child: glyph,
        ),
      ),
    );
  }
}
