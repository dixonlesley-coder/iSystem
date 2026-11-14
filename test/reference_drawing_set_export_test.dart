// Reference buildings — DRAWING-SET EXPORT generator (gated: REF_EXPORT=1).
//
// Loads each of the five reference buildings (house, shophouse, office,
// apartment, tower — fixtures in `packages/mechx_engine/test/reference/`)
// through the SAME store intents the `reference_*_app_test.dart` suites use,
// sets the project identity the way a user would (project name, Document
// control drawn / checked / approved + revision), then writes the issued set
// through the app's own export entry points:
//   * `writeSubmittalPackageToDir` — the ONE-folder submittal package the
//     Export sheet's primary row writes (cover + Daftar Gambar, every plan
//     PDF + DXF, riser SLD, electrical SLD / overview / riser / one-line,
//     reports, schedules, BOM);
//   * `exportElectricalPanelSchedulesPdf` — the panel-schedule set (not part
//     of the package), driven through a fake save dialog.
// Nothing is asserted beyond "the files were written"; the review is done on
// the rasterised PNGs (`tool/ref_drawings_precheck.py`).
//
// Run (from the repo root):
//   REF_EXPORT=1 REF_EXPORT_DIR=/abs/out flutter test \
//       test/reference_drawing_set_export_test.dart
// Output: $REF_EXPORT_DIR/<building>/ (default build/ref_drawings).
import 'dart:io';

// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart'
    show exportHasZeroLengthEdgesProvider;
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_export.dart'
    show exportElectricalPanelSchedulesPdf;
import 'package:mechx/ui/inspector/project_panel.dart'
    show writeSubmittalPackageToDir;
import 'package:mechx_engine/report/file_names.dart' show safeFileStem;

import 'reference_drawing_loader.dart';

final bool _enabled = Platform.environment['REF_EXPORT'] == '1';
final String _outRoot =
    Platform.environment['REF_EXPORT_DIR'] ?? 'build/ref_drawings';

void main() {
  for (final spec in kRefDrawingSpecs) {
    testWidgets('export the ${spec.key} drawing set', (tester) async {
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

      final dir = Directory('$_outRoot/${spec.key}');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);

      // Drawing-review D7 — the package path applies the SAME zero-length
      // guard [runExportGuarded] applies to every other export (the folder
      // picker in front of it cannot run headless).
      expect(c.read(exportHasZeroLengthEdgesProvider), isFalse,
          reason: 'zero-length guard would refuse the submittal package');
      final ok = await tester
          .runAsync(() => writeSubmittalPackageToDir(ref, dir.path));
      expect(ok, isTrue);

      final previous = FilePickerPlatform.instance;
      final stem = safeFileStem(spec.projectName);
      FilePickerPlatform.instance =
          FakeSavePicker('${dir.path}/$stem-panel-schedules.pdf');
      addTearDown(() => FilePickerPlatform.instance = previous);
      if (c.read(electricalResultProvider).order.isNotEmpty) {
        await tester.runAsync(() => exportElectricalPanelSchedulesPdf(ref));
      }
      final err = c.read(loadErrorProvider);
      if (err != null) {
        File('${dir.path}/EXPORT-ERRORS.txt').writeAsStringSync('$err\n');
      }
      final files = dir.listSync().whereType<File>().toList();
      expect(files, isNotEmpty);
    }, skip: !_enabled);
  }
}
