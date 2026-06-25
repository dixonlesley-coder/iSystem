import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';

import 'test_util.dart';

void main() {
  testWidgets('project panel shows its sections + a building summary',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // inspector sections
    expect(find.text('PROJECT'), findsOneWidget);
    // The BUILDING section is now a compact summary that opens the dedicated
    // Building page (the floor editor itself moved off the inspector).
    expect(find.text('BUILDING'), findsOneWidget);
    expect(find.text('SCALE'), findsOneWidget);
    // The summary readout ("11.0 m · 3 levels") and its Edit affordance.
    expect(find.textContaining('3 levels'), findsOneWidget);

    // The floor editor (rows / Add level) is no longer in the inspector.
    expect(find.text('+  Add level'), findsNothing);
  });

  testWidgets('uncalibrated sheet shows a calibration prompt', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    expect(find.textContaining('Not calibrated'), findsOneWidget);
  });
}
