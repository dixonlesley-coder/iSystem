/// First-run orientation + on-canvas teaching for the Layout workspace
/// (Apple-design review, Theme A). Two small, additive, MechXTheme-styled
/// widgets — no Material:
///
///  • [FirstRunOrientationCard] (A1) — a one-time, dismissible welcome card on a
///    genuinely EMPTY project (no sheets) that names the five-step workflow
///    (Calibrate · Building · Draw · Size · Report) and points at "Import a plan".
///    Its "seen" state is a machine-local flag (see `data/app_settings.dart`),
///    so once dismissed it never returns; it never shows once a sheet exists.
///
///  • [FirstDrawHint] (A4) — a quiet on-canvas hint over a calibrated-but-empty
///    canvas teaching the primary draw gesture. It is purely informational
///    (mount inside an [IgnorePointer] so it never eats a drawing tap) and its
///    caller gates it off the moment anything is drawn.
///
/// Both keep the guardrails: content is opaque (only chrome is glass), every
/// on-canvas [TextStyle] rides the Roboto type tokens, and the copy is plain
/// ASCII (no arrows/checks/superscripts) so the golden screenshots stay
/// tofu-free.
library;

import 'package:flutter/widgets.dart';

import '../../store/command_store.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';

/// The five workflow steps, in order — the map the newcomer is missing. Each is
/// (name, one-line "what it does"). Localized via [strings]; the step names
/// reuse [WorkflowStageInfo.label] (A3) so the orientation card and the
/// status-bar stepper always agree on ONE term per stage — notably "Building"
/// for the floor/height step, matching the nav-rail destination it points at.
List<(String, String)> _workflowSteps(MechXStringsData strings) => [
      (
        WorkflowStage.calibrate.label(strings),
        strings(StringKey.firstRunStepCalibrateDesc),
      ),
      (
        WorkflowStage.floors.label(strings),
        strings(StringKey.firstRunStepBuildingDesc),
      ),
      (
        WorkflowStage.draw.label(strings),
        strings(StringKey.firstRunStepDrawDesc),
      ),
      (
        WorkflowStage.size.label(strings),
        strings(StringKey.firstRunStepSizeDesc),
      ),
      (
        WorkflowStage.report.label(strings),
        strings(StringKey.firstRunStepReportDesc),
      ),
    ];

/// A1 — the one-time first-run orientation card. Additive: it sits ABOVE the
/// existing empty-state card, so the empty Layout still carries its own Import /
/// template actions. [onImport] routes into Import; [onDismiss] records the
/// machine-local "seen" flag so the card never returns.
class FirstRunOrientationCard extends StatelessWidget {
  final VoidCallback onImport;
  final VoidCallback onDismiss;

  const FirstRunOrientationCard({
    super.key,
    required this.onImport,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final steps = _workflowSteps(context.strings);
    return _GuideEntrance(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Container(
          padding: const EdgeInsets.all(MechXSpacing.lg),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: MechXRadii.card,
            border: Border.all(color: colors.border),
            boxShadow: MechXShadow.card,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Welcome to iSystem',
                  style: type.title.copyWith(color: colors.textPrimary)),
              const SizedBox(height: MechXSpacing.xs),
              Text(
                'Design mechanical, electrical and plumbing systems in five '
                'steps:',
                style: type.body.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: MechXSpacing.md),
              for (var i = 0; i < steps.length; i++) ...[
                if (i > 0) const SizedBox(height: MechXSpacing.sm),
                _StepRow(
                  number: i + 1,
                  name: steps[i].$1,
                  description: steps[i].$2,
                ),
              ],
              const SizedBox(height: MechXSpacing.md),
              Wrap(
                spacing: MechXSpacing.sm,
                runSpacing: MechXSpacing.sm,
                children: [
                  MechXButton(
                    label: 'Import a plan',
                    primary: true,
                    onPressed: onImport,
                  ),
                  MechXButton(
                    label: 'Not now',
                    tertiary: true,
                    onPressed: onDismiss,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One numbered workflow step: a small round index badge + the step name (in the
/// primary label) and its one-line description (secondary).
class _StepRow extends StatelessWidget {
  final int number;
  final String name;
  final String description;

  const _StepRow({
    required this.number,
    required this.name,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.accentMuted,
            borderRadius: MechXRadii.rounded,
          ),
          child: Text(
            '$number',
            style: type.caption.copyWith(
              color: colors.accent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: MechXSpacing.sm),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text.rich(
              TextSpan(
                style: type.body.copyWith(color: colors.textSecondary),
                children: [
                  TextSpan(
                    text: name,
                    style: type.body.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(text: ' - $description'),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A4 — a quiet on-canvas hint teaching the first draw gesture, shown over a
/// calibrated-but-empty canvas. Purely informational: the caller mounts it
/// inside an [IgnorePointer] and gates it off once anything is drawn. Muted
/// (neutral) styling so it reads as guidance, not a warning.
class FirstDrawHint extends StatelessWidget {
  const FirstDrawHint({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return _GuideEntrance(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.sm + 2,
          vertical: MechXSpacing.xs + 1,
        ),
        decoration: BoxDecoration(
          color: colors.surface.withAlpha(240),
          borderRadius: MechXRadii.control,
          border: Border.all(color: colors.border),
          boxShadow: MechXShadow.card,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(right: MechXSpacing.xs),
              decoration: BoxDecoration(
                color: colors.accent,
                borderRadius: MechXRadii.small,
              ),
            ),
            Text(
              'Pick the Run tool (R), then tap two points to draw',
              style: type.label.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// A one-shot entrance: fades 0 -> 1 and scales ~0.96 -> 1.0 over
/// [MechXMotion.appear] the first time it's built, so the guidance arrives
/// rather than pops. Transient motion — no at-rest pixel change once settled.
class _GuideEntrance extends StatelessWidget {
  final Widget child;
  const _GuideEntrance({required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: MechXMotion.appear,
      curve: MechXMotion.standard,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(scale: 0.96 + 0.04 * t, child: child),
      ),
    );
  }
}
