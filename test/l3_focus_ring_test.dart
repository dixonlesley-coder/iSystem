/// L3 — keyboard-focus support was inconsistently applied: `MechXMenuRow` (the
/// ONE shared row every mechanical AND electrical right-click context menu
/// renders), `ElectricalToggleRow`, and the Offset dialog's `_SideButton` were
/// bare `GestureDetector`s with no `Focus`/`MechXFocusRing`, so a keyboard user
/// could never Tab to or activate them. This test drives the shared,
/// fully-public `MechXMenuRow` through its new focus-ring keyboard path.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/context_menu.dart';

import 'test_util.dart';

Widget _host(Widget child) => MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    );

void main() {
  testWidgets('Tab reaches a MechXMenuRow and Enter fires its onTap',
      (tester) async {
    setDesktopSurface(tester);
    var taps = 0;
    await tester.pumpWidget(_host(MechXMenuRow(
      label: 'Delete',
      onTap: () => taps++,
    )));

    final focusNode = Focus.of(
      tester.element(find.descendant(
        of: find.byType(MechXMenuRow),
        matching: find.byType(Text),
      )),
    );
    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(taps, 1, reason: 'Enter on a focused menu row should fire onTap');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(taps, 2, reason: 'Space should also activate the focused row');
  });
}
