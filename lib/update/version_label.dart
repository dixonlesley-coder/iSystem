/// A minimal, unobtrusive surface for the running app version (e.g. `v1.0.0`),
/// read from `package_info_plus` (source of truth = pubspec `version`).
///
/// It renders **nothing** until the version resolves. In widget/golden tests the
/// platform channel `package_info_plus` relies on isn't wired, so the future
/// never completes with a value and this stays empty — keeping the golden
/// screenshots byte-identical.
library;

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../ui/theme/design_tokens.dart';
import '../ui/theme/mechx_theme.dart';

class VersionLabel extends StatefulWidget {
  const VersionLabel({super.key});

  @override
  State<VersionLabel> createState() => _VersionLabelState();
}

class _VersionLabelState extends State<VersionLabel> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      if (info.version.isNotEmpty) {
        setState(() => _version = info.version);
      }
    } catch (_) {
      // No platform channel (tests) / unavailable — stay hidden.
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _version;
    if (v == null) return const SizedBox.shrink();
    final colors = context.colors;
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.only(left: MechXSpacing.sm),
      child: Text(
        'v$v',
        style: type.caption.copyWith(color: colors.textMuted),
      ),
    );
  }
}
