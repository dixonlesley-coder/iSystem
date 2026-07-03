import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/ui/canvas/canvas_view.dart';
import 'package:mechx/ui/canvas/drop_overlay.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

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

  testWidgets('dragging a palette node onto the canvas places it', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    Network net() => container.read(networkControllerProvider).network;
    expect(net().nodes, isEmpty);

    // The 'Fitting' palette card (NODES group) is a Draggable<PaletteItem>.
    final card = find.text('Fitting');
    expect(card, findsOneWidget);
    final from = tester.getCenter(card);
    // Drop near the centre of the live canvas.
    final to = tester.getCenter(find.byType(CanvasView));

    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 20));
    // Move in steps so the drag avatar tracks across to the canvas.
    await gesture.moveTo(Offset((from.dx + to.dx) / 2, (from.dy + to.dy) / 2));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveTo(to);
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pump();

    // A node must have been placed.
    expect(net().nodes, isNotEmpty,
        reason: 'dropping a palette card should add a node to the network');
  });

  testWidgets('a drag paints the place-preview, idle paints nothing extra',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The DropOverlay is mounted but, at rest, paints no preview CustomPaint
    // (it only renders the ghost/snap layer while a drag hovers).
    final overlay = find.byType(DropOverlay);
    expect(overlay, findsOneWidget);
    int previewPaints() => find
        .descendant(of: overlay, matching: find.byType(CustomPaint))
        .evaluate()
        .length;
    final idlePaints = previewPaints();

    final card = find.text('Fitting');
    final from = tester.getCenter(card);
    final to = tester.getCenter(find.byType(CanvasView));

    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveTo(Offset((from.dx + to.dx) / 2, (from.dy + to.dy) / 2));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveTo(to);
    await tester.pump(const Duration(milliseconds: 20));

    // During the drag the preview layer (ghost + snap) is painted, so the
    // overlay now hosts MORE CustomPaints than at rest.
    expect(previewPaints(), greaterThan(idlePaints),
        reason: 'a hovering drag should paint the place-preview');

    await gesture.up();
    await tester.pump();

    // After the drop the preview is torn down again.
    expect(previewPaints(), idlePaints,
        reason: 'the preview must not persist after the drop');
  });
}
