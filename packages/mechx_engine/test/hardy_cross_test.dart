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

  group('balanceFlows — scale-aware convergence (relative tolerance)', () {
    // An n×n grid rooted at a corner, 0.2 m3/s drawn at every other node,
    // deterministic pseudo-random lengths 1-30 m (resistance = length), n = 2
    // (air). Loops = edges − nodes + 1 = 2n(n−1) − n² + 1 = (n−1)².
    ({List<({String id, String from, String to})> edges,
      Map<String, double> demand, Map<String, double> k}) grid(int n) {
      var seed = 12345;
      double next() {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed / 0x7fffffff;
      }

      final edges = <({String id, String from, String to})>[];
      final k = <String, double>{};
      final demand = <String, double>{};
      String node(int r, int c) => 'n${r}_$c';
      for (var r = 0; r < n; r++) {
        for (var c = 0; c < n; c++) {
          if (r != 0 || c != 0) demand[node(r, c)] = 0.2;
          if (c + 1 < n) {
            final id = 'h${r}_$c';
            edges.add((id: id, from: node(r, c), to: node(r, c + 1)));
            k[id] = 1 + 29 * next();
          }
          if (r + 1 < n) {
            final id = 'v${r}_$c';
            edges.add((id: id, from: node(r, c), to: node(r + 1, c)));
            k[id] = 1 + 29 * next();
          }
        }
      }
      return (edges: edges, demand: demand, k: k);
    }

    test('a 7x7 mixed-length grid converges with the DEFAULTS', () {
      final g = grid(7);
      final r = balanceFlows(
        edges: g.edges,
        root: 'n0_0',
        demand: g.demand,
        resistance: res(g.k),
        exponent: 2.0,
      );
      expect(r.loopCount, 36); // (7−1)²
      expect(r.converged, isTrue);
      // Default budget scales with the loop count: max(500, 50·36) = 1800.
      expect(r.iterations, lessThanOrEqualTo(1800));

      // The settled split agrees with a run pushed far tighter (relative
      // 1e-14, huge budget) to well within anything a size ladder resolves:
      // total throughput = 48 × 0.2 = 9.6 m3/s, so 1e-6 relative ≈ 1e-5 m3/s.
      final tight = balanceFlows(
        edges: g.edges,
        root: 'n0_0',
        demand: g.demand,
        resistance: res(g.k),
        exponent: 2.0,
        tolerance: 1e-14,
        maxIterations: 100000,
      );
      for (final e in g.edges) {
        expect(r.edgeFlow[e.id]!, closeTo(tight.edgeFlow[e.id]!, 9.6e-6));
      }
      // Continuity at the root: the two legs out of n0_0 carry all 9.6 m3/s.
      expect(r.edgeFlow['h0_0']! + r.edgeFlow['v0_0']!, closeTo(9.6, 1e-9));
    });

    test('a tree still reports iterations 0 / converged true', () {
      final r = balanceFlows(
        edges: const [
          (id: 't', from: 'S', to: 'a'),
          (id: 'b', from: 'a', to: 'b'),
        ],
        root: 'S',
        demand: const {'b': 1.0},
        resistance: (_) => 1.0,
      );
      expect(r.iterations, 0);
      expect(r.converged, isTrue);
    });

    test('an all-zero-demand loop terminates (absolute floor)', () {
      final r = balanceFlows(
        edges: const [
          (id: 'a', from: 'S', to: 'D'),
          (id: 'b', from: 'S', to: 'D'),
        ],
        root: 'S',
        demand: const {},
        resistance: (_) => 1.0,
      );
      expect(r.converged, isTrue);
      expect(r.iterations, 1);
    });
  });
}
