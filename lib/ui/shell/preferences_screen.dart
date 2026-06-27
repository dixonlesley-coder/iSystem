import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/app_state.dart';
import '../../update/update_check.dart';
import '../../update/update_provider.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/hub_scaffold.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_text_field.dart';

/// Preferences. Surfaces the real app-wide settings that exist today (the
/// light/dark appearance + the UI language); more design defaults move here in
/// a later wave.
class PreferencesScreen extends ConsumerWidget {
  const PreferencesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = context.strings;
    final brightness = ref.watch(brightnessProvider);
    final isDark = brightness == Brightness.dark;
    final locale = ref.watch(localeProvider);
    final otherLocale = locale == AppLocale.en ? AppLocale.id : AppLocale.en;
    final update = ref.watch(updateControllerProvider);

    return HubScaffold(
      title: strings(StringKey.prefsTitle),
      lead: strings(StringKey.prefsLead),
      children: [
        _SettingCard(
          title: strings(StringKey.prefsAppearance),
          value: isDark ? strings(StringKey.prefsDark) : strings(StringKey.prefsLight),
          action: MechXButton(
            label: isDark
                ? strings(StringKey.prefsSwitchToLight)
                : strings(StringKey.prefsSwitchToDark),
            onPressed: () => ref.read(brightnessProvider.notifier).toggle(),
          ),
        ),
        const SizedBox(height: MechXSpacing.sm),
        _SettingCard(
          title: strings(StringKey.prefsLanguage),
          value: locale.displayName,
          action: MechXButton(
            // Show the language we'd switch TO, so the action reads clearly.
            label: otherLocale.displayName,
            onPressed: () => ref.read(localeProvider.notifier).set(otherLocale),
          ),
        ),
        const SizedBox(height: MechXSpacing.sm),
        _SettingCard(
          title: 'Software update',
          value: _updateStatusText(update),
          action: _updateAction(ref, update),
        ),
        const SizedBox(height: MechXSpacing.sm),
        const _ApiKeyCard(),
      ],
    );
  }
}

/// The BYO Anthropic API key for the in-app Claude copilot. Stored in the
/// project's `DesignSettings` (round-trips in `.mechx`). The field is masked and
/// only ever shows whether a key is configured — never the key itself. English
/// literals: Preferences isn't in the golden set.
class _ApiKeyCard extends ConsumerStatefulWidget {
  const _ApiKeyCard();

  @override
  ConsumerState<_ApiKeyCard> createState() => _ApiKeyCardState();
}

class _ApiKeyCardState extends ConsumerState<_ApiKeyCard> {
  bool _editing = false;
  String _draft = '';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final hasKey = ref.watch(aiApiKeyProvider).trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(MechXSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Claude copilot (Anthropic API key)',
                        style: type.body.copyWith(color: colors.textPrimary)),
                    const SizedBox(height: 2),
                    Text(
                      hasKey
                          ? 'Configured — open the command palette and run "Ask Claude".'
                          : 'Not set — the copilot is disabled.',
                      style: type.caption.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              MechXButton(
                label: _editing ? 'Cancel' : (hasKey ? 'Change' : 'Add key'),
                tertiary: true,
                onPressed: () => setState(() {
                  _editing = !_editing;
                  _draft = '';
                }),
              ),
            ],
          ),
          if (_editing) ...[
            const SizedBox(height: MechXSpacing.sm),
            MechXTextField(
              value: _draft,
              hint: 'sk-ant-…',
              onChanged: (v) => _draft = v,
            ),
            const SizedBox(height: MechXSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (hasKey)
                  MechXButton(
                    label: 'Remove',
                    tertiary: true,
                    onPressed: () {
                      ref.read(aiApiKeyProvider.notifier).set('');
                      setState(() => _editing = false);
                    },
                  ),
                const SizedBox(width: MechXSpacing.xs),
                MechXButton(
                  label: 'Save',
                  primary: true,
                  onPressed: () {
                    ref.read(aiApiKeyProvider.notifier).set(_draft);
                    setState(() => _editing = false);
                  },
                ),
              ],
            ),
            const SizedBox(height: MechXSpacing.xs),
            Text(
              'Stored in this project file. Do not share a .mechx that carries '
              'your key.',
              style: type.caption.copyWith(color: colors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Human-readable status line for the update card, mapping each [UpdateStatus]
/// branch to a calm sentence. (English literals — Preferences isn't in the
/// golden set; an i18n pass for these keys is a noted follow-up.)
String _updateStatusText(UpdateStatus s) => switch (s) {
      UpdateDisabled(:final reason) => reason,
      UpdateIdle() => 'Checks automatically on launch and every 6 hours.',
      UpdateChecking() => 'Checking for updates...',
      UpdateAvailable(:final version) =>
        'Update available: v$version - downloading...',
      UpdateDownloading(:final percent) => 'Downloading update... $percent%',
      UpdateDownloaded(:final version) => 'Update v$version is ready to install.',
      UpdateUpToDate() => "You're on the latest version.",
      UpdateError(:final message) => 'Update check failed: $message',
    };

/// The trailing action for the update card. A ready download offers "Restart &
/// update" (primary); otherwise a "Check for updates" button (or "Retry" after
/// an error), disabled while a check/download is mid-flight. In a disabled
/// (non-release) build the action is omitted entirely.
Widget _updateAction(WidgetRef ref, UpdateStatus s) {
  final ctrl = ref.read(updateControllerProvider.notifier);
  if (s is UpdateDisabled) return const SizedBox.shrink();
  if (s is UpdateDownloaded) {
    return MechXButton(
      label: 'Restart & update',
      primary: true,
      onPressed: ctrl.installUpdate,
    );
  }
  final busy = s is UpdateChecking || s is UpdateDownloading;
  return MechXButton(
    label: s is UpdateError ? 'Retry' : 'Check for updates',
    onPressed: busy ? null : ctrl.checkForUpdates,
  );
}

/// A single settings row: a title + current value on the left, an action on the
/// right, in a bordered card. Mirrors the existing Appearance card styling so
/// both settings read consistently. Hovering the card gently lifts its border +
/// fill (a coordination affordance), eased on the `hover` idiom; the action's
/// own hover/press/focus feedback lives in [MechXButton].
class _SettingCard extends StatefulWidget {
  final String title;
  final String value;
  final Widget action;

  const _SettingCard({
    required this.title,
    required this.value,
    required this.action,
  });

  @override
  State<_SettingCard> createState() => _SettingCardState();
}

class _SettingCardState extends State<_SettingCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: MechXMotion.hover,
        curve: MechXMotion.standard,
        width: double.infinity,
        padding: const EdgeInsets.all(MechXSpacing.md),
        decoration: BoxDecoration(
          color: _hover
              ? Color.lerp(colors.surface, colors.surfaceHover, 0.5)!
              : colors.surface,
          borderRadius: MechXRadii.card,
          border:
              Border.all(color: _hover ? colors.textMuted : colors.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title,
                      style:
                          type.subtitle.copyWith(color: colors.textPrimary)),
                  const SizedBox(height: MechXSpacing.xxs),
                  Text(widget.value,
                      style: type.caption.copyWith(color: colors.textMuted)),
                ],
              ),
            ),
            widget.action,
          ],
        ),
      ),
    );
  }
}
