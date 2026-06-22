import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';

/// Sizes the test surface to a realistic desktop window so the full app shell
/// (top bar, rail, canvas, inspector, status bar) lays out without spurious
/// overflow. Desktop apps have a sensible minimum window size; the default
/// 800×600 test surface is narrower than MechX targets.
void setDesktopSurface(WidgetTester tester,
    {Size size = const Size(1280, 832)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
