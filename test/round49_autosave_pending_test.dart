// Round 49 (regression-autosave-no-protection-while-snapshot-pending) — while
// the launch banner still offers a pending crash snapshot that owns this
// session's recovery slot, the autosave loop writes this session's work to
// the slot's SESSION SIBLING (never skipping, never touching the pending
// file), and Restore / Discard / Save resolve the sibling with it.
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

Future<String?> _awaitFileContaining(String path, String needle,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final f = File(path);
    if (f.existsSync()) {
      final t = f.readAsStringSync();
      if (t.contains(needle)) return t;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return null;
}

void main() {
  late Directory support;
  setUp(() {
    support = Directory.systemTemp.createTempSync('mechx_r49_support');
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

  test('recoveryPartnerSlot toggles <key>.mechx <-> <key>.session.mechx', () {
    final p = recoverySlotFor(null);
    expect(p, endsWith('untitled.mechx'));
    expect(recoveryPartnerSlot(p), endsWith('untitled.session.mechx'));
    expect(recoveryPartnerSlot(recoveryPartnerSlot(p)), p);
  });

  Future<(ProviderContainer, String, String)> pendingSession() async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final slot = recoverySlotFor(null);
    await writeRecovery(_doc('CRASHED'), path: slot);
    final pendingBytes = File(slot).readAsStringSync();
    c.read(recoveryDocProvider.notifier).set((
      doc: _doc('CRASHED'),
      savedAt: null,
      sourcePath: null,
      recoveryPath: slot,
    ));
    // The relaunched untitled session keeps working with the banner showing.
    c.read(projectControllerProvider.notifier).setName('NEW SESSION WORK');
    return (c, slot, pendingBytes);
  }

  test('a dirty session beside a pending untitled snapshot is snapshotted to '
      'the sibling; the pending file stays byte-identical', () async {
    final (c, slot, pendingBytes) = await pendingSession();
    final timer = startAutosave(c, interval: const Duration(milliseconds: 20));
    addTearDown(timer.cancel);
    final sibling = recoveryPartnerSlot(slot);
    final written = await _awaitFileContaining(sibling, 'NEW SESSION WORK');
    expect(written, isNotNull,
        reason: 'the new session must be crash-protected while pending');
    expect(File(slot).readAsStringSync(), pendingBytes);
    // A second crash now: the launch lookup offers the newest snapshot —
    // this session's work, not the older pending one.
    expect(await findLatestRecovery(), sibling);
    expect((await readRecovery(path: sibling))?.projectName,
        'NEW SESSION WORK');
  });

  test('Discard / Restore (clearPendingRecovery) resolve the sibling too',
      () async {
    final (c, slot, _) = await pendingSession();
    final timer = startAutosave(c, interval: const Duration(milliseconds: 20));
    final sibling = recoveryPartnerSlot(slot);
    expect(await _awaitFileContaining(sibling, 'NEW SESSION WORK'), isNotNull);
    timer.cancel();
    await clearPendingRecovery(path: slot);
    expect(File(slot).existsSync(), isFalse);
    expect(File(sibling).existsSync(), isFalse);
  });

  test('a Save elsewhere keeps the pending snapshot but clears this '
      "session's sibling (that work is now saved)", () async {
    final (c, slot, pendingBytes) = await pendingSession();
    final timer = startAutosave(c, interval: const Duration(milliseconds: 20));
    final sibling = recoveryPartnerSlot(slot);
    expect(await _awaitFileContaining(sibling, 'NEW SESSION WORK'), isNotNull);
    timer.cancel();
    final target = '${support.path}/Saved.mechx';
    final toClear =
        recoverySlotsToClear(c.read, [null, target, null], target: target);
    expect(toClear.spare, {slot});
    expect(toClear.alsoClear, [sibling]);
    await clearRecoveryFor(toClear);
    expect(File(slot).readAsStringSync(), pendingBytes);
    expect(File(sibling).existsSync(), isFalse);
  });
}
