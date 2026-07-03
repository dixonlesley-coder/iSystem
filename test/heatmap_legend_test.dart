import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/canvas/heatmap_layer.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

/// Finding J2 — the heatmap legend used a hard 148 px row with ellipsizing
/// mono labels, so the numeric endpoints it exists to show shipped as
/// "Low 31 k… / High 31 …" (golden 03). It now sizes to the labels' intrinsic
/// width: every endpoint renders whole, at any value width.
Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
  final mono = FontLoader('Roboto Mono')
    ..addFont(bytes('assets/fonts/RobotoMono-Regular.ttf'));
  await mono.load();
}

Widget _host(Widget child) => MechXTheme(
      data: MechXThemeData.dark,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: child),
      ),
    );

/// Asserts the [label] paragraph got at least its full intrinsic width — i.e.
/// the text laid out whole, with nothing elided/clipped away.
void _expectRendersWhole(WidgetTester tester, String label) {
  final finder = find.text(label);
  expect(finder, findsOneWidget, reason: '"$label" must be present');
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  expect(
    paragraph.size.width,
    greaterThanOrEqualTo(
        paragraph.getMaxIntrinsicWidth(double.infinity) - 0.01),
    reason: '"$label" must render whole, never truncated',
  );
}

void main() {
  setUpAll(_loadFonts);

  testWidgets(
      'the uniform-field case renders "Low 31 kPa / High 31 kPa" whole '
      '(the golden-03 truncation)', (tester) async {
    await tester.pumpWidget(_host(
      const HeatmapLegend(minKpa: 31, maxKpa: 31),
    ));
    _expectRendersWhole(tester, 'Low 31 kPa');
    _expectRendersWhole(tester, 'High 31 kPa');
    // The near-uniform note still shows.
    expect(find.text('uniform field'), findsOneWidget);
  });

  testWidgets('wide endpoint values still render whole (intrinsic sizing)',
      (tester) async {
    await tester.pumpWidget(_host(
      const HeatmapLegend(minKpa: 3.2, maxKpa: 12345),
    ));
    // toStringAsFixed(0): 3.2 -> "3", 12345 -> "12345".
    _expectRendersWhole(tester, 'Low 3 kPa');
    _expectRendersWhole(tester, 'High 12345 kPa');
    // A genuinely spread field shows no uniform note.
    expect(find.text('uniform field'), findsNothing);
  });
}
