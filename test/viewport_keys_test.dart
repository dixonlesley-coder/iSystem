/// K1 — the shared canvas VIEW keyboard vocabulary (`viewport_keys.dart`):
/// a pure key → intent mapping that mirrors `CanvasView._onKey` exactly (the
/// 1.2 zoom step, the 64 px arrow pan, F fit, Ctrl 0 actual size, nudge only
/// on a fresh unmodified key-down) plus the hold-Space pan latch. The Riser
/// canvases adopt it now; the electrical canvas is the next adopter.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx/ui/canvas/viewport_keys.dart';

KeyDownEvent _down(LogicalKeyboardKey k) => KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.keyA, logicalKey: k, timeStamp: Duration.zero);
KeyRepeatEvent _repeat(LogicalKeyboardKey k) => KeyRepeatEvent(
    physicalKey: PhysicalKeyboardKey.keyA, logicalKey: k, timeStamp: Duration.zero);
KeyUpEvent _up(LogicalKeyboardKey k) => KeyUpEvent(
    physicalKey: PhysicalKeyboardKey.keyA, logicalKey: k, timeStamp: Duration.zero);

void main() {
  group('viewportIntentForKey mirrors CanvasView', () {
    test('Ctrl/Cmd = + numpad+ zoom in by 1.2; - numpad- zoom out', () {
      for (final k in [
        LogicalKeyboardKey.equal,
        LogicalKeyboardKey.add,
        LogicalKeyboardKey.numpadAdd,
      ]) {
        expect(viewportIntentForKey(_down(k), mod: true),
            const ViewportZoomBy(1.2));
        // Without the modifier these are not view keys.
        expect(viewportIntentForKey(_down(k), mod: false), isNull);
      }
      for (final k in [
        LogicalKeyboardKey.minus,
        LogicalKeyboardKey.numpadSubtract,
      ]) {
        expect(viewportIntentForKey(_down(k), mod: true),
            const ViewportZoomBy(1 / 1.2));
      }
    });

    test('Ctrl 0 is actual size; F fits with or without a modifier', () {
      expect(viewportIntentForKey(_down(LogicalKeyboardKey.digit0), mod: true),
          const ViewportActualSize());
      expect(viewportIntentForKey(_down(LogicalKeyboardKey.digit0), mod: false),
          isNull);
      expect(viewportIntentForKey(_down(LogicalKeyboardKey.keyF), mod: false),
          const ViewportFit());
      expect(viewportIntentForKey(_down(LogicalKeyboardKey.keyF), mod: true),
          const ViewportFit());
    });

    test('arrows pan 64 px (Left moves the content right); a nudge candidate '
        'only on a fresh unmodified key-down', () {
      final left = viewportIntentForKey(_down(LogicalKeyboardKey.arrowLeft),
          mod: false) as ViewportPan;
      expect(left.delta, const Offset(64, 0));
      expect(left.nudgeCandidate, isTrue);
      expect(
          (viewportIntentForKey(_down(LogicalKeyboardKey.arrowRight),
                  mod: false) as ViewportPan)
              .delta,
          const Offset(-64, 0));
      expect(
          (viewportIntentForKey(_down(LogicalKeyboardKey.arrowUp), mod: false)
                  as ViewportPan)
              .delta,
          const Offset(0, 64));
      expect(
          (viewportIntentForKey(_down(LogicalKeyboardKey.arrowDown), mod: false)
                  as ViewportPan)
              .delta,
          const Offset(0, -64));
      // A held arrow (repeat) and any modifier+arrow pan, never nudge.
      expect(
          (viewportIntentForKey(_repeat(LogicalKeyboardKey.arrowLeft),
                  mod: false) as ViewportPan)
              .nudgeCandidate,
          isFalse);
      for (final m in [
        (mod: true, shift: false, alt: false),
        (mod: false, shift: true, alt: false),
        (mod: false, shift: false, alt: true),
      ]) {
        final p = viewportIntentForKey(_down(LogicalKeyboardKey.arrowLeft),
            mod: m.mod, shift: m.shift, alt: m.alt) as ViewportPan;
        expect(p.nudgeCandidate, isFalse);
        expect(p.delta, const Offset(64, 0));
      }
    });

    test('key-up and non-view keys map to nothing; only pans are immediate',
        () {
      expect(viewportIntentForKey(_up(LogicalKeyboardKey.keyF), mod: false),
          isNull);
      expect(viewportIntentForKey(_down(LogicalKeyboardKey.keyQ), mod: true),
          isNull);
      expect(const ViewportZoomBy(2).eased, isTrue);
      expect(const ViewportFit().eased, isTrue);
      expect(const ViewportActualSize().eased, isTrue);
      expect(
          const ViewportPan(Offset(1, 0), LogicalKeyboardKey.arrowLeft).eased,
          isFalse);
    });
  });

  group('applyViewportIntent', () {
    const viewport = Size(800, 600);
    const content = Size(1600, 1200);
    const current = ViewportTransform(scale: 0.5, offset: Offset(10, 20));

    test('zoom is about the viewport centre', () {
      final next = applyViewportIntent(const ViewportZoomBy(1.2), current,
          contentSize: content, viewportSize: viewport);
      expect(next, current.zoomedBy(1.2, const Offset(400, 300)));
      // The world point under the centre stays put.
      expect(next.screenToWorld(const Offset(400, 300)).dx,
          closeTo(current.screenToWorld(const Offset(400, 300)).dx, 1e-9));
    });

    test('fit / actual size / pan resolve like the transform factories', () {
      expect(
          applyViewportIntent(const ViewportFit(), current,
              contentSize: content, viewportSize: viewport),
          ViewportTransform.fit(content, viewport));
      expect(
          applyViewportIntent(const ViewportFit(), current,
              contentSize: content, viewportSize: viewport, fitPadding: 40),
          ViewportTransform.fit(content, viewport, padding: 40));
      expect(
          applyViewportIntent(const ViewportActualSize(), current,
              contentSize: content, viewportSize: viewport),
          ViewportTransform.actualSize(content, viewport));
      expect(
          applyViewportIntent(
              const ViewportPan(Offset(64, 0), LogicalKeyboardKey.arrowLeft),
              current,
              contentSize: content,
              viewportSize: viewport),
          current.panned(const Offset(64, 0)));
    });
  });

  group('SpacePanLatch', () {
    test('Space down / repeat latch, up releases; other keys pass through', () {
      final latch = SpacePanLatch();
      expect(latch.handle(_down(LogicalKeyboardKey.keyF)), isFalse);
      expect(latch.handle(_up(LogicalKeyboardKey.space)), isFalse,
          reason: 'an up with nothing held is not consumed');
      expect(latch.handle(_down(LogicalKeyboardKey.space)), isTrue);
      expect(latch.held, isTrue);
      expect(latch.handle(_repeat(LogicalKeyboardKey.space)), isTrue);
      expect(latch.handle(_up(LogicalKeyboardKey.space)), isTrue);
      expect(latch.held, isFalse);
    });

    test('a possible text entry keeps the space bar; release() drops a stuck '
        'latch', () {
      final latch = SpacePanLatch();
      expect(
          latch.handle(_down(LogicalKeyboardKey.space),
              textEntryPossible: true),
          isFalse);
      expect(latch.held, isFalse);
      latch.handle(_down(LogicalKeyboardKey.space));
      expect(latch.release(), isTrue);
      expect(latch.held, isFalse);
      expect(latch.release(), isFalse);
    });
  });
}
