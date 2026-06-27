import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/units.dart';

import '../../store/calibration_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_text_field.dart';
import 'viewport.dart';

/// Transparent layer shown over the canvas while calibrating. Captures taps
/// (mapping them to sheet/world coordinates via the current viewport), draws
/// the reference line, and collects the known real distance.
class CalibrationOverlay extends ConsumerStatefulWidget {
  final String sheetId;

  const CalibrationOverlay({super.key, required this.sheetId});

  @override
  ConsumerState<CalibrationOverlay> createState() => _CalibrationOverlayState();
}

class _CalibrationOverlayState extends ConsumerState<CalibrationOverlay> {
  String _distance = '1.0';

  void _commit() {
    final meters = double.tryParse(_distance.trim());
    if (meters == null || meters <= 0) return;
    final cal = ref
        .read(calibrationControllerProvider.notifier)
        .resolve(Length(meters));
    if (cal == null) return;
    ref
        .read(projectControllerProvider.notifier)
        .setCalibration(widget.sheetId, cal);
    ref.read(calibrationControllerProvider.notifier).cancel();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final cal = ref.watch(calibrationControllerProvider);
    final transform = ref.watch(sheetsControllerProvider).viewportFor(widget.sheetId) ??
        const ViewportTransform();
    final notifier = ref.read(calibrationControllerProvider.notifier);

    return Stack(
      children: [
        // Tap capture + line painter.
        Positioned.fill(
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) =>
                  notifier.addWorldPoint(transform.screenToWorld(details.localPosition)),
              child: CustomPaint(
                painter: _CalibrationPainter(
                  state: cal,
                  transform: transform,
                  color: colors.accent,
                ),
              ),
            ),
          ),
        ),

        // Instruction banner.
        Positioned(
          top: MechXSpacing.md,
          left: 0,
          right: 0,
          child: Center(
            child: _Banner(
              text: switch (cal.phase) {
                CalibrationPhase.awaitingFirst =>
                  'Click the first point of a known distance',
                CalibrationPhase.awaitingSecond => 'Click the second point',
                _ => 'Enter the real-world length',
              },
              onCancel: notifier.cancel,
            ),
          ),
        ),

        // Distance entry.
        if (cal.phase == CalibrationPhase.awaitingDistance)
          Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 280),
              padding: const EdgeInsets.all(MechXSpacing.md),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: MechXRadii.card,
                border: Border.all(color: colors.border),
                boxShadow: MechXShadow.popover,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Known distance',
                    style: type.subtitle.copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: MechXSpacing.xs),
                  Text(
                    'Span = ${cal.pixelDistance!.toStringAsFixed(1)} px',
                    style: type.caption.copyWith(color: colors.textMuted),
                  ),
                  const SizedBox(height: MechXSpacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: MechXTextField(
                          value: _distance,
                          onChanged: (v) => _distance = v,
                        ),
                      ),
                      const SizedBox(width: MechXSpacing.sm),
                      Text('m', style: type.body.copyWith(color: colors.textSecondary)),
                    ],
                  ),
                  const SizedBox(height: MechXSpacing.md),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: MechXSpacing.sm,
                    runSpacing: MechXSpacing.xs,
                    children: [
                      MechXButton(label: 'Cancel', onPressed: notifier.cancel),
                      MechXButton(
                        label: 'Set scale',
                        primary: true,
                        onPressed: _commit,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  final String text;
  final VoidCallback onCancel;
  const _Banner({required this.text, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.md,
        vertical: MechXSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: type.label.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: MechXSpacing.md),
          MechXButton(label: 'Esc', onPressed: onCancel),
        ],
      ),
    );
  }
}

class _CalibrationPainter extends CustomPainter {
  final CalibrationState state;
  final ViewportTransform transform;
  final Color color;

  _CalibrationPainter({
    required this.state,
    required this.transform,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final dot = Paint()..color = color;
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final a = state.first == null ? null : transform.worldToScreen(state.first!);
    final b =
        state.second == null ? null : transform.worldToScreen(state.second!);

    if (a != null && b != null) canvas.drawLine(a, b, line);
    if (a != null) canvas.drawCircle(a, 4, dot);
    if (b != null) canvas.drawCircle(b, 4, dot);
  }

  @override
  bool shouldRepaint(_CalibrationPainter old) =>
      old.state != state || old.transform != transform || old.color != color;
}
