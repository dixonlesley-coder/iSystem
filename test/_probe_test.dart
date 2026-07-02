import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/sheets_store.dart';

import 'test_util.dart';

void main() {
  testWidgets('probe empty frame', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('probe seeded frame', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    ).read(sheetsControllerProvider.notifier).loadDemoSheets();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
