/// L5/M4 — the shared hover-tooltip mechanism: shows only after a real hover
/// delay (never on a quick pass-over, so idle goldens never move) and hides
/// immediately the pointer leaves.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_tooltip.dart';

import 'test_util.dart';

/// Minimal ancestry a bespoke MechX control needs, plus an [Overlay] (the
/// tooltip's bubble is an [OverlayPortal] entry).
Widget _host(Widget child) => MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: Overlay(initialEntries: [
            OverlayEntry(
              // Align LOOSENS the incoming (screen-tight) constraints, so the
              // tooltip's fixed-size child below determines its own render
              // box rather than being stretched to fill the screen.
              builder: (_) => Align(alignment: Alignment.topLeft, child: child),
            ),
          ]),
        ),
      ),
    );

void main() {
  testWidgets(
      'the bubble stays hidden until the hover delay elapses, then shows the '
      'message, and disappears the instant the pointer leaves',
      (tester) async {
    setDesktopSurface(tester);
    const targetKey = ValueKey('tooltip-target');
    await tester.pumpWidget(_host(const MechXTooltip(
      message: 'Zoom in',
      child: SizedBox(key: targetKey, width: 28, height: 28),
    )));

    expect(find.text('Zoom in'), findsNothing);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byKey(targetKey)));

    // Short of the ~600 ms delay: still hidden (a quick pass-over never
    // flashes it).
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Zoom in'), findsNothing);

    // Past the delay: the bubble is up.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Zoom in'), findsOneWidget);

    // Moving the pointer away hides it immediately (no lingering fade).
    await gesture.moveTo(const Offset(290, 190));
    await tester.pump();
    expect(find.text('Zoom in'), findsNothing);
  });
}
