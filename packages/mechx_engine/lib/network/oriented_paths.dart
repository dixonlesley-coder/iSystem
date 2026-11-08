/// Orientation-aware path-cost accumulation shared by the pressurized solves
/// (`pressure_solve.dart`) and the fan index-run static (`duct_static.dart`).
///
/// mech-props-3 — the solves used to do a first-visit BFS from the source and
/// add each edge's |loss| along whichever path reached a node FIRST. On a tree
/// that is the unique path, but on a ring the two paths to a node are not
/// head-consistent (the Hardy–Cross split balances on a uniform-diameter
/// length basis, friction is evaluated at the per-edge sized diameters), and
/// the BFS path can even run an edge AGAINST its balanced flow and still ADD
/// its loss. The required pump head therefore changed with edge order.
///
/// Here every edge the sizing oriented ([flowFromOf], the `EdgeSizing`
/// `flowFromId` — the balanced flow sign on a ring) is walked IN its flow
/// direction, and a node's cost is the MAX over all of its upstream paths, in
/// topological order (the governing — index — path, the standard design
/// basis). Edges with no orientation, or that lie outside the region the flow
/// carries away from [sourceId] (e.g. the transfer leg below a roof tank the
/// downfeed solve starts from), fall back to the BFS orientation from the
/// source. On a tree rooted at the source this is identical to the old BFS.
/// Pure Dart, zero Flutter imports.
library;

import 'dart:collection';

import 'network.dart';

/// Cost (friction head / static Pa — any additive loss) at every node reachable
/// from [sourceId] over [adjacency]. [edgeCost] returns the loss of an edge
/// arriving at the given node (so an arriving-node minor loss can be added).
Map<String, double> orientedPathCost({
  required String sourceId,
  required Map<String, List<({NetEdge edge, String other})>> adjacency,
  required String? Function(NetEdge edge) flowFromOf,
  required double Function(NetEdge edge, String arriving) edgeCost,
}) {
  // 1. Undirected BFS — reachability, BFS order, and the legacy cost (the
  //    fallback for any node a cycle leaves unresolved).
  final order = <String, int>{sourceId: 0};
  final bfsCost = <String, double>{sourceId: 0.0};
  final queue = <String>[sourceId];
  for (var i = 0; i < queue.length; i++) {
    final n = queue[i];
    for (final link
        in adjacency[n] ?? const <({NetEdge edge, String other})>[]) {
      if (order.containsKey(link.other)) continue;
      order[link.other] = queue.length;
      bfsCost[link.other] = bfsCost[n]! + edgeCost(link.edge, link.other);
      queue.add(link.other);
    }
  }

  // Edge orientation from the sizing (only when it names an endpoint).
  String? oriented(NetEdge e) {
    final f = flowFromOf(e);
    return (f == e.fromId || f == e.toId) ? f : null;
  }

  // 2. The region the flow carries AWAY from the source: nodes reachable
  //    following oriented edges only.
  final downstream = <String>{sourceId};
  final stack = [sourceId];
  while (stack.isNotEmpty) {
    final n = stack.removeLast();
    for (final link
        in adjacency[n] ?? const <({NetEdge edge, String other})>[]) {
      if (oriented(link.edge) == n && downstream.add(link.other)) {
        stack.add(link.other);
      }
    }
  }

  // 3. One direction per reachable edge.
  final outEdges = <String, List<({NetEdge edge, String to})>>{};
  final indegree = <String, int>{for (final n in queue) n: 0};
  final seenEdges = <String>{};
  for (final n in queue) {
    for (final link
        in adjacency[n] ?? const <({NetEdge edge, String other})>[]) {
      final e = link.edge;
      if (!seenEdges.add(e.id)) continue;
      final a = e.fromId, b = e.toId;
      if (!order.containsKey(a) || !order.containsKey(b) || a == b) continue;
      String from;
      final f = oriented(e);
      if (f != null && downstream.contains(a) && downstream.contains(b)) {
        from = f;
      } else {
        from = order[a]! <= order[b]! ? a : b;
      }
      final to = from == a ? b : a;
      if (to == sourceId) continue; // nothing flows back into the source
      (outEdges[from] ??= []).add((edge: e, to: to));
      indegree[to] = indegree[to]! + 1;
    }
  }

  // 4. Longest (governing) path in topological order (Kahn).
  final cost = <String, double>{};
  final best = <String, double>{};
  final ready = Queue<String>();
  for (final n in queue) {
    if (indegree[n] == 0) {
      cost[n] = n == sourceId ? 0.0 : bfsCost[n]!;
      ready.add(n);
    }
  }
  while (ready.isNotEmpty) {
    final u = ready.removeFirst();
    for (final o in outEdges[u] ?? const <({NetEdge edge, String to})>[]) {
      final cand = cost[u]! + edgeCost(o.edge, o.to);
      final prev = best[o.to];
      if (prev == null || cand > prev) best[o.to] = cand;
      final d = indegree[o.to]! - 1;
      indegree[o.to] = d;
      if (d == 0) {
        cost[o.to] = best[o.to]!;
        ready.add(o.to);
      }
    }
  }
  // A (pathological) mixed-orientation cycle leaves nodes unresolved — keep
  // the legacy BFS figure for those rather than dropping them.
  // Returned in BFS order (stable critical-node tie-breaking for callers).
  return {for (final n in queue) n: cost[n] ?? bfsCost[n]!};
}
