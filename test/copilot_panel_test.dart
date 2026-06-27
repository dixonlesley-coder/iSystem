import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/ai_copilot_store.dart';
import 'package:mechx/ui/ai/copilot_panel.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

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

  Future<ProviderContainer> pump(WidgetTester tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(children: [CopilotOverlay()]),
        ),
      ),
    ));
    return container;
  }

  testWidgets('renders nothing when closed (golden-safe)', (tester) async {
    await pump(tester);
    expect(find.text('Ask Claude'), findsNothing);
  });

  testWidgets('opening shows the panel; disabled without a key',
      (tester) async {
    final container = await pump(tester);
    container.read(copilotOpenProvider.notifier).open();
    await tester.pump();
    expect(find.text('Ask Claude'), findsOneWidget);
    expect(container.read(copilotEnabledProvider), isFalse);
  });
}
