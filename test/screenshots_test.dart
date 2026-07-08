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
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart';
import 'package:mechx/ui/electrical/electrical_view.dart';
import 'package:mechx/ui/electrical/panel_geometry.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
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

    // Production launches with NO sheets and an EMPTY electrical project (A1/A2)
    // so the first-run screens are honest; the golden suite seeds a
    // deterministic multi-sheet project + the sample switchboard explicitly so
    // the captured design states stay stable.
    container.read(sheetsControllerProvider.notifier).loadDemoSheets();
    container.read(electricalProjectProvider.notifier).resetToSample();
    await tester.pump();

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
    // A clean-water outlet on a short branch off the main — exercises the new
    // readable faucet/drop icon so the golden confirms it renders on-canvas
    // (connected, so it's a real outlet rather than an orphaned marker).
    net.addComponentNode(
        's1', 0, const Offset(700, 640), NodeComponent.waterOutlet);
    net.setTool(DrawTool.drawRun);
    net.placeRunPoint('s1', 0, const Offset(700, 360)); // tee into the main
    net.placeRunPoint('s1', 0, const Offset(700, 640)); // snap onto the outlet
    net.setTool(DrawTool.select);
    container.read(showSizingProvider.notifier).toggle();
    await tester.pump(const Duration(milliseconds: 250));

    // Drawing the network above triggers the live sizing solve, which fires
    // the one-shot "Auto-sized N runs" status confirmation (J2,
    // `firstAutoSizeNudgeProvider` via the `AppShell` `ref.listen`, which
    // resolves on the pump above). That pill is transient (self-clearing
    // after 3s) and orthogonal to what these screenshots capture, so clear it
    // here rather than let it linger across every golden below (covered on
    // its own in `test/app_state_test.dart`) — then pump once more so the
    // pill widget (built while the message was briefly set) actually
    // rebuilds to its collapsed null form before anything is captured.
    container.read(statusMessageProvider.notifier).clear();
    await tester.pump();

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

    // (The Overview tab was removed — its essential-red colouring + feeder
    // cable/breaker labels folded into the Single-line canvas above; the compact
    // whole-building Overview remains an EXPORT, not a tab.)
    Finder elecSegment(String label) => find.descendant(
          of: find.byType(ElectricalView),
          matching: find.text(label),
        );

    // Electrical RISER tab — the floor-by-floor building riser: panels stacked
    // by true building elevation with vertical riser feeders + a floor/FFL
    // gutter, via `buildElectricalRiser` over the live mechanical
    // BuildingLevels.
    await tester.tap(elecSegment('Building riser'));
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
    // B9: the fixed `kBoardScheduleThreshold + 0.3` reading scale clipped the
    // 920-unit-wide board schedule at both edges once the canvas (nav rail +
    // inspector subtracted from the 1440px surface) was narrower than the
    // schedule needed. `focusPanelSchedule` now clamps to whatever scale
    // actually fits the canvas width, floored at `kLodThreshold` so the
    // schedule LOD still renders. Assert both halves of that contract: still
    // in the schedule LOD, and the framed board no longer overflows the
    // canvas.
    final schedCanvasSize = tester.getSize(find.byType(ElectricalCanvas));
    expect(schedCanvas.currentScale, greaterThanOrEqualTo(kLodThreshold));
    expect(schedCanvas.currentScale * panelDetailWidth(),
        lessThanOrEqualTo(schedCanvasSize.width));
    await expectLater(
        app, matchesGoldenFile('goldens/11_electrical_schedule.png'));

    // ── Hub screens (H9) — the non-canvas shell sections now carry real,
    // Wave-4/5-changed content (the Review compliance + deliverables, the
    // Commercial M+E+P BOM/quotation, the Projects landing) but had NO golden
    // coverage. Capture them from the seeded project so a regression shows.
    container.read(shellSectionProvider.notifier).set(ShellSection.review);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(app, matchesGoldenFile('goldens/12_review_hub.png'));

    container.read(shellSectionProvider.notifier).set(ShellSection.commercial);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(app, matchesGoldenFile('goldens/13_commercial_hub.png'));

    container.read(shellSectionProvider.notifier).set(ShellSection.projects);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(app, matchesGoldenFile('goldens/14_projects_hub.png'));

    // ── J6 — a LIGHT-theme hub capture (the app is otherwise golden-covered in
    // light only on the plan canvas, golden 02). The Review hub in light exercises
    // the compliance card + issue rows across the light palette.
    container.read(brightnessProvider.notifier).toggle();
    container.read(shellSectionProvider.notifier).set(ShellSection.review);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(app, matchesGoldenFile('goldens/15_review_hub_light.png'));
    container.read(brightnessProvider.notifier).toggle();
    await tester.pump();
  });
}
