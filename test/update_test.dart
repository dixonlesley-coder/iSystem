import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/update/update_check.dart';
import 'package:mechx/update/update_service.dart';

void main() {
  group('compareVersions', () {
    test('numeric, not lexical (0.2.7 < 0.2.10)', () {
      expect(compareVersions('0.2.7', '0.2.10'), lessThan(0));
      expect(compareVersions('0.2.10', '0.2.7'), greaterThan(0));
    });

    test('equal versions compare to 0', () {
      expect(compareVersions('1.2.3', '1.2.3'), 0);
    });

    test('major/minor/patch precedence', () {
      expect(compareVersions('2.0.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('1.3.0', '1.2.9'), greaterThan(0));
      expect(compareVersions('1.2.4', '1.2.3'), greaterThan(0));
    });

    test('tolerates a leading v', () {
      expect(compareVersions('v1.2.0', '1.1.0'), greaterThan(0));
      expect(compareVersions('1.2.0', 'v1.2.0'), 0);
    });

    test('ignores build metadata (SemVer §10)', () {
      expect(compareVersions('1.0.0+5', '1.0.0+9'), 0);
      expect(compareVersions('1.0.0+build.1', '1.0.0'), 0);
    });

    test('pre-release sorts below the full release (SemVer §11)', () {
      expect(compareVersions('1.0.0-rc.1', '1.0.0'), lessThan(0));
      expect(compareVersions('1.0.0', '1.0.0-rc.1'), greaterThan(0));
    });

    test('missing components default to 0', () {
      expect(compareVersions('1', '1.0.0'), 0);
      expect(compareVersions('1.2', '1.2.0'), 0);
      expect(compareVersions('1.2', '1.2.1'), lessThan(0));
    });
  });

  group('parseLatest', () {
    test('parses a valid feed and strips a leading v', () {
      final r = parseLatest({
        'version': 'v1.4.2',
        'url': 'https://example.com/iSystem-1.4.2-setup.exe',
        'sha256': 'ABCDEF',
        'notes': 'bugfixes',
      });
      expect(r, isNotNull);
      expect(r!.version, '1.4.2');
      expect(r.url, 'https://example.com/iSystem-1.4.2-setup.exe');
      expect(r.sha256, 'abcdef'); // lower-cased
      expect(r.notes, 'bugfixes');
    });

    test('sha256 and notes are optional', () {
      final r = parseLatest({
        'version': '1.0.0',
        'url': 'https://example.com/x.exe',
      });
      expect(r, isNotNull);
      expect(r!.sha256, '');
      expect(r.notes, '');
    });

    test('returns null when version is missing or not a string', () {
      expect(parseLatest({'url': 'https://example.com/x.exe'}), isNull);
      expect(
        parseLatest({'version': 42, 'url': 'https://example.com/x.exe'}),
        isNull,
      );
      expect(
        parseLatest({'version': '', 'url': 'https://example.com/x.exe'}),
        isNull,
      );
    });

    test('returns null when url is missing or empty', () {
      expect(parseLatest({'version': '1.0.0'}), isNull);
      expect(parseLatest({'version': '1.0.0', 'url': ''}), isNull);
    });
  });

  group('isBenignUpdateError', () {
    test('SocketException is benign (offline)', () {
      expect(isBenignUpdateError(const SocketException('failed')), isTrue);
    });

    test('TimeoutException is benign', () {
      expect(isBenignUpdateError(TimeoutException('slow')), isTrue);
    });

    test('HttpException is benign', () {
      expect(isBenignUpdateError(const HttpException('aborted')), isTrue);
    });

    test('404 / not found message is benign', () {
      expect(isBenignUpdateError(Exception('feed returned HTTP 404')), isTrue);
      expect(isBenignUpdateError('Not Found'), isTrue);
    });

    test('DNS failure message is benign', () {
      expect(isBenignUpdateError('Failed host lookup: github.com'), isTrue);
    });

    test('a genuine FormatException (bad hash) is NOT benign', () {
      expect(
        isBenignUpdateError(
            const FormatException('Downloaded installer failed SHA-256')),
        isFalse,
      );
    });

    test('an unexpected error is NOT benign', () {
      expect(isBenignUpdateError(StateError('boom')), isFalse);
    });
  });

  group('UpdateRunner.check transitions', () {
    test('disabled build emits UpdateDisabled and skips the network', () async {
      final backend = _FakeBackend();
      final runner = UpdateRunner(backend, enabled: false);
      final seen = <UpdateStatus>[];
      final result = await runner.check(seen.add);
      expect(result, isNull);
      expect(seen.single, isA<UpdateDisabled>());
      expect(backend.fetchCalls, 0);
    });

    test('newer remote version → checking then available', () async {
      final backend = _FakeBackend(
        current: '1.0.0',
        latest: const LatestRelease(version: '1.1.0', url: 'https://x/y.exe'),
      );
      final runner = UpdateRunner(backend);
      final seen = <UpdateStatus>[];
      final result = await runner.check(seen.add);
      expect(seen.first, isA<UpdateChecking>());
      expect(seen.last, isA<UpdateAvailable>());
      expect((seen.last as UpdateAvailable).version, '1.1.0');
      expect(result?.version, '1.1.0');
    });

    test('same version → upToDate, no release returned', () async {
      final backend = _FakeBackend(
        current: '1.1.0',
        latest: const LatestRelease(version: '1.1.0', url: 'https://x/y.exe'),
      );
      final runner = UpdateRunner(backend);
      final seen = <UpdateStatus>[];
      final result = await runner.check(seen.add);
      expect(seen.last, isA<UpdateUpToDate>());
      expect(result, isNull);
    });

    test('null feed (404) → upToDate', () async {
      final backend = _FakeBackend(current: '1.0.0', latest: null);
      final runner = UpdateRunner(backend);
      final seen = <UpdateStatus>[];
      await runner.check(seen.add);
      expect(seen.last, isA<UpdateUpToDate>());
    });

    test('benign network error → upToDate (silent)', () async {
      final backend = _FakeBackend.throwing(const SocketException('offline'));
      final runner = UpdateRunner(backend);
      final seen = <UpdateStatus>[];
      await runner.check(seen.add);
      expect(seen.last, isA<UpdateUpToDate>());
    });

    test('non-benign error → UpdateError', () async {
      final backend = _FakeBackend.throwing(StateError('boom'));
      final runner = UpdateRunner(backend);
      final seen = <UpdateStatus>[];
      await runner.check(seen.add);
      expect(seen.last, isA<UpdateError>());
    });
  });

  group('UpdateRunner.download transitions', () {
    test('progress then downloaded', () async {
      final backend = _FakeBackend(downloadedPath: r'C:\tmp\setup.exe');
      final runner = UpdateRunner(backend);
      final seen = <UpdateStatus>[];
      const release = LatestRelease(version: '1.2.0', url: 'https://x/y.exe');
      final result = await runner.download(release, seen.add);
      expect(seen.first, isA<UpdateDownloading>());
      expect(result, isA<UpdateDownloaded>());
      expect((result as UpdateDownloaded).path, r'C:\tmp\setup.exe');
      // The fake reports a 100% tick before finishing.
      expect(
        seen.whereType<UpdateDownloading>().last.percent,
        100,
      );
    });

    test('benign download failure → upToDate', () async {
      final backend =
          _FakeBackend.throwingDownload(const SocketException('drop'));
      final runner = UpdateRunner(backend);
      final seen = <UpdateStatus>[];
      const release = LatestRelease(version: '1.2.0', url: 'https://x/y.exe');
      final result = await runner.download(release, seen.add);
      expect(result, isA<UpdateUpToDate>());
    });

    test('hash-mismatch (FormatException) download → UpdateError', () async {
      final backend = _FakeBackend.throwingDownload(
          const FormatException('failed SHA-256 verification'));
      final runner = UpdateRunner(backend);
      final seen = <UpdateStatus>[];
      const release = LatestRelease(version: '1.2.0', url: 'https://x/y.exe');
      final result = await runner.download(release, seen.add);
      expect(result, isA<UpdateError>());
    });
  });
}

/// A test double for [UpdateBackend] — no network, no filesystem, no Process.
class _FakeBackend implements UpdateBackend {
  final String current;
  final LatestRelease? latest;
  final String downloadedPath;
  final Object? fetchError;
  final Object? downloadError;
  int fetchCalls = 0;

  _FakeBackend({
    this.current = '1.0.0',
    this.latest,
    this.downloadedPath = r'C:\tmp\setup.exe',
  })  : fetchError = null,
        downloadError = null;

  _FakeBackend.throwing(this.fetchError)
      : current = '1.0.0',
        latest = null,
        downloadedPath = r'C:\tmp\setup.exe',
        downloadError = null;

  _FakeBackend.throwingDownload(this.downloadError)
      : current = '1.0.0',
        latest = null,
        downloadedPath = r'C:\tmp\setup.exe',
        fetchError = null;

  @override
  Future<String> currentVersion() async => current;

  @override
  Future<LatestRelease?> fetchLatest() async {
    fetchCalls++;
    if (fetchError != null) throw fetchError!;
    return latest;
  }

  @override
  Future<String> download(
    LatestRelease release, {
    void Function(int percent)? onProgress,
  }) async {
    if (downloadError != null) throw downloadError!;
    onProgress?.call(50);
    onProgress?.call(100);
    return downloadedPath;
  }

  @override
  Future<void> launchInstaller(String path) async {}
}
