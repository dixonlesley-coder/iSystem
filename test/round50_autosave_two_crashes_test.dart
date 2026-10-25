// Round 50 (regression-4) — two crashes in a row with the recovery banner
// left unresolved: the FIRST crash's snapshot (never restored nor discarded)
// must still be on disk, and offered, after the second relaunch's autosave
// ticks — the Round-48 rule that only Restore / an explicit Discard may
// replace a pending snapshot, applied to every unresolved member of the
// primary / sibling family.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/data/recovery.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/shell/project_io.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

ProjectDocument _doc(String name) => ProjectDocument(
      projectName: name,
      floors: const [Floor('Ground', Length(4.0))],
      calibrations: const {},
      sheets: const [],
      network: const Network(),
    );

Future<bool> _awaitFileContaining(String path, String needle,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final f = File(path);
    if (f.existsSync() && f.readAsStringSync().contains(needle)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return false;
}

/// Every file under the recovery dir holding [needle].
List<String> _filesContaining(String needle) {
  final d = Directory(recoveryDir());
  if (!d.existsSync()) return const [];
  return [
    for (final e in d.listSync(recursive: true))
      if (e is File && e.readAsStringSync().contains(needle)) e.path,
  ];
}

/// A relaunch: the launch lookup + banner state exactly as `main.dart` sets
/// it, then a dirty session that keeps working with the banner open.
Future<ProviderContainer> _launch(String work) async {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  final offered = await findRecoveryToOffer();
  if (offered != null) {
    c
        .read(protectedRecoverySlotsProvider.notifier)
        .set({...recoveryFamilyOnDisk(offered), offered});
    c.read(recoveryDocProvider.notifier).set((
      doc: await readRecovery(path: offered),
      savedAt: null,
      sourcePath: null,
      recoveryPath: offered,
    ));
  }
  c.read(projectControllerProvider.notifier).setName(work);
  return c;
}

void main() {
  late Directory support;
  setUp(() {
    support = Directory.systemTemp.createTempSync('mechx_r50_support');
    appSupportDirOverride = support.path;
  });
  tearDown(() async {
    for (var i = 0; i < 5; i++) {
      try {
        if (support.existsSync()) support.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  test('slot family naming', () {
    final p = recoverySlotFor(null);
    expect(recoverySessionSlot(p, 0), p);
    expect(recoverySessionSlot(p, 1), endsWith('untitled.session.mechx'));
    expect(recoverySessionSlot(p, 2), endsWith('untitled.session-2.mechx'));
    expect(recoveryPrimarySlot(recoverySessionSlot(p, 7)), p);
    expect(sameRecoveryFamily(recoverySessionSlot(p, 3), p), isTrue);
    expect(sameRecoveryFamily(recoverySlotFor('/x/a.mechx'), p), isFalse);
  });

  test('crash A, launch 1 writes B beside it, crash, launch 2 ticks: A is '
      'still on disk and offered first, B is kept too', () async {
    // Crash A.
    await writeRecovery(_doc('CRASH-A'), path: recoverySlotFor(null));
    // Launch 1: the banner offers A; the session keeps working (B).
    final c1 = await _launch('SESSION-B');
    expect(c1.read(recoveryDocProvider)?.recoveryPath, recoverySlotFor(null));
    final t1 = startAutosave(c1, interval: const Duration(milliseconds: 20));
    final sibling = recoveryPartnerSlot(recoverySlotFor(null));
    expect(await _awaitFileContaining(sibling, 'SESSION-B'), isTrue);
    t1.cancel();
    // Second crash. Launch 2 (no resolution of A ever happened): the OLDEST
    // unresolved member of the family — A — is offered.
    final c2 = await _launch('SESSION-C');
    expect(c2.read(recoveryDocProvider)?.doc?.projectName, 'CRASH-A');
    final t2 = startAutosave(c2, interval: const Duration(milliseconds: 20));
    addTearDown(t2.cancel);
    final third = recoverySessionSlot(recoverySlotFor(null), 2);
    expect(await _awaitFileContaining(third, 'SESSION-C'), isTrue);
    // Several more ticks: neither unresolved snapshot is ever overwritten.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    t2.cancel();
    expect(_filesContaining('CRASH-A'), isNotEmpty);
    expect(_filesContaining('SESSION-B'), isNotEmpty);
    expect(
        (await readRecovery(path: recoverySlotFor(null)))?.projectName,
        'CRASH-A');
    expect((await readRecovery(path: sibling))?.projectName, 'SESSION-B');

    // A Save elsewhere while A is pending clears only SESSION-C (this
    // session's own work), never A nor B.
    final target = '${support.path}/Saved.mechx';
    await clearRecoveryFor(
        recoverySlotsToClear(c2.read, [null, target, null], target: target));
    expect(File(third).existsSync(), isFalse);
    expect(_filesContaining('CRASH-A'), isNotEmpty);
    expect(_filesContaining('SESSION-B'), isNotEmpty);

    // Discarding A deletes A only — B is a different unresolved snapshot and
    // is offered at the next launch.
    await clearPendingRecovery(
        path: recoverySlotFor(null),
        sessionSlots: c2.read(sessionRecoverySlotsProvider));
    expect(_filesContaining('CRASH-A'), isEmpty);
    expect(_filesContaining('SESSION-B'), isNotEmpty);
    expect(await findRecoveryToOffer(), sibling);
  });
}
