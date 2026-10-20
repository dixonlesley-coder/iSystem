import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/units.dart';

import '../../store/app_state.dart' show AppLocale, localeProvider;
import '../../store/base_point_command_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/smart_input_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import 'snapping.dart';

/// What the smart input bar is currently typing FOR — the one command line
/// shared by every precise-entry gesture on the Layout canvas.
enum SmartBarMode {
  /// The next point of a run being drawn (length / `len ang` / `len<ang` /
  /// `@dx,dy`).
  run,

  /// The target of a base-point Move / Copy (same forms, measured from the
  /// base point; a bare length runs along the cursor direction).
  displacement,

  /// The angle of a base-point Rotate (degrees, CCW positive).
  angle,

  /// The exact length of a run whose free end is being stretched by its grip
  /// (a bare length, measured from the fixed end along the drag direction).
  stretch,
}

/// The active [SmartBarMode] for [sheetId], or null when the bar has nothing
/// to type for. Pure over provider READS — shared by the bar's build and the
/// Layout canvas key handler (which forwards the drafting keys only while this
/// is non-null), so the two can never disagree.
SmartBarMode? smartBarModeOf(
  ({DrawTool tool, Offset? pending}) drawing,
  BasePointCommand? cmd,
  EndpointStretch? stretch,
  String sheetId,
) {
  if (stretch != null && !stretch.typed) return SmartBarMode.stretch;
  if (cmd != null && !cmd.pickingBase && cmd.sheetId == sheetId) {
    return cmd.kind == BasePointCommandKind.rotate
        ? SmartBarMode.angle
        : SmartBarMode.displacement;
  }
  if (drawing.tool == DrawTool.drawRun && drawing.pending != null) {
    return SmartBarMode.run;
  }
  return null;
}

