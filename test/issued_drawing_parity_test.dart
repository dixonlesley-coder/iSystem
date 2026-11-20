// Drawing backlog I-1 (2026-11-13) — a standalone drawing export is the
// submittal package's drawing: for every single-line-family drawing kind
// (mechanical riser M-201, electrical SLD E-201, building single-line E-301,
// electrical riser E-401, power one-line E-501, panel schedules E-601) the
// standalone PDF and DXF are byte-identical to the package's files — so the
// page count, the per-page text, `SHEET i of n`, the LANJUT marks and the
// drawing number all agree — and a paginated drawing's DXF carries one frame
// per PDF page (it used to write ONE sheet).
//
// Backlog K-3 (2026-11-20) — the standalone PLAN exports (annotated plan
// PDF, Ctrl+P, and the plan DXF) issue the package's pages for that plan: the
// plan at the set's shared scale with its DETAIL bubbles, then every M-5nn
// detail sheet its bubbles point at, each byte-identical to the package's
// `plan-<i>-<name>[-detail[-k]]` file.
import 'dart:convert' show latin1;
import 'dart:io';

// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/electrical/electrical_export.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart'
    show
        exportAnnotatedPlanPdf,
        exportDrawingDxf,
        issuedPlanDetailPath,
        writeSubmittalPackageToDir;
import 'package:mechx/ui/schematic/schematic_export.dart'
    show exportMechanicalRiserDxf, exportMechanicalRiserPdf;
import 'package:mechx_engine/report/file_names.dart' show safeFileStem;

import 'reference_drawing_loader.dart';

/// The PDF's page count (`/Type /Page` objects, not `/Pages`).
int _pdfPages(List<int> bytes) =>
    RegExp(r'/Type\s*/Page(?![s\w])').allMatches(latin1.decode(bytes)).length;

/// The DXF's `SHEET i of n` frames: the distinct `i of n` stamps it carries.
Set<String> _dxfSheetStamps(String dxf) => {
      for (final m in RegExp(r'^(\d+ of \d+)\r?$', multiLine: true)
          .allMatches(dxf))
        m.group(1)!,
    };

