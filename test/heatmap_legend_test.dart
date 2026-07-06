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
///
/// Finding I2/E4 — the legend now also carries the ABSOLUTE pass anchor: the
/// SNI target residual (a threshold tick + a "Min NN kPa" label on a spread
/// field; a PASS/LOW verdict on the uniform field), so the colours read against
/// the code requirement, not just the view's own min/max.
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
      'the uniform-field case renders a single "Uniform 31 kPa" line whole '
      'with an honest LOW verdict against the target (no Low/High pair)',
      (tester) async {
    await tester.pumpWidget(_host(
      // 31 kPa everywhere, target 225 kPa ⇒ below the requirement ⇒ LOW.
      const HeatmapLegend(minKpa: 31, maxKpa: 31, targetKpa: 225),
    ));
    // A uniform field reads honestly as ONE value, not an identical Low/High
    // pair (which looked like a bug), and carries the PASS/LOW verdict.
    _expectRendersWhole(tester, 'Uniform 31 kPa');
    expect(find.text('LOW'), findsOneWidget);
    expect(find.text('PASS'), findsNothing);
    expect(find.text('Low 31 kPa'), findsNothing);
    expect(find.text('High 31 kPa'), findsNothing);
    expect(find.text('uniform field'), findsNothing);
  });

  testWidgets('a uniform field at/above the target reads PASS', (tester) async {
    await tester.pumpWidget(_host(
      const HeatmapLegend(minKpa: 260, maxKpa: 260, targetKpa: 225),
    ));
    _expectRendersWhole(tester, 'Uniform 260 kPa');
    expect(find.text('PASS'), findsOneWidget);
    expect(find.text('LOW'), findsNothing);
  });

  testWidgets(
      'wide endpoint values still render whole and the target Min label shows',
      (tester) async {
    await tester.pumpWidget(_host(
      const HeatmapLegend(minKpa: 3.2, maxKpa: 12345, targetKpa: 225),
    ));
    // toStringAsFixed(0): 3.2 -> "3", 12345 -> "12345".
    _expectRendersWhole(tester, 'Low 3 kPa');
    _expectRendersWhole(tester, 'High 12345 kPa');
    // The absolute anchor is labelled (the threshold tick's meaning).
    _expectRendersWhole(tester, 'Min 225 kPa');
    // A genuinely spread field shows no uniform verdict / note.
    expect(find.text('PASS'), findsNothing);
    expect(find.text('LOW'), findsNothing);
    expect(find.text('uniform field'), findsNothing);
  });
}
