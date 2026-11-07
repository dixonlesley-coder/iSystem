/// Biconnected-component (BLOCK) decomposition of an undirected multigraph —
/// pure graph structure, no hydraulics.
///
/// Round 66 (regression-yard-ring-arms-merge-cycles-at-articulation-node):
/// grouping cycle edges by SHARED NODES merges two cycles that touch at one
/// node (an articulation point) into one "ring". A cycle group is a block:
/// two edges lie in the same block iff some simple cycle contains both.
library;

import 'dart:math' as math;

/// The blocks of the graph formed by [edges] (each `(id, a, b)`), each a list
/// of edge ids. A block of ONE edge is a bridge (it lies on no cycle) and is
/// dropped; self-loops are ignored. Deterministic: roots and neighbours are
/// visited in sorted key / input order.
List<List<String>> cycleBlocks(List<(String, String, String)> edges) {
  final adj = <String, List<(String, String)>>{};
  for (final (id, a, b) in edges) {
    if (a == b) continue;
    (adj[a] ??= []).add((id, b));
    (adj[b] ??= []).add((id, a));
  }
  final disc = <String, int>{};
  final low = <String, int>{};
  final blocks = <List<String>>[];
  final edgeStack = <String>[];
  var time = 0;
  for (final root in adj.keys.toList()..sort()) {
    if (disc.containsKey(root)) continue;
    // Frame: (node, parent edge id, next neighbour index).
    final stack = <(String, String?, int)>[(root, null, 0)];
    disc[root] = time;
    low[root] = time;
    time++;
    while (stack.isNotEmpty) {
      final (v, pe, i) = stack.removeLast();
      final links = adj[v]!;
      if (i < links.length) {
        stack.add((v, pe, i + 1));
        final (e, w) = links[i];
        if (e == pe) continue;
        if (!disc.containsKey(w)) {
          edgeStack.add(e);
          disc[w] = time;
          low[w] = time;
          time++;
          stack.add((w, e, 0));
        } else if (disc[w]! < disc[v]!) {
          // A back edge to an ancestor (its reverse, seen from the ancestor,
          // has disc[w] > disc[v] and is skipped).
          edgeStack.add(e);
          low[v] = math.min(low[v]!, disc[w]!);
        }
      } else if (pe != null && stack.isNotEmpty) {
        // Finished v: propagate to its parent (the frame now on top).
        final u = stack.last.$1;
        low[u] = math.min(low[u]!, low[v]!);
        if (low[v]! >= disc[u]!) {
          // u separates v's subtree: pop one block, down to the tree edge.
          final block = <String>[];
          while (edgeStack.isNotEmpty) {
            final x = edgeStack.removeLast();
            block.add(x);
            if (x == pe) break;
          }
          if (block.length >= 2) blocks.add(block);
        }
      }
    }
  }
  return blocks;
}
