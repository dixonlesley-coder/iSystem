import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/stepped_value_field.dart';

import 'test_util.dart';

/// Wraps [child] in the minimal ancestry a bespoke MechX control needs
/// (MediaQuery + Directionality + MechXTheme) so `context.colors` / typing work.
Widget _host(Widget child) => MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 260, child: child),
          ),
        ),
      ),
    );

void main() {
  testWidgets('at rest renders the display text and no editor', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(_host(SteppedValueField(
      display: '3.00 m',
      editSeed: '3.00',
      onDecrement: () {},
      onIncrement: () {},
      onSubmit: (_) {},
    )));
    expect(find.text('3.00 m'), findsOneWidget);
    expect(find.byType(EditableText), findsNothing);
    // The two glyph buttons.
    expect(find.text('−'), findsOneWidget);
    expect(find.text('+'), findsOneWidget);
  });

  testWidgets('a single tap on + fires onIncrement exactly once',
      (tester) async {
    setDesktopSurface(tester);
    var inc = 0;
    await tester.pumpWidget(_host(SteppedValueField(
      display: '5',
      editSeed: '5',
      onDecrement: () {},
      onIncrement: () => inc++,
      onSubmit: (_) {},
    )));
    await tester.tap(find.text('+'));
    await tester.pump();
    expect(inc, 1);
  });

  testWidgets('click-to-type commits a clamped value on Enter', (tester) async {
    setDesktopSurface(tester);
    double? submitted;
    await tester.pumpWidget(_host(SteppedValueField(
      display: '200 mm/hr',
      editSeed: '200',
      min: 50,
      max: 600,
      onDecrement: () {},
      onIncrement: () {},
      onSubmit: (v) => submitted = v,
    )));

    // Click the value → an inline editor appears seeded with the bare number.
    await tester.tap(find.text('200 mm/hr'));
    await tester.pump();
    expect(find.byType(EditableText), findsOneWidget);

    // Type an over-max value and commit with Enter — it clamps to max.
    await tester.enterText(find.byType(EditableText), '999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(submitted, 600); // clamped to max
    expect(find.byType(EditableText), findsNothing); // editor dismissed
  });

  testWidgets('an empty field commits null (reset semantics)', (tester) async {
    setDesktopSurface(tester);
    var called = false;
    double? submitted = -1; // sentinel
    await tester.pumpWidget(_host(SteppedValueField(
      display: '250 cm',
      editSeed: '250',
      min: 0,
      onDecrement: () {},
      onIncrement: () {},
      onSubmit: (v) {
        called = true;
        submitted = v;
      },
    )));
    await tester.tap(find.text('250 cm'));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(called, isTrue);
    expect(submitted, isNull);
  });

  testWidgets('Esc cancels the edit without committing', (tester) async {
    setDesktopSurface(tester);
    var called = false;
    await tester.pumpWidget(_host(SteppedValueField(
      display: '3.00 m',
      editSeed: '3.00',
      onDecrement: () {},
      onIncrement: () {},
      onSubmit: (_) => called = true,
    )));
    await tester.tap(find.text('3.00 m'));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), '7.5');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(called, isFalse); // no commit
    expect(find.byType(EditableText), findsNothing); // reverted to display
    expect(find.text('3.00 m'), findsOneWidget);
  });

  testWidgets('blur (focus loss) commits the typed value', (tester) async {
    setDesktopSurface(tester);
    double? submitted;
    await tester.pumpWidget(_host(SteppedValueField(
      display: '100 L',
      editSeed: '100',
      min: 0,
      onDecrement: () {},
      onIncrement: () {},
      onSubmit: (v) => submitted = v,
    )));
    await tester.tap(find.text('100 L'));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), '175');
    // Drop focus → commit on blur.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(submitted, 175);
  });

  testWidgets('press-and-hold on + repeats onIncrement', (tester) async {
    setDesktopSurface(tester);
    var inc = 0;
    await tester.pumpWidget(_host(SteppedValueField(
      display: '5',
      editSeed: '5',
      repeatInterval: const Duration(milliseconds: 120),
      onDecrement: () {},
      onIncrement: () => inc++,
      onSubmit: (_) {},
    )));

    final gesture = await tester.startGesture(tester.getCenter(find.text('+')));
    // Hold past the long-press threshold (~500ms): first fire happens here.
    await tester.pump(const Duration(milliseconds: 600));
    expect(inc, greaterThanOrEqualTo(1));
    // Keep holding — the periodic timer fires each interval.
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.up();
    await tester.pump();
    // One long-press fire + at least a couple of repeats.
    expect(inc, greaterThanOrEqualTo(3));

    // After release, the repeat stops — no further fires.
    final afterRelease = inc;
    await tester.pump(const Duration(milliseconds: 240));
    expect(inc, afterRelease);
  });
}
