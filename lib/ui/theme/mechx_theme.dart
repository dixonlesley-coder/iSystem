import 'package:flutter/widgets.dart';

import 'design_tokens.dart';

/// Bundles a brightness's colours + the shared type scale.
@immutable
class MechXThemeData {
  final MechXColors colors;
  final MechXTypography typography;

  const MechXThemeData({required this.colors, required this.typography});

  Brightness get brightness => colors.brightness;

  static const MechXThemeData light = MechXThemeData(
    colors: MechXColors.light,
    typography: MechXTypography.standard,
  );
  static const MechXThemeData dark = MechXThemeData(
    colors: MechXColors.dark,
    typography: MechXTypography.standard,
  );

  static MechXThemeData forBrightness(Brightness b) =>
      b == Brightness.dark ? dark : light;
}

/// Inherited design system. `MechXTheme.of(context)` (or the `context.colors` /
/// `context.type` extensions) reads it.
class MechXTheme extends InheritedWidget {
  final MechXThemeData data;

  const MechXTheme({super.key, required this.data, required super.child});

  static MechXThemeData of(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<MechXTheme>();
    assert(widget != null, 'No MechXTheme found in context');
    return widget!.data;
  }

  static MechXThemeData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MechXTheme>()?.data;

  @override
  bool updateShouldNotify(MechXTheme oldWidget) => data != oldWidget.data;
}

/// Ergonomic accessors: `context.colors.accent`, `context.type.title`.
extension MechXThemeContext on BuildContext {
  MechXThemeData get mechxTheme => MechXTheme.of(this);
  MechXColors get colors => MechXTheme.of(this).colors;
  MechXTypography get type => MechXTheme.of(this).typography;
}
