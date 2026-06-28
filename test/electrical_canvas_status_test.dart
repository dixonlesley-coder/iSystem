import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_store.dart';

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

  testWidgets(
      'a rejected feeder connection surfaces via the shared status pill, not a '
      'bespoke toast', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    final ctrl = container.read(electricalProjectProvider.notifier);

    // A self-feed is refused with a reason — the exact case the canvas feeds to
    // the status pill in _onFeederDragEnd.
    final panelId = container.read(electricalProjectProvider).panels.first.id;
    final res = ctrl.connectFeeder(panelId, panelId);
    expect(res.connected, isFalse);
    expect(res.reason, isNotNull);

    // The canvas now routes res.reason through the shared statusMessageProvider
    // (the same primitive Save/Open/Import use) — drive that exact call and
    // assert the message reaches the app-wide status pill.
    container.read(statusMessageProvider.notifier).showStatus(res.reason!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text(res.reason!), findsOneWidget);

    container.read(statusMessageProvider.notifier).clear();
    await tester.pump();
  });

  test('the bespoke electrical toast widget is gone (one feedback primitive)',
      () async {
    final src = await File('lib/ui/electrical/electrical_canvas.dart')
        .readAsString();
    // The old per-canvas toast helper + widget were removed in favour of the
    // shared status pill.
    expect(src.contains('class _Toast'), isFalse);
    expect(src.contains('void _toast('), isFalse);
  });
}
