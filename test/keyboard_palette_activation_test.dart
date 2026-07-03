import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/segment_palette.dart';
import 'package:mechx/ui/widgets/palette_card.dart';
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

/// Focuses the [Focus] node hosting the palette card whose label is [label],
/// then presses Enter — exercising the card's keyboard-activation path.
Future<void> _focusAndActivate(WidgetTester tester, String label) async {
  final card = find.ancestor(
    of: find.text(label),
    matching: find.byType(PaletteCard<PaletteItem>),
  );
  expect(card, findsOneWidget);
  // The MechXFocusRing's FocusableActionDetector creates a Focus node in the
  // card subtree; grab it and request focus, then send Enter.
  final focusNode = Focus.of(
    tester.element(find.descendant(of: card, matching: find.byType(Text)).first),
  );
  focusNode.requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('Enter on a focused palette card drops a node at sheet centre',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Production launches with NO sheets (A1); a palette drop targets the
    // current sheet's centre, so seed the demo sheets first.
    seedDemoSheets(container);
    await tester.pump();
    Network net() => container.read(networkControllerProvider).network;
    expect(net().nodes, isEmpty);

    final sheet = container.read(sheetsControllerProvider).current!;
    final centre = sheet.sizePx.center(Offset.zero);

    await _focusAndActivate(tester, 'Fitting');

    expect(net().nodes, isNotEmpty,
        reason: 'Enter on a focused palette card should add a node');
    final placed = net().nodes.last;
    expect(placed.x, closeTo(centre.dx, 0.5));
    expect(placed.y, closeTo(centre.dy, 0.5));
  });

  testWidgets('keyboard-activating Terminal / Riser cards places their nodes',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Production launches with NO sheets (A1); seed the demo sheets so the
    // keyboard-activated cards have a current sheet to drop their nodes onto.
    seedDemoSheets(container);
    await tester.pump();
    Network net() => container.read(networkControllerProvider).network;

    await _focusAndActivate(tester, 'Terminal');
    expect(net().nodes.any((n) => n.role == NodeRole.fixture), isTrue,
        reason: 'Terminal activation should add a fixture node');

    await _focusAndActivate(tester, 'Riser node');
    expect(net().nodes.any((n) => n.component == NodeComponent.riser), isTrue,
        reason: 'Riser activation should add a riser component node');
  });
}
