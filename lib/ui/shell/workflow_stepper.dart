/// A compact workflow stepper for the status bar: the five MEP stages
/// (Calibrate · Floors · Draw · Size · Report) with a done / active / pending
/// state derived from project state ([workflowStageStateProvider]).
///
/// Each stage is CLICKABLE — tapping it navigates straight to where that step
/// is done (Calibrate → start calibration on the Layout canvas; Floors → the
/// Building screen; Draw → the Layout canvas; Size → the Layout canvas; Report
/// → the Review hub) through the existing controllers/providers (no new state).
///
/// App-shell-local; custom design system only. Every text style is
/// Roboto-backed via `context.type`. The done tick is a small custom-painted
/// check (no icon font / no glyph that could tofu in goldens).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/calibration_store.dart';
import '../../store/command_store.dart';
import '../../store/electrical_store.dart';
import '../shell/nav_rail.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_focus_ring.dart';

/// The status-bar workflow stepper. Lays the five stages out horizontally with
/// hairline connectors; the done stages are accented, the active one is
/// outlined, the rest muted.
class WorkflowStepper extends ConsumerWidget {
  const WorkflowStepper({super.key});

  /// Navigate to where [stage] is carried out, through the existing providers.
  /// The status bar stays put — only the workspace section / view changes.
  void _goTo(WidgetRef ref, WorkflowStage stage) {
    switch (stage) {
      case WorkflowStage.calibrate:
        ref.read(shellSectionProvider.notifier).set(ShellSection.design);
        ref.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
        ref.read(calibrationControllerProvider.notifier).start();
      case WorkflowStage.floors:
        ref.read(shellSectionProvider.notifier).set(ShellSection.building);
      case WorkflowStage.draw:
        ref.read(shellSectionProvider.notifier).set(ShellSection.design);
        ref.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
      case WorkflowStage.size:
        ref.read(shellSectionProvider.notifier).set(ShellSection.design);
        ref.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
      case WorkflowStage.report:
        ref.read(shellSectionProvider.notifier).set(ShellSection.review);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workflowStageStateProvider);
    final active = state.active;

    final stages = WorkflowStage.values;
    final children = <Widget>[];
    for (var i = 0; i < stages.length; i++) {
      final s = stages[i];
      children.add(_StageChip(
        label: s.label(context.strings),
        done: state.isDone(s),
        active: s == active,
        onTap: () => _goTo(ref, s),
      ));
      if (i != stages.length - 1) {
        children.add(_connector(context));
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _connector(BuildContext context) => Container(
        width: 10,
        height: 1,
        margin: const EdgeInsets.symmetric(horizontal: MechXSpacing.xs),
        color: context.colors.border,
      );
}

class _StageChip extends StatefulWidget {
  final String label;
  final bool done;
  final bool active;
  final VoidCallback onTap;

  const _StageChip({
    required this.label,
    required this.done,
    required this.active,
    required this.onTap,
  });

  @override
  State<_StageChip> createState() => _StageChipState();
}

class _StageChipState extends State<_StageChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final done = widget.done;
    final active = widget.active;

    final Color fg;
    if (done) {
      fg = colors.success;
    } else if (active) {
      fg = colors.accent;
    } else {
      fg = colors.textMuted;
    }

    final chip = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.xs + 2,
        vertical: MechXSpacing.xxs,
      ),
      decoration: BoxDecoration(
        // The standard nav-item hover fill: the chip is a documented click
        // target, so it should look like one before the click — not only via
        // the cursor change.
        color: active
            ? colors.accentMuted
            : (_hover ? colors.surfaceHover : const Color(0x00000000)),
        borderRadius: MechXRadii.small,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A small status mark: a check when done, else a hollow / filled dot.
          CustomPaint(
            size: const Size(10, 10),
            painter: _StageMark(done: done, active: active, color: fg),
          ),
          const SizedBox(width: MechXSpacing.xs),
          Text(
            widget.label,
            style: type.caption.copyWith(
              color: fg,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );

    // Each stage jumps to where that step is performed. Wrapped in a
    // MechXFocusRing so the chip is keyboard-focusable + Enter/Space-activatable
    // and announced as a button (I7); [MergeSemantics] folds the ring's button
    // role, focus state, and the inner Text into ONE labelled button node so a
    // screen reader announces e.g. "Calibrate, button". At rest the ring paints
    // nothing, and Semantics/MergeSemantics are layout/paint-transparent, so the
    // goldens are byte-identical.
    return MergeSemantics(
      child: MechXFocusRing(
        borderRadius: MechXRadii.small,
        onActivated: widget.onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: chip,
          ),
        ),
      ),
    );
  }
}

/// The per-stage status mark: a tick when [done], a filled dot when [active],
/// else a hollow ring. Custom-painted so it can never render as tofu.
class _StageMark extends CustomPainter {
  final bool done;
  final bool active;
  final Color color;

  _StageMark({required this.done, required this.active, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final c = Offset(w / 2, h / 2);
    if (done) {
      final stroke = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path()
        ..moveTo(w * 0.18, h * 0.52)
        ..lineTo(w * 0.42, h * 0.76)
        ..lineTo(w * 0.84, h * 0.24);
      canvas.drawPath(path, stroke);
      return;
    }
    if (active) {
      canvas.drawCircle(c, w * 0.28, Paint()..color = color);
      return;
    }
    canvas.drawCircle(
      c,
      w * 0.30,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_StageMark old) =>
      old.done != done || old.active != active || old.color != color;
}
