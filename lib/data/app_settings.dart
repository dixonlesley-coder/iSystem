import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' show Brightness;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/ai_client.dart' show kDefaultAnthropicModel;
import '../store/app_state.dart';
import 'recovery.dart' show appSupportDir, atomicWriteString;

/// Machine-local (per-user) app settings — an OFFLINE, plugin-free JSON file
/// under the app-support dir. Nothing survives a restart today (the review's
/// A4): locale re-seeds English and the theme dark every launch, and there is
/// no recent-projects list. This file carries the handful of things that SHOULD
/// persist across sessions but must NOT ride inside the shareable `.mechx`: the
/// MRU (recent projects), the last-open file, the UI language + theme, and the
/// BYO AI provider/key/model (the key is a secret — machine-local, never in a
/// project file: the review's B8).
///
/// It is deliberately DECOUPLED from the project document. Load it once at
/// launch ([loadAppSettings]) to seed the providers, then persist on change via
/// [appSettingsProvider] / [wireAppSettingsPersistence]. Every read/write
/// tolerates IO/parse errors and degrades to defaults — a bare env with no
/// settings file gets today's behaviour.

/// One recent-project entry: the file path, a display name, and when it was last
/// opened (epoch millis, for ordering + a relative "opened …" hint later).
class MruEntry {
  final String path;
  final String name;
  final int lastOpenedMillis;

  const MruEntry({
    required this.path,
    required this.name,
    required this.lastOpenedMillis,
  });

  Map<String, dynamic> toJson() =>
      {'path': path, 'name': name, 'at': lastOpenedMillis};

