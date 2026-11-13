// Drawing backlog I-1 (2026-11-13) — a standalone drawing export is the
// submittal package's drawing: for every single-line-family drawing kind
// (mechanical riser M-201, electrical SLD E-201, building single-line E-301,
// electrical riser E-401, power one-line E-501, panel schedules E-601) the
// standalone PDF and DXF are byte-identical to the package's files — so the
// page count, the per-page text, `SHEET i of n`, the LANJUT marks and the
// drawing number all agree — and a paginated drawing's DXF carries one frame
// per PDF page (it used to write ONE sheet).
import 'dart:convert' show latin1;
import 'dart:io';

// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/electrical/electrical_export.dart';
import 'package:mechx/ui/inspector/project_panel.dart'
    show writeSubmittalPackageToDir;
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
}
