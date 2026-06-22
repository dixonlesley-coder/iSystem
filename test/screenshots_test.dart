import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
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
    await tester.pump(const Duration(milliseconds: 250));
    await expectLater(app, matchesGoldenFile('goldens/02_plan_light.png'));
    container.read(brightnessProvider.notifier).toggle();
    await tester.pump();

    container.read(showHeatmapProvider.notifier).toggle();
    await tester.pump(const Duration(milliseconds: 250));
    await expectLater(app, matchesGoldenFile('goldens/03_heatmap.png'));
    container.read(showHeatmapProvider.notifier).toggle();
    await tester.pump();

    container.read(showSchematicProvider.notifier).toggle();
    await tester.pump(const Duration(milliseconds: 250));
    await expectLater(app, matchesGoldenFile('goldens/04_schematic.png'));
  });
}
