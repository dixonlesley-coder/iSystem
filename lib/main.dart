import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import 'ai/ai_client.dart' show aiProviderFromName;
import 'app.dart';
import 'data/app_settings.dart';
import 'data/autosave.dart';
import 'data/recovery.dart';
import 'store/app_state.dart';
import 'store/models/sheet.dart';
import 'ui/canvas/dxf_sheet_page.dart';
import 'ui/canvas/pdf_sheet_page.dart';
import 'ui/canvas/sheet_canvas.dart';
import 'ui/shell/project_io.dart';

void main(List<String> args) async {
  // pdfrxFlutterInitialize calls WidgetsFlutterBinding.ensureInitialized()
  // internally, so we don't need to call it again here.
  await pdfrxFlutterInitialize();

  final container = ProviderContainer(
    overrides: [
      // Override the seam so PDF sheets render their page via pdfrx and
      // placeholder sheets continue to show PlaceholderSheetPage (P0 demo).
      sheetContentBuilderProvider.overrideWithValue(
        (BuildContext context, Sheet sheet) {
          if (sheet.pdfPath != null) {
            return PdfSheetPage(sheet: sheet);
          }
          if (sheet.dxfPath != null) {
            return DxfSheetPage(sheet: sheet);
          }
          return PlaceholderSheetPage(sheet: sheet);
        },
      ),
    ],
  );

  // App-level settings (offline JSON under the app-support dir): seed the UI
  // language, theme, and BYO AI provider/key/model from the machine-local file
  // BEFORE the first frame, so nothing (notably the engineer's language) resets
  // on every relaunch. A bare env with no settings file gets today's defaults.
  final settings = await loadAppSettings();
  container.read(appSettingsProvider.notifier).seed(settings);
  container
      .read(localeProvider.notifier)
      .set(settings.localeCode == 'id' ? AppLocale.id : AppLocale.en);
  container.read(brightnessProvider.notifier).set(
      settings.brightness == 'light' ? Brightness.light : Brightness.dark);
  container
      .read(aiProviderProvider.notifier)
      .set(aiProviderFromName(settings.aiProvider));
  container.read(aiModelProvider.notifier).set(settings.aiModel);
  if (settings.aiApiKey.isNotEmpty) {
    container.read(aiApiKeyProvider.notifier).set(settings.aiApiKey);
  }
  // From here on, any change to those prefs (Preferences, palette, Open) is
  // persisted back to the settings file. Wired AFTER the seed so seeding itself
  // never re-writes the file we just read.
  wireAppSettingsPersistence(container);

  // Crash recovery: offer the MOST-RECENT per-project snapshot from a previous
  // (unclean) session, with its autosaved-at time for the banner copy and its
  // source `.mechx` path so Restore can re-link the file identity. An UNREADABLE
  // snapshot (torn by an interrupted write) is surfaced too — with a null doc —
  // so it is never silently indistinguishable from a clean exit. Then start the
  // periodic autosave loop (which writes to per-project slots).
  final latest = await findLatestRecovery();
  if (latest != null) {
    final recovered = await readRecoveryStatus(path: latest);
    if (recovered.status != RecoveryReadStatus.absent) {
      final savedAt = await recoverySnapshotMtime(path: latest);
      final sourcePath = await readRecoverySource(latest);
      container.read(recoveryDocProvider.notifier).set((
        doc: recovered.doc,
        savedAt: savedAt,
        sourcePath: sourcePath,
        recoveryPath: latest,
      ));
    }
  }
  startAutosave(container);

  // M2 (Windows-desktop citizenship): a `.mechx` handed to us on the command
  // line — an Explorer double-click, "Open with", or a taskbar jump-list entry
  // (windows/runner forwards the file path to this entrypoint) — is auto-opened
  // after bootstrap, through the SAME loader File → Open uses. A pending
  // crash-recovery snapshot takes PRECEDENCE: the engineer's unsaved work must
  // never be shadowed by a double-clicked file, so we only auto-open when there
  // is nothing to recover. Opening happens BEFORE the first frame, so the app
  // paints straight into the project (a missing path is silently ignored).
  // Single-instance forwarding (handing the path to an already-running iSystem
  // rather than launching a second window) is deliberately out of scope.
  final launchOpenPath = launchProjectPathFromArgs(args);
  if (launchOpenPath != null && container.read(recoveryDocProvider) == null) {
    await openProjectAtLaunch(container, launchOpenPath);
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const MechXApp(),
    ),
  );
}
