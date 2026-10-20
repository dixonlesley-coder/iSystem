/// Visual / interaction polish batch — the behaviour pins for the changes that
/// are not purely pixels (those ride the goldens):
///  * reduced motion ⇒ the shared animated widgets get ZERO durations;
///  * an export raises the busy pill once the file is chosen, and a second
///    trigger while it runs is ignored;
///  * the top bar's actions hug the right edge; the Review compliance verdicts
///    form one column; the layer switcher keeps one width as the active
///    layer moves;
///  * a DXF sheet parses OFF the UI isolate (loading → loaded), and a sheet
///    that cannot load offers 'Replace plan…';
///  * the minimap letterboxes a sliver sheet; the riser label LOD helpers;
///    locale-aware commercial quantities; the zoom controls' 40-px targets.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/ui/canvas/canvas_minimap.dart';
import 'package:mechx/ui/canvas/dxf_sheet_page.dart';
import 'package:mechx/ui/canvas/sheet_page_states.dart';
import 'package:mechx/ui/canvas/zoom_controls.dart';
import 'package:mechx/ui/commercial/commercial_table.dart';
import 'package:mechx/ui/inspector/project_panel.dart'
    show pickExportSave, runExportGuarded;
import 'package:mechx/ui/layout/layer_switcher.dart';
import 'package:mechx/ui/review/review_hub.dart';
import 'package:mechx/ui/shell/nav_rail.dart' show ShellSection, shellSectionProvider;
import 'package:mechx/ui/schematic/schematic_view.dart'
    show riserLabelFontSize, riserLabelZoomBucket, kRiserLabelMaxZoom;
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_button.dart';
import 'package:mechx/ui/widgets/mechx_segment.dart';

import 'test_util.dart';

Widget _themed(Widget child, {bool reduceMotion = false}) => MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: child),
        ),
      ),
    );

/// A save dialog that "chooses" [path] without any OS UI.
class _FakeSavePicker extends FilePickerPlatform {
  final String path;
  _FakeSavePicker(this.path);

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async =>
      path;
}

