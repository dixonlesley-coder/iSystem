import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/review/review_hub.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

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
      'Review hub shows a pass/fail compliance roll-up and no placeholder prose',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: ReviewHub(),
          ),
        ),
      ),
    );
    await tester.pump();

    // The "coming together" placeholder lead is gone.
    expect(find.textContaining('coming together'), findsNothing);
    // The new lead is present.
    expect(find.textContaining('Check the design before you issue it'),
        findsOneWidget);

    // The compliance roll-up renders an overall verdict + the three category
    // rows. With the default const standards profiles carrying // VERIFY items,
    // the Standards row must be REVIEW (so the overall verdict is REVIEW
    // REQUIRED).
    expect(find.text('Air velocities within band'), findsOneWidget);
    expect(find.text('Sheet calibration'), findsOneWidget);
    expect(find.text('Standards verification'), findsOneWidget);
    expect(find.text('REVIEW REQUIRED'), findsOneWidget);
    // 'REVIEW' verdict labels appear at least for the Standards row.
    expect(find.text('REVIEW'), findsWidgets);

    // J3: the hub ends in an 'Export deliverables' card leading with the
    // verdict (the "check, then issue" pairing), followed by the reused
    // export buttons — no new export path, just the existing Projects-screen
    // functions surfaced here too.
    expect(find.text('Export deliverables'), findsOneWidget);
    expect(
      find.text('REVIEW REQUIRED — you decide whether to issue'),
      findsOneWidget,
    );
    expect(find.text('Export calc report (MD)'), findsOneWidget);
    expect(find.text('Export unified MEP report (MD)'), findsOneWidget);
    expect(find.text('Export equipment schedule (MD)'), findsOneWidget);
  });
}
