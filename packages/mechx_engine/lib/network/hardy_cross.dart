/// Hardy–Cross loop-flow balancing for LOOPED pipe/duct networks (rings, grids).
///
/// The tree solvers (`accumulateFlows`, `solvePressurized`) assume each node has
/// a single path from the source. A loop has parallel paths, and the flow split
/// between them is whatever makes the head loss around the loop sum to zero.
/// Hardy–Cross finds that split iteratively:
///
///   • seed any continuity-preserving flow (here: route all demand through a
///     spanning tree, chord flows = 0);
///   • for each fundamental loop, correct every pipe by
///       ΔQ = −Σ(±h_f) / Σ(n·k·|Q|^(n−1)),
///     where h_f = sign(Q)·k·|Q|^n is the (signed) head loss; the correction is
///     divergence-free, so continuity is preserved at every step;
///   • iterate until the largest |ΔQ| falls below the tolerance.
///
/// This module is topology/units-agnostic: callers supply a resistance `k` and
/// an exponent `n` per pipe (n ≈ 1.852 Hazen–Williams, 2.0 Darcy). Pure Dart,
/// ZERO Flutter imports.
library;

import 'dart:math' as math;

/// One pipe in a balance: a signed flow [q] from [fromNode] to [toNode], with a
/// head-loss model h_f = sign(q)·[k]·|q|^[exponent]. [q] is mutated in place by
/// the solve.
class HcPipe {
  final String id;
  final String fromNode;
  final String toNode;
  final double k;
  final double exponent;
  double q;

  HcPipe({
    required this.id,
    required this.fromNode,
    required this.toNode,
    required this.k,
    this.exponent = 1.852,
    this.q = 0,
  });

  /// Signed head loss h_f = sign(q)·k·|q|^n.
  double get headLoss {
    final m = q.abs();
    final h = k * math.pow(m, exponent).toDouble();
    return q < 0 ? -h : h;
  }

  /// dh_f/dQ magnitude = n·k·|q|^(n−1) — the Hardy–Cross denominator term.
  double get gradient =>
      exponent * k * math.pow(q.abs(), exponent - 1).toDouble();
}

/// One traversal step of a loop: a [pipe] taken in [dir] (+1 along from→to,
/// −1 against).
typedef HcStep = ({HcPipe pipe, int dir});

/// A fundamental loop: an ordered, closed list of steps.
typedef HcLoop = List<HcStep>;

/// Outcome of a [hardyCrossDetailed] balance: the iterations used and whether
/// the largest loop correction actually fell below the tolerance.
///
/// M17 — the iteration COUNT alone cannot answer "did it converge?": a balance
/// that converges on its very last permitted sweep returns exactly
/// `maxIterations`, indistinguishable from one that gave up. The two facts are
/// reported separately so a caller can be honest about a best-effort split
/// instead of guessing from `iterations < maxIterations`.
///
/// The convergence tolerance is RELATIVE to the loop flow scale — the largest
/// |Q| over all loop pipes after the sweep — not an absolute m3/s figure: a
/// balance has settled when `max|ΔQ| <= tolerance × max|Q|` (floored at
/// [kHardyCrossAbsoluteFloor] so an all-zero loop still terminates). A fixed
/// absolute 1e-12 m3/s on ~1 m3/s air flows asked for double-precision noise,
/// so linearly-converging grids were reported unsettled (and every edge
/// flagged provisional) even though the split was balanced to ~1e-10.
typedef HcOutcome = ({int iterations, bool converged});

/// Default RELATIVE convergence tolerance (see [HcOutcome]): the largest loop
/// correction must fall to this fraction of the loop flow scale. 1e-9 is far
/// below anything the standard-size ladder can resolve (sizes snap to discrete
/// diameters), yet comfortably above double-precision round-off.
const double kHardyCrossRelativeTolerance = 1e-9;

/// Absolute floor (m3/s) under the relative test, so a loop whose flows are all
/// ~0 still terminates.
const double kHardyCrossAbsoluteFloor = 1e-15;

