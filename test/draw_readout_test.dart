import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/smart_input_store.dart';
import 'package:mechx/ui/canvas/drawing_overlay.dart';
import 'package:mechx/ui/canvas/snapping.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';

/// Draw-time CAD readouts (B21 polar chip, B29 invert-level line, B17 ortho
/// route preview + Tab cycle, B24 OSNAP marker vocabulary). The pure formatters
/// are asserted directly; the widget-level gating/marker resolution is driven
/// through a pumped [DrawingOverlay] whose live [RubberBandPainter] carries the
/// resolved readout state.
void main() {
  group('polarLabel (B21)', () {
    test('calibrated: metres @ bearing', () {
      // 100 px east at 0.01 m/px = 1.00 m, bearing 0 (East).
      final s = polarLabel(
          const Offset(100, 100), const Offset(200, 100),
          const ScaleCalibration(0.01));
      expect(s, '1.00 m @ 0');
    });

    test('bearing is CCW positive with screen-Y down (up = 90)', () {
      final s = polarLabel(
          const Offset(100, 100), const Offset(100, 0),
          const ScaleCalibration(0.01)); // straight up
      expect(s.endsWith('@ 90'), isTrue);
    });

    test('uncalibrated: pixels @ bearing', () {
      final s =
          polarLabel(const Offset(0, 0), const Offset(300, 0), null);
      expect(s, '300 px @ 0');
    });
  });

  group('fallLabel (B29, Round 17 follow-up)', () {
    test('slope x developed length, datum-free', () {
      // 3.00 m at slope 0.01 falls 0.03 m; 1/0.01 = 1:100.
      expect(fallLabel(3.0, 0.01), 'fall 0.03 m @ 1:100');
      // A 12 m run at 0.02 falls 0.24 m; 1/0.02 = 1:50.
      expect(fallLabel(12.0, 0.02), 'fall 0.24 m @ 1:50');
      // No fabricated invert: the readout never carries an 'IL' level.
      expect(fallLabel(12.0, 0.02).contains('IL'), isFalse);
    });
  });

  RubberBandPainter painterOf(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((c) => c.painter)
      .whereType<RubberBandPainter>()
      .first;

  Future<TestGesture> hoverAt(WidgetTester tester, Offset at) async {
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(() => g.removePointer());
    await g.moveTo(at);
    await tester.pump();
    return g;
  }

  Future<void> pumpOverlay(WidgetTester tester, ProviderContainer c) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        // Fill the whole test surface so gesture (global) coords == the overlay's
        // local coords == world coords (default identity viewport).
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: DrawingOverlay(sheetId: 's1', floorIndex: 0, levelCount: 3),
        ),
      ),
    );
  }

  // A run A-B on sheet s1 so the pending point (B) is a real node and the edge
  // midpoint is a snap target.
  void seedRun(ProviderContainer c, {bool calibrated = true}) {
    if (calibrated) {
      c
          .read(projectControllerProvider.notifier)
          .setCalibration('s1', const ScaleCalibration(0.01));
    }
    final net = c.read(networkControllerProvider.notifier);
    net.setService(ServiceType.drainage);
    net.setTool(DrawTool.drawRun);
    net.placeRunPoint('s1', 0, const Offset(100, 100));
    net.placeRunPoint('s1', 0, const Offset(300, 100)); // pending = (300,100)
  }

  testWidgets('B21/B29: calibrated drainage draw shows polar + fall lines',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    seedRun(c);
    await pumpOverlay(tester, c);
    await hoverAt(tester, const Offset(400, 100));

    final p = painterOf(tester);
    expect(p.polarText, isNotNull);
    expect(p.polarText, contains('m @'));
    // Gravity service + calibrated ⇒ the datum-free FALL line is present:
    // the 100 px leg at 0.01 m/px is 1.00 m, which falls 0.01 m at 1:100.
    expect(p.ilText, 'fall 0.01 m @ 1:100');
  });

  testWidgets('B29: fall line is omitted on an uncalibrated sheet',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    seedRun(c, calibrated: false);
    await pumpOverlay(tester, c);
    await hoverAt(tester, const Offset(400, 100));

    final p = painterOf(tester);
    expect(p.polarText, contains('px @')); // uncalibrated polar
    expect(p.ilText, isNull); // honest omission
  });

  testWidgets('B17: Tab cycles the ortho route preview label', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    seedRun(c); // ortho defaults ON ⇒ route mode active
    await pumpOverlay(tester, c);
    await hoverAt(tester, const Offset(450, 260));

    var p = painterOf(tester);
    expect(p.routeScreen, isNotNull); // a multi-leg route preview
    expect(p.routeLabel, 'Auto route · Tab');

    // Cycle the route kind (the key the Tab handler drives).
    c.read(orthoRouteKindProvider.notifier).cycle();
    await tester.pump();
    p = painterOf(tester);
    expect(p.routeLabel, 'L: across then up · Tab');

    c.read(orthoRouteKindProvider.notifier).cycle();
    await tester.pump();
    p = painterOf(tester);
    expect(p.routeLabel, 'L: up then across · Tab');
  });

  testWidgets('B24: OSNAP marker kind — node vs midpoint', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // Turn ortho OFF so the resolved end is the raw snap (no route rewrite).
    seedRun(c);
    c.read(orthoProvider.notifier).toggle(); // -> off
    await pumpOverlay(tester, c);

    // One live mouse pointer, moved between the two targets.
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(() => g.removePointer());

    // Hover over the far node A (100,100): a node snap (square marker).
    await g.moveTo(const Offset(102, 100));
    await tester.pump();
    expect(painterOf(tester).snapKind, SnapKind.node);

    // Hover over the run midpoint (200,100): a midpoint snap (triangle marker).
    await g.moveTo(const Offset(200, 101));
    await tester.pump();
    expect(painterOf(tester).snapKind, SnapKind.midpoint);
  });
}
