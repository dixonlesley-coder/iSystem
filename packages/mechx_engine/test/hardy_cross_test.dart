import 'package:mechx_engine/network/hardy_cross.dart';
import 'package:test/test.dart';

void main() {
  // Resistance helper from a {id: k} map.
  double Function(String) res(Map<String, double> k) => (id) => k[id]!;

  group('balanceFlows — analytic splits', () {
    test('two parallel pipes split so k·Q^n is equal on both legs', () {
      // S =a= D and S =b= D. With n=2, kA=1, kB=4: kA·Qa² = kB·Qb² ⇒
      // Qa = 2·Qb, and Qa+Qb = 100 ⇒ Qa = 66.67, Qb = 33.33.
      final r = balanceFlows(
        edges: const [
          (id: 'a', from: 'S', to: 'D'),
          (id: 'b', from: 'S', to: 'D'),
        ],
        root: 'S',
        demand: const {'D': 100.0},
        resistance: res(const {'a': 1.0, 'b': 4.0}),
        exponent: 2.0,
      );
      expect(r.loopCount, 1);
      expect(r.edgeFlow['a']!.abs(), closeTo(66.667, 1e-2));
      expect(r.edgeFlow['b']!.abs(), closeTo(33.333, 1e-2));
      // Continuity: the two legs carry the whole demand.
      expect(r.edgeFlow['a']!.abs() + r.edgeFlow['b']!.abs(),
          closeTo(100, 1e-6));
      // Head loss balanced around the loop.
      final ha = 1.0 * r.edgeFlow['a']! * r.edgeFlow['a']!.abs();
      final hb = 4.0 * r.edgeFlow['b']! * r.edgeFlow['b']!.abs();
      expect(ha, closeTo(hb, 1e-3));
    });

    test('triangle loop: one-pipe path vs two-pipe path', () {
      // X→Z direct (e3) vs X→Y→Z (e1+e2), all k=1, n=2, 60 drawn at Z.
      // 1·Q3² = 1·Q1² + 1·Q1²  ⇒ Q3 = √2·Q1, Q1+Q3 = 60.
      final r = balanceFlows(
        edges: const [
          (id: 'e1', from: 'X', to: 'Y'),
          (id: 'e2', from: 'Y', to: 'Z'),
          (id: 'e3', from: 'X', to: 'Z'),
        ],
        root: 'X',
        demand: const {'Z': 60.0},
        resistance: res(const {'e1': 1.0, 'e2': 1.0, 'e3': 1.0}),
        exponent: 2.0,
      );
      expect(r.loopCount, 1);
      final q1 = r.edgeFlow['e1']!.abs();
      final q2 = r.edgeFlow['e2']!.abs();
      final q3 = r.edgeFlow['e3']!.abs();
      expect(q1, closeTo(24.85, 1e-1));
      expect(q2, closeTo(24.85, 1e-1));
      expect(q3, closeTo(35.15, 1e-1));
      // Continuity at Z: both legs deliver the 60 draw.
      expect(q2 + q3, closeTo(60, 1e-6));
    });

    test('two parallel pipes of equal resistance split 50/50', () {
      final r = balanceFlows(
        edges: const [
          (id: 'a', from: 'S', to: 'D'),
          (id: 'b', from: 'S', to: 'D'),
        ],
        root: 'S',
        demand: const {'D': 80.0},
        resistance: res(const {'a': 2.0, 'b': 2.0}),
        exponent: 1.852,
      );
      expect(r.edgeFlow['a']!.abs(), closeTo(40, 1e-3));
      expect(r.edgeFlow['b']!.abs(), closeTo(40, 1e-3));
    });
  });

  group('balanceFlows — trees (degenerate, no loops)', () {
    test('a branching tree returns the unique continuity flows', () {
      // S → a → {b, c}. Demand 10 at b, 20 at c. Trunk carries 30.
      final r = balanceFlows(
        edges: const [
          (id: 't', from: 'S', to: 'a'),
          (id: 'b1', from: 'a', to: 'b'),
          (id: 'b2', from: 'a', to: 'c'),
        ],
        root: 'S',
        demand: const {'b': 10.0, 'c': 20.0},
        resistance: res(const {'t': 5.0, 'b1': 5.0, 'b2': 5.0}),
      );
      expect(r.loopCount, 0);
      expect(r.iterations, 0);
      expect(r.edgeFlow['t']!.abs(), closeTo(30, 1e-9));
      expect(r.edgeFlow['b1']!.abs(), closeTo(10, 1e-9));
      expect(r.edgeFlow['b2']!.abs(), closeTo(20, 1e-9));
    });
  });

  group('hardyCross — direct', () {
    test('an empty loop list converges immediately', () {
      expect(hardyCross(const []), 0);
    });
  });
}
