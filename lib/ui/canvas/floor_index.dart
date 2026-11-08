import 'package:mechx_engine/network/network.dart';

/// Drafting-feel perf (P9/P10) — the network elements on ONE sheet/floor,
/// resolved once per [Network] instance and reused by every per-pointer-move
/// scan (the draw overlay's snap preview, the selection overlay's hover /
/// tap / marquee hit-tests). Those used to walk EVERY node and edge of the
/// whole building (two `nodeById` lookups per edge) on each mouse move, and
/// throw away all but one floor's worth.
///
/// Keyed on the immutable [Network] instance (like `network_layer.dart`'s
/// `_NetDerived`): every edit commits a new [Network], so a stale index is
/// never served; a pan / hover frame (same network) reuses it.
class FloorIndex {
  /// The nodes on the sheet/floor, in network order.
  final List<NetNode> nodes;

  /// Run edges with BOTH ends on the sheet/floor, with their resolved ends.
  final List<FloorEdge> runs;

  /// Riser edges with AT LEAST ONE end on the sheet/floor (the other end is on
  /// an adjacent floor), with their resolved ends.
  final List<FloorEdge> risers;

  /// [runs] and [risers] together, in network edge order (hit-tests that
  /// break ties by order keep the whole-network scan's result).
  final List<FloorEdge> edges;

  FloorIndex._(this.nodes, this.runs, this.risers, this.edges);
}

/// One edge of a [FloorIndex] with its two resolved end nodes.
class FloorEdge {
  final NetEdge edge;
  final NetNode a;
  final NetNode b;
  const FloorEdge(this.edge, this.a, this.b);
}

final _cache = Expando<Map<(String, int), FloorIndex>>();

/// The (memoised) [FloorIndex] of [net] for [sheetId]/[floorIndex].
FloorIndex floorIndexOf(Network net, String sheetId, int floorIndex) {
  final byFloor = _cache[net] ??= <(String, int), FloorIndex>{};
  return byFloor[(sheetId, floorIndex)] ??= _build(net, sheetId, floorIndex);
}

FloorIndex _build(Network net, String sheetId, int floorIndex) {
  bool on(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;
  final nodes = <NetNode>[
    for (final n in net.nodes)
      if (on(n)) n,
  ];
  final runs = <FloorEdge>[];
  final risers = <FloorEdge>[];
  final all = <FloorEdge>[];
  for (final e in net.edges) {
    final a = net.nodeById(e.fromId);
    final b = net.nodeById(e.toId);
    if (a == null || b == null) continue;
    if (e.kind == EdgeKind.riser) {
      if (on(a) || on(b)) {
        all.add(FloorEdge(e, a, b));
        risers.add(all.last);
      }
    } else if (on(a) && on(b)) {
      all.add(FloorEdge(e, a, b));
      runs.add(all.last);
    }
  }
  return FloorIndex._(List.unmodifiable(nodes), List.unmodifiable(runs),
      List.unmodifiable(risers), List.unmodifiable(all));
}
