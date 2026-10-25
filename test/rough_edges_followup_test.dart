/// Drafting-feel follow-up — the residuals recorded by batches 4 and 6:
///
///  * a dragged board on the single-line latches to a sibling board's column
///    / row (a dashed guide shows while it does, never at rest);
///  * a Layout plan marker stops growing past [kLayoutMarkerMaxScale] so a
///    deep zoom never balloons it over the plan (and its hit rect follows);
///  * the sheet loading / load-error cards stay screen-sized at any zoom.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/canvas_zoom_scope.dart';
import 'package:mechx/ui/canvas/sheet_page_states.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart';
import 'package:mechx/ui/electrical/electrical_layout_view.dart';
import 'package:mechx/ui/layout/electrical_layer.dart';
import 'package:mechx/ui/widgets/mechx_empty_state_card.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';

import 'test_util.dart';

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MechXApp)),
        listen: false);

ElectricalPanel _panel(ProviderContainer c, String id) =>
    c.read(electricalProjectProvider).panels.firstWhere((p) => p.id == id);

Rect _cardRect(WidgetTester tester, String id) =>
    tester.getRect(find.byKey(ValueKey('electrical-card-$id')));

bool _guideShown(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .any((p) => p.painter is PanelAlignGuidePainter);

void main() {
  testWidgets(
      'a dragged board latches onto a sibling board\'s column, with a guide '
      'only while dragging', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = _containerOf(tester);
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    final ctrl = container.read(electricalProjectProvider.notifier);
    ctrl.setProject(sampleElectricalProject());
    // The MDP sits OFF the 16-unit grid, so only alignment (never the grid)
    // can put lp1's left edge exactly on it.
    ctrl.setPanelPosition('mdp', 203, 0);
    ctrl.setPanelPosition('lp1', 0, 640);
    await tester.pump();
    await tester.pump();
    expect(_guideShown(tester), isFalse, reason: 'no guide at rest');

    final start = _cardRect(tester, 'lp1');
    final gesture = await tester.startGesture(
        Offset(start.left + start.width * 0.25, start.top + start.height / 2));
    await tester.pump();
    // Walk right in small steps (past the pan slop), then close the gap to
    // ~3 screen px left of the MDP's left edge — inside the latch tolerance.
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(12, 0));
      await tester.pump();
    }
    for (var i = 0; i < 3; i++) {
      final gap = _cardRect(tester, 'mdp').left - _cardRect(tester, 'lp1').left;
      await gesture.moveBy(Offset(gap - 3, 0));
      await tester.pump();
    }
    expect(_panel(container, 'lp1').x, 203,
        reason: 'the left edge latched onto the sibling column');
    expect(_guideShown(tester), isTrue, reason: 'the guide shows mid-drag');

    await gesture.up();
    await tester.pump();
    expect(_panel(container, 'lp1').x, 203);
    expect(_panel(container, 'lp1').y! % 16, 0,
        reason: 'the un-latched axis keeps the grid');
    expect(_guideShown(tester), isFalse, reason: 'the guide clears on release');
  });

  testWidgets(
      'a plan marker tracks the zoom up to the cap, then stays that size',
      (tester) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = _containerOf(tester);
    seedDemoSheets(container);
    container
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.01));
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
    container
        .read(activeDisciplineProvider.notifier)
        .set(DisciplineLayer.electrical);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final ctrl = container.read(electricalProjectProvider.notifier);
    final id = ctrl.addPanelAt(name: 'A', tag: 'A', x: 0, y: 0);
    ctrl.setPanelLayoutPos(
        id, const LayoutPos(sheetId: 's1', floorIndex: 0, x: 300, y: 300));

    Future<Size> markerAt(double zoom) async {
      container
          .read(sheetsControllerProvider.notifier)
          .setViewport('s1', ViewportTransform(scale: zoom));
      await tester.pump();
      await tester.pump();
      expect(tester.widget<ElectricalLayoutLayer>(
              find.byType(ElectricalLayoutLayer)).transform.scale,
          zoom);
      return tester
          .getSize(find.byKey(ValueKey('elec-layout-panel-$id')));
    }

    expect(await markerAt(1.0),
        const Size(kLayoutPanelW, kLayoutPanelH),
        reason: 'below the cap the marker is sized to the plan');
    expect(await markerAt(4.0),
        const Size(kLayoutPanelW * kLayoutMarkerMaxScale,
            kLayoutPanelH * kLayoutMarkerMaxScale),
        reason: 'past the cap it stops growing');
    expect(layoutMarkerScale(0.5), 0.5);
    expect(layoutMarkerScale(8), kLayoutMarkerMaxScale);
  });

  testWidgets('the load-error card is the same on-screen size at any zoom',
      (tester) async {
    Future<Rect> cardAt(double zoom) async {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Transform.scale(
            scale: zoom,
            alignment: Alignment.topLeft,
            child: SizedBox(
              // Fits the 800 x 600 test window at 1:1.
              width: 800,
              height: 600,
              child: CanvasZoomScope(
                scale: zoom,
                child: const SheetLoadErrorPage(
                    message: 'The PDF could not be opened.'),
              ),
            ),
          ),
        ),
      ));
      return tester.getRect(find.byType(MechXEmptyStateCard));
    }

    final actual = await cardAt(1.0);
    for (final zoom in [0.25, 0.5, 2.0]) {
      final r = await cardAt(zoom);
      expect(r.width, closeTo(actual.width, 0.01), reason: 'zoom $zoom');
      expect(r.height, closeTo(actual.height, 0.01), reason: 'zoom $zoom');
      // Still centred on the (scaled) sheet — even at 0.25, where the
      // 200 x 150 px sheet is smaller than the card and it overhangs.
      expect(r.center.dx, closeTo(400 * zoom, 0.5), reason: 'zoom $zoom');
      expect(r.center.dy, closeTo(300 * zoom, 0.5), reason: 'zoom $zoom');
    }
  });

  testWidgets('the counter-scaled card keeps its action clickable',
      (tester) async {
    var replaced = 0;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: Transform.scale(
          scale: 0.5,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 800,
            height: 600,
            child: CanvasZoomScope(
              scale: 0.5,
              child: SheetLoadErrorPage(
                message: 'The PDF could not be opened.',
                onReplacePlan: () => replaced++,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Replace plan\u2026').hitTestable());
    expect(replaced, 1);
  });
}
