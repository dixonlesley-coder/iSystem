import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';

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

  test('statusMessageProvider auto-clears after its window', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(statusMessageProvider), isNull);

    container.read(statusMessageProvider.notifier).showStatus('Saved x.mechx');
    expect(container.read(statusMessageProvider), 'Saved x.mechx');

    // Past the 3-second window it self-clears.
    await Future<void>.delayed(const Duration(milliseconds: 3100));
    expect(container.read(statusMessageProvider), isNull);
  });

  test('a fresh message supersedes the previous one', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final ctrl = container.read(statusMessageProvider.notifier);
    ctrl.showStatus('first');
    ctrl.showStatus('second');
    expect(container.read(statusMessageProvider), 'second');
    ctrl.clear();
    expect(container.read(statusMessageProvider), isNull);
  });

  testWidgets('a status message renders a confirmation pill in the status bar',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    // Nothing shown at rest.
    expect(find.text('Project opened'), findsNothing);

    container.read(statusMessageProvider.notifier).showStatus('Project opened');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Project opened'), findsOneWidget);
  });
}
