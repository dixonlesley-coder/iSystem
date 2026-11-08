import 'dart:io';
import 'dart:math';

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
/// SNI target residual (a threshold tick + a "Target NN kPa" label (Round 33: the tick is the COMFORT target, never 'Min') on a spread
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
    _expectRendersWhole(tester, 'Target 225 kPa');
    // A genuinely spread field shows no uniform verdict / note.
    expect(find.text('PASS'), findsNothing);
    expect(find.text('LOW'), findsNothing);
    expect(find.text('uniform field'), findsNothing);
  });

  // ── G6 (WORKFLOW-FRICTION): the caveat belongs on BOTH branches ───────────

  testWidgets(
      'a SPREAD field whose target is held by design says so, and names the '
      'check that CAN fail', (tester) async {
    await tester.pumpWidget(_host(
      const HeatmapLegend(
          minKpa: 230, maxKpa: 310, targetKpa: 225, targetHeldByDesign: true),
    ));
    // The Target tick keeps its label — but it no longer stands alone: on the
    // upfeed solve every residual clears it by construction.
    _expectRendersWhole(tester, 'Target 225 kPa');
    _expectRendersWhole(tester, 'target held by design');
    _expectRendersWhole(tester, '- the real check is the pump duty');
    // It is a statement, not a verdict — no green PASS is claimed.
    expect(find.text('PASS'), findsNothing);
  });

  testWidgets('a spread field on a genuine (downfeed) check is unchanged',
      (tester) async {
    await tester.pumpWidget(_host(
      const HeatmapLegend(minKpa: 230, maxKpa: 310, targetKpa: 225),
    ));
    _expectRendersWhole(tester, 'Target 225 kPa');
    expect(find.text('target held by design'), findsNothing);
    expect(find.text('- the real check is the pump duty'), findsNothing);
  });

  testWidgets('the uniform branch keeps its verdict and gains the pointer',
      (tester) async {
    await tester.pumpWidget(_host(
      const HeatmapLegend(
          minKpa: 260, maxKpa: 260, targetKpa: 225, targetHeldByDesign: true),
    ));
    _expectRendersWhole(tester, 'Uniform 260 kPa');
    expect(find.text('held by design'), findsOneWidget);
    expect(find.text('PASS'), findsNothing);
    _expectRendersWhole(tester, '- the real check is the pump duty');
  });

  // ---------------------------------------------------------------------
  // Round 34 — the legend range is the residual AT FIXTURES.
  // ---------------------------------------------------------------------
  test(
      'heatmapLegendRange ranges over delivery nodes only: a ceiling junction '
      'sits 2.6 m x 9.81 kPa/m = 25.5 kPa above any fixture and must not '
      'set Low', () {
    // Golden-03 shape: bare junctions n0/n1 at 55.3 kPa (ceiling level), the
    // delivery nodes (outlet + two open ends) at 80.8 kPa = minResidual.
    final r = heatmapLegendRange(
      residualKpa: const {'n0': 55.3, 'n1': 55.3, 'n11': 80.8, 'e1': 80.8},
      deliveryNodeIds: const {'n11', 'e1', 'elsewhere'},
    )!;
    expect(r.atFixtures, isTrue);
    expect(r.minKpa, 80.8);
    expect(r.maxKpa, 80.8);
    // A floor with only a junction falls back to the pipework, flagged.
    final j = heatmapLegendRange(
      residualKpa: const {'n7': 28.8},
      deliveryNodeIds: const {'n11'},
    )!;
    expect(j.atFixtures, isFalse);
    expect(j.minKpa, 28.8);
    expect(heatmapLegendRange(residualKpa: const {}, deliveryNodeIds: const {}),
        isNull);
  });

  // Seeded property: the legend Low is never below the lowest DELIVERY
  // residual, whatever junction values are mixed in.
  test('property: Low/High always equal the delivery min/max (seeded)', () {
    final rnd = Random(34);
    for (var trial = 0; trial < 200; trial++) {
      final res = <String, double>{};
      final delivery = <String>{};
      final n = 1 + rnd.nextInt(12);
      for (var i = 0; i < n; i++) {
        res['n$i'] = rnd.nextDouble() * 300;
        if (rnd.nextBool()) delivery.add('n$i');
      }
      final r = heatmapLegendRange(residualKpa: res, deliveryNodeIds: delivery)!;
      final pool = delivery.isEmpty
          ? res.values.toList()
          : [for (final id in delivery) res[id]!];
      expect(r.atFixtures, delivery.isNotEmpty);
      expect(r.minKpa, pool.reduce(min));
      expect(r.maxKpa, pool.reduce(max));
    }
  });

  testWidgets(
      'a sheet with no fixture captions the pipework and prints no PASS/LOW',
      (tester) async {
    await tester.pumpWidget(_host(const HeatmapLegend(
        minKpa: 28.8, maxKpa: 28.8, targetKpa: 225, atFixtures: false)));
    _expectRendersWhole(
        tester, 'residual at pipework (no fixture on this floor)');
    expect(find.text('residual at fixtures'), findsNothing);
    expect(find.text('LOW'), findsNothing);
    expect(find.text('PASS'), findsNothing);
    _expectRendersWhole(tester, 'Uniform 29 kPa');
  });

  testWidgets(
      'Low and High are separated by at least one 16 px spacer (never the '
      'run-on "Low 55 kPaHigh 81 kPa")', (tester) async {
    await tester.pumpWidget(_host(
        const HeatmapLegend(minKpa: 55, maxKpa: 81, targetKpa: 225)));
    final low = tester.getRect(find.text('Low 55 kPa'));
    final high = tester.getRect(find.text('High 81 kPa'));
    expect(high.left - low.right, greaterThanOrEqualTo(16.0 - 0.01));
  });
}
