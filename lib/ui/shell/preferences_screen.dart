import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/app_state.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/hub_scaffold.dart';
import '../widgets/mechx_button.dart';

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
      ],
    );
  }
}

/// A single settings row: a title + current value on the left, an action on the
/// right, in a bordered card. Mirrors the existing Appearance card styling so
/// both settings read consistently.
class _SettingCard extends StatelessWidget {
  final String title;
  final String value;
  final Widget action;

  const _SettingCard({
    required this.title,
    required this.value,
    required this.action,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(MechXSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: type.subtitle.copyWith(color: colors.textPrimary)),
                const SizedBox(height: MechXSpacing.xxs),
                Text(value,
                    style: type.caption.copyWith(color: colors.textMuted)),
              ],
            ),
          ),
          action,
        ],
      ),
    );
  }
}
