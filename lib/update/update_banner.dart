/// A small bottom-corner card that surfaces auto-update progress and offers
/// "Restart & update" once a release is downloaded. Built entirely from
/// MechXTheme tokens (no Material/Fluent).
///
/// Ported from PanelMaker's `UpdateNotifier.tsx`: it renders **nothing** unless
/// the status is available / downloading / downloaded / error. Idle, checking,
/// upToDate and disabled all collapse to `SizedBox.shrink()`, so wiring it into
/// the shell as an overlay leaves the golden screenshots byte-identical (in
/// tests the updater is disabled, so the status is always `UpdateDisabled`).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/theme/design_tokens.dart';
import '../ui/theme/mechx_theme.dart';
import '../ui/widgets/mechx_button.dart';
import 'update_check.dart';
import 'update_provider.dart';

/// Overlay wrapper: stacks the banner in the bottom-right WITHOUT participating
/// in the surrounding layout, so it never shifts the shell (goldens stay
/// identical when it's hidden). Drop this over the shell with a [Stack].
class UpdateBannerOverlay extends StatelessWidget {
  const UpdateBannerOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return const Positioned(
      right: MechXSpacing.md,
      bottom: MechXSpacing.md,
      child: UpdateBanner(),
    );
  }
}

class UpdateBanner extends ConsumerStatefulWidget {
  const UpdateBanner({super.key});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  /// Local dismiss. Re-shown on a genuinely new event (an update appearing or
  /// finishing download) — not on every progress tick or transient error — so
  /// dismissing it stays dismissed mid-download (mirrors UpdateNotifier).
  bool _dismissed = false;
  String? _lastShownKey;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(updateControllerProvider);

    // Re-arm the banner when a new available/downloaded event arrives.
    final key = switch (status) {
      UpdateAvailable(:final version) => 'available:$version',
      UpdateDownloaded(:final version) => 'downloaded:$version',
      _ => null,
    };
    if (key != null && key != _lastShownKey) {
      _lastShownKey = key;
      _dismissed = false;
    }

    final visible = status is UpdateAvailable ||
        status is UpdateDownloading ||
        status is UpdateDownloaded ||
        status is UpdateError;
    if (!visible || _dismissed) return const SizedBox.shrink();

    final colors = context.colors;
    final type = context.type;
    final isError = status is UpdateError;
    final accent = isError ? colors.danger : colors.accent;

    final title = switch (status) {
      UpdateDownloaded() => 'Update ready',
      UpdateError() => 'Update error',
      _ => 'Updating iSystem',
    };

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Container(
        padding: const EdgeInsets.all(MechXSpacing.sm + 2),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: MechXRadii.card,
          border: Border.all(color: colors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: MechXSpacing.sm),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: const BorderRadius.all(Radius.circular(4)),
                  ),
                ),
                Expanded(
                  child: Text(
                    title,
                    style: type.label.copyWith(color: colors.textPrimary),
                  ),
                ),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => setState(() => _dismissed = true),
                    child: Text(
                      'Dismiss',
                      style: type.caption.copyWith(color: colors.textMuted),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: MechXSpacing.xs),
            ..._body(context, status),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, UpdateStatus status) {
    final colors = context.colors;
    final type = context.type;
    switch (status) {
      case UpdateAvailable(:final version):
        return [
          Text(
            'Version $version is available and downloading.',
            style: type.caption.copyWith(color: colors.textSecondary),
          ),
        ];
      case UpdateDownloading(:final percent):
        return [
          Text(
            'Downloading update… $percent%',
            style: type.caption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: MechXSpacing.xs),
          _ProgressBar(percent: percent),
        ];
      case UpdateDownloaded(:final version):
        return [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Version $version is ready to install.',
                  style: type.caption.copyWith(color: colors.textSecondary),
                ),
              ),
              const SizedBox(width: MechXSpacing.sm),
              MechXButton(
                label: 'Restart & update',
                primary: true,
                onPressed: () => ref
                    .read(updateControllerProvider.notifier)
                    .installUpdate(),
              ),
            ],
          ),
        ];
      case UpdateError(:final message):
        return [
          Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: type.caption.copyWith(color: colors.danger),
          ),
        ];
      // Hidden states never reach _body (guarded above).
      case UpdateIdle():
      case UpdateChecking():
      case UpdateUpToDate():
      case UpdateDisabled():
        return const [];
    }
  }
}

class _ProgressBar extends StatelessWidget {
  final int percent;
  const _ProgressBar({required this.percent});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fraction = (percent / 100).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(3)),
      child: Container(
        height: 5,
        color: colors.surfaceHover,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: fraction,
            child: ColoredBox(color: colors.accent),
          ),
        ),
      ),
    );
  }
}
