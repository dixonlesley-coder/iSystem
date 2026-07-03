import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/app_settings.dart';
import 'package:mechx/store/app_state.dart';

/// A4 / B8 — the machine-local app-settings file: MRU (recent projects),
/// last-open, UI language + theme, and the BYO AI provider/key/model that must
/// persist across sessions but live OUTSIDE the shareable `.mechx`.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mechx_app_settings'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('MRU model', () {
    test('withRecent promotes to front, dedups by path, refreshes the name and '
        'sets lastOpenPath', () {
      var s = const AppSettings();
      s = s.withRecent('/a.mechx', 'A');
      s = s.withRecent('/b.mechx', 'B');
      s = s.withRecent('/a.mechx', 'A2'); // reopen A ⇒ promoted + deduped
      expect(s.mru.map((e) => e.path).toList(), ['/a.mechx', '/b.mechx']);
      expect(s.mru.first.name, 'A2'); // name refreshed
      expect(s.lastOpenPath, '/a.mechx');
    });

    test('withRecent caps the list at the 10 most-recent', () {
      var s = const AppSettings();
      for (var i = 0; i < 15; i++) {
        s = s.withRecent('/p$i.mechx', 'P$i');
      }
      expect(s.mru.length, 10);
      expect(s.mru.first.path, '/p14.mechx'); // newest first
      expect(s.mru.any((e) => e.path == '/p4.mechx'), isFalse); // oldest dropped
    });

    test('withoutRecent removes the entry and clears a matching lastOpenPath',
        () {
      var s = const AppSettings().withRecent('/a.mechx', 'A');
      expect(s.lastOpenPath, '/a.mechx');
      s = s.withoutRecent('/a.mechx');
      expect(s.mru, isEmpty);
      expect(s.lastOpenPath, isNull);
    });
  });

  group('(de)serialization', () {
    test('toJson omits an empty AI key (nothing to store), keeps a real one', () {
      expect(const AppSettings().toJson().containsKey('aiApiKey'), isFalse);
      expect(const AppSettings(aiApiKey: 'k').toJson()['aiApiKey'], 'k');
    });

    test('fromJson is tolerant: bad MRU entries dropped, unknown enums default',
        () {
      final s = AppSettings.fromJson({
        'mru': [
          'garbage',
          {'name': 'no path'},
          {'path': '/ok.mechx', 'name': 'Ok', 'at': 5},
        ],
        'aiProvider': 'gemini', // unknown ⇒ anthropic
        'locale': 'xx', // unknown ⇒ en
        'brightness': 'zz', // unknown ⇒ dark
      });
      expect(s.mru.single.path, '/ok.mechx');
      expect(s.aiProvider, 'anthropic');
      expect(s.localeCode, 'en');
      expect(s.brightness, 'dark');
    });
  });

  group('file IO', () {
    test('save then load round-trips through an injected temp file', () async {
      final tmp = '${dir.path}/settings.json';
      const s = AppSettings(
        mru: [MruEntry(path: '/x/a.mechx', name: 'A', lastOpenedMillis: 111)],
        lastOpenPath: '/x/a.mechx',
        localeCode: 'id',
        brightness: 'light',
        aiProvider: 'openai',
        aiApiKey: 'k',
        aiModel: 'm',
      );
      await saveAppSettings(s, path: tmp);
      final back = await loadAppSettings(path: tmp);
      expect(back.mru.single.path, '/x/a.mechx');
      expect(back.lastOpenPath, '/x/a.mechx');
      expect(back.localeCode, 'id');
      expect(back.brightness, 'light');
      expect(back.aiProvider, 'openai');
      expect(back.aiApiKey, 'k');
      expect(back.aiModel, 'm');
    });

    test('load returns defaults for a missing or corrupt file', () async {
      expect((await loadAppSettings(path: '${dir.path}/nope.json')).mru, isEmpty);
      final bad = '${dir.path}/bad.json';
      await File(bad).writeAsString('{ not json');
      final s = await loadAppSettings(path: bad);
      expect(s.localeCode, 'en');
      expect(s.aiApiKey, '');
    });
  });

  group('appSettingsProvider', () {
    test('mutates in-memory state (recordRecent) even before a seed', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      // No seed ⇒ persistence is inert (writes no real user dir), but the state
      // still updates so the Projects screen / palette can render the MRU.
      c.read(appSettingsProvider.notifier).recordRecent('/x/a.mechx', 'A');
      expect(c.read(appSettingsProvider).mru.single.path, '/x/a.mechx');
    });

    test('seeded with a temp path, recordRecent persists to that file', () async {
      final tmp = '${dir.path}/settings.json';
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(appSettingsProvider.notifier).seed(const AppSettings(), path: tmp);
      c.read(appSettingsProvider.notifier).recordRecent('/x/tower.mechx', 'Tower');
      final ok = await _awaitFile(
          tmp, (raw) => AppSettings.fromJson(jsonDecode(raw)).mru.isNotEmpty);
      expect(ok, isTrue);
      expect(
          AppSettings.fromJson(jsonDecode(await File(tmp).readAsString()))
              .mru
              .single
              .path,
          '/x/tower.mechx');
    });

    test('wireAppSettingsPersistence persists a locale/theme/AI change to disk',
        () async {
      final tmp = '${dir.path}/settings.json';
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(appSettingsProvider.notifier).seed(const AppSettings(), path: tmp);
      wireAppSettingsPersistence(c);

      // A language switch (as Preferences does) must survive a restart.
      c.read(localeProvider.notifier).set(AppLocale.id);
      final localeOk = await _awaitFile(
          tmp, (raw) => AppSettings.fromJson(jsonDecode(raw)).localeCode == 'id');
      expect(localeOk, isTrue);

      // And the BYO key persists machine-local (B8), never a project file.
      c.read(aiApiKeyProvider.notifier).set('sk-ant-secret');
      final keyOk = await _awaitFile(tmp,
          (raw) => AppSettings.fromJson(jsonDecode(raw)).aiApiKey == 'sk-ant-secret');
      expect(keyOk, isTrue);
    });
  });
}

/// Poll [path] until [ready] passes on its contents (the settings write is
/// fire-and-forget, like the autosave mirror), or a short timeout elapses.
Future<bool> _awaitFile(String path, bool Function(String) ready,
    {Duration timeout = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      final f = File(path);
      if (await f.exists() && ready(await f.readAsString())) return true;
    } catch (_) {
      // partial write / transient — keep polling
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return false;
}
