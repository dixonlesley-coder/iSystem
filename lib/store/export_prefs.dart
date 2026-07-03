/// H4 — the shared "last export directory" seam. Every export save-dialog reads
/// this as its `initialDirectory` and records the folder it wrote into, so a
/// session's exports converge on one place instead of re-prompting from the OS
/// default each time. The one-folder submittal package seeds it too.
///
/// Machine-local + transient (NOT persisted in `.mechx`): it is a per-session
/// convenience, not project data — a colleague opening the file starts from
/// their own last-used folder.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The last directory an export used (absolute path), or null until the first
/// export this session.
final lastExportDirProvider =
    NotifierProvider<LastExportDirController, String?>(
  LastExportDirController.new,
);

class LastExportDirController extends Notifier<String?> {
  @override
  String? build() => null;

  /// Record a chosen directory. An empty/null value is ignored (keeps the prior
  /// memory) so a cancelled dialog never wipes it.
  void set(String? dir) {
    if (dir != null && dir.isNotEmpty) state = dir;
  }

  /// Record the directory of a chosen FILE path (the common case — the save
  /// dialogs return a file path). Tolerant of either path separator.
  void rememberFile(String path) {
    final i = path.lastIndexOf(RegExp(r'[/\\]'));
    if (i > 0) state = path.substring(0, i);
  }
}
