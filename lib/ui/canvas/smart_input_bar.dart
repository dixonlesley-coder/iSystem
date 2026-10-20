import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/units.dart';

import '../../store/app_state.dart' show AppLocale, localeProvider;
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/smart_input_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'snapping.dart';

/// A calm, context-aware input for precise drawing — the SIMPLER-than-AutoCAD
/// command line. It appears only while a Run is being drawn (a pending point is
/// set) on a calibrated sheet, lets the drafter type an exact length in mm (and
/// optionally a bearing), and on Enter places the next point at exactly that
/// distance. With nothing typed it stays out of the way; idle (Select tool) it
/// renders nothing at all, so the golden screenshots are byte-identical.
///
/// H1 — typing reaches it by TWO routes that never double up:
///   * it CLAIMS the keyboard (an explicit post-frame `requestFocus`, the
///     `MechXTextField.autofocus` pattern — `EditableText.autofocus` is
///     ignored once the canvas focus scope already has a focused child) every
///     time the run's pending point appears or moves, so a click-type-Enter
///     flow needs no mouse trip into the field;
///   * the Layout canvas key handler forwards the drafting characters
///     (digits . , - and a separating space) to [SmartInputBarState.insertText]
///     while a run is pending, WHICHEVER node holds focus — consuming the key,
///     so the platform's own text input never inserts it a second time. A
///     digit therefore always types a length mid-run and never re-picks the
///     service (which would drop the pending chain).
class SmartInputBar extends ConsumerStatefulWidget {
  final String sheetId;
  final int floorIndex;

  const SmartInputBar({
    super.key,
    required this.sheetId,
    required this.floorIndex,
  });

  @override
  ConsumerState<SmartInputBar> createState() => SmartInputBarState();
}

