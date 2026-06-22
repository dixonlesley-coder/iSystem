import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';

void main() {
  testWidgets('boots into the shell and lists the demo sheets', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // rail navigation (sheet names are distinct from floor names)
    expect(find.text('First Floor'), findsOneWidget); // rail only (not current)
    expect(find.text('Roof Plan'), findsOneWidget);
    // current sheet name shows in BOTH the rail and the page watermark
    expect(find.text('Ground Floor'), findsWidgets);
    // app chrome
    expect(find.text('MechX'), findsOneWidget);
  });

  testWidgets('clicking a sheet in the rail switches the canvas', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    await tester.tap(find.text('First Floor'));
    await tester.pump();

    // now 'First Floor' is the current sheet → also rendered on the page
    expect(find.text('First Floor'), findsWidgets);
  });

  testWidgets('top bar shows a zoom percentage after the canvas fits', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump(); // run the post-frame fit
    await tester.pump(); // rebuild with the emitted transform
    expect(find.textContaining('%'), findsWidgets);
  });
}