void main() {
  group('reduced motion — the shared widgets snap (zero durations)', () {
    Future<void> pumpControls(WidgetTester tester, bool reduce) =>
        tester.pumpWidget(_themed(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MechXButton(label: 'Go', onPressed: () {}),
              MechXSegment(label: 'Seg', selected: true, onTap: () {}),
              ZoomControls(onIn: () {}, onOut: () {}, onFit: () {}),
            ],
          ),
          reduceMotion: reduce,
        ));

    testWidgets('with the OS setting on every implicit animation is zero',
        (tester) async {
      await pumpControls(tester, true);
      final containers =
          tester.widgetList<AnimatedContainer>(find.byType(AnimatedContainer));
      final scales = tester.widgetList<AnimatedScale>(find.byType(AnimatedScale));
      expect(containers, isNotEmpty);
      expect(scales, isNotEmpty);
      for (final w in containers) {
        expect(w.duration, Duration.zero);
      }
      for (final w in scales) {
        expect(w.duration, Duration.zero);
      }
    });

    testWidgets('without it they keep their motion tokens', (tester) async {
      await pumpControls(tester, false);
      for (final w in tester
          .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))) {
        expect(w.duration, isNot(Duration.zero));
      }
    });
  });

  group('export busy feedback', () {
    testWidgets(
        'the busy pill rises once the file is chosen, a second trigger is '
        'ignored, and both clear when the write settles', (tester) async {
      final previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance =
          _FakeSavePicker('${Directory.systemTemp.path}/polish-export.csv');
      addTearDown(() => FilePickerPlatform.instance = previous);

      late WidgetRef ref;
      await tester.pumpWidget(ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Consumer(builder: (context, r, _) {
            ref = r;
            return const SizedBox.shrink();
          }),
        ),
      ));
      final c = ProviderScope.containerOf(
          tester.element(find.byType(Consumer)));

      final gate = Completer<void>();
      var writes = 0;
      String? busyDuringWrite;
      final first = runExportGuarded(ref, name: 'BOM', write: () async {
        writes++;
        await pickExportSave(ref,
            dialogTitle: 'Save', fileName: 'bom', ext: 'csv');
        busyDuringWrite = c.read(busyProvider);
        await gate.future;
        return true;
      });
      await tester.pump();
      expect(c.read(exportInFlightProvider), 'BOM');
      expect(busyDuringWrite, 'Exporting BOM...');

      // A repeated click / accelerator mid-write: no second write.
      var secondWrites = 0;
      await runExportGuarded(ref, name: 'BOM', write: () async {
        secondWrites++;
        return true;
      });
      expect(secondWrites, 0);

      gate.complete();
      await first;
      await tester.pump();
      expect(writes, 1);
      expect(c.read(busyProvider), isNull);
      expect(c.read(exportInFlightProvider), isNull);
      // The next export runs normally again.
      await runExportGuarded(ref, name: 'BOM', write: () async {
        secondWrites++;
        return false;
      });
      expect(secondWrites, 1);
    });
  });

  group('layout alignment', () {
    testWidgets('the top-bar actions hug the right edge', (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final export = tester.getRect(find.text('Export').first);
      final open = tester.getRect(find.text('Open').first);
      // 1280-px window; 16-px bar inset + the button's own padding.
      expect(export.right, greaterThan(1280 - 48));
      expect(open.left, greaterThan(1280 / 2),
          reason: 'the actions no longer sit mid-bar');
    });

    testWidgets('the compliance verdicts share one column', (tester) async {
      setDesktopSurface(tester, size: const Size(1440, 900));
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final c = ProviderScope.containerOf(tester.element(find.byType(MechXApp)));
      c.read(shellSectionProvider.notifier).set(ShellSection.review);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final verdicts = [
        ...find.descendant(
            of: find.byType(ReviewHub), matching: find.text('PASS'))
            .evaluate(),
        ...find.descendant(
            of: find.byType(ReviewHub), matching: find.text('REVIEW'))
            .evaluate(),
      ];
      expect(verdicts.length, greaterThan(1));
      final lefts = {
        for (final e in verdicts)
          (tester.getRect(find.byWidget(e.widget).first)).left.round()
      };
      expect(lefts.length, 1, reason: 'every verdict starts at one x');
    });

    testWidgets('the layer switcher keeps one width as the active layer moves',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final c = ProviderScope.containerOf(tester.element(find.byType(MechXApp)));
      final widths = <double>{};
      for (final layer in DisciplineLayer.values) {
        c.read(activeDisciplineProvider.notifier).set(layer);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        widths.add(tester.getSize(find.byType(LayerSwitcher)).width);
      }
      expect(widths.length, 1, reason: 'the breadcrumb beside it never jumps');
    });
  });

  group('sheet pages', () {
    testWidgets('a DXF parses off the UI isolate: loading -> loaded',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('polish_dxf');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/plan.dxf';
      File(path).writeAsStringSync('0\nSECTION\n2\nENTITIES\n'
          '0\nLINE\n10\n0\n20\n0\n11\n100\n21\n80\n'
          '0\nENDSEC\n0\nEOF\n');
      final sheet = Sheet(
          id: 'd', name: 'd', dxfPath: path, sizePx: const Size(100, 80));
      // The background parse is a real isolate: start it (initState) and
      // await it on the real event loop.
      await tester.runAsync(() async {
        await tester.pumpWidget(_themed(SizedBox(
            width: 100, height: 80, child: DxfSheetPage(sheet: sheet))));
        expect(find.byType(SheetLoadingPage), findsOneWidget,
            reason: 'first frame: the paper + caption, never a frozen build');
        await DxfSheetPage.loadAsync(path);
      });
      await tester.pump();
      expect(find.byType(SheetLoadingPage), findsNothing);
      expect(find.byType(SheetLoadErrorPage), findsNothing);
      expect(DxfSheetPage.cachedDrawing(path), isNotNull,
          reason: 'the background parse lands in the shared cache');
    });

    testWidgets('an unreadable plan offers Replace plan…', (tester) async {
      const path = '/no/such/plan.dxf';
      DxfSheetPage.cacheForTest(path, null);
      var replaced = 0;
      await tester.pumpWidget(_themed(SizedBox(
        width: 600,
        height: 400,
        child: DxfSheetPage(
          sheet: const Sheet(id: 'x', name: 'x', dxfPath: path),
          onReplacePlan: () => replaced++,
        ),
      )));
      expect(find.byType(SheetLoadErrorPage), findsOneWidget);
      await tester.tap(find.text('Replace plan…'));
      expect(replaced, 1);
    });
  });

  testWidgets('the minimap letterboxes a sliver sheet and drops its caption',
      (tester) async {
    await tester.pumpWidget(_themed(CanvasMinimap(
      contentSize: const Size(4000, 300),
      markers: const [],
      viewport: null,
      onRecenter: (_) {},
    )));
    final box = tester.getSize(find.byType(CanvasMinimap));
    expect(box.height, greaterThanOrEqualTo(CanvasMinimap.minBoxExtent));
    expect(find.text('MAP'), findsNothing);
  });

  test('riser label LOD: hidden below 6 px, capped above 2x, 1.0 at rest', () {
    expect(riserLabelZoomBucket(1.0), 1.0);
    expect(riserLabelZoomBucket(1.7), 1.0);
    expect(riserLabelFontSize(9, 1.0), 9);
    // 8 px at 0.5x is 4 px on screen — skipped.
    expect(riserLabelFontSize(8, riserLabelZoomBucket(0.5)), isNull);
    // Deep zoom: the on-screen size stops near 2x the design size.
    final z = riserLabelZoomBucket(8);
    final f = riserLabelFontSize(10, z)!;
    expect(f * 8, lessThanOrEqualTo(10 * kRiserLabelMaxZoom * 1.2));
    expect(f * 8, greaterThanOrEqualTo(10 * kRiserLabelMaxZoom));
  });

  test('commercial quantities read in the UI locale', () {
    expect(CommercialFormat.qty(20.2, AppLocale.en), '20.2');
    expect(CommercialFormat.qty(20.2, AppLocale.id), '20,2');
    expect(CommercialFormat.qty(1234, AppLocale.en), '1,234');
    expect(CommercialFormat.qty(1234, AppLocale.id), '1.234');
    expect(CommercialFormat.hours(3.5, AppLocale.en), '3.5');
    // Money keeps the issued Indonesian notation.
    expect(CommercialFormat.money(1181250), '1.181.250,00');
  });

  testWidgets('the zoom controls answer 40-px targets', (tester) async {
    await tester.pumpWidget(_themed(
        ZoomControls(onIn: () {}, onOut: () {}, onFit: () {})));
    for (final glyph in ['+', '−', 'fit']) {
      // The glyph's tappable ancestor is its 40-px column.
      final hit = find
          .ancestor(of: find.text(glyph), matching: find.byType(GestureDetector))
          .first;
      final Rect r = tester.getRect(hit);
      expect(r.height, greaterThanOrEqualTo(ZoomControls.hitExtent),
          reason: glyph);
      expect(r.width, greaterThanOrEqualTo(ZoomControls.hitExtent),
          reason: glyph);
    }
  });
}
