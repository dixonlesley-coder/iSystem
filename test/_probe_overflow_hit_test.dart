import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Mirror of electrical_layer.dart _ScaledLayoutChild.
Widget scaled(double scale, double w, double h, Widget child) => Transform.scale(
      scale: scale,
      alignment: Alignment.topLeft,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: 0, maxWidth: double.infinity, minHeight: 0, maxHeight: double.infinity,
        child: SizedBox(width: w, height: h, child: child),
      ),
    );

void main() {
  for (final s in [0.4, 1.0, 2.0]) {
    testWidgets('probe scale $s', (tester) async {
      var taps = <String>[];
      const w = 100.0, h = 60.0;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(children: [
          Positioned(
            left: 50, top: 50, width: w * s, height: h * s,
            child: scaled(s, w, h, Builder(builder: (c) => Stack(children: [
              Positioned(left: 0, top: 0, width: 50, height: 30,
                child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => taps.add('TL'))),
              Positioned(left: 50, top: 30, width: 50, height: 30,
                child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => taps.add('BR'))),
            ]))),
          ),
        ]),
      ));
      await tester.tapAt(Offset(50 + 25 * s, 50 + 15 * s));
      await tester.tapAt(Offset(50 + 75 * s, 50 + 45 * s));
      // ignore: avoid_print
      print('PROBE scale=$s taps=$taps');
    });
  }
}