/// Public so the Layout canvas key handler (which owns the keyboard routing,
/// H1/H4/M2) can type into / commit / query the bar via a [GlobalKey].
class SmartInputBarState extends ConsumerState<SmartInputBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'smart-input');
  String? _error;

  /// The pending point the bar last claimed focus for (H1): a NEW / moved
  /// pending point re-claims it (each click on the canvas hands the keyboard
  /// to the canvas first).
  Offset? _focusedFor;

  /// Whether nothing is typed (Enter / Space / Backspace then act on the RUN —
  /// finish it, pan, or undo its last point — instead of on the text).
  bool get isEmpty => _controller.text.isEmpty;

  /// Whether the field itself holds the keyboard.
  bool get hasKeyboardFocus => _focusNode.hasFocus;

  /// Insert [text] at the caret (replacing any selection) — the canvas
  /// handler's forwarding route.
  void insertText(String text) {
    final v = _controller.value;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: v.text.length);
    final next = v.text.replaceRange(sel.start, sel.end, text);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
    _onChanged(next);
  }

  /// Delete the character before the caret (or the selection).
  void deleteBackward() {
    final v = _controller.value;
    if (v.text.isEmpty) return;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: v.text.length);
    final start = sel.isCollapsed ? math.max(0, sel.start - 1) : sel.start;
    final next = v.text.replaceRange(start, sel.end, '');
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start),
    );
    _onChanged(next);
  }

  /// Place the typed length (the Enter action). No-op on empty text.
  void commit() => _commit();

  void _onChanged(String text) {
    if (_error != null) setState(() => _error = null);
    // B25 — seed the Alt parallel-offset lock with the last valid typed
    // length, so 'type an offset, then Alt over a wall' works.
    final parsed = parseDrawingInput(text, indonesian: _indonesian);
    if (parsed.ok) {
      ref.read(parallelOffsetProvider.notifier).set(parsed.lengthMm!);
    }
    setState(() {}); // refresh the live preview
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Round 19 — the active UI locale's number convention.
  bool get _indonesian => ref.read(localeProvider) == AppLocale.id;

  void _commit() {
    final parse =
        parseDrawingInput(_controller.text, indonesian: _indonesian);
    if (parse.error != null) {
      setState(() => _error = parse.error);
      return;
    }
    if (!parse.ok) return; // empty — nothing to place
    final cal = ref.read(projectControllerProvider).calibrationFor(widget.sheetId);
    final pending = ref.read(networkControllerProvider).pendingPoint;
    if (cal == null || pending == null) return;

    final lengthPx = cal.pixelsForLength(Length.mm(parse.lengthMm!));
    // Direct-distance entry uses the live pointing direction (ortho-snapped when
    // ortho is on); a typed angle overrides it.
    Offset? hover = parse.angleDeg == null ? ref.read(drawHoverProvider) : null;
    if (hover != null && ref.read(orthoProvider)) {
      hover = orthoSnap(pending, hover);
    }
    final target = polarRunTarget(
      pending,
      lengthPx,
      angleDeg: parse.angleDeg,
      hover: hover,
    );
    // C4: a TYPED exact length must land at exactly that distance — endSnapRadius
    // 0 so the END can't silently merge onto a node near the computed point (the
    // default 12 world-px snap is zoom-inconsistent and would corrupt the typed
    // measurement). The START keeps the normal snap so the run still tees/adopts
    // its source — passing 0 for BOTH would disconnect the run at its start.
    // Ending on an existing node is done by clicking it.
    ref.read(networkControllerProvider.notifier).placeRunPoint(
          widget.sheetId,
          widget.floorIndex,
          target,
          endSnapRadius: 0,
        );
    _controller.clear();
    setState(() => _error = null);
    _focusNode.requestFocus();
  }

  /// H1 — claim the keyboard after the frame that shows (or moves) the
  /// pending point.
  void _claimFocusFor(Offset pending) {
    if (_focusedFor == pending) return;
    _focusedFor = pending;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focusNode.hasFocus) _focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final drawing = ref.watch(networkControllerProvider
        .select((d) => (tool: d.tool, pending: d.pendingPoint)));
    // Only while actively drawing a run from a pending point.
    if (drawing.tool != DrawTool.drawRun || drawing.pending == null) {
      // The chain ended: forget the typed text so the next run starts clean.
      _focusedFor = null;
      _error = null;
      if (_controller.text.isNotEmpty) {
        // After the frame (the field is still mounted while this builds).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              ref.read(networkControllerProvider).pendingPoint == null) {
            _controller.clear();
          }
        });
      }
      return const SizedBox.shrink();
    }
    _claimFocusFor(drawing.pending!);
    final calibrated =
        ref.watch(projectControllerProvider).calibrationFor(widget.sheetId) !=
            null;
    final colors = context.colors;
    final type = context.type;

    // Live preview of the parsed length (e.g. "3000 mm = 3.0 m").
    final parse = parseDrawingInput(_controller.text,
        indonesian: ref.watch(localeProvider) == AppLocale.id);
    String preview;
    Color previewColor = colors.textMuted;
    if (!calibrated) {
      preview = 'Calibrate the sheet to type exact lengths';
    } else if (_error != null) {
      preview = _error!;
      previewColor = colors.danger;
    } else if (parse.ok) {
      final m = parse.lengthMm! / 1000.0;
      preview = '${parse.lengthMm!.toStringAsFixed(0)} mm = '
          '${m.toStringAsFixed(m >= 10 ? 0 : 2)} m'
          '${parse.angleDeg != null ? ' @ ${parse.angleDeg!.toStringAsFixed(0)}°' : ''}'
          '  ·  Enter to place';
    } else {
      preview = 'Type a length in mm (e.g. 3000), Enter to place';
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.xs,
      ),
      constraints: const BoxConstraints(maxWidth: 360),
      decoration: BoxDecoration(
        color: colors.surface.withAlpha(245),
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
        boxShadow: MechXShadow.popover,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Length',
              style: type.caption.copyWith(color: colors.textSecondary)),
          const SizedBox(width: MechXSpacing.sm),
          SizedBox(
            width: 96,
            child: Focus(
              // Submit on Enter without the canvas swallowing the key. With
              // nothing typed the Enter bubbles on to the canvas, which
              // FINISHES the run (M2).
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    !isEmpty &&
                    (event.logicalKey == LogicalKeyboardKey.enter ||
                        event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
                  _commit();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: EditableText(
                controller: _controller,
                focusNode: _focusNode,
                // C4/H1: the field claims focus explicitly in build (see
                // [_claimFocusFor]) — `autofocus` alone is ignored once the
                // canvas scope already holds a focused child.
                onChanged: _onChanged,
                maxLines: 1,
                style: type.mono.copyWith(color: colors.textPrimary),
                cursorColor: colors.accent,
                backgroundCursorColor: colors.textMuted,
                cursorWidth: 1.5,
                selectionColor: colors.accentMuted,
                enableInteractiveSelection: true,
              ),
            ),
          ),
          const SizedBox(width: MechXSpacing.sm),
          Flexible(
            child: Text(
              preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: type.caption.copyWith(color: previewColor),
            ),
          ),
        ],
      ),
    );
  }
}
