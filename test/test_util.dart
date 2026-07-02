import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/sheets_store.dart';

/// Sizes the test surface to a realistic desktop window so the full app shell
/// (top bar, rail, canvas, inspector, status bar) lays out without spurious
/// overflow. Desktop apps have a sensible minimum window size; the default
/// 800×600 test surface is narrower than MechX targets.
void setDesktopSurface(WidgetTester tester,
    {Size size = const Size(1280, 832)}) {
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
