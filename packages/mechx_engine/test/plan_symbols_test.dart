import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:test/test.dart';

/// The plan-symbol primitive library (CAD-OUTPUT-UX-REVIEW Part 1 A5) — the
/// export analogue of the on-canvas `paintComponentSymbol`. These pin that
/// every `NodeComponent` yields a real, centred, ASCII-safe glyph so the plan
/// exporters can draw equipment instead of an anonymous dot.
void main() {
  // Bounding box of a prim list (SldLine + SldCircle, the only kinds the
  // library emits — a circle counts its full extent cx±r / cy±r).
  ({double minX, double minY, double maxX, double maxY}) boundsOf(
      List<SldPrim> prims) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    void inc(double x, double y) {
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }

    for (final p in prims) {
      switch (p) {
        case final SldLine l:
          inc(l.x1, l.y1);
          inc(l.x2, l.y2);
        case final SldCircle c:
          inc(c.cx - c.r, c.cy - c.r);
          inc(c.cx + c.r, c.cy + c.r);
        case SldRect():
        case SldLabel():
          fail('plan symbols must not emit rect/label prims');
      }
    }
    return (minX: minX, minY: minY, maxX: maxX, maxY: maxY);
  }

  test('every NodeComponent yields a non-empty glyph (exhaustive)', () {
    for (final c in NodeComponent.values) {
      final prims = planComponentPrims(c, cx: 0, cy: 0);
      expect(prims, isNotEmpty, reason: '$c produced no glyph');
      // Only the two neutral kinds are used.
      expect(
        prims.every((p) => p is SldLine || p is SldCircle),
        isTrue,
        reason: '$c emitted a non line/circle prim',
      );
    }
  });

  test('glyphs are roughly centred on (cx, cy) within tolerance', () {
    // The authored fractions live in ~[0.06 .. 0.94], so a glyph's bounding box
    // straddles the centre. A gross mis-placement (a whole box off) would push
    // the bbox centre past 0.5·size from (cx, cy); the strainer (bottom-heavy
    // Y-body) is the worst real case at ~0.20·size, so 0.4·size is a safe pin.
    const cx = 100.0, cy = 50.0, size = 14.0;
    const tol = size * 0.4;
    for (final c in NodeComponent.values) {
      final b = boundsOf(planComponentPrims(c, cx: cx, cy: cy, size: size));
      final bcx = (b.minX + b.maxX) / 2;
      final bcy = (b.minY + b.maxY) / 2;
      expect((bcx - cx).abs(), lessThan(tol), reason: '$c off-centre in x');
      expect((bcy - cy).abs(), lessThan(tol), reason: '$c off-centre in y');
      // The glyph fits inside (a little padding over) its size box.
      expect(b.maxX - b.minX, lessThanOrEqualTo(size * 1.05));
      expect(b.maxY - b.minY, lessThanOrEqualTo(size * 1.05));
    }
  });

  test('cx/cy translate the whole glyph (pump)', () {
    final atOrigin = boundsOf(planComponentPrims(NodeComponent.pump,
        cx: 0, cy: 0, size: 14));
    final moved = boundsOf(planComponentPrims(NodeComponent.pump,
        cx: 200, cy: -30, size: 14));
    expect(moved.minX, closeTo(atOrigin.minX + 200, 1e-9));
    expect(moved.maxX, closeTo(atOrigin.maxX + 200, 1e-9));
    expect(moved.minY, closeTo(atOrigin.minY - 30, 1e-9));
    expect(moved.maxY, closeTo(atOrigin.maxY - 30, 1e-9));
  });

  test('the pump glyph carries its impeller circle', () {
    // Pump = a body circle (radius 0.30·size) + a 3-line impeller triangle.
    const size = 14.0;
    final prims = planComponentPrims(NodeComponent.pump, cx: 0, cy: 0, size: size);
    final circles = prims.whereType<SldCircle>().toList();
    expect(circles, hasLength(1));
    expect(circles.single.r, closeTo(0.30 * size, 1e-9));
  });

  test('planFixturePrims is a 3-line down-triangle centred on (cx, cy)', () {
    const cx = 5.0, cy = 7.0, size = 10.0;
    final prims = planFixturePrims(cx: cx, cy: cy, size: size);
    expect(prims, hasLength(3));
    expect(prims.every((p) => p is SldLine), isTrue);
    const r = size * 0.4;
    // The apex sits below the centre at (cx, cy + r); two base corners above.
    final ys = prims.whereType<SldLine>().expand((l) => [l.y1, l.y2]).toList();
    expect(ys.reduce((a, b) => a > b ? a : b), closeTo(cy + r, 1e-9)); // apex
    expect(ys.where((y) => (y - (cy - r * 0.7)).abs() < 1e-9), isNotEmpty);
  });

  group('riserUpDown', () {
    test('rising to a higher floor is UP', () {
      expect(riserUpDown(hereFloor: 0, otherFloor: 1), 'UP');
      expect(riserUpDown(hereFloor: 2, otherFloor: 5), 'UP');
    });
    test('dropping to a lower floor is DN', () {
      expect(riserUpDown(hereFloor: 3, otherFloor: 1), 'DN');
    });
    test('same floor has no vertical sense (null)', () {
      expect(riserUpDown(hereFloor: 2, otherFloor: 2), isNull);
    });
    test('the labels are printable ASCII', () {
      for (final s in ['UP', 'DN']) {
        expect(s.codeUnits.every((c) => c >= 0x20 && c <= 0x7e), isTrue);
      }
    });
  });
}