/// Balance the [loops] in place (correcting their shared [HcPipe.q]s) until the
/// largest loop correction is below [tolerance] × the loop flow scale. Returns the iterations used
/// (== [maxIterations] if it did not converge — caller may treat that as a
/// best-effort result).
///
/// Thin wrapper over [hardyCrossDetailed], kept for callers that only want the
/// count; prefer [hardyCrossDetailed] when the convergence verdict matters.
int hardyCross(
  List<HcLoop> loops, {
  double tolerance = kHardyCrossRelativeTolerance,
  int maxIterations = 500,
}) =>
    hardyCrossDetailed(
      loops,
      tolerance: tolerance,
      maxIterations: maxIterations,
    ).iterations;

/// [hardyCross] with an explicit convergence verdict (see [HcOutcome]).
/// An empty [loops] list is a TREE — nothing to balance, so it converges
/// trivially in 0 iterations.
HcOutcome hardyCrossDetailed(
  List<HcLoop> loops, {
  double tolerance = kHardyCrossRelativeTolerance,
  int maxIterations = 500,
}) {
  if (loops.isEmpty) return (iterations: 0, converged: true);
  for (var iter = 1; iter <= maxIterations; iter++) {
    var maxCorrection = 0.0;
    for (final loop in loops) {
      var numerator = 0.0;
      var denominator = 0.0;
      for (final step in loop) {
        numerator += step.dir * step.pipe.headLoss;
        denominator += step.pipe.gradient;
      }
      if (denominator <= 0) continue; // dead loop (all flows ≈ 0)
      final dq = -numerator / denominator;
      for (final step in loop) {
        step.pipe.q += step.dir * dq;
      }
      maxCorrection = math.max(maxCorrection, dq.abs());
    }
    // Relative, scale-aware stopping test (see [HcOutcome]).
    var maxAbsQ = 0.0;
    for (final loop in loops) {
      for (final step in loop) {
        maxAbsQ = math.max(maxAbsQ, step.pipe.q.abs());
      }
    }
    final threshold = math.max(tolerance * maxAbsQ, kHardyCrossAbsoluteFloor);
    if (maxCorrection <= threshold) {
      return (iterations: iter, converged: true);
    }
  }
  return (iterations: maxIterations, converged: false);
}

/// Largest loop count [balanceFlows] solves with the simultaneous Newton loop
/// method ([newtonLoopBalance], a dense L×L solve per iteration); larger grids
/// fall back to the Gauss–Seidel [hardyCrossDetailed] sweep.
const int kNewtonMaxLoops = 400;

