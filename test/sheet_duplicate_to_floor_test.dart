import 'dart:io';

import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_assets.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';

/// F6 — reuse one imported floor plan across repeated building floors:
/// [SheetsController.duplicateSheetToFloor] creates a new rail entry that
/// SHARES the source path + a COPY of the calibration (no re-import), mapped to
/// a chosen floor. The shared-source link is plain duplication (no live link),
/// and both sheets round-trip through `.mechx`.
void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('duplicateSheetToFloor', () {
    test(
        'shares the source path + a copy of the calibration, distinct id, '
        'mapped to the chosen floor', () {
      final c = makeContainer();
      final sheets = c.read(sheetsControllerProvider.notifier);
      final project = c.read(projectControllerProvider.notifier);
      sheets.loadSheets(const [
        Sheet(
            id: 'typical',
            name: 'Typical Floor',
            pdfPath: '/plans/typical.pdf',
            pageIndex: 0,
            sizePx: Size(1000, 800)),
      ]);
      project.setCalibration('typical', const ScaleCalibration(0.0125));

      final newId = sheets.duplicateSheetToFloor('typical', 1);
      expect(newId, isNotNull);
      expect(newId, isNot('typical')); // distinct sheet id

      final state = c.read(sheetsControllerProvider);
      final dup = state.sheetById(newId!)!;
      // Same source (no re-import): path + page + natural size all carried.
      expect(dup.pdfPath, '/plans/typical.pdf');
      expect(dup.pageIndex, 0);
      expect(dup.sizePx, const Size(1000, 800));
      // A copy of the calibration (equal scale, keyed by the NEW id).
      final proj = c.read(projectControllerProvider);
      expect(proj.calibrationFor(newId), const ScaleCalibration(0.0125));
      // Mapped to the chosen building floor.
      final levelCount = proj.building.levelCount;
      expect(state.floorFor(newId, levelCount), 1);
      // The source sheet is untouched, and the duplicate is selected.
      expect(state.sheetById('typical')!.name, 'Typical Floor');
      expect(state.current!.id, newId);
    });

    test('the shared source is a plain COPY, not a live link', () {
      final c = makeContainer();
      final sheets = c.read(sheetsControllerProvider.notifier);
      final project = c.read(projectControllerProvider.notifier);
      sheets.loadSheets(const [
        Sheet(id: 'typical', name: 'Typical', pdfPath: '/p.pdf'),
      ]);
      project.setCalibration('typical', const ScaleCalibration(0.01));
      final newId = sheets.duplicateSheetToFloor('typical', 2)!;

      // Re-calibrating the SOURCE does not touch the copy…
      project.setCalibration('typical', const ScaleCalibration(0.02));
      expect(c.read(projectControllerProvider).calibrationFor(newId),
          const ScaleCalibration(0.01));
      // …and re-calibrating the COPY does not touch the source.
      project.setCalibration(newId, const ScaleCalibration(0.05));
      expect(c.read(projectControllerProvider).calibrationFor('typical'),
          const ScaleCalibration(0.02));
    });

    test('an uncalibrated source duplicates with no calibration', () {
      final c = makeContainer();
      final sheets = c.read(sheetsControllerProvider.notifier);
      sheets.loadSheets(const [
        Sheet(id: 'raw', name: 'Raw', pdfPath: '/r.pdf'),
      ]);
      final newId = sheets.duplicateSheetToFloor('raw', 1)!;
      expect(c.read(projectControllerProvider).calibrationFor(newId), isNull);
    });

    test('a second duplicate onto the same floor gets a distinct id', () {
      final c = makeContainer();
      final sheets = c.read(sheetsControllerProvider.notifier);
      sheets.loadSheets(const [
        Sheet(id: 'typical', name: 'Typical', pdfPath: '/p.pdf'),
      ]);
      final a = sheets.duplicateSheetToFloor('typical', 1)!;
      final b = sheets.duplicateSheetToFloor('typical', 1)!;
      expect(a, isNot(b));
      expect(c.read(sheetsControllerProvider).sheets.length, 3);
    });

    test('unknown sheet id → null, no change', () {
      final c = makeContainer();
      final sheets = c.read(sheetsControllerProvider.notifier);
      sheets.loadSheets(const [Sheet(id: 's', name: 'S', pdfPath: '/s.pdf')]);
      expect(sheets.duplicateSheetToFloor('nope', 1), isNull);
      expect(c.read(sheetsControllerProvider).sheets.length, 1);
    });
  });

  test(
      'gatherSheetAssets embeds a shared source path ONCE for two sheets '
      '(portable-embed dedup — F6 verification)', () {
    final dir = Directory.systemTemp.createTempSync('mechx_f6_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final plan = File('${dir.path}/typical.dxf')
      ..writeAsStringSync('0\nSECTION\n0\nENDSEC\n0\nEOF\n');

    final assets = gatherSheetAssets([
      Sheet(id: 'typical', name: 'F1', dxfPath: plan.path),
      Sheet(id: 'typical-f2', name: 'F2', dxfPath: plan.path),
    ]);
    // Two sheets, one path ⇒ a single embedded blob (keyed by path).
    expect(assets.keys, [plan.path]);
    expect(assets.length, 1);
  });

  test('save/load round-trip keeps BOTH sheets, their floors + calibration',
      () {
    final c1 = makeContainer();
    final sheets1 = c1.read(sheetsControllerProvider.notifier);
    final project1 = c1.read(projectControllerProvider.notifier);
    sheets1.loadSheets(const [
      Sheet(id: 'typical', name: 'Typical', pdfPath: '/typical.pdf'),
    ]);
    project1.setCalibration('typical', const ScaleCalibration(0.0125));
    final newId = sheets1.duplicateSheetToFloor('typical', 1)!;

    // Encode → decode (the on-disk `.mechx` round-trip).
    final doc = buildDocument(c1.read);
    final restored = ProjectDocument.decode(doc.encode());

    // Apply into a fresh container and read the sheets/floors/calibration back.
    final c2 = makeContainer();
    applyDocument(c2.read, restored);
    final state2 = c2.read(sheetsControllerProvider);
    final proj2 = c2.read(projectControllerProvider);

    expect(state2.sheetById('typical')!.pdfPath, '/typical.pdf');
    final dup2 = state2.sheetById(newId)!;
    expect(dup2.pdfPath, '/typical.pdf'); // shared source survives the trip
    final levelCount = proj2.building.levelCount;
    expect(state2.floorFor(newId, levelCount), 1); // floor mapping survives
    expect(proj2.calibrationFor(newId), const ScaleCalibration(0.0125));
    expect(proj2.calibrationFor('typical'), const ScaleCalibration(0.0125));
  });
}
