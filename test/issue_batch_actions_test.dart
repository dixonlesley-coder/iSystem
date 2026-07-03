import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';

import 'test_util.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // Production launches with NO sheets (A1); this suite is about the
    // calibrate-all-sheets batch action, so seed the demo sheets as its targets.
    seedDemoSheets(c);
    return c;
  }

  IssueBatchAction? calibrateAction(ProviderContainer c) {
    final actions = c.read(issueBatchActionsProvider);
    for (final a in actions) {
      if (a.kind == IssueBatchKind.calibrateAllSheets) return a;
    }
    return null;
  }

  group('issueBatchActionsProvider — calibrate all', () {
    test('present but DISABLED when no sheet is calibrated', () {
      final c = makeContainer();
      final a = calibrateAction(c);
      expect(a, isNotNull);
      expect(a!.enabled, isFalse);
      expect(a.sourceSheetId, isNull);
      // Every demo sheet is a target.
      final sheetIds =
          c.read(sheetsControllerProvider).sheets.map((s) => s.id).toSet();
      expect(a.targetSheetIds, sheetIds);
    });

    test('ENABLED with a source once one sheet is calibrated', () {
      final c = makeContainer();
      final sheets = c.read(sheetsControllerProvider).sheets;
      final firstId = sheets.first.id;
      c
          .read(projectControllerProvider.notifier)
          .setCalibration(firstId, const ScaleCalibration(0.01));

      final a = calibrateAction(c)!;
      expect(a.enabled, isTrue);
      expect(a.sourceSheetId, firstId);
      // The calibrated sheet is no longer a target.
      expect(a.targetSheetIds.contains(firstId), isFalse);
      expect(a.targetSheetIds.length, sheets.length - 1);
    });

    test('action disappears once every sheet is calibrated', () {
      final c = makeContainer();
      final p = c.read(projectControllerProvider.notifier);
      for (final s in c.read(sheetsControllerProvider).sheets) {
        p.setCalibration(s.id, const ScaleCalibration(0.01));
      }
      expect(calibrateAction(c), isNull);
    });
  });

  test('no air warnings/unsized ⇒ only the calibration action (clean network)',
      () {
    final c = makeContainer();
    final kinds =
        c.read(issueBatchActionsProvider).map((a) => a.kind).toSet();
    expect(kinds, {IssueBatchKind.calibrateAllSheets});
  });
}