/// Balance [loops] in place with the SIMULTANEOUS (Newton) loop method:
/// each iteration solves J·Δ = −F for all loop corrections at once, where
///   F_L  = Σ_{e∈L} s_e·h_f(e)                 (loop head residual)
///   J_LM = Σ_{e∈L∩M} s_e^L·s_e^M·n·k·|Q_e|^(n−1)
/// and applies Q_e += Σ_L s_e^L·Δ_L (divergence-free ⇒ continuity is kept).
/// The step is halved (up to 20×) while it would increase Σ F², so a poor seed
/// cannot overshoot into divergence. Same convergence test and [HcOutcome]
/// verdict as [hardyCrossDetailed]: max|Δ| ≤ tolerance × max|Q| (floored).
HcOutcome newtonLoopBalance(
  List<HcLoop> loops, {
  double tolerance = kHardyCrossRelativeTolerance,
  int maxIterations = 500,
}) {
  if (loops.isEmpty) return (iterations: 0, converged: true);
  final nL = loops.length;
  // Per pipe: the loops it belongs to with the traversal sign.
  final membership = <HcPipe, List<({int loop, int dir})>>{};
  for (var l = 0; l < nL; l++) {
    for (final step in loops[l]) {
      (membership[step.pipe] ??= []).add((loop: l, dir: step.dir));
    }
  }
  final pipes = membership.keys.toList();

  List<double> residual() {
    final f = List<double>.filled(nL, 0);
    for (var l = 0; l < nL; l++) {
      var sum = 0.0;
      for (final step in loops[l]) {
        sum += step.dir * step.pipe.headLoss;
      }
      f[l] = sum;
    }
    return f;
  }

  double norm2(List<double> v) {
    var s = 0.0;
    for (final x in v) {
      s += x * x;
    }
    return s;
  }

  for (var iter = 1; iter <= maxIterations; iter++) {
    var maxAbsQ = 0.0;
    for (final p in pipes) {
      maxAbsQ = math.max(maxAbsQ, p.q.abs());
    }
    // Gradient floor so a zero-flow shared pipe cannot make J singular.
    final qFloor = math.max(1e-6 * maxAbsQ, 1e-12);
    final f = residual();
    final j = List.generate(nL, (_) => List<double>.filled(nL, 0));
    for (final p in pipes) {
      final m = math.max(p.q.abs(), qFloor);
      final g = p.exponent * p.k * math.pow(m, p.exponent - 1).toDouble();
      final mem = membership[p]!;
      for (final a in mem) {
        for (final b in mem) {
          j[a.loop][b.loop] += a.dir * b.dir * g;
        }
      }
    }
    final delta = _solveDense(j, [for (final x in f) -x]);
    var maxCorrection = 0.0;
    if (delta != null) {
      final before = norm2(f);
      final q0 = [for (final p in pipes) p.q];
      var scale = 1.0;
      for (var halving = 0; halving <= 20; halving++) {
        for (var i = 0; i < pipes.length; i++) {
          var dq = 0.0;
          for (final a in membership[pipes[i]]!) {
            dq += a.dir * delta[a.loop];
          }
          pipes[i].q = q0[i] + scale * dq;
        }
        if (before == 0 || norm2(residual()) <= before) break;
        scale /= 2;
      }
      for (final d in delta) {
        maxCorrection = math.max(maxCorrection, (scale * d).abs());
      }
    }
    maxAbsQ = 0.0;
    for (final p in pipes) {
      maxAbsQ = math.max(maxAbsQ, p.q.abs());
    }
    final threshold = math.max(tolerance * maxAbsQ, kHardyCrossAbsoluteFloor);
    if (maxCorrection <= threshold) {
      return (iterations: iter, converged: true);
    }
  }
  return (iterations: maxIterations, converged: false);
}

/// Gaussian elimination with partial pivoting; null when singular.
List<double>? _solveDense(List<List<double>> a, List<double> b) {
  final n = b.length;
  for (var c = 0; c < n; c++) {
    var piv = c;
    for (var r = c + 1; r < n; r++) {
      if (a[r][c].abs() > a[piv][c].abs()) piv = r;
    }
    if (a[piv][c].abs() < 1e-300) return null;
    if (piv != c) {
      final t = a[c];
      a[c] = a[piv];
      a[piv] = t;
      final tb = b[c];
      b[c] = b[piv];
      b[piv] = tb;
    }
    for (var r = c + 1; r < n; r++) {
      final f = a[r][c] / a[c][c];
      if (f == 0) continue;
      for (var k = c; k < n; k++) {
        a[r][k] -= f * a[c][k];
      }
      b[r] -= f * b[c];
    }
  }
  final x = List<double>.filled(n, 0);
  for (var r = n - 1; r >= 0; r--) {
    var s = b[r];
    for (var k = r + 1; k < n; k++) {
      s -= a[r][k] * x[k];
    }
    x[r] = s / a[r][r];
  }
  return x;
}

/// Result of [balanceFlows]: the signed flow per edge id (positive = from→to)
/// and how many independent loops the component had.
class LoopBalanceResult {
  /// Edge id → signed flow (from→to). For a tree these are the unique
  /// continuity flows; for a looped graph they are the Hardy–Cross split.
  final Map<String, double> edgeFlow;

  /// Number of independent (fundamental) loops = edges − nodes + 1.
  final int loopCount;

  /// Iterations the balance took (0 for a tree).
  final int iterations;