/// A calm, context-aware input for precise drawing — the SIMPLER-than-AutoCAD
/// command line. It appears only while there is something to type for (see
/// [SmartBarMode]): the next point of a run, a base-point Move / Copy target,
/// a Rotate angle, or the length of a run end being stretched by its grip. With
/// nothing typed it stays out of the way; at rest it renders nothing at all,
/// so the golden screenshots are byte-identical.
///
/// M9 — the typed forms are AutoCAD's: `3000` (along the cursor), `3000 90`,
/// `3000<90`, `@3000<90` and `@1500,-2000` (relative Cartesian, +Y up). Typed
/// points honour NO snap (exact), like the typed length always has.
///
/// H1 — the CANVAS keeps the keyboard (one owner, so Ctrl+Z still undoes the
/// last segment and the arrows still pan): the Layout canvas key handler
/// forwards the drafting characters (digits . , - @ < ; and a separating
/// space), Backspace, Enter and Esc to this bar while it is active — consuming
/// the key, so the platform's own text input never inserts it a second time.
/// Clicking INTO the field still focuses it for caret editing; Enter then
/// commits and hands the keyboard straight back to the canvas.
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

  /// Whether nothing is typed (Enter / Space / Backspace then act on the RUN —
  /// finish it, pan, or undo its last point — instead of on the text).
  bool get isEmpty => _controller.text.isEmpty;

  /// Whether the field itself holds the keyboard.
  bool get hasKeyboardFocus => _focusNode.hasFocus;

  /// The live mode (read, not watched).
  SmartBarMode? get mode => smartBarModeOf(
        ref.read(networkControllerProvider
            .select((d) => (tool: d.tool, pending: d.pendingPoint))),
        ref.read(basePointCommandProvider),
        ref.read(endpointStretchProvider),
        widget.sheetId,
      );

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

  /// Forget the typed text (Esc).
  void clear() {
    _controller.clear();
    setState(() => _error = null);
  }

  /// Commit the typed entry (the Enter action). No-op on empty text.
  void commit() => _commit();

  void _onChanged(String text) {
    if (_error != null) setState(() => _error = null);
    // B25 — seed the Alt parallel-offset lock with the last valid typed
    // length, so 'type an offset, then Alt over a wall' works.
    if (mode == SmartBarMode.run) {
      final parsed = parseDrawingInput(text, indonesian: _indonesian);
      if (parsed.ok && parsed.lengthMm != null) {
        ref.read(parallelOffsetProvider.notifier).set(parsed.lengthMm!);
      }
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

  void _fail(String message) => setState(() => _error = message);

  void _commit() {
    final m = mode;
    if (m == null || _controller.text.trim().isEmpty) return;
    final placed = switch (m) {
      SmartBarMode.run => _commitRun(),
      SmartBarMode.displacement => _commitDisplacement(),
      SmartBarMode.angle => _commitAngle(),
      SmartBarMode.stretch => _commitStretch(),
    };
    if (!placed) return;
    _controller.clear();
    setState(() => _error = null);
    // Back to the canvas (the keyboard owner) if the field was clicked into
    // for editing.
    if (_focusNode.hasFocus) {
      _focusNode.unfocus(
          disposition: UnfocusDisposition.previouslyFocusedChild);
    }
  }

  /// World px per millimetre on this sheet, or null when uncalibrated.
  double? get _pxPerMm => ref
      .read(projectControllerProvider)
      .calibrationFor(widget.sheetId)
      ?.pixelsForLength(Length.mm(1));

  /// The live cursor (ortho-projected from [from] when ortho is on), the
  /// direction a bare typed length runs along.
  Offset? _direction(Offset from) {
    var hover = ref.read(drawHoverProvider);
    if (hover != null && ref.read(orthoProvider)) {
      hover = orthoSnap(from, hover);
    }
    return hover;
  }

  bool _commitRun() {
    final parse = parseDrawingInput(_controller.text, indonesian: _indonesian);
    if (!parse.ok) {
      _fail(parse.error ?? 'Enter a length in mm, e.g. 3000');
      return false;
    }
    final pxPerMm = _pxPerMm;
    final pending = ref.read(networkControllerProvider).pendingPoint;
    if (pxPerMm == null || pending == null) return false;
    // Direct-distance entry uses the live pointing direction (ortho-snapped
    // when ortho is on); a typed angle / @dx,dy overrides it.
    final target = drawInputTarget(pending, parse, pxPerMm,
        hover: parse.isCartesian || parse.angleDeg != null
            ? null
            : _direction(pending));
    // C4: a TYPED exact point must land at exactly that place — endSnapRadius
    // 0 so the END can't silently merge onto a node near the computed point
    // (the default 12 world-px snap is zoom-inconsistent and would corrupt the
    // typed measurement). The START keeps the normal snap so the run still
    // tees/adopts its source — passing 0 for BOTH would disconnect the run at
    // its start. Ending on an existing node is done by clicking it.
    ref.read(networkControllerProvider.notifier).placeRunPoint(
          widget.sheetId,
          widget.floorIndex,
          target,
          endSnapRadius: 0,
        );
    return true;
  }

  bool _commitDisplacement() {
    final parse = parseDrawingInput(_controller.text, indonesian: _indonesian);
    if (!parse.ok) {
      _fail(parse.error ?? 'Enter @x,y or a length in mm');
      return false;
    }
    final pxPerMm = _pxPerMm;
    final base = ref.read(basePointCommandProvider)?.base;
    if (pxPerMm == null || base == null) return false;
    final hover = parse.isCartesian || parse.angleDeg != null
        ? null
        : _direction(base);
    if (!parse.isCartesian &&
        parse.angleDeg == null &&
        (hover == null || hover == base)) {
      _fail('Point the cursor the way to go, or type @x,y');
      return false;
    }
    // Exact: the displacement is applied as typed (no snap).
    final target = drawInputTarget(base, parse, pxPerMm, hover: hover);
    return ref
        .read(basePointCommandProvider.notifier)
        .placeDisplacement(target - base);
  }

  bool _commitAngle() {
    final parse = parseAngleInput(_controller.text, indonesian: _indonesian);
    final deg = parse.degrees;
    if (deg == null) {
      _fail(parse.error ?? 'Enter an angle in degrees, e.g. 90');
      return false;
    }
    final ok = ref.read(basePointCommandProvider.notifier).rotateBy(deg);
    if (!ok) _fail('Nothing to turn at that angle');
    return ok;
  }

  bool _commitStretch() {
    final s = ref.read(endpointStretchProvider);
    final cal =
        ref.read(projectControllerProvider).calibrationFor(widget.sheetId);
    if (s == null || cal == null) return false;
    final parse = parseDrawingInput(_controller.text, indonesian: _indonesian);
    if (!parse.ok || parse.isCartesian || parse.angleDeg != null) {
      _fail(parse.error ?? 'Type the run length in mm, e.g. 3000');
      return false;
    }
    final metres = parse.lengthMm! / 1000.0;
    final net = ref.read(networkControllerProvider.notifier);
    final ok = net.setRunLength(s.edgeId, metres, cal.metersPerPixel,
        moveEndId: s.nodeId, duringDrag: true);
    if (!ok && !_alreadyLength(s.edgeId, metres, cal.metersPerPixel)) {
      _fail('Drag the end away from the run first');
      return false;
    }
    ref.read(endpointStretchProvider.notifier).markTyped();
    return true;
  }

  bool _alreadyLength(String edgeId, double metres, double mpp) {
    final net = ref.read(networkControllerProvider).network;
    final e = net.edgeById(edgeId);
    final a = e == null ? null : net.nodeById(e.fromId);
    final b = e == null ? null : net.nodeById(e.toId);
    if (a == null || b == null) return false;
    final len = Offset(b.x - a.x, b.y - a.y).distance * mpp;
    return len > 0 && (len - metres).abs() < 1e-9;
  }

  String _label(SmartBarMode m) => switch (m) {
        SmartBarMode.run => 'Length',
        SmartBarMode.displacement =>
          ref.read(basePointCommandProvider)?.kind == BasePointCommandKind.copy
              ? 'Copy'
              : 'Move',
        SmartBarMode.angle => 'Angle',
        SmartBarMode.stretch => 'Length',
      };

  String _hint(SmartBarMode m) => switch (m) {
        SmartBarMode.run =>
          'Type a length in mm (3000, 3000<45, @1500,-2000), Enter to place',
        SmartBarMode.displacement =>
          'Type @x,y or length<angle in mm, or a length along the cursor',
        SmartBarMode.angle => 'Type an angle in degrees (CCW +), Enter',
        SmartBarMode.stretch => 'Type the run length in mm, Enter',
      };

  @override
  Widget build(BuildContext context) {
    final drawing = ref.watch(networkControllerProvider
        .select((d) => (tool: d.tool, pending: d.pendingPoint)));
    final cmd = ref.watch(basePointCommandProvider);
    final stretch = ref.watch(endpointStretchProvider);
    final m = smartBarModeOf(drawing, cmd, stretch, widget.sheetId);
    if (m == null) {
      // The entry ended: forget the typed text so the next one starts clean.
      _error = null;
      if (_controller.text.isNotEmpty) {
        // After the frame (the field is still mounted while this builds).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && mode == null) _controller.clear();
        });
      }
      return const SizedBox.shrink();
    }
    final needsScale = m != SmartBarMode.angle;
    final calibrated =
        ref.watch(projectControllerProvider).calibrationFor(widget.sheetId) !=
            null;
    // A grip stretch on an uncalibrated sheet has nothing to type: stay out
    // of the way rather than flash a calibration hint on every end drag.
    if (m == SmartBarMode.stretch && !calibrated) {
      return const SizedBox.shrink();
    }
    final colors = context.colors;
    final type = context.type;
    final indonesian = ref.watch(localeProvider) == AppLocale.id;

    String preview;
    Color previewColor = colors.textMuted;
    if (needsScale && !calibrated) {
      preview = 'Calibrate the sheet to type exact lengths';
    } else if (_error != null) {
      preview = _error!;
      previewColor = colors.danger;
    } else if (m == SmartBarMode.angle) {
      final a = parseAngleInput(_controller.text, indonesian: indonesian);
      preview = a.degrees != null
          ? 'turn ${formatAngleDeg(a.degrees!)}° '
              '${a.degrees! >= 0 ? 'counter-clockwise' : 'clockwise'}'
              '  ·  Enter to rotate'
          : (a.error ?? _hint(m));
      if (a.error != null) previewColor = colors.danger;
    } else {
      final parse = parseDrawingInput(_controller.text, indonesian: indonesian);
      if (parse.ok) {
        preview = '${describeDrawInput(parse)}  ·  Enter to '
            '${m == SmartBarMode.stretch ? 'set' : 'place'}';
      } else {
        preview = _hint(m);
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.xs,
      ),
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: BoxDecoration(
        color: colors.surface.withAlpha(245),
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
        boxShadow: MechXShadow.popover,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_label(m),
              style: type.caption.copyWith(color: colors.textSecondary)),
          const SizedBox(width: MechXSpacing.sm),
          SizedBox(
            width: 112,
            child: Focus(
              // Submit on Enter without the canvas swallowing the key. With
              // nothing typed the Enter bubbles on to the canvas, which
              // FINISHES the run / command (M2).
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
                // H1: no autofocus — the canvas keeps the keyboard and
                // forwards the drafting keys here (see the class doc).
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
