import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/autosave.dart';
import 'store/app_state.dart';
import 'store/project_store.dart';
import 'ui/app_shell.dart';
import 'ui/shell/confirm_discard_dialog.dart';
import 'ui/shell/project_io.dart';
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
            child: const _WindowTitle(child: _ExitGuard(child: AppShell())),
          ),
        ),
      ),
    );
  }
}

/// A7: keeps the native OS window title in sync with the live project — e.g.
/// `iSystem — Tower B`, with a trailing edited marker (`•`) while the work
/// differs from the last clean Save. Uses the framework's own offline title
/// mechanism (the [Title] widget → `SystemChrome.setApplicationSwitcherDescription`,
/// which the Windows embedder maps to `SetWindowText`) — no plugin, no platform
/// channel of our own. Isolated in its own [ConsumerWidget] so a name/dirty
/// change rebuilds ONLY this node (the [child] instance is preserved, so the
/// shell never rebuilds), and it paints nothing (Title just returns its child),
/// so goldens are byte-identical.
class _WindowTitle extends ConsumerWidget {
  final Widget child;
  const _WindowTitle({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(projectControllerProvider.select((p) => p.name)).trim();
    final dirty = ref.watch(projectDirtyProvider);
    final base = name.isEmpty ? 'iSystem' : 'iSystem — $name';
    // Mirror the top bar's document-app "edited" cue into the window title.
    final title = dirty ? '$base •' : base;
    return Title(
      title: title,
      // Window-manager identity colour (cosmetic; ignored on Windows). Forced
      // opaque to satisfy Title's opaque-colour assert.
      color: context.colors.accent.withAlpha(0xFF),
      child: child,
    );
  }
}

/// Guards a desktop quit: when the live project has unsaved work, an
/// [AppLifecycleListener.onExitRequested] intercepts the close, shows the same
/// Save / Discard / Cancel dialog as Open/Import, and cancels the exit unless
/// the user Discards or Saves successfully. Placed under [MechXTheme] /
/// [MechXStrings] so the dialog is themed + localized. On platforms without
/// exit-request support the callback simply never fires (a plain pass-through).
class _ExitGuard extends ConsumerStatefulWidget {
  final Widget child;
  const _ExitGuard({required this.child});

  @override
  ConsumerState<_ExitGuard> createState() => _ExitGuardState();
}

class _ExitGuardState extends ConsumerState<_ExitGuard> {
  late final AppLifecycleListener _listener =
      AppLifecycleListener(onExitRequested: _onExitRequested);

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  Future<AppExitResponse> _onExitRequested() async {
    // Fresh dirty check (not the timer-fed hint) — let a clean project quit.
    if (!isProjectDirty(ref.read)) return AppExitResponse.exit;
    if (!mounted) return AppExitResponse.exit;
    final choice = await showConfirmDiscardDialog(context);
    switch (choice) {
      case DiscardChoice.save:
        await saveProject(ref);
        // A cancelled OS Save leaves the work dirty — hold the window open.
        return isProjectDirty(ref.read)
            ? AppExitResponse.cancel
            : AppExitResponse.exit;
      case DiscardChoice.discard:
        return AppExitResponse.exit;
      case DiscardChoice.cancel:
      case null:
        return AppExitResponse.cancel;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
