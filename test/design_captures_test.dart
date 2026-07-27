@Tags(['golden', 'sim'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/ui/shell/nav_rail.dart';

/// One-off design-review captures for the pages the golden suite does NOT
/// cover (Building setup, Preferences). Run with:
///   flutter test --update-goldens --tags sim test/design_captures_test.dart
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

  testWidgets('capture Building + Preferences', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    Future<void> capture(ShellSection section, String name) async {
      container.read(shellSectionProvider.notifier).set(section);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MechXApp),
        matchesGoldenFile('goldens_design/$name.png'),
      );
    }

    await capture(ShellSection.building, 'building_dark');
    await capture(ShellSection.preferences, 'preferences_dark');

    container.read(brightnessProvider.notifier).set(Brightness.light);
    await tester.pumpAndSettle();
    await capture(ShellSection.building, 'building_light');
  });
}
