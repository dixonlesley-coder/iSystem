import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/pipe_products.dart';

import 'test_util.dart';

/// E9 — the selected-edge inspector can EDIT size + material (not just display
/// them), via the same store setters the right-click menu uses.
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

  testWidgets('selected pipe edge: a size pill + a material pill edit the edge',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container.read(sheetsControllerProvider.notifier).loadDemoSheets();
    container
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.01));

    // Draw a single cold-water run, then select the edge it created.
    final net = container.read(networkControllerProvider.notifier);
    net.setService(ServiceType.coldWater);
    net.setTool(DrawTool.drawRun);
    net.placeRunPoint('s1', 0, const Offset(360, 360));
    net.placeRunPoint('s1', 0, const Offset(900, 360));
    net.setTool(DrawTool.select);
    final edgeId = container.read(networkControllerProvider).network.edges.first.id;
    container.read(selectionProvider.notifier).selectEdge(edgeId);
    await tester.pump();

    NetEdge edge() =>
        container.read(networkControllerProvider).network.edges.first;

    // Size pill: 2" → DN50 (npsLabel(2.0) == '2"').
    expect(edge().sizeOverride, isNull);
    await tester.ensureVisible(find.text('2"'));
    await tester.tap(find.text('2"'));
    await tester.pump();
    expect(edge().sizeOverride, isNotNull);
    expect(edge().sizeOverride!.inMillimeters, closeTo(50, 0.5));

    // Material pill: pick the first catalogued pipe product by its label.
    final product = PipeProduct.values.first;
    expect(edge().pipeProduct, isNull);
    await tester.ensureVisible(find.text(labelFor(product)));
    await tester.tap(find.text(labelFor(product)));
    await tester.pump();
    expect(edge().pipeProduct, product);

    // The "Auto" size pill clears the override (E9 dropped the separate button).
    await tester.ensureVisible(find.text('Auto'));
    await tester.tap(find.text('Auto').first);
    await tester.pump();
    expect(edge().sizeOverride, isNull);
  });
}
