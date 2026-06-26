/// Pipe cut-plan optimiser — an "efficiency engine" for where couplings fall so
/// stock pipe wastage is minimised.
///
/// Real pipe ships in fixed STOCK lengths (PVC / PPR ≈ 4 m, steel ≈ 6 m), joined
/// by couplings. Two things drive waste:
///   1. **Coupling placement.** A long straight run is a chain of drawn segments;
///      if each segment started a fresh stock length you'd waste an offcut per
///      segment. Instead we merge maximal **collinear** same-(service,diameter)
///      run segments into ONE continuous pipe and place couplings only at stock
///      boundaries along it — so only the chain's tail is a cut piece.
///   2. **Offcut reuse.** The tail offcut of one chain can supply a short piece
///      elsewhere. A first-fit-decreasing cutting-stock pack of the remainder
///      pieces into stock bars reuses offcuts, minimising bars purchased.
///
/// Pure Dart, zero Flutter imports.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/duct_products.dart';

/// Stock (per-pipe) length in metres for a service's pipe material: the fire
/// services (sprinkler / hydrant) are steel and ship in 6 m lengths; PVC / PPR
/// (and the other pressurised / gravity pipes) in 4 m. Air ducts are not pipes.
double stockLengthMForService(ServiceType s) =>
    (s == ServiceType.fireSprinkler || s == ServiceType.fireHydrant) ? 6.0 : 4.0;

/// Standard fabrication SECTION length (m) for a duct [product] — the spacing of
/// its flanged joints: BJLS galvanised-steel sheet duct is sectioned ≈ 1.2 m
/// (the sheet-metal joint spacing), PU pre-insulated panel duct ≈ 4 m (the
/// panel length). A null product ⇒ BJLS (the galvanised-steel default).
///
// VERIFY: 1.2 m (BJLS) / 4.0 m (PU) are representative Indonesian HVAC
// fabrication section lengths, not an SNI/SMACNA verbatim clause.
double ductSectionLengthM(DuctProduct? product) =>
    product == DuctProduct.pu ? 4.0 : 1.2;

/// Stock / fabrication section length (m) for an [edge]'s material — pipes by
/// service, ducts by [DuctProduct]. The unit both the on-canvas joint marks and
/// the cut plan are computed against.
double stockLengthForEdge(NetEdge e) => e.service.regime == FlowRegime.air
    ? ductSectionLengthM(effectiveDuctProductFor(e))
    : stockLengthMForService(e.service);

/// One stock bar in the cut plan and the cut pieces taken from it.
class CutBar {
  final List<double> pieces;
  const CutBar(this.pieces);

  double get used => pieces.fold(0.0, (a, b) => a + b);
}

/// The result of packing a group's required pieces into stock bars.
class StockCutPlan {
  final double stockLengthM;

  /// Whole stock bars consumed by runs longer than one bar (used end-to-end with
  /// no waste — only the final remainder of such a run is packed).
  final int fullBars;

  /// Stock bars holding the packed remainder/short pieces (these carry offcuts).
  final List<CutBar> packedBars;

  /// Total length actually required (sum of all run lengths in the group).
  final double requiredM;

  const StockCutPlan({
    required this.stockLengthM,
    required this.fullBars,
    required this.packedBars,
    required this.requiredM,
  });

  int get totalBars => fullBars + packedBars.length;
  double get purchasedM => totalBars * stockLengthM;
  double get wasteM => math.max(0.0, purchasedM - requiredM);
  double get wastePercent => purchasedM <= 0 ? 0 : 100 * wasteM / purchasedM;
}

/// Pack [pieceLengthsM] into stock bars of [stockLengthM], minimising bars (and
/// so waste). A piece longer than a bar uses `floor(len/stock)` whole bars plus
/// a remainder piece; remainders are first-fit-decreasing packed (offcut reuse).
StockCutPlan planStockCuts(Iterable<double> pieceLengthsM, double stockLengthM) {
  assert(stockLengthM > 0, 'stock length must be positive');
  var fullBars = 0;
  var required = 0.0;
  final remainders = <double>[];
  for (final raw in pieceLengthsM) {
    if (raw <= 1e-9) continue;
    required += raw;
    final whole = (raw / stockLengthM).floor();
    fullBars += whole;
    final rem = raw - whole * stockLengthM;
    if (rem > 1e-6) remainders.add(rem);
  }
  // First-fit-decreasing: place the biggest remainders first into the first bar
  // they fit, opening a new bar only when none has room (offcut reuse).
  remainders.sort((a, b) => b.compareTo(a));
  final bars = <List<double>>[];
  final used = <double>[];
  for (final piece in remainders) {
    var placed = false;
    for (var i = 0; i < bars.length; i++) {
      if (used[i] + piece <= stockLengthM + 1e-9) {
        bars[i].add(piece);
        used[i] += piece;
        placed = true;
        break;
      }
    }
    if (!placed) {
      bars.add([piece]);
      used.add(piece);
    }
  }
  return StockCutPlan(
    stockLengthM: stockLengthM,
    fullBars: fullBars,
    packedBars: [for (final b in bars) CutBar(b)],
    requiredM: required,
  );
}

