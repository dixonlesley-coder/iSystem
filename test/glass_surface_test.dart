import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/theme/design_tokens.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/glass_surface.dart';

import 'test_util.dart';

Widget _host(Widget child, {MechXThemeData theme = MechXThemeData.dark}) =>
    MechXTheme(
      data: theme,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(alignment: Alignment.topLeft, child: child),
      ),
    );

void main() {
  testWidgets('GlassSurface renders its child over a backdrop blur',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(_host(
      const GlassSurface(child: Text('chrome')),
    ));
    await tester.pump();

    expect(find.text('chrome'), findsOneWidget);
    // The Liquid-Glass material is a real backdrop blur (it refracts the
    // content painted behind it), not just a translucent fill.
    final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
    final blur = filter.filter as ui.ImageFilter;
    // Sanity: the configured blur sigma is non-trivial.
    expect(MechXGlass.blurSigma, greaterThan(0));
    expect(blur, isNotNull);
  });

  testWidgets('glass tokens differ by brightness (adapts light/dark)',
      (tester) async {
    // The fill / sheen / edge are distinct per brightness so the chrome reads
    // as glass in both modes (a smoked panel in dark, a bright frost in light).
    expect(MechXColors.light.glassFill, isNot(MechXColors.dark.glassFill));
    expect(MechXColors.light.glassSheen, isNot(MechXColors.dark.glassSheen));
    // Both fills are translucent (alpha < 1.0) so the backdrop shows through.
    expect(MechXColors.light.glassFill.a, lessThan(1.0));
    expect(MechXColors.dark.glassFill.a, lessThan(1.0));
  });

  testWidgets('a custom edge limits the hairline to the chosen side',
      (tester) async {
    setDesktopSurface(tester);
    const edge = Border(right: BorderSide(color: Color(0xFFFFFFFF), width: 0.6));
    await tester.pumpWidget(_host(
      const GlassSurface(edge: edge, child: SizedBox(width: 40, height: 40)),
    ));
    await tester.pump();
    // The DecoratedBox inside the glass carries the supplied one-sided border.
    final decorated = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((d) => d.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((d) => d.border == edge);
    expect(decorated.border, edge);
  });
}
