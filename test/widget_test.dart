import 'package:flutter_test/flutter_test.dart';

import 'package:mechx/main.dart';

void main() {
  testWidgets('MechX shell smoke test — finds MechX text', (WidgetTester tester) async {
    // Build the minimal placeholder shell.
    await tester.pumpWidget(const MechXShell(dn100AreaM2: '0.007854'));

    // The shell must render a widget containing "MechX".
    expect(find.textContaining('MechX'), findsOneWidget);
  });
}
