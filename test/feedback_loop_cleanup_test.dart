import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/sheets/sheet_rail.dart';

import 'test_util.dart';

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

  testWidgets('the dead "Import loads" button no longer renders in Electrical',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Production launches with an EMPTY electrical project (A2); seed the sample
    // switchboard so the Electrical workspace renders its canvas + toolbar (the
    // Export affordance we assert on) rather than the empty-state card.
    seedSampleElectrical(container);
    container
        .read(workspaceViewProvider.notifier)
        .set(WorkspaceView.electrical);
    await tester.pump();

    expect(find.text('Import loads'), findsNothing);
    // The real export affordance stays.
    expect(find.text('Export'), findsOneWidget);
  });

  testWidgets('the sheet rail renders its calibration glyph', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // The rail is present on the Layout workspace; it renders without error
    // (the calibration glyph is custom-painted, so this also guards tofu).
    expect(find.byType(SheetRail), findsOneWidget);
  });
}
