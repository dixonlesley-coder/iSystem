import 'dart:io';

import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/recovery.dart' show appSupportDirOverride;
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/network/network.dart';

/// One isolated app-support dir per test isolate (test file), created lazily.
/// The app's machine-local state (settings + per-project crash-recovery
/// snapshots) lives under `appSupportDir()`; without this override every
/// app-pumping widget test across the concurrently-run suite would write to
/// the same on-disk tree and race / leak recovery snapshots into each other
/// (a recovery banner popping in an unrelated test). A per-file temp dir keeps
/// each isolate hermetic. Production is unaffected (override null there).
String? _isolatedAppSupport;
void _ensureIsolatedAppSupport() {
  if (_isolatedAppSupport != null) return;
  _isolatedAppSupport =
      Directory.systemTemp.createTempSync('mechx_appsupport_test').path;
  appSupportDirOverride = _isolatedAppSupport;
}

/// Sizes the test surface to a realistic desktop window so the full app shell
/// (top bar, rail, canvas, inspector, status bar) lays out without spurious
/// overflow. Desktop apps have a sensible minimum window size; the default
/// 800×600 test surface is narrower than MechX targets. Also isolates the
/// app-support dir for this test isolate (recovery/settings hermeticity).
void setDesktopSurface(WidgetTester tester,
    {Size size = const Size(1280, 832)}) {
  _ensureIsolatedAppSupport();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Seed the deterministic demo sheets. Production now launches with NO sheets
/// (A1 — work drawn on placeholder paper was a dead end), so tests that need a
/// drawable sheet must seed them explicitly. Pass the app's ProviderContainer
/// (from `ProviderScope.containerOf`, or a bare `ProviderContainer()`).
void seedDemoSheets(ProviderContainer c) =>
    c.read(sheetsControllerProvider.notifier).loadDemoSheets();

/// Seed the sample electrical switchboard. Production now launches with an
/// EMPTY electrical project (A2 — the fictional sample no longer rides into
/// real deliverables), so tests exercising the sample MDP/LP-1 seed it here.
void seedSampleElectrical(ProviderContainer c) =>
    c.read(electricalProjectProvider.notifier).resetToSample();

/// Round 15 (drafting-visual-2-5) — [net] plus a lone two-node HYDRANT run
/// (`fh-a` → `fh-b`, off to the side, connected to nothing else). The
/// standpipe fire pump is scheduled / electrically fed only when the project
/// actually draws a fire service, so a test about that duty draws one.
Network withFireHydrantRun([Network net = const Network()]) => Network(
      nodes: [
        ...net.nodes,
        const NetNode(id: 'fh-a', sheetId: 's1', x: 5000, y: 5000, floorIndex: 0),
        const NetNode(id: 'fh-b', sheetId: 's1', x: 5100, y: 5000, floorIndex: 0),
      ],
      edges: [
        ...net.edges,
        const NetEdge(
            id: 'fh-run',
            fromId: 'fh-a',
            toId: 'fh-b',
            service: ServiceType.fireHydrant),
      ],
    );

/// Loads [withFireHydrantRun] of the container's CURRENT network.
void drawFireHydrantRun(ProviderContainer c) {
  final n = c.read(networkControllerProvider.notifier);
  n.loadNetwork(withFireHydrantRun(c.read(networkControllerProvider).network));
}
