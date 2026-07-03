import 'dart:io';

import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/data/recovery.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

void main() {
  late String path;

  setUp(() {
    path = '${Directory.systemTemp.path}/mechx_recovery_test_'
        '${DateTime.now().microsecondsSinceEpoch}.mechx';
  });
  tearDown(() async {
    for (final p in [path, '$path.bak', '$path.tmp']) {
      final f = File(p);
      if (await f.exists()) await f.delete();
    }
  });

  const doc = ProjectDocument(
    projectName: 'Recovered',
    floors: [Floor('G', Length(3.5))],
    calibrations: {'s1': ScaleCalibration(0.02)},
    sheets: [Sheet(id: 's1', name: 'P', sizePx: Size(100, 100))],
    network: Network(
      nodes: [NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0)],
    ),
  );

  test('write → read round-trips the document', () async {
    await writeRecovery(doc, path: path);
    final back = await readRecovery(path: path);
    expect(back, isNotNull);
    expect(back!.projectName, 'Recovered');
    expect(back.network.nodes.single.id, 'a');
  });

  test('read falls back to the .bak when the primary is missing', () async {
    // Simulate a crash in the atomic writer's displace→rename window: the good
    // snapshot sits in `<path>.bak`, the primary `path` never got created.
    await File('$path.bak').writeAsString(doc.encode());
    expect(await File(path).exists(), isFalse);
    final read = await readRecoveryStatus(path: path);
    expect(read.status, RecoveryReadStatus.ok);
    expect(read.doc, isNotNull);
    expect(read.doc!.projectName, 'Recovered');
  });

  test('read prefers a good .bak over a torn primary', () async {
    // Primary is present but corrupt (torn write); the backup is intact.
    await File(path).writeAsString('{ not: valid json');
    await File('$path.bak').writeAsString(doc.encode());
    final read = await readRecoveryStatus(path: path);
    expect(read.status, RecoveryReadStatus.ok);
    expect(read.doc!.projectName, 'Recovered');
  });

  test('a torn primary with no backup is surfaced as unreadable', () async {
    await File(path).writeAsString('{ not: valid json');
    final read = await readRecoveryStatus(path: path);
    expect(read.status, RecoveryReadStatus.unreadable);
    expect(read.doc, isNull);
  });

  test('read returns null when there is no recovery file', () async {
    expect(await readRecovery(path: path), isNull);
  });

  test('clear deletes the recovery file', () async {
    await writeRecovery(doc, path: path);
    expect(await File(path).exists(), isTrue);
    await clearRecovery(path: path);
    expect(await File(path).exists(), isFalse);
    expect(await readRecovery(path: path), isNull);
  });

  test('recoverySnapshotMtime reads the write time alongside readRecovery',
      () async {
    final before = DateTime.now().subtract(const Duration(seconds: 2));
    await writeRecovery(doc, path: path);
    final mtime = await recoverySnapshotMtime(path: path);
    expect(mtime, isNotNull);
    // The stat time must be sane — at/after the moment we started writing.
    expect(mtime!.isBefore(before), isFalse);
  });

  test('recoverySnapshotMtime returns null when there is no recovery file',
      () async {
    expect(await recoverySnapshotMtime(path: path), isNull);
  });

  test(
      'writeRecovery is atomic: the displaced previous snapshot survives as '
      '.bak and no .tmp is left behind', () async {
    await writeRecovery(doc, path: path);
    final firstContent = await File(path).readAsString();

    const doc2 = ProjectDocument(
      projectName: 'Recovered v2',
      floors: [Floor('G', Length(3.5))],
      calibrations: {},
      sheets: [],
      network: Network(),
    );
    await writeRecovery(doc2, path: path);

    // The target carries the NEW write; the previous good copy was displaced
    // to `.bak` (never overwritten in place), and the temp file was renamed
    // into place (not abandoned).
    expect((await readRecovery(path: path))!.projectName, 'Recovered v2');
    expect(await File('$path.bak').exists(), isTrue);
    expect(await File('$path.bak').readAsString(), firstContent);
    expect(await File('$path.tmp').exists(), isFalse);
  });

  test(
      'readRecoveryStatus distinguishes absent from unreadable (a torn '
      'snapshot must not read as a clean exit)', () async {
    // No file at all — the previous session exited cleanly.
    var read = await readRecoveryStatus(path: path);
    expect(read.status, RecoveryReadStatus.absent);
    expect(read.doc, isNull);

    // A file EXISTS but is torn (interrupted write) — distinct status.
    await File(path).writeAsString('{"version": 2, "projectName": "torn');
    read = await readRecoveryStatus(path: path);
    expect(read.status, RecoveryReadStatus.unreadable);
    expect(read.doc, isNull);
    // The nullable-doc wrapper keeps its old contract for both cases.
    expect(await readRecovery(path: path), isNull);

    // A good snapshot decodes with `ok`.
    await writeRecovery(doc, path: path);
    read = await readRecoveryStatus(path: path);
    expect(read.status, RecoveryReadStatus.ok);
    expect(read.doc!.projectName, 'Recovered');
  });

  test('clearRecovery also removes the .bak/.tmp/.src siblings', () async {
    await writeRecovery(doc, path: path, sourcePath: '/proj/tower.mechx');
    await writeRecovery(doc, path: path); // second write creates the .bak
    expect(await File('$path.bak').exists(), isTrue);
    await clearRecovery(path: path);
    expect(await File(path).exists(), isFalse);
    expect(await File('$path.bak').exists(), isFalse);
    expect(await File('$path.tmp').exists(), isFalse);
    expect(await File('$path.src').exists(), isFalse);
  });

  group('B2 — per-project slots, source sidecar, latest lookup', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mechx_recovery_b2'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('appSupportDir / recoveryDir resolve under an "iSystem" folder', () {
      expect(appSupportDir().endsWith('iSystem'), isTrue);
      expect(recoveryDir().contains('iSystem'), isTrue);
      expect(recoveryDir().endsWith('recovery'), isTrue);
    });

    test('recoverySlotFor: untitled is stable; a path hashes deterministically '
        'to its own slot', () {
      final untitled = recoverySlotFor(null);
      expect(recoverySlotFor(''), untitled); // empty ⇒ untitled
      expect(untitled.endsWith('untitled.mechx'), isTrue);
      final a = recoverySlotFor('/x/tower.mechx');
      expect(recoverySlotFor('/x/tower.mechx'), a); // deterministic across calls
      expect(a, isNot(recoverySlotFor('/x/other.mechx')));
      expect(a, isNot(untitled));
      expect(a.endsWith('.mechx'), isTrue);
    });

    test('recoveryFilePath is the untitled slot (no longer %TEMP%)', () {
      expect(recoveryFilePath(), recoverySlotFor(null));
      expect(recoveryFilePath().contains('iSystem'), isTrue);
    });

    test('writeRecovery stores the source path in a .src sidecar; '
        'readRecoverySource reads it back; a source-less write clears it',
        () async {
      final p = '${dir.path}/slot.mechx';
      await writeRecovery(doc, path: p, sourcePath: '/projects/tower.mechx');
      expect(await File('$p.src').exists(), isTrue);
      expect(await readRecoverySource(p), '/projects/tower.mechx');

      // A subsequent write with NO source clears the stale sidecar.
      await writeRecovery(doc, path: p);
      expect(await File('$p.src').exists(), isFalse);
      expect(await readRecoverySource(p), isNull);
    });

    test('findLatestRecovery returns the primary .mechx (skipping siblings) and '
        'null for an empty / missing dir', () async {
      // Empty dir ⇒ null.
      expect(await findLatestRecovery(dir: dir.path), isNull);

      final p = '${dir.path}/only.mechx';
      await writeRecovery(doc, path: p, sourcePath: '/a.mechx');
      // Add sibling noise the lookup must ignore.
      await File('$p.tmp').writeAsString('x');
      await File('$p.bak').writeAsString('y');

      final latest = await findLatestRecovery(dir: dir.path);
      expect(latest, p); // the primary, not the .src/.tmp/.bak
      expect(latest!.endsWith('.mechx'), isTrue);

      // A non-existent directory ⇒ null (never throws).
      expect(await findLatestRecovery(dir: '${dir.path}/missing'), isNull);
    });
  });
}
