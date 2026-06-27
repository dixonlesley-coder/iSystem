/// The Claude-copilot overlay panel — a calm right-side card where the engineer
/// asks Claude to design or change the current selection, reviews the proposed
/// plan, and confirms or discards it (plan → preview → confirm → apply). Renders
/// NOTHING when closed, so the goldens stay byte-identical; the rest of the app
/// is unaffected when the copilot is disabled (no API key) or offline.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/ai_copilot_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';

class CopilotOverlay extends ConsumerWidget {
  const CopilotOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(copilotOpenProvider)) return const SizedBox.shrink();
    final colors = context.colors;
    return Positioned.fill(
      child: Stack(
        children: [
          // Scrim — tap outside to close.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => ref.read(copilotOpenProvider.notifier).close(),
              child: ColoredBox(color: colors.scrim),
            ),
          ),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: 340,
            child: _CopilotPanel(),
          ),
        ],
      ),
    );
  }
}

class _CopilotPanel extends ConsumerStatefulWidget {
  @override
  ConsumerState<_CopilotPanel> createState() => _CopilotPanelState();
}

class _CopilotPanelState extends ConsumerState<_CopilotPanel> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    ref.read(copilotProvider.notifier).ask(text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final state = ref.watch(copilotProvider);
    final enabled = ref.watch(copilotEnabledProvider);

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.border)),
        boxShadow: MechXShadow.popover,
      ),
      padding: const EdgeInsets.all(MechXSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Ask Claude',
                    style: type.title.copyWith(color: colors.textPrimary)),
              ),
              MechXButton(
                label: 'Close',
                tertiary: true,
                onPressed: () => ref.read(copilotOpenProvider.notifier).close(),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.xs),
          Text(
            'Select a room or element, then ask Claude to design or change it. '
            'You review every step before it is applied.',
            style: type.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: MechXSpacing.md),

          // Input.
          _PromptField(
            controller: _input,
            focusNode: _focus,
            enabled: enabled && state.phase != CopilotPhase.thinking,
            onSubmit: _send,
            hint: enabled
                ? 'e.g. design supply air for this room'
                : 'Add an API key in Preferences to enable',
          ),
          const SizedBox(height: MechXSpacing.sm),
          MechXButton(
            label: state.phase == CopilotPhase.thinking ? 'Thinking…' : 'Ask',
            primary: true,
            onPressed: enabled && state.phase != CopilotPhase.thinking
                ? _send
                : null,
          ),

          const SizedBox(height: MechXSpacing.md),
          Expanded(child: SingleChildScrollView(child: _Body(state: state))),
        ],
      ),
    );
  }
}

/// The state-dependent body: thinking / proposed plan / error message / idle.
class _Body extends ConsumerWidget {
  final CopilotState state;
  const _Body({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    switch (state.phase) {
      case CopilotPhase.idle:
        return const SizedBox.shrink();
      case CopilotPhase.thinking:
        return Text('Claude is planning…',
            style: type.caption.copyWith(color: colors.textMuted));
      case CopilotPhase.error:
        return Container(
          padding: const EdgeInsets.all(MechXSpacing.sm),
          decoration: BoxDecoration(
            color: colors.surfaceHover,
            borderRadius: MechXRadii.control,
            border: Border.all(color: colors.border),
          ),
          child: Text(state.message ?? 'No suggestion.',
              style: type.body.copyWith(color: colors.textSecondary)),
        );
      case CopilotPhase.proposed:
        final plan = state.plan!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.message != null) ...[
              Text(state.message!,
                  style: type.body.copyWith(color: colors.textSecondary)),
              const SizedBox(height: MechXSpacing.sm),
            ],
            Text('Proposed plan · ${plan.mutatingCount} change'
                '${plan.mutatingCount == 1 ? '' : 's'}',
                style: type.caption.copyWith(color: colors.textMuted)),
            const SizedBox(height: MechXSpacing.xs),
            for (final c in plan.commands)
              Padding(
                padding: const EdgeInsets.only(bottom: MechXSpacing.xxs),
                child: Text('· ${c.preview}',
                    style: type.body.copyWith(color: colors.textPrimary)),
              ),
            const SizedBox(height: MechXSpacing.md),
            Row(
              children: [
                Expanded(
                  child: MechXButton(
                    label: 'Apply',
                    primary: true,
                    onPressed: () =>
                        ref.read(copilotProvider.notifier).applyPlan(),
                  ),
                ),
                const SizedBox(width: MechXSpacing.xs),
                Expanded(
                  child: MechXButton(
                    label: 'Discard',
                    tertiary: true,
                    onPressed: () =>
                        ref.read(copilotProvider.notifier).discard(),
                  ),
                ),
              ],
            ),
          ],
        );
    }
  }
}

/// A small Enter-to-submit text field (themed, no Material).
class _PromptField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback onSubmit;
  final String hint;
  const _PromptField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onSubmit,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: MechXSpacing.sm, vertical: MechXSpacing.xs + 2),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: MechXRadii.control,
        border: Border.all(color: colors.border),
      ),
      child: Focus(
        onKeyEvent: (_, e) {
          if (enabled &&
              e is KeyDownEvent &&
              (e.logicalKey == LogicalKeyboardKey.enter ||
                  e.logicalKey == LogicalKeyboardKey.numpadEnter)) {
            onSubmit();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            if (controller.text.isEmpty)
              IgnorePointer(
                child: Text(hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.body.copyWith(color: colors.textMuted)),
              ),
            EditableText(
              controller: controller,
              focusNode: focusNode,
              readOnly: !enabled,
              maxLines: 1,
              style: type.body.copyWith(color: colors.textPrimary),
              cursorColor: colors.accent,
              backgroundCursorColor: colors.textMuted,
              cursorWidth: 1.5,
              selectionColor: colors.accentMuted,
              onChanged: (_) {},
            ),
          ],
        ),
      ),
    );
  }
}