/// One run segment's place within its continuous pipe chain: the chain
/// arc-length coordinate (metres) at the edge's `from` and `to` endpoints. A
/// point at fraction `t` along from→to has chain coordinate
/// `offsetAtFromM + t·(offsetAtToM − offsetAtFromM)`, so couplings at `k·stock`
/// map back to a fraction regardless of the edge's drawn direction.
class PipeChainEdge {
  final String edgeId;
  final double offsetAtFromM;
  final double offsetAtToM;
  const PipeChainEdge(this.edgeId, this.offsetAtFromM, this.offsetAtToM);
}

/// A maximal continuous straight pipe/duct: collinear same-(service,diameter,
/// material) run segments merged through degree-2 pass-through vertices.
class PipeChain {
  final ServiceType service;
  final int diameterMm;

  /// Stock / section length (m) of this chain's material (4/6 m pipe, 1.2/4 m
  /// duct) — couplings / flange joints fall at its multiples.
  final double stockLengthM;
  final double lengthM;
  final List<PipeChainEdge> edges;
  const PipeChain({
    required this.service,
    required this.diameterMm,
    required this.stockLengthM,
    required this.lengthM,
    required this.edges,
  });
}

/// Cosine threshold for two segments meeting at a vertex to count as collinear
/// (a continuous pipe passing through), ≈ within 12°.
const double _kCollinearCos = 0.978;

/// Merge the sized RUN network into continuous pipe chains (risers excluded —
/// they're single vertical drops). Each chain is uniform (service, diameter);
/// it breaks at any branch (a vertex with ≠2 same-group runs), a direction
/// change, a service/diameter change, or a sheet/floor change. Lengths come from
/// [edgeLength] (calibration for runs), so an uncalibrated sheet yields the pixel
/// fallback there.
List<PipeChain> buildPipeChains({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required Map<String, ScaleCalibration> calibrationBySheet,
  required BuildingLevels building,
}) {
  // Group key per edge so a chain stays uniform (service, diameter AND stock
  // length, so a BJLS→PU or PVC→steel transition breaks the chain).
  ({ServiceType s, int mm, double stock})? groupOf(NetEdge e) {
    if (e.kind != EdgeKind.run) return null;
    final es = sizing[e.id];
    if (es == null) return null;
    return (
      s: e.service,
      mm: es.diameter.inMillimeters.round(),
      stock: stockLengthForEdge(e),
    );
  }

  // Eligible run edges + their endpoint world points (same sheet/floor only).
  final runs = <String, NetEdge>{};
  final pFrom = <String, Offset2>{};
  final pTo = <String, Offset2>{};
  final lenM = <String, double>{};
  for (final e in net.edges) {
    if (groupOf(e) == null) continue;
    final a = net.nodeById(e.fromId);
    final b = net.nodeById(e.toId);
    if (a == null || b == null) continue;
    if (a.sheetId != b.sheetId || a.floorIndex != b.floorIndex) continue;
    runs[e.id] = e;
    pFrom[e.id] = Offset2(a.x, a.y);
    pTo[e.id] = Offset2(b.x, b.y);
    lenM[e.id] =
        edgeLength(e, net, calibrationBySheet: calibrationBySheet, building: building)
            .meters;
  }

  // node → incident run edge ids.
  final incident = <String, List<String>>{};
  for (final e in runs.values) {
    (incident[e.fromId] ??= []).add(e.id);
    (incident[e.toId] ??= []).add(e.id);
  }

  // Whether [node] is a pass-through for the chain arriving via edge [viaId]:
  // exactly two same-group run edges meet there and they're collinear.
  String? nextEdgeThrough(String node, String viaId) {
    final here = incident[node] ?? const [];
    if (here.length != 2) return null;
    final otherId = here[0] == viaId ? here[1] : here[0];
    if (otherId == viaId) return null;
    final g1 = groupOf(runs[viaId]!)!;
    final g2 = groupOf(runs[otherId]!)!;
    if (g1.s != g2.s || g1.mm != g2.mm || g1.stock != g2.stock) return null;
    // Direction of the incoming edge AT this node (pointing INTO the node) and
    // of the outgoing edge LEAVING the node; collinear ⇒ small turn.
    final inDir = _dirAtNode(viaId, node, runs, pFrom, pTo, incoming: true);
    final outDir = _dirAtNode(otherId, node, runs, pFrom, pTo, incoming: false);
    if (inDir == null || outDir == null) return null;
    final dot = inDir.dx * outDir.dx + inDir.dy * outDir.dy;
    return dot >= _kCollinearCos ? otherId : null;
  }

  final visited = <String>{};
  final chains = <PipeChain>[];

  for (final startId in runs.keys) {
    if (visited.contains(startId)) continue;
    // Walk to one end of this chain first (so we order from a true end).
    var endEdge = startId;
    var endNode = runs[startId]!.fromId;
    final guard = <String>{};
    while (true) {
      final prev = nextEdgeThrough(endNode, endEdge);
      if (prev == null || guard.contains(prev)) break;
      guard.add(prev);
      // Step to the far node of `prev`.
      final e = runs[prev]!;
      endNode = e.fromId == endNode ? e.toId : e.fromId;
      endEdge = prev;
    }

    // Now walk forward from this end, accumulating arc length.
    final ordered = <PipeChainEdge>[];
    var cur = endEdge;
    var atNode = endNode; // the chain-start node
    var cum = 0.0;
    final g = groupOf(runs[startId]!)!;
    while (true) {
      if (visited.contains(cur)) break;
      visited.add(cur);
      final e = runs[cur]!;
      final farNode = e.fromId == atNode ? e.toId : e.fromId;
      final l = lenM[cur] ?? 0.0;
      final offAtStart = cum; // at `atNode`
      final offAtFar = cum + l;
      // Map to the edge's stored from/to orientation.
      final offFrom = (e.fromId == atNode) ? offAtStart : offAtFar;
      final offTo = (e.fromId == atNode) ? offAtFar : offAtStart;
      ordered.add(PipeChainEdge(cur, offFrom, offTo));
      cum += l;
      final nxt = nextEdgeThrough(farNode, cur);
      if (nxt == null || visited.contains(nxt)) break;
      cur = nxt;
      atNode = farNode;
    }

    chains.add(PipeChain(
      service: g.s,
      diameterMm: g.mm,
      stockLengthM: g.stock,
      lengthM: cum,
      edges: ordered,
    ));
  }
  return chains;
}

