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

  test('clearRecovery also removes the .bak/.tmp siblings', () async {
    await writeRecovery(doc, path: path);
    await writeRecovery(doc, path: path); // second write creates the .bak
    expect(await File('$path.bak').exists(), isTrue);
    await clearRecovery(path: path);
    expect(await File(path).exists(), isFalse);
    expect(await File('$path.bak').exists(), isFalse);
    expect(await File('$path.tmp').exists(), isFalse);
  });
}
