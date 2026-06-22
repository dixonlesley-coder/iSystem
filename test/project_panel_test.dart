import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';

import 'test_util.dart';

void main() {
  testWidgets('project panel shows sections, floors, and adds a level',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // inspector sections
    expect(find.text('PROJECT'), findsOneWidget);
    expect(find.text('BUILDING'), findsOneWidget);
    expect(find.text('SCALE'), findsOneWidget);

    // a floor name that is unique to the panel (not a sheet name)
    expect(find.text('Level 2'), findsOneWidget);

    // add a level → 'Level 3' appears
    await tester.tap(find.text('+  Add level'));
    await tester.pump();
    expect(find.text('Level 3'), findsOneWidget);
  });

  testWidgets('uncalibrated sheet shows a calibration prompt', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    expect(find.textContaining('Not calibrated'), findsOneWidget);
  });
}