  /// M17 — whether the Hardy–Cross sweeps actually settled (largest loop
  /// correction below the tolerance) rather than exhausting `maxIterations`.
  /// A TREE has no loops to balance and converges trivially, so this defaults
  /// to `true` — every pre-existing construction site keeps its old meaning and
  /// the flag can only ever be `false` for a genuinely unsettled ring/grid.
  /// [edgeFlow] is still returned in that case (it preserves continuity at
  /// every step, so it is a usable best-effort split) — but the caller must
  /// SURFACE the fact rather than present the split as balanced.
  final bool converged;

  const LoopBalanceResult({
    required this.edgeFlow,
    required this.loopCount,
    required this.iterations,
    this.converged = true,
  });
}

typedef _Edge = ({String id, String from, String to});

/// Compute per-edge flows for one connected component, balancing any loops.
///
/// [edges] is the component's edge list; [root] is the source/sink (it supplies
/// the net of all sink [demand]s — pass demand only for the sink nodes, the root
/// is implicit). [resistance] returns each edge's `k`; [exponent] its `n`.
///
/// Builds a spanning tree (so chord edges define the fundamental loops), seeds
/// continuity flows by routing demand through the tree, then runs [hardyCross].
/// For a tree the result is exact in one pass (loopCount 0).
///
/// [tolerance] is RELATIVE to the loop flow scale (see [HcOutcome]).
/// [maxIterations] defaults to `max(500, 50 × loopCount)`: Hardy–Cross
/// converges linearly and a larger grid needs proportionately more sweeps, so a
/// fixed cap would mis-report big grids as unsettled. An explicit value is
/// honoured as given.
LoopBalanceResult balanceFlows({
  required List<_Edge> edges,
  required String root,
  required Map<String, double> demand,
  required double Function(String edgeId) resistance,
  double exponent = 1.852,
  double tolerance = kHardyCrossRelativeTolerance,
  int? maxIterations,
}) {
  final edgeById = {for (final e in edges) e.id: e};

  // ── Spanning tree: MINIMUM-RESISTANCE (Kruskal on (k, id)) ────────────────
  // The fundamental-loop basis is the chord set of the spanning tree. A BFS
  // tree in adjacency (= drawing) order made the basis — and with it the
  // convergence speed and the converged/unconverged VERDICT — depend on the
  // order the edges were drawn (mech-props-4). The minimum-resistance tree is
  // a property of the network alone: sort by (k, edge id), union-find, then
  // walk the chosen tree from the root. Long, high-resistance pipes become
  // chords, so each loop owns its long leg and loops couple only through the
  // short shared pipes.
  final sortedEdges = [...edges]..sort((a, b) {
      final c = resistance(a.id).compareTo(resistance(b.id));
      return c != 0 ? c : a.id.compareTo(b.id);
    });
  final uf = <String, String>{};
  String find(String x) {
    var r = uf[x] ?? x;
    while (r != (uf[r] ?? r)) {
      r = uf[r] ?? r;
    }
    uf[x] = r;
    return r;
  }

  final treeAdjacency = <String, List<({String edgeId, String other})>>{};
  final treeEdgeIds = <String>{};
  for (final e in sortedEdges) {
    final a = find(e.from), b = find(e.to);
    if (a == b) continue;
    uf[a] = b;
    treeEdgeIds.add(e.id);
    (treeAdjacency[e.from] ??= []).add((edgeId: e.id, other: e.to));
    (treeAdjacency[e.to] ??= []).add((edgeId: e.id, other: e.from));
  }
  final parentNode = <String, String>{};
  final parentEdge = <String, String>{};
  final depth = <String, int>{root: 0};
  final visited = <String>{root};
  final order = <String>[root];
  for (var i = 0; i < order.length; i++) {
    final n = order[i];
    for (final link
        in treeAdjacency[n] ?? const <({String edgeId, String other})>[]) {
      if (visited.add(link.other)) {
        parentNode[link.other] = n;
        parentEdge[link.other] = link.edgeId;
        depth[link.other] = depth[n]! + 1;
        order.add(link.other);
      }
    }
  }
  // Tree edges outside the root's component (a disconnected edge list) are
  // not part of this balance.
  treeEdgeIds.retainAll(parentEdge.values);

  // ── Chords = reachable edges not in the tree (each defines one loop) ────────
  final chords = <_Edge>[];
  for (final e in edges) {
    if (treeEdgeIds.contains(e.id)) continue;
    if (!visited.contains(e.from) || !visited.contains(e.to)) continue;
    chords.add(e);
  }

  // ── Seed continuity flows: each tree edge carries its child-subtree demand ──
  final subtree = <String, double>{
    for (final n in visited) n: demand[n] ?? 0.0
  };
  for (var i = order.length - 1; i >= 1; i--) {
    final n = order[i];
    final p = parentNode[n]!;
    subtree[p] = subtree[p]! + subtree[n]!;
  }

  final pipes = <String, HcPipe>{
    for (final e in edges)
      e.id: HcPipe(
        id: e.id,
        fromNode: e.from,
        toNode: e.to,
        k: resistance(e.id),
        exponent: exponent,
      ),
  };
  parentEdge.forEach((child, edgeId) {
    final e = edgeById[edgeId]!;
    final p = parentNode[child]!;
    final mag = subtree[child]!; // flow magnitude, p → child
    pipes[edgeId]!.q = (e.from == p && e.to == child) ? mag : -mag;
  });

  // ── Fundamental loops: chord + the tree path between its endpoints ──────────
  final loops = <HcLoop>[];
  for (final chord in chords) {
    final path = _treePath(chord.from, chord.to, parentNode, depth);
    final loop = <HcStep>[
      (pipe: pipes[chord.id]!, dir: 1)
    ]; // from→to along chord
    for (var i = path.length - 1; i > 0; i--) {
      final x = path[i];
      final y = path[i - 1];
      final teId = parentNode[x] == y ? parentEdge[x]! : parentEdge[y]!;
      final te = edgeById[teId]!;
      loop.add(
          (pipe: pipes[teId]!, dir: (te.from == x && te.to == y) ? 1 : -1));
    }
    loops.add(loop);
  }

  final cap = maxIterations ?? math.max(500, 50 * loops.length);
  // Simultaneous (Newton) loop correction for any practical loop count: the
  // Gauss–Seidel sweep of [hardyCrossDetailed] converges linearly and, on a
  // ladder/grid whose loops share long legs, can exhaust its budget in one
  // basis and settle in a handful of sweeps in another (mech-props-4). Newton
  // on the full loop system converges quadratically and its fixed point is the
  // same head-balanced split. Very large grids keep the O(L)-per-sweep path.
  final outcome = loops.length <= kNewtonMaxLoops
      ? newtonLoopBalance(loops, tolerance: tolerance, maxIterations: cap)
      : hardyCrossDetailed(loops, tolerance: tolerance, maxIterations: cap);
  return LoopBalanceResult(
    edgeFlow: {for (final e in edges) e.id: pipes[e.id]!.q},
    loopCount: loops.length,
    iterations: outcome.iterations,
    converged: outcome.converged,
  );
}

/// Unique tree path of nodes from [a] to [b] (inclusive), via their lowest
/// common ancestor.
List<String> _treePath(
  String a,
  String b,
  Map<String, String> parentNode,
  Map<String, int> depth,
) {
  final up = <String>[]; // a … (just below LCA)
  final down = <String>[]; // b … (just below LCA)
  var x = a, y = b;
  while (depth[x]! > depth[y]!) {
    up.add(x);
    x = parentNode[x]!;
  }
  while (depth[y]! > depth[x]!) {
    down.add(y);
    y = parentNode[y]!;
  }
  while (x != y) {
    up.add(x);
    down.add(y);
    x = parentNode[x]!;
    y = parentNode[y]!;
  }
  return [...up, x, ...down.reversed]; // a … LCA … b
}
