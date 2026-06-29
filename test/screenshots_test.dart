@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart';
import 'package:mechx/ui/electrical/electrical_view.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';

/// Renders each UI state to a real PNG via the golden pipeline (headless).
/// Run with: flutter test --update-goldens test/screenshots_test.dart
Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
  final mono = FontLoader('Roboto Mono')
    ..addFont(bytes('assets/fonts/RobotoMono-Regular.ttf'));
  await mono.load();
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('capture UI screenshots', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump(); // first-frame fit
    await tester.pump(const Duration(milliseconds: 50));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    final net = container.read(networkControllerProvider.notifier);

    // Draw a small cold-water network on the ground-floor sheet.
    net.setService(ServiceType.coldWater);
    net.setTool(DrawTool.drawRun);
    net.placeRunPoint('s1', 0, const Offset(360, 360));
    net.placeRunPoint('s1', 0, const Offset(1040, 360));
    net.placeRunPoint('s1', 0, const Offset(1040, 820));
    net.setTool(DrawTool.drawRun);
    net.placeRunPoint('s1', 0, const Offset(1040, 360));
    net.placeRunPoint('s1', 0, const Offset(1380, 360));
    net.setTool(DrawTool.drawRiser);
    net.placeRiser('s1', 0, const Offset(360, 360), 3);
    net.setTool(DrawTool.select);
    container.read(showSizingProvider.notifier).toggle();
    await tester.pump(const Duration(milliseconds: 250));

    final app = find.byType(MechXApp);

    await expectLater(app, matchesGoldenFile('goldens/01_plan_dark.png'));

    container.read(brightnessProvider.notifier).toggle();
    // One frame to rebuild (AnimatedContainers pick up the new theme target),
    // then advance past the colour cross-fade so the golden captures the
    // settled light palette rather than the first frame of the transition.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(app, matchesGoldenFile('goldens/02_plan_light.png'));
    container.read(brightnessProvider.notifier).toggle();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // settle back to dark

    container.read(showHeatmapProvider.notifier).toggle();
    await tester.pump(const Duration(milliseconds: 250));
    await expectLater(app, matchesGoldenFile('goldens/03_heatmap.png'));
    container.read(showHeatmapProvider.notifier).toggle();
    await tester.pump();

    container.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
    await tester.pump(const Duration(milliseconds: 250));
    await expectLater(app, matchesGoldenFile('goldens/04_schematic.png'));

    // Electrical workspace — renders the built-in sample electrical project
    // through the pure A4 engine (panel schedule + summaries + warnings).
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    await tester.pump(const Duration(milliseconds: 250));
    // Zoom in past the LOD threshold so the showcase shows each panel's full
    // internal schematic + individual load nodes (the fit default is an
    // overview, where loads merge — see golden 08).
    final elecCanvas =
        tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));
    var zin = 0;
    while (elecCanvas.currentScale < kLodThreshold && zin++ < 8) {
      elecCanvas.zoomIn();
    }
    await tester.pump();
    // Let the summary→schematic LOD cross-fade settle before capturing.
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(app, matchesGoldenFile('goldens/05_electrical.png'));

    // Unified LAYOUT canvas, Electrical layer — panels + loads placed on the
    // calibrated PDF floor plan, cable length from geometry. Calibrate the
    // sheet, place the MDP + a few loads, then open the Layout workspace with
    // the Electrical discipline active (plumbing/HVAC ghost underneath).
    container
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.01));
    final elec = container.read(electricalProjectProvider.notifier);
    elec.setPanelLayoutPos(
        'mdp', const LayoutPos(sheetId: 's1', floorIndex: 0, x: 560, y: 380));
    elec.setLoadPos('mdp', 'mdp-c1',
        const LayoutPos(sheetId: 's1', floorIndex: 0, x: 980, y: 560));
    elec.setLoadPos('mdp', 'mdp-c3',
        const LayoutPos(sheetId: 's1', floorIndex: 0, x: 1180, y: 360));
    elec.setLoadPos('mdp', 'mdp-c4',
        const LayoutPos(sheetId: 's1', floorIndex: 0, x: 760, y: 760));
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
    container.read(activeDisciplineProvider.notifier).set(DisciplineLayer.electrical);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(app, matchesGoldenFile('goldens/06_electrical_layout.png'));

    // Vertical riser EDIT mode — the editable elevation: floors stacked by true
    // elevation, risers placed across them and sized (length = elevation delta).
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
    final levels = container.read(projectControllerProvider).building.levelCount;
    final netCtrl = container.read(networkControllerProvider.notifier);
    netCtrl.placeRiserAt('s1', 0, 700, levels, service: ServiceType.hotWater);
    netCtrl.placeRiserAt('s1', 1, 1040, levels, service: ServiceType.drainage);
    await tester.pump();
    await tester.tap(find.text('Edit').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(app, matchesGoldenFile('goldens/07_riser_edit.png'));

    // Electrical single-line at the fit OVERVIEW — each panel's loads collapse
    // into one tidy "N loads" node (they break out individually only when
    // zoomed in past the LOD threshold, golden 05), so the map reads cleanly.
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    await tester.pump(const Duration(milliseconds: 250));
    final overview =
        tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));
    overview.fitView();
    // The left-to-right tree is compact enough that fit can land in the detail
    // (board-schedule) tier; zoom OUT below the LOD threshold so the panels
    // collapse to their summary card + merged "N loads" node (this golden's
    // whole point).
    var zout = 0;
    while (overview.currentScale >= kLodThreshold && zout++ < 8) {
      overview.zoomOut();
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The merged-loads summary nodes are present at the overview scale.
    expect(find.textContaining('loads'), findsWidgets);
    await expectLater(
        app, matchesGoldenFile('goldens/08_electrical_collapsed.png'));

    // Electrical OVERVIEW tab — the zoomed-out building single-line: every
    // panel a compact node in a top-down tree (normal / essential colour split,
    // PLN/MV/transformer/LV-main source spine), rendered LIVE from the pure
    // `buildElectricalOverview` SldSheet via SldSheetView. Scoped to the
    // electrical view so the tab tap is unambiguous.
    Finder elecSegment(String label) => find.descendant(
          of: find.byType(ElectricalView),
          matching: find.text(label),
        );
    await tester.tap(elecSegment('Overview'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
        app, matchesGoldenFile('goldens/09_electrical_overview.png'));

    // Electrical RISER tab — the floor-by-floor building riser: panels stacked
    // by true building elevation with vertical riser feeders + a floor/FFL
    // gutter, via `buildElectricalRiser` over the live mechanical
    // BuildingLevels.
    await tester.tap(elecSegment('Riser'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
        app, matchesGoldenFile('goldens/10_electrical_riser.png'));

    // Electrical board-schedule deep-zoom LOD — back on the Single-line tab,
    // frame the MDP at a scale past `kBoardScheduleThreshold` so its full engine
    // board schedule (the SAME geometry the PDF/DXF export draws, via
    // `buildElectricalPanelDetail` + SldSheetPainter) renders in place of the
    // mid-detail R-S-T busbar.
    await tester.tap(elecSegment('Single-line'));
    await tester.pump();
    final schedCanvas =
        tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));
    schedCanvas.focusPanelSchedule('mdp');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(schedCanvas.currentScale, greaterThanOrEqualTo(kBoardScheduleThreshold));
    await expectLater(
        app, matchesGoldenFile('goldens/11_electrical_schedule.png'));
  });
}
