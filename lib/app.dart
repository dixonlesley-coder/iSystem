import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'store/app_state.dart';
import 'ui/app_shell.dart';
import 'ui/strings/app_strings.dart';
import 'ui/theme/mechx_theme.dart';

/// Root application. Uses [WidgetsApp] (not MaterialApp) so MechX owns its
/// visual language entirely (§4: no default Material theme). Provides the
/// MechXTheme + a default text style above the shell.
class MechXApp extends ConsumerWidget {
  const MechXApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = MechXThemeData.forBrightness(ref.watch(brightnessProvider));
    final strings = MechXStringsData(ref.watch(localeProvider));

    return WidgetsApp(
      title: 'iSystem',
      debugShowCheckedModeBanner: false,
      color: theme.colors.accent,
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (context, _, _) => builder(context),
      ),
      home: MechXTheme(
        data: theme,
        child: MechXStrings(
          data: strings,
          child: DefaultTextStyle(
            style:
                theme.typography.body.copyWith(color: theme.colors.textPrimary),
            child: const AppShell(),
          ),
        ),
      ),
    );
  }
}
