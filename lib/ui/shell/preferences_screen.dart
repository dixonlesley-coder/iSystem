import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/app_state.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/hub_scaffold.dart';
import '../widgets/mechx_button.dart';

/// Preferences. Surfaces the real app-wide settings that exist today (the
/// light/dark appearance); more design defaults move here in a later wave.
class PreferencesScreen extends ConsumerWidget {
  const PreferencesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final type = context.type;
    final brightness = ref.watch(brightnessProvider);
    final isDark = brightness == Brightness.dark;

    return HubScaffold(
      title: 'Preferences',
      lead: 'App-wide settings. More design defaults will gather here.',
      children: [
        Container(
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
                    Text('Appearance',
                        style: type.subtitle
                            .copyWith(color: colors.textPrimary)),
                    const SizedBox(height: MechXSpacing.xxs),
                    Text(isDark ? 'Dark' : 'Light',
                        style: type.caption
                            .copyWith(color: colors.textMuted)),
                  ],
                ),
              ),
              MechXButton(
                label: isDark ? 'Switch to Light' : 'Switch to Dark',
                onPressed: () =>
                    ref.read(brightnessProvider.notifier).toggle(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
