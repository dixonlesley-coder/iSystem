import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/theme/design_tokens.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

void main() {
  test('spacing follows a 4/8pt grid', () {
    for (final s in [
      MechXSpacing.xs,
      MechXSpacing.sm,
      MechXSpacing.md,
      MechXSpacing.lg,
      MechXSpacing.xl,
      MechXSpacing.xxl,
    ]) {
      expect(s % 4, 0, reason: '$s should be a multiple of 4');
    }
    expect(MechXSpacing.units(2), 16);
  });

  test('light and dark are distinct, correctly tagged', () {
    expect(MechXThemeData.light.colors.brightness, Brightness.light);
    expect(MechXThemeData.dark.colors.brightness, Brightness.dark);
    expect(
      MechXThemeData.light.colors.background,
      isNot(MechXThemeData.dark.colors.background),
    );
    expect(MechXThemeData.forBrightness(Brightness.dark), MechXThemeData.dark);
  });

  testWidgets('MechXTheme.of resolves; context extensions read it', (tester) async {
    late MechXColors seenColors;
    late MechXTypography seenType;
    await tester.pumpWidget(
      MechXTheme(
        data: MechXThemeData.dark,
        child: Builder(
          builder: (context) {
            seenColors = context.colors;
            seenType = context.type;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seenColors.brightness, Brightness.dark);
    expect(seenColors.accent, MechXColors.dark.accent);
    expect(seenType.body.fontSize, MechXTypography.standard.body.fontSize);
  });
}