void main() {
  for (final key in ['shophouse', 'house']) {
    testWidgets(
        'I-1: every standalone $key drawing equals the package drawing '
        '(PDF + DXF, same pages)', (tester) async {
      final spec = kRefDrawingSpecs.firstWhere((s) => s.key == key);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.runAsync(() => loadRefDrawingSpec(c, spec));
      late WidgetRef ref;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Consumer(builder: (context, r, _) {
            ref = r;
            return const SizedBox.shrink();
          }),
        ),
      ));
      await tester.pump();

      final tmp = Directory.systemTemp.createTempSync('i1_parity_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final pkg = Directory('${tmp.path}/pkg')..createSync();
      final solo = Directory('${tmp.path}/solo')..createSync();
      final ok = await tester
          .runAsync(() => writeSubmittalPackageToDir(ref, pkg.path));
      expect(ok, isTrue);
      final stem = safeFileStem(spec.projectName);

      final previous = FilePickerPlatform.instance;
      addTearDown(() => FilePickerPlatform.instance = previous);
      final kinds = <(String, Future<void> Function(WidgetRef))>[
        ('riser-sld.pdf', (r) => exportMechanicalRiserPdf(r, null)),
        ('riser-sld.dxf', (r) => exportMechanicalRiserDxf(r, null)),
        ('electrical-sld.pdf', exportElectricalSldPdf),
        ('electrical-sld.dxf', exportElectricalSldDxf),
        ('electrical-overview-sld.pdf', exportElectricalOverviewPdf),
        ('electrical-overview-sld.dxf', exportElectricalOverviewDxf),
        ('electrical-riser.pdf', exportElectricalRiserPdf),
        ('electrical-riser.dxf', exportElectricalRiserDxf),
        ('electrical-power-one-line.pdf', exportPowerOneLinePdf),
        ('electrical-power-one-line.dxf', exportPowerOneLineDxf),
        ('panel-schedules.pdf', exportElectricalPanelSchedulesPdf),
      ];
      var multiPage = 0;
      for (final (suffix, export) in kinds) {
        final packaged = File('${pkg.path}/$stem-$suffix');
        if (!packaged.existsSync()) continue;
        final path = '${solo.path}/$stem-$suffix';
        FilePickerPlatform.instance = FakeSavePicker(path);
        await tester.runAsync(() => export(ref));
        final standalone = File(path);
        expect(standalone.existsSync(), isTrue, reason: suffix);
        final a = packaged.readAsBytesSync(), b = standalone.readAsBytesSync();
        expect(b, equals(a), reason: '$suffix: standalone != package');
        if (suffix.endsWith('.pdf')) {
          final n = _pdfPages(a);
          if (n > 1) multiPage++;
          final dxf = File(packaged.path.replaceFirst(RegExp(r'pdf$'), 'dxf'));
          if (n > 1 && dxf.existsSync()) {
            // One DXF frame per PDF page: stamps '1 of n' .. 'n of n'.
            expect(_dxfSheetStamps(dxf.readAsStringSync()),
                {for (var i = 1; i <= n; i++) '$i of $n'},
                reason: '$suffix: DXF frames vs $n PDF pages');
          }
        }
      }
      if (key == 'shophouse') {
        // The shophouse riser, SLD and board schedules are paginated, so the
        // check above exercised multi-page drawings.
        expect(multiPage, greaterThanOrEqualTo(2));
      }
    });
  }

  testWidgets(
      'K-3: a standalone apartment plan export equals the package plan and '
      'the detail sheets it points at (PDF + DXF)', (tester) async {
    final spec = kRefDrawingSpecs.firstWhere((s) => s.key == 'apartment');
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.runAsync(() => loadRefDrawingSpec(c, spec));
    late WidgetRef ref;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Consumer(builder: (context, r, _) {
          ref = r;
          return const SizedBox.shrink();
        }),
      ),
    ));
    await tester.pump();

    final tmp = Directory.systemTemp.createTempSync('k3_parity_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final pkg = Directory('${tmp.path}/pkg')..createSync();
    final solo = Directory('${tmp.path}/solo')..createSync();
    final ok =
        await tester.runAsync(() => writeSubmittalPackageToDir(ref, pkg.path));
    expect(ok, isTrue);
    final stem = safeFileStem(spec.projectName);
    final sheets = c.read(sheetsControllerProvider).sheets;
    String planStem(int i) =>
        '$stem-plan-${i + 1}-${safeFileStem(sheets[i].name, fallback: 'sheet')}';
    // The detail files written beside [plan] (`-detail`, `-detail-2`, ...).
    List<File> detailsBeside(String plan) {
      final out = <File>[];
      while (true) {
        final f = File(issuedPlanDetailPath(plan, out.length));
        if (!f.existsSync()) return out;
        out.add(f);
      }
    }

    // The first plan that issues its own detail sheets in the package, and
    // the first later plan that issues none (a typical floor pointing at it).
    final dense = [
      for (var i = 0; i < sheets.length; i++)
        if (detailsBeside('${pkg.path}/${planStem(i)}.pdf').isNotEmpty) i,
    ].first;
    final typical = [
      for (var i = dense + 1; i < sheets.length; i++)
        if (detailsBeside('${pkg.path}/${planStem(i)}.pdf').isEmpty) i,
    ].firstOrNull;

    final previous = FilePickerPlatform.instance;
    addTearDown(() => FilePickerPlatform.instance = previous);
    for (final i in [dense, ?typical]) {
      c.read(sheetsControllerProvider.notifier).selectSheetById(sheets[i].id);
      await tester.pump();
      for (final ext in ['pdf', 'dxf']) {
        final path = '${solo.path}/${planStem(i)}.$ext';
        FilePickerPlatform.instance = FakeSavePicker(path);
        await tester.runAsync(() =>
            ext == 'pdf' ? exportAnnotatedPlanPdf(ref) : exportDrawingDxf(ref));
        expect(File(path).readAsBytesSync(),
            equals(File('${pkg.path}/${planStem(i)}.$ext').readAsBytesSync()),
            reason: '${planStem(i)}.$ext: standalone != package');
        final got = detailsBeside(path);
        bool same(List<File> a, List<File> b) =>
            a.length == b.length &&
            [
              for (var g = 0; g < a.length; g++)
                listEquals(a[g].readAsBytesSync(), b[g].readAsBytesSync()),
            ].every((x) => x);
        if (i == dense) {
          // The plan's own detail sheets, byte for byte.
          expect(got, isNotEmpty);
          expect(
              same(got, detailsBeside('${pkg.path}/${planStem(i)}.$ext')),
              isTrue,
              reason: '${planStem(i)}.$ext: detail sheets != package');
        } else if (got.isNotEmpty) {
          // A typical floor issues none of its own: its bubbles point at an
          // earlier plan's sheets, and the standalone issues exactly those.
          expect(
              [
                for (var j = 0; j < i; j++)
                  same(got, detailsBeside('${pkg.path}/${planStem(j)}.$ext')),
              ].contains(true),
              isTrue,
              reason: '${planStem(i)}.$ext: not an issued detail set');
        }
      }
    }
  });
}
