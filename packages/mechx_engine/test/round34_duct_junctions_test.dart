/// Round 34 (fire-hvac-drawings-double-line-duct-junctions) — double-line
/// duct take-offs and elbows are trimmed: a branch's walls stop at the trunk
/// wall, the trunk wall breaks across the opening, an elbow closes in a square
/// corner. One geometry ([planDuctOutlines]) for the plan PDF and the DXF.
library;

import 'dart:math';

import 'package:mechx_engine/report/plan_annotation_layout.dart'
    show planDoubleLineOutline;
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:test/test.dart';

PlanDuctRun _r(String id, String f, String t, double ax, double ay, double bx,
        double by, double half) =>
    (id: id, fromId: f, toId: t, ax: ax, ay: ay, bx: bx, by: by, half: half);

/// Total covered length of [segs] along y = [y] between x0..x1 (horizontal
/// segments only).
double _coverX(List<LabelSegment> segs, double y, double x0, double x1) {
  final iv = <(double, double)>[
    for (final s in segs)
      if ((s.y1 - y).abs() < 1e-9 && (s.y2 - y).abs() < 1e-9)
        (max(min(s.x1, s.x2), x0), min(max(s.x1, s.x2), x1)),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  var total = 0.0, reach = x0;
  for (final (a, b) in iv) {
    if (b <= reach) continue;
    total += b - max(a, reach);
    reach = b;
  }
  return total;
}

void main() {
  test('a lone run keeps exactly its two walls (byte-identical)', () {
    final o = planDuctOutlines([_r('a', 'A', 'B', 0, 0, 100, 0, 10)]);
    expect(o['a'], planDoubleLineOutline(0, 0, 100, 0, 10));
  });

  test('a tee: branch walls start at the trunk wall, trunk wall opens', () {
    // Trunk A(0,0)-T(100,0)-B(200,0) half 10; branch T-(100,100) half 5.
    final o = planDuctOutlines([
      _r('t1', 'A', 'T', 0, 0, 100, 0, 10),
      _r('t2', 'T', 'B', 100, 0, 200, 0, 10),
      _r('br', 'T', 'E', 100, 0, 100, 100, 5),
    ]);
    // The branch walls (x = 95, 105) run from the trunk wall y = 10 to 100:
    // nothing of them inside the trunk.
    for (final s in o['br']!) {
      expect(min(s.y1, s.y2), closeTo(10, 1e-9));
      expect(max(s.y1, s.y2), closeTo(100, 1e-9));
    }
    final trunk = [...o['t1']!, ...o['t2']!];
    // The trunk wall facing the branch (y = 10) is open over 95..105 only…
    expect(_coverX(trunk, 10, 95, 105), closeTo(0, 1e-9));
    expect(_coverX(trunk, 10, 0, 95), closeTo(95, 1e-9));
    expect(_coverX(trunk, 10, 105, 200), closeTo(95, 1e-9));
    // …and the far wall (y = -10) stays continuous 0..200.
    expect(_coverX(trunk, -10, 0, 200), closeTo(200, 1e-9));
  });

  test('a 90-degree elbow closes in a square corner, inner walls meet', () {
    // A(0,0)-K(100,0) then K-(100,100), both half 10.
    final o = planDuctOutlines([
      _r('a', 'A', 'K', 0, 0, 100, 0, 10),
      _r('b', 'K', 'C', 100, 0, 100, 100, 10),
    ]);
    final segs = {...o['a']!, ...o['b']!};
    bool has(double x1, double y1, double x2, double y2) => segs.any((s) =>
        ((s.x1 - x1).abs() < 1e-9 &&
            (s.y1 - y1).abs() < 1e-9 &&
            (s.x2 - x2).abs() < 1e-9 &&
            (s.y2 - y2).abs() < 1e-9) ||
        ((s.x1 - x2).abs() < 1e-9 &&
            (s.y1 - y2).abs() < 1e-9 &&
            (s.x2 - x1).abs() < 1e-9 &&
            (s.y2 - y1).abs() < 1e-9));
    // Outer walls: y = -10 to x = 110, x = 110 from y = -10 (square corner).
    expect(has(0, -10, 110, -10), isTrue);
    expect(has(110, -10, 110, 100), isTrue);
    // Inner walls stop at their crossing (90, 10).
    expect(has(0, 10, 90, 10), isTrue);
    expect(has(90, 10, 90, 100), isTrue);
  });

  // Seeded property: no wall piece of a run ever lies strictly inside another
  // duct it meets at a node (the overlap the finding drew), whatever the
  // angles and widths.
  test('property: no wall inside a neighbouring duct (seeded)', () {
    final rnd = Random(34);
    for (var t = 0; t < 200; t++) {
      final n = 2 + rnd.nextInt(3);
      final runs = <PlanDuctRun>[
        for (var i = 0; i < n; i++)
          () {
            final ang = rnd.nextDouble() * 2 * pi;
            final l = 50 + rnd.nextDouble() * 100;
            return _r('r$i', 'J', 'E$i', 0, 0, l * cos(ang), l * sin(ang),
                2 + rnd.nextDouble() * 10);
          }(),
      ];
      final o = planDuctOutlines(runs);
      for (final r in runs) {
        for (final s in o[r.id]!) {
          final mx = (s.x1 + s.x2) / 2, my = (s.y1 + s.y2) / 2;
          for (final q in runs) {
            if (q.id == r.id) continue;
            // Midpoint strictly inside q's UNEXTENDED rectangle would be a
            // visible overlap.
            final dx = q.bx - q.ax, dy = q.by - q.ay;
            final l = sqrt(dx * dx + dy * dy);
            final along = (mx * dx + my * dy) / l;
            final across = (-mx * dy + my * dx) / l;
            final strictly =
                along > 1e-6 && along < l - 1e-6 && across.abs() < q.half - 1e-6;
            expect(strictly, isFalse, reason: 'trial $t ${r.id} in ${q.id}');
          }
        }
      }
    }
  });
}
