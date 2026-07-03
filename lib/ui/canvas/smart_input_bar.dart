import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/units.dart';

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
class SmartInputBar extends ConsumerStatefulWidget {
  final String sheetId;
  final int floorIndex;

  const SmartInputBar({
    super.key,
    required this.sheetId,
    required this.floorIndex,
  });

  @override
  ConsumerState<SmartInputBar> createState() => _SmartInputBarState();
}

class _SmartInputBarState extends ConsumerState<SmartInputBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _commit() {
    final parse = parseDrawingInput(_controller.text);
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

  @override
  Widget build(BuildContext context) {
    final drawing = ref.watch(networkControllerProvider);
    // Only while actively drawing a run from a pending point.
    if (drawing.tool != DrawTool.drawRun || drawing.pendingPoint == null) {
      return const SizedBox.shrink();
    }
    final calibrated =
        ref.watch(projectControllerProvider).calibrationFor(widget.sheetId) !=
            null;
    final colors = context.colors;
    final type = context.type;

    // Live preview of the parsed length (e.g. "3000 mm = 3.0 m").
    final parse = parseDrawingInput(_controller.text);
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
              // Submit on Enter without the canvas swallowing the key.
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
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
                // C4: grab focus the moment the bar appears (a run chain is
                // live), so "click a point, type 3000, Enter" works without
                // first mousing into the 96-px field. The field only enters the
                // tree while drawing, so idle focus is untouched; canvas clicks
                // (pointer) keep working regardless of who holds key focus.
                autofocus: true,
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                  setState(() {}); // refresh the live preview
                },
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
