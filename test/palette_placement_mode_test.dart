import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/ui/canvas/canvas_view.dart';
import 'package:mechx/ui/canvas/segment_palette.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

/// F5 — click-to-place-repeatedly: clicking a palette card ARMS a placement
/// mode; each canvas click drops another instance; Esc disarms.
Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
}

void main() {
  setUpAll(_loadFonts);

  testWidgets(
      'F5: clicking a palette card arms placement; three clicks place three '
      'nodes; Esc disarms', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false);
    seedDemoSheets(c);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    Network net() => c.read(networkControllerProvider).network;
    expect(net().nodes, isEmpty);

    // Click (not drag) the Fitting palette card → arm click-to-place.
    await tester.tap(find.text('Fitting'));
    await tester.pump();
    expect(c.read(armedPlacementProvider), isNotNull,
        reason: 'clicking a palette card arms click-to-place');
    // The armed hint pill is shown on the canvas.
    expect(find.textContaining('Placing Fitting'), findsOneWidget);

    // Three DISTINCT canvas clicks → three placed fittings.
    final centre = tester.getCenter(find.byType(CanvasView));
    for (final d in const [Offset(0, 0), Offset(80, 0), Offset(-80, 0)]) {
      await tester.tapAt(centre + d);
      await tester.pump();
    }
    expect(net().nodes.length, 3,
        reason: 'each armed canvas click placed another fitting');

    // Esc disarms; a further click places nothing more.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(c.read(armedPlacementProvider), isNull,
        reason: 'Esc disarms the placement mode');
    await tester.tapAt(centre + const Offset(160, 0));
    await tester.pump();
    expect(net().nodes.length, 3,
        reason: 'after Esc, a canvas click no longer places');
  });

  testWidgets('F5: re-clicking the armed card disarms it', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final c = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false);
    seedDemoSheets(c);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Terminal'));
    await tester.pump();
    expect(c.read(armedPlacementProvider), isNotNull);
    // Clicking the SAME card again toggles the mode off.
    await tester.tap(find.text('Terminal'));
    await tester.pump();
    expect(c.read(armedPlacementProvider), isNull);
  });
}
