// Round 48 — project I/O never destroys work it should keep:
//   persist-io-1  a pending crash-recovery snapshot survives Open / Save /
//                 New until the banner's Restore or Discard;
//   persist-io-2  Open falls back to `<file>.bak` only for a torn save, never
//                 for a file it must refuse (a newer format version).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/data/recovery.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/shell/project_io.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

ProjectDocument _doc(String name) => ProjectDocument(
  projectName: name,
  floors: const [Floor('Ground', Length(4.0))],
  calibrations: const {},
  sheets: const [],
  network: const Network(),
);

Directory _tmp(String tag) {
  final d = Directory.systemTemp.createTempSync(tag);
  addTearDown(() {
    if (d.existsSync()) d.deleteSync(recursive: true);
  });
  return d;
}

void main() {
  setUp(() {
    appSupportDirOverride = _tmp('mechx_r48_support').path;
  });

  group('persist-io-1 — a pending crash snapshot survives Open', () {
    test('opening another project keeps the untitled snapshot on disk and '
        'still offered', () async {
      final c = _c();
      // The crashed, never-saved work, exactly as main() finds and offers it.
      final slot = recoverySlotFor(null);
      await writeRecovery(_doc('CRASHED unsaved work'), path: slot);
      c.read(recoveryDocProvider.notifier).set((
        doc: _doc('CRASHED unsaved work'),
        savedAt: null,
        sourcePath: null,
        recoveryPath: slot,
      ));
      final other = '${_tmp('mechx_r48_other').path}/Other.mechx';
      File(other).writeAsStringSync(_doc('Other').encode());

      await openProjectAtLaunch(c, other);

      expect(c.read(projectControllerProvider).name, 'Other');
      expect(File(slot).existsSync(), isTrue);
      expect(
        c.read(recoveryDocProvider)?.doc?.projectName,
        'CRASHED unsaved work',
      );
      expect(await findLatestRecovery(), slot);
    });

    test(
      'opening the snapshot\'s OWN file drops it (the work is that file)',
      () async {
        final c = _c();
        final file = '${_tmp('mechx_r48_own').path}/Own.mechx';
        File(file).writeAsStringSync(_doc('Own').encode());
        final slot = recoverySlotFor(file);
        await writeRecovery(_doc('Own edited'), path: slot, sourcePath: file);
        c.read(recoveryDocProvider.notifier).set((
          doc: _doc('Own edited'),
          savedAt: null,
          sourcePath: file,
          recoveryPath: slot,
        ));
        await openProjectAtLaunch(c, file);
        expect(c.read(recoveryDocProvider), isNull);
        expect(File(slot).existsSync(), isFalse);
      },
    );

    test('recoverySlotsToClear spares only the pending slot', () {
      final c = _c();
      expect(recoverySlotsToClear(c.read, ['a.mechx', null]).paths, [
        'a.mechx',
        null,
      ]);
      c.read(recoveryDocProvider.notifier).set((
        doc: null,
        savedAt: null,
        sourcePath: null,
        recoveryPath: recoverySlotFor(null),
      ));
      final r = recoverySlotsToClear(c.read, [
        'a.mechx',
        'b.mechx',
        null,
      ], target: 'b.mechx');
      expect(r.paths, ['a.mechx', 'b.mechx']);
      expect(r.dropPending, isFalse);
    });
  });

  group('persist-io-2 — the .bak fallback is for torn saves only', () {
    test('a NEWER-format target beside a valid .bak is refused, both files '
        'untouched', () async {
      final c = _c();
      final path = '${_tmp('mechx_r48_newer').path}/Gedung.mechx';
      final newer = jsonDecode(_doc('NEW rev').encode()) as Map<String, dynamic>
        ..['version'] = ProjectDocument.currentVersion + 1;
      final newerText = jsonEncode(newer);
      File(path).writeAsStringSync(newerText);
      final bakText = _doc('OLD rev').encode();
      File('$path.bak').writeAsStringSync(bakText);

      await openProjectAtLaunch(c, path);

      expect(c.read(loadErrorProvider), contains('saved by a newer'));
      expect(c.read(projectControllerProvider).name, isNot('OLD rev'));
      expect(File(path).readAsStringSync(), newerText);
      expect(File('$path.bak').readAsStringSync(), bakText);
    });

    test('an absent target + valid .bak is restored', () async {
      final c = _c();
      final path = '${_tmp('mechx_r48_absent').path}/Gedung.mechx';
      File('$path.bak').writeAsStringSync(_doc('From backup').encode());
      await openProjectAtLaunch(c, path);
      expect(c.read(projectControllerProvider).name, 'From backup');
      expect(c.read(loadErrorProvider), isNull);
      expect(
        ProjectDocument.decode(File(path).readAsStringSync()).projectName,
        'From backup',
      );
    });

    test('a truncated target + valid .bak is restored; the torn file is kept '
        'as .corrupt-*', () async {
      final c = _c();
      final dir = _tmp('mechx_r48_torn');
      final path = '${dir.path}/Gedung.mechx';
      File(path).writeAsStringSync('{"torn');
      File('$path.bak').writeAsStringSync(_doc('Good copy').encode());
      await openProjectAtLaunch(c, path);
      expect(c.read(projectControllerProvider).name, 'Good copy');
      expect(c.read(loadErrorProvider), isNull);
      final kept = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('Gedung.mechx.corrupt-'))
          .toList();
      expect(kept, hasLength(1));
      expect(kept.single.readAsStringSync(), '{"torn');
    });

    test('corruptSidecarPath stamps yyyyMMdd-HHmmss', () {
      expect(
        corruptSidecarPath('a.mechx', DateTime(2026, 10, 18, 9, 5, 3)),
        'a.mechx.corrupt-20261018-090503',
      );
    });
  });
}