/// A diameter-grouped cut-plan summary for one (service, diameter) of pipe.
class PipeCutGroup {
  final ServiceType service;
  final int diameterMm;
  final double stockLengthM;
  final StockCutPlan plan;
  const PipeCutGroup({
    required this.service,
    required this.diameterMm,
    required this.stockLengthM,
    required this.plan,
  });
}

/// Build the per-(service,diameter) cut plan from the merged chains: each chain
/// is one continuous pipe whose length is a "piece" packed into that group's
/// stock bars. Sorted by service then diameter.
List<PipeCutGroup> buildPipeCutPlan(List<PipeChain> chains) {
  final byGroup = <({ServiceType s, int mm, double stock}), List<double>>{};
  for (final c in chains) {
    if (c.lengthM <= 1e-9) continue;
    (byGroup[(s: c.service, mm: c.diameterMm, stock: c.stockLengthM)] ??= [])
        .add(c.lengthM);
  }
  final groups = <PipeCutGroup>[
    for (final entry in byGroup.entries)
      PipeCutGroup(
        service: entry.key.s,
        diameterMm: entry.key.mm,
        stockLengthM: entry.key.stock,
        plan: planStockCuts(entry.value, entry.key.stock),
      ),
  ];
  groups.sort((a, b) {
    final svc = a.service.index.compareTo(b.service.index);
    if (svc != 0) return svc;
    return a.diameterMm.compareTo(b.diameterMm);
  });
  return groups;
}

/// A tiny 2-D point so this module needs no Flutter `Offset`.
class Offset2 {
  final double dx;
  final double dy;
  const Offset2(this.dx, this.dy);
}

/// Unit direction of edge [id] AT [node]: pointing INTO the node when
/// [incoming], else LEAVING it. Null for a zero-length edge.
Offset2? _dirAtNode(
  String id,
  String node,
  Map<String, NetEdge> runs,
  Map<String, Offset2> pFrom,
  Map<String, Offset2> pTo, {
  required bool incoming,
}) {
  final e = runs[id]!;
  final nodePt = e.fromId == node ? pFrom[id]! : pTo[id]!;
  final otherPt = e.fromId == node ? pTo[id]! : pFrom[id]!;
  final vx = otherPt.dx - nodePt.dx;
  final vy = otherPt.dy - nodePt.dy;
  final len = math.sqrt(vx * vx + vy * vy);
  if (len < 1e-9) return null;
  final ux = vx / len, uy = vy / len; // leaving the node
  return incoming ? Offset2(-ux, -uy) : Offset2(ux, uy);
}
