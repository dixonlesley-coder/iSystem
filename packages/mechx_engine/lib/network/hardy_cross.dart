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
typedef HcOutcome = ({int iterations, bool converged});

/// Balance the [loops] in place (correcting their shared [HcPipe.q]s) until the
/// largest loop correction is below [tolerance]. Returns the iterations used
/// (== [maxIterations] if it did not converge — caller may treat that as a
/// best-effort result).
///
/// Thin wrapper over [hardyCrossDetailed], kept for callers that only want the
/// count; prefer [hardyCrossDetailed] when the convergence verdict matters.
int hardyCross(
  List<HcLoop> loops, {
  double tolerance = 1e-12,
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
  double tolerance = 1e-12,
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
    if (maxCorrection < tolerance) return (iterations: iter, converged: true);
  }
  return (iterations: maxIterations, converged: false);
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
LoopBalanceResult balanceFlows({
  required List<_Edge> edges,
  required String root,
  required Map<String, double> demand,
  required double Function(String edgeId) resistance,
  double exponent = 1.852,
  double tolerance = 1e-12,
  int maxIterations = 500,
}) {
  final adjacency = <String, List<({String edgeId, String other})>>{};
  for (final e in edges) {
    (adjacency[e.from] ??= []).add((edgeId: e.id, other: e.to));
    (adjacency[e.to] ??= []).add((edgeId: e.id, other: e.from));
  }
  final edgeById = {for (final e in edges) e.id: e};

  // ── Spanning tree via BFS from the root ────────────────────────────────────
  final parentNode = <String, String>{};
  final parentEdge = <String, String>{};
  final depth = <String, int>{root: 0};
  final visited = <String>{root};
  final treeEdgeIds = <String>{};
  final order = <String>[root];
  for (var i = 0; i < order.length; i++) {
    final n = order[i];
    for (final link in adjacency[n] ?? const <({String edgeId, String other})>[]) {
      if (visited.add(link.other)) {
        parentNode[link.other] = n;
        parentEdge[link.other] = link.edgeId;
        depth[link.other] = depth[n]! + 1;
        treeEdgeIds.add(link.edgeId);
        order.add(link.other);
      }
    }
  }

  // ── Chords = reachable edges not in the tree (each defines one loop) ────────
  final chords = <_Edge>[];
  for (final e in edges) {
    if (treeEdgeIds.contains(e.id)) continue;
    if (!visited.contains(e.from) || !visited.contains(e.to)) continue;
    chords.add(e);
  }

  // ── Seed continuity flows: each tree edge carries its child-subtree demand ──
  final subtree = <String, double>{for (final n in visited) n: demand[n] ?? 0.0};
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
    final loop = <HcStep>[(pipe: pipes[chord.id]!, dir: 1)]; // from→to along chord
    for (var i = path.length - 1; i > 0; i--) {
      final x = path[i];
      final y = path[i - 1];
      final teId =
          parentNode[x] == y ? parentEdge[x]! : parentEdge[y]!;
      final te = edgeById[teId]!;
      loop.add((pipe: pipes[teId]!, dir: (te.from == x && te.to == y) ? 1 : -1));
    }
    loops.add(loop);
  }

  final outcome = hardyCrossDetailed(
    loops,
    tolerance: tolerance,
    maxIterations: maxIterations,
  );
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
