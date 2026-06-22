import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/canvas/viewport.dart';

void main() {
  group('ViewportTransform', () {
    test('world <-> screen round-trip', () {
      const vt = ViewportTransform(scale: 2.0, offset: Offset(10, 20));
      final screen = vt.worldToScreen(const Offset(5, 7));
      expect(screen, const Offset(20, 34));
      expect(vt.screenToWorld(screen), const Offset(5, 7));
    });

    test('zoomedTo keeps the focal world point under the cursor', () {
      const vt = ViewportTransform(scale: 1, offset: Offset(30, 40));
      const focal = Offset(100, 80);
      final worldUnderCursor = vt.screenToWorld(focal);
      final z = vt.zoomedTo(3.0, focal);
      expect(z.scale, 3.0);
      final after = z.worldToScreen(worldUnderCursor);
      expect(after.dx, closeTo(focal.dx, 1e-9));
      expect(after.dy, closeTo(focal.dy, 1e-9));
    });

    test('zoomedBy multiplies the scale', () {
      const vt = ViewportTransform(scale: 2);
      expect(vt.zoomedBy(1.5, Offset.zero).scale, closeTo(3.0, 1e-9));
    });

    test('scale clamps to [minScale, maxScale]', () {
      const vt = ViewportTransform(scale: 1);
      expect(vt.zoomedTo(1e6, Offset.zero).scale, ViewportTransform.maxScale);
      expect(vt.zoomedTo(1e-6, Offset.zero).scale, ViewportTransform.minScale);
    });

    test('panned shifts the offset', () {
      const vt = ViewportTransform(scale: 1, offset: Offset(5, 5));
      expect(vt.panned(const Offset(10, -3)).offset, const Offset(15, 2));
    });

    test('fit scales and centres content', () {
      final vt = ViewportTransform.fit(
        const Size(100, 50),
        const Size(400, 400),
        padding: 0,
      );
      expect(vt.scale, 4.0); // min(400/100, 400/50)
      expect(vt.offset, const Offset(0, 100)); // centred: (400-400)/2, (400-200)/2
    });

    test('actualSize is 100% centred', () {
      final vt = ViewportTransform.actualSize(
        const Size(100, 100),
        const Size(400, 300),
      );
      expect(vt.scale, 1.0);
      expect(vt.offset, const Offset(150, 100));
    });

    test('fit on degenerate sizes is identity', () {
      expect(
        ViewportTransform.fit(Size.zero, const Size(100, 100)),
        const ViewportTransform(),
      );
    });

    test('equality and hashCode by value', () {
      const a = ViewportTransform(scale: 2, offset: Offset(1, 1));
      const b = ViewportTransform(scale: 2, offset: Offset(1, 1));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
