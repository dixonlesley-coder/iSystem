import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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

  testWidgets('selected pipe edge: the size stepper + a material pill edit the '
      'edge', (tester) async {
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

    // E6 replaced the inline ~11-pill size ladder with a shared stepper. Scope
    // the +/- glyphs to the edge's own size stepper by its key (the Design-inputs
    // rainfall/runoff steppers carry the same glyphs).
    final sizeField = find.byKey(const ValueKey('edge-size-stepper'));
    expect(sizeField, findsOneWidget);
    final sizeInc = find.descendant(of: sizeField, matching: find.text('+'));
    // The decrement glyph is U+2212 MINUS SIGN (matches SteppedValueField).
    final sizeDec = find.descendant(of: sizeField, matching: find.text('−'));

    // From Auto, '+' enters the ladder at the smallest standard size — the
    // stepper edits the override through the same setEdgeSizeOverride intent.
    expect(edge().sizeOverride, isNull);
    await tester.ensureVisible(sizeField);
    await tester.tap(sizeInc);
    await tester.pump();
    expect(edge().sizeOverride, isNotNull);

    // Material pill (E3 kept these): pick the first catalogued pipe product.
    final product = PipeProduct.values.first;
    expect(edge().pipeProduct, isNull);
    await tester.ensureVisible(find.text(labelFor(product)));
    await tester.tap(find.text(labelFor(product)));
    await tester.pump();
    expect(edge().pipeProduct, product);

    // Stepping '-' back off the smallest ladder size returns to Auto, clearing
    // the override (the stepper's Auto sits below the smallest size).
    await tester.ensureVisible(sizeField);
    await tester.tap(sizeDec);
    await tester.pump();
    expect(edge().sizeOverride, isNull);
  });
}