  /// Tolerant decode — a non-map or a missing/empty path yields null (dropped).
  static MruEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    return MruEntry(
      path: path,
      name: raw['name'] is String ? raw['name'] as String : path,
      lastOpenedMillis: (raw['at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The machine-local settings value object.
class AppSettings {
  /// Recent projects, most-recent first, capped at [_mruCap].
  final List<MruEntry> mru;

  /// The last project file opened/saved (for a future reopen-last).
  final String? lastOpenPath;

  /// UI language code: `'en'` (default) or `'id'`.
  final String localeCode;

  /// Theme: `'light'` or `'dark'` (default).
  final String brightness;

  /// BYO AI copilot provider (`'anthropic'` default / `'openai'` / `'glm'`),
  /// key, and model — machine-local, kept OUT of the shareable `.mechx` (B8).
  final String aiProvider;
  final String aiApiKey;
  final String aiModel;

  const AppSettings({
    this.mru = const [],
    this.lastOpenPath,
    this.localeCode = 'en',
    this.brightness = 'dark',
    this.aiProvider = 'anthropic',
    this.aiApiKey = '',
    this.aiModel = kDefaultAnthropicModel,
  });

  static const int _mruCap = 10;
  static const Object _noUpdate = Object();

  AppSettings copyWith({
    List<MruEntry>? mru,
    Object? lastOpenPath = _noUpdate,
    String? localeCode,
    String? brightness,
    String? aiProvider,
    String? aiApiKey,
    String? aiModel,
  }) =>
      AppSettings(
        mru: mru ?? this.mru,
        lastOpenPath: identical(lastOpenPath, _noUpdate)
            ? this.lastOpenPath
            : lastOpenPath as String?,
        localeCode: localeCode ?? this.localeCode,
        brightness: brightness ?? this.brightness,
        aiProvider: aiProvider ?? this.aiProvider,
        aiApiKey: aiApiKey ?? this.aiApiKey,
        aiModel: aiModel ?? this.aiModel,
      );

  /// Promote [path] to the front of the MRU (dedup by path, refresh its name +
  /// timestamp), cap the list, and remember it as the last-open file.
  AppSettings withRecent(String path, String name) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rest = mru.where((e) => e.path != path);
    final next = <MruEntry>[
      MruEntry(path: path, name: name, lastOpenedMillis: now),
      ...rest,
    ];
    return copyWith(
      mru: next.length > _mruCap ? next.sublist(0, _mruCap) : next,
      lastOpenPath: path,
    );
  }

  /// Drop [path] from the MRU (a moved/deleted file the user removed), clearing
  /// the last-open pointer when it referenced that file.
  AppSettings withoutRecent(String path) => copyWith(
        mru: mru.where((e) => e.path != path).toList(growable: false),
        lastOpenPath: lastOpenPath == path ? null : lastOpenPath,
      );

  Map<String, dynamic> toJson() => {
        'mru': [for (final e in mru) e.toJson()],
        if (lastOpenPath != null) 'lastOpenPath': lastOpenPath,
        'locale': localeCode,
        'brightness': brightness,
        'aiProvider': aiProvider,
        if (aiApiKey.isNotEmpty) 'aiApiKey': aiApiKey,
        'aiModel': aiModel,
      };

  /// Tolerant decode: every field falls back to its default on an
  /// unknown/absent/ill-typed value.
  factory AppSettings.fromJson(Map<dynamic, dynamic> raw) => AppSettings(
        mru: [
          for (final e in (raw['mru'] as List? ?? const [])) ?MruEntry.fromJson(e),
        ],
        lastOpenPath:
            raw['lastOpenPath'] is String ? raw['lastOpenPath'] as String : null,
        localeCode: raw['locale'] == 'id' ? 'id' : 'en',
        brightness: raw['brightness'] == 'light' ? 'light' : 'dark',
        aiProvider: const {'openai', 'glm'}.contains(raw['aiProvider'])
            ? raw['aiProvider'] as String
            : 'anthropic',
        aiApiKey: raw['aiApiKey'] is String ? raw['aiApiKey'] as String : '',
        aiModel: raw['aiModel'] is String && (raw['aiModel'] as String).isNotEmpty
            ? raw['aiModel'] as String
            : kDefaultAnthropicModel,
      );
}

/// Test seam: when set, the settings file resolves here instead of the real
/// per-user location, so the widget/golden suite + unit tests never read/write a
/// real user dir and don't race across parallel isolates. Null in production.
String? appSettingsPathOverride;

/// The machine-local settings file path (`<app-support>/settings.json`), or the
/// [appSettingsPathOverride] when a test injected one.
String appSettingsFilePath() =>
    appSettingsPathOverride ??
    '${appSupportDir()}${Platform.pathSeparator}settings.json';

/// Load the settings file, degrading to defaults on any error (absent file,
/// bad JSON, wrong shape) — a fresh install gets today's behaviour.
Future<AppSettings> loadAppSettings({String? path}) async {
  try {
    final f = File(path ?? appSettingsFilePath());
    if (!await f.exists()) return const AppSettings();
    final raw = jsonDecode(await f.readAsString());
    return raw is Map ? AppSettings.fromJson(raw) : const AppSettings();
  } catch (_) {
    return const AppSettings();
  }
}

/// Persist [s] atomically (best effort — a transient disk error is swallowed so
/// a settings write never interrupts the app).
Future<void> saveAppSettings(AppSettings s, {String? path}) async {
  try {
    await atomicWriteString(
      path ?? appSettingsFilePath(),
      const JsonEncoder.withIndent('  ').convert(s.toJson()),
    );
  } catch (_) {
    // best effort
  }
}

/// The live app settings. Starts at defaults; [AppSettingsController.seed] loads
/// the on-disk state at launch AND enables persistence. Persistence is INERT
/// until seeded — so the widget/golden suite (which never calls [seed]) touches
/// no user dir.
final appSettingsProvider =
    NotifierProvider<AppSettingsController, AppSettings>(
  AppSettingsController.new,
);

class AppSettingsController extends Notifier<AppSettings> {
  // Null ⇒ persistence is inert (pre-launch, and in tests) so no real user dir
  // is written. Set by [seed] to the resolved (or injected) settings path.
  String? _persistPath;

  @override
  AppSettings build() => const AppSettings();

  /// Seed from disk at launch and ENABLE persistence to [path] (defaults to the
  /// resolved per-user file). Does not itself persist — nothing changed since
  /// the read.
  void seed(AppSettings settings, {String? path}) {
    _persistPath = path ?? appSettingsFilePath();
    state = settings;
  }

  void set(AppSettings settings) {
    state = settings;
    _persist();
  }

  /// Record a project file at [path] in the MRU / last-open list.
  void recordRecent(String path, String name) =>
      set(state.withRecent(path, name));

  /// Remove a project file (moved/deleted) from the recent list.
  void removeRecent(String path) => set(state.withoutRecent(path));

  void _persist() {
    final p = _persistPath;
    if (p == null) return; // inert until seeded (tests, pre-launch)
    saveAppSettings(state, path: p); // fire-and-forget, like the autosave mirror
  }
}

/// Wire the app-level preference providers (language, theme, AI provider/key/
/// model) so any change persists to the machine-local settings file. Called
/// once at launch AFTER [AppSettingsController.seed]. NOT active in the
/// widget/golden suite (which never calls it), so those tests write no user dir.
void wireAppSettingsPersistence(ProviderContainer c) {
  void capture() {
    final cur = c.read(appSettingsProvider);
    c.read(appSettingsProvider.notifier).set(cur.copyWith(
          localeCode: c.read(localeProvider).name,
          brightness:
              c.read(brightnessProvider) == Brightness.light ? 'light' : 'dark',
          aiProvider: c.read(aiProviderProvider).name,
          aiApiKey: c.read(aiApiKeyProvider),
          aiModel: c.read(aiModelProvider),
        ));
  }

  c.listen(localeProvider, (_, __) => capture());
  c.listen(brightnessProvider, (_, __) => capture());
  c.listen(aiProviderProvider, (_, __) => capture());
  c.listen(aiApiKeyProvider, (_, __) => capture());
  c.listen(aiModelProvider, (_, __) => capture());
}
