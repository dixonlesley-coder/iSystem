/// Pure (Flutter-free) helpers for the Auto single-line / Riser view: a
/// FUNCTION suffix on a pipe tag (GRAVITASI / BOOSTER / TRANSFER) and a
/// deterministic per-service riser TAG (e.g. `CW-R1`). These live here, apart
/// from the painter, so they can be unit-tested without a widget.
///
/// HONESTY: a function suffix is appended ONLY when it is confidently derivable
/// from the two endpoints' components/roles + the feed strategy; when ambiguous
/// the helper returns null and NOTHING is appended (never guess). The riser
/// tags are pure bookkeeping numbering (no fabricated datum).
///
/// To stay engine-only (cleanly unit-testable, no Flutter import) this file
/// imports only `package:mechx_engine/network/network.dart` and redeclares the
/// feed-strategy as a plain `bool downfeed` parameter rather than importing the
/// app's `FeedStrategy` enum.
library;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fan.dart' show FanDuty;
import 'package:mechx_engine/sizing/pump.dart' show PumpDuty;

/// The Indonesian drawing-convention FUNCTION of a supply riser/run, appended to
/// the single-line pipe tag (e.g. `100-CW-PPR-BOOSTER`).
enum RiserFunction { gravitasi, booster, transfer }

extension RiserFunctionCode on RiserFunction {
  /// The verbatim on-canvas code drawn after the pipe tag.
  String get code => switch (this) {
        RiserFunction.gravitasi => 'GRAVITASI',
        RiserFunction.booster => 'BOOSTER',
        RiserFunction.transfer => 'TRANSFER',
      };
}

/// Two-letter service code used on the single-line (CW = air bersih, etc.).
/// The single source of truth shared by `_pipeTag` and the riser tags.
String riserServiceCode(ServiceType s) => switch (s) {
      ServiceType.coldWater => 'CW',
      ServiceType.hotWater => 'HW',
      ServiceType.drainage => 'D',
      ServiceType.vent => 'V',
      ServiceType.rainwater => 'RW',
      ServiceType.duct => 'SA',
      ServiceType.returnAir => 'RA',
      ServiceType.exhaust => 'EA',
      ServiceType.fireSprinkler => 'SP',
      ServiceType.fireHydrant => 'FH',
    };

/// The industry floor-elevation notation drawn in the riser single-line gutter —
/// the finished-floor-level datum with the `FFL` abbreviation and two decimals
/// (e.g. `FFL +4.00`). ONE formatter shared by the live Riser canvas painter and
/// the exported [buildMechanicalRiserSld] SldSheet so the working view and the
/// issued deliverable read the elevation identically (E6). [meters] is the SI
/// elevation; this is a display formatter only (no unit maths).
String fflLabel(double meters) => 'FFL +${meters.toStringAsFixed(2)}';

bool _isSupplyTank(NodeComponent? c) =>
    c == NodeComponent.groundTank || c == NodeComponent.pump ||
    c == NodeComponent.boosterSet;

bool _isPumpish(NodeComponent? c) =>
    c == NodeComponent.pump || c == NodeComponent.boosterSet;

/// True when [net] has a pump / booster set on this [service]'s component (any
/// node touching an edge of that service). Cheap O(nodes) scan, deterministic.
bool _serviceHasPump(Network net, ServiceType service) {
  for (final n in net.nodes) {
    if (!_isPumpish(n.component)) continue;
    // The pump must touch an edge of this service to count for it.
    if (net.edgesAt(n.id).any((e) => e.service == service)) return true;
  }
  return false;
}

/// Best-effort FUNCTION classification for [edge] on the single-line.
///
/// Returns null for air services and for any case that is NOT confidently
/// derivable (the tag then stays exactly `100-CW-PPR`). Heuristic — each rule is
/// // VERIFY (drawing-convention inference, not an SNI clause):
///
///   * TRANSFER — a riser lifting supply from a groundTank / pump UP to a
///     roofTank (the unambiguous tank→tank lift). Preferred when it also reads
///     as BOOSTER.
///   * BOOSTER — a run/riser downstream of a pump / boosterSet; or, under
///     upfeed, an ASCENDING pressurized cold/hot-water riser when the service
///     has a pump.
///   * GRAVITASI — a run/riser descending/distributing from a roofTank plant;
///     or, under downfeed, a distribution main/riser NOT downstream of a pump.
///
/// When two rules could fire prefer TRANSFER; if STILL ambiguous return null.
// VERIFY heuristic — appends a function suffix only when confidently derivable;
// ambiguous => null (no suffix). Drawing-convention inference, not an SNI clause.
RiserFunction? riserFunctionFor(Network net, NetEdge edge,
    {required bool downfeed}) {
  // Only piped (non-air) services carry a function suffix.
  if (edge.service.regime == FlowRegime.air) return null;

  final from = net.nodeById(edge.fromId);
  final to = net.nodeById(edge.toId);
  if (from == null || to == null) return null;

  final fromC = from.component;
  final toC = to.component;

  // Determine the LOWER / UPPER endpoint by elevation (floorIndex is the proxy
  // for vertical order in the single-line; the riser kind is the strongest cue).
  final ascending = to.floorIndex > from.floorIndex;
  final lower = ascending ? from : to;
  final upper = ascending ? to : from;
  final lowerC = lower.component;
  final upperC = upper.component;

  // ── TRANSFER (the unambiguous tank→tank lift) ───────────────────────────────
  // A riser whose LOWER end is a groundTank/pump and UPPER end is a roofTank.
  // VERIFY: tank→tank transfer riser.
  if (edge.kind == EdgeKind.riser &&
      _isSupplyTank(lowerC) &&
      upperC == NodeComponent.roofTank) {
    return RiserFunction.transfer;
  }

  // ── GRAVITASI (gravity feed from the roof tank) ─────────────────────────────
  // A run/riser with a roofTank endpoint that DESCENDS/distributes below it.
  // VERIFY: gravity downfeed from a roof tank.
  final touchesRoofTank =
      fromC == NodeComponent.roofTank || toC == NodeComponent.roofTank;
  if (touchesRoofTank) {
    // A riser descending from the roof tank, or any distribution run leaving it.
    if (edge.kind == EdgeKind.riser) {
      // Descending from a roofTank at the UPPER end => gravity.
      if (upperC == NodeComponent.roofTank && !_isSupplyTank(lowerC)) {
        return RiserFunction.gravitasi;
      }
    } else {
      // A distribution run leaving the roof tank.
      return RiserFunction.gravitasi;
    }
  }

  // ── BOOSTER (pressurized, pump-driven) ──────────────────────────────────────
  // A run/riser directly downstream of a pump/boosterSet (an endpoint is one).
  // VERIFY: pumped/pressurized run downstream of a pump.
  final touchesPump = _isPumpish(fromC) || _isPumpish(toC);
  if (touchesPump) return RiserFunction.booster;

  // Under UPFEED, an ASCENDING pressurized cold/hot-water riser is the booster
  // riser when the service has a pump in its component.
  // VERIFY: upfeed pressurized supply riser.
  final isWater =
      edge.service == ServiceType.coldWater || edge.service == ServiceType.hotWater;
  if (!downfeed &&
      edge.kind == EdgeKind.riser &&
      ascending &&
      isWater &&
      _serviceHasPump(net, edge.service)) {
    return RiserFunction.booster;
  }

  // Under DOWNFEED, a distribution main / riser that is NOT downstream of a pump
  // and the service is water => gravity from the roof tank.
  // VERIFY: downfeed distribution main fed from the roof tank.
  if (downfeed && isWater && !_serviceHasPump(net, edge.service)) {
    return RiserFunction.gravitasi;
  }

  // Ambiguous — append nothing.
  return null;
}

/// Deterministic per-service riser TAG for every riser edge: service code + `R`
/// + a 1-based index, e.g. `CW-R1`, `CW-R2`, `HW-R1`. Co-linear risers stacked
/// across floors (same x bucket) share one tag index.
///
/// Risers are grouped into vertical STACKS by rounding the lower endpoint's x to
/// a tolerance bucket (that grouping is geometric, and must be — a stack IS the
/// co-linear set). When [focus] is non-null only that service's risers are
/// tagged.
///
/// B4 — the NUMBERING is NOT positional. Stacks used to be numbered in
/// ascending-x order, so dragging one riser sideways past another (a
/// diagram-decluttering gesture, or any plan-side endpoint drag) silently
/// RENUMBERED `CW-R1`/`CW-R2` across the plan labels, the riser single-line, the
/// BOM tag column and the calc report between revisions — with no diff and no
/// warning. Stacks are now ordered by a STABLE first-assigned ordinal: the
/// earliest position, in `net.nodes` list order, of any node the stack's risers
/// touch. That list is INSERTION order (the store appends new nodes and never
/// reorders; the `.mechx` round-trip preserves it), so the first-drawn stack is
/// `R1` for life, a moved stack keeps its number, and a NEW stack takes the next
/// one. Ties (two stacks whose earliest node index is equal — impossible for
/// distinct nodes, defensive only) fall back to ascending x, then edge id.
///
/// Node IDS are deliberately NOT used as the ordering key: they are minted `n0`,
/// `n1`, … `n10`, so their LEXICOGRAPHIC order is not the creation order
/// (`n10` < `n2`), and an opened project keeps whatever ids it was saved with.
/// List position is the honest, stable creation order.
Map<String, String> riserTags(Network net, ServiceType? focus) {
  const xBucket = 12.0; // px tolerance for "same vertical stack".
  final out = <String, String>{};

  // First-assigned ordinal per node: its index in the network's node list.
  final nodeOrder = <String, int>{};
  for (var i = 0; i < net.nodes.length; i++) {
    nodeOrder[net.nodes[i].id] = i;
  }

  final services =
      focus != null ? [focus] : ServiceType.values.toList(growable: false);

  for (final service in services) {
    // Collect this service's riser edges with their lower-node x + the stable
    // ordinal of the EARLIEST node either endpoint occupies.
    final risers = <_RiserRef>[];
    for (final e in net.edges) {
      if (e.service != service || e.kind != EdgeKind.riser) continue;
      final a = net.nodeById(e.fromId);
      final b = net.nodeById(e.toId);
      if (a == null || b == null) continue;
      final lower = a.floorIndex <= b.floorIndex ? a : b;
      final oa = nodeOrder[a.id] ?? nodeOrder.length;
      final ob = nodeOrder[b.id] ?? nodeOrder.length;
      risers.add(_RiserRef(e.id, lower.x, oa < ob ? oa : ob));
    }
    if (risers.isEmpty) continue;

    // Group into x-buckets (the geometric stack), then rank the buckets by the
    // stable ordinal of their earliest-created node.
    double bucketOf(double x) => (x / xBucket).round() * xBucket;
    final earliestByBucket = <double, int>{};
    for (final r in risers) {
      final b = bucketOf(r.x);
      final seen = earliestByBucket[b];
      if (seen == null || r.order < seen) earliestByBucket[b] = r.order;
    }
    final buckets = earliestByBucket.keys.toList()
      ..sort((p, q) {
        final byOrder = earliestByBucket[p]!.compareTo(earliestByBucket[q]!);
        return byOrder != 0 ? byOrder : p.compareTo(q);
      });
    final indexOfBucket = <double, int>{
      for (var i = 0; i < buckets.length; i++) buckets[i]: i + 1,
    };

    final code = riserServiceCode(service);
    for (final r in risers) {
      out[r.edgeId] = '$code-R${indexOfBucket[bucketOf(r.x)]}';
    }
  }
  return out;
}

class _RiserRef {
  final String edgeId;
  final double x;

  /// The stable first-assigned ordinal of this riser: the smaller of its two
  /// endpoints' positions in the network's node list (creation order).
  final int order;
  const _RiserRef(this.edgeId, this.x, this.order);
}

/// The stable, cross-artifact ELEMENT TAG for [edge] (N13) — the SAME string on
/// the plan, the riser single-line, the BOM and the calc report, so one
/// run/riser can be traced across the whole issued set instead of matched by a
/// bare, ambiguous `DN`.
///
///   * A RISER carries its per-service stack tag from [riserTags] (e.g.
///     `CW-R1`) — position-derived and identical on every artifact. Pass the
///     network-wide map in [riserTagByEdge] (compute it once via
///     `riserTags(net, null)`); an edge with no riser-tag entry falls back to
///     the bare service code.
///   * A RUN carries `<service-code>-F<n>` where `n` is its 1-based building
///     floor (the from-node's `floorIndex + 1`), e.g. `CW-F2` — the coarsest
///     locator a per-(service, size, material, floor) BOM row can also carry (a
///     per-run serial would not survive that aggregation, so it could not read
///     identically on the BOM). A run whose from-node is unknown (should not
///     happen) falls back to the bare service code.
///
/// Pure + deterministic. Never fabricates — an absent floor / riser tag simply
/// degrades to the service code.
String elementTagForEdge(
    Network net, NetEdge edge, Map<String, String> riserTagByEdge) {
  final code = riserServiceCode(edge.service);
  if (edge.kind == EdgeKind.riser) {
    return riserTagByEdge[edge.id] ?? code;
  }
  final floor = net.nodeById(edge.fromId)?.floorIndex;
  return floor == null ? code : '$code-F${floor + 1}';
}

/// Per-edge stable element tags for the WHOLE [net] (N13), keyed by edge id: the
/// [riserTags] stack tag for each riser, `<code>-F<floor>` for each run. This is
/// the ONE map threaded into the plan-drawing labels ([planToPdf]/[networkToDxf]
/// `edgeTags`), the BOM tag column and the calc-report run schedule, so a
/// run/riser reads the same tag on all four artifacts. Pure + deterministic.
Map<String, String> elementTags(Network net) {
  final risers = riserTags(net, null);
  return <String, String>{
    for (final e in net.edges) e.id: elementTagForEdge(net, e, risers),
  };
}

/// px tolerance for grouping nodes into one vertical COLUMN — shared with
/// [riserTags]'s stack bucket so a co-linear riser stack that shares a tag id
/// also shares a layout column.
const double kRiserColumnBucket = 12.0;

/// Visible node ids under a single-service [focus] — endpoints of that service's
/// edges (null ⇒ the combined view, no filter). Shared by [riserLayoutPositions]
/// and mirrors the painter/export focus filters.
Set<String>? _layoutFocusedNodeIds(Network net, ServiceType? focus) {
  if (focus == null) return null;
  final ids = <String>{};
  for (final e in net.edges) {
    if (e.service == focus) {
      ids
        ..add(e.fromId)
        ..add(e.toId);
    }
  }
  return ids;
}

/// The ONE horizontal-layout helper shared by the on-canvas Auto riser painter
/// and the vector EXPORT builder (B7), so a vertical riser stack reads as a
/// single clean column on BOTH surfaces instead of jogging into L-shapes.
///
/// Returns a NORMALIZED x in [0, 1] per visible node id — 0 = the left edge of
/// the placement band, 1 = the right edge — which each consumer maps into its
/// own band width (`left + t * innerWidth`). A single column (every node
/// vertically aligned, or a lone node) maps to 0.5 (centred), matching both
/// consumers' prior single-node/zero-span centring.
///
/// Nodes are grouped into vertical COLUMNS by bucketing their world x with the
/// [kRiserColumnBucket] tolerance (the same bucket the riser tags use), so
/// co-linear nodes across floors — a riser stack — land in ONE column and read
/// vertical regardless of how many other nodes each floor carries. The distinct
/// buckets are ranked left→right by x, so non-stack nodes keep their horizontal
/// rank order. [focus] restricts to a single service's node set (null ⇒ the
/// combined view). Pure + deterministic (bucket rounding + a stable rank).
Map<String, double> riserLayoutPositions(Network net, {ServiceType? focus}) {
  final visible = _layoutFocusedNodeIds(net, focus);
  final nodes = <NetNode>[
    for (final n in net.nodes)
      if (visible == null || visible.contains(n.id)) n,
  ];
  if (nodes.isEmpty) return const {};

  double bucketOf(double x) => (x / kRiserColumnBucket).round() * kRiserColumnBucket;

  // Distinct column buckets, sorted ascending → a stable left→right rank.
  final buckets = <double>{for (final n in nodes) bucketOf(n.x)}.toList()..sort();
  final rankOf = <double, int>{
    for (var i = 0; i < buckets.length; i++) buckets[i]: i,
  };
  final columns = buckets.length;

  return <String, double>{
    for (final n in nodes)
      n.id: columns <= 1 ? 0.5 : rankOf[bucketOf(n.x)]! / (columns - 1),
  };
}

/// One grouped entry in a floor's fan-out: a fixture TYPE label and how many of
/// that type the floor distributes (e.g. `WC` × 3). Grouping by type means a
/// whole floor's fixture population fits in a few compact rows, so the riser
/// SHEET can enumerate every fixture with counts instead of truncating at a
/// per-fixture cap (N7). Pure bookkeeping — the count is a real tally, never a
/// fabricated value.
class FanGroup {
  /// The fixture-type stub label (e.g. `WC`, `Lavatory`).
  final String label;

  /// How many fixtures of this type the floor distributes (>= 1).
  final int count;

  const FanGroup(this.label, this.count);
}

/// One floor's branch fan-out for the riser single-line: the fixtures/terminals
/// that floor DISTRIBUTES, exposed two ways over the SAME node set —
///   • [labels] / [overflow] — the legacy per-fixture list capped at `max` (the
///     on-canvas Auto painter still renders this compact preview);
///   • [groups] / [groupOverflow] — the per fixture-TYPE counts the issued riser
///     SHEET renders, capped only at a much higher DISTINCT-TYPE bound so a real
///     floor's whole fixture population is enumerated with no truncation (N7).
/// A node counts as a distributed fixture when its [NodeRole] is `fixture`. Pure
/// bookkeeping over the network (no fabricated value).
class FloorFanOut {
  /// The floor index this fan-out belongs to.
  final int floorIndex;

  /// The shown per-fixture stub labels (length <= max) — the legacy preview.
  final List<String> labels;

  /// How many fixtures were elided past the per-fixture cap (0 when none).
  final int overflow;

  /// Per fixture-TYPE counts in first-appearance order (x-then-id) — the whole
  /// floor with no per-fixture cap loss. Empty only when the floor has no
  /// fixtures.
  final List<FanGroup> groups;

  /// Distinct fixture TYPES elided past the group cap (0 in practice — a real
  /// floor never carries that many distinct types). Surfaced so the cap is
  /// LOGGED, never silently dropped.
  final int groupOverflow;

  const FloorFanOut(
    this.floorIndex,
    this.labels,
    this.overflow, {
    this.groups = const [],
    this.groupOverflow = 0,
  });
}

/// The equipment detail SUFFIX drawn beside an equipment symbol on the
/// single-line — a tank capacity (`237 m3`) or a duty (`5.5 kW`) — or null when
/// no datum genuinely exists (the node then keeps its plain name, no fabricated
/// value). HONEST: a tank's m3 is a direct conversion of the stored
/// [NetNode.tankCapacityLitres]; a duty is shown only when the matching system
/// duty provider is non-null.
///
/// Pure + Flutter-free (engine types only) so it is unit-testable in isolation
/// and shared by the schematic painter AND the riser single-line EXPORT builder
/// (`mechanical_sld_drawing.dart` `equipmentDetailByNodeId` — B1 parity).
String? equipmentDetail(
  NetNode node, {
  PumpDuty? supplyPump,
  FanDuty? fan,
  PumpDuty? firePump,
}) {
  final c = node.component;
  if (c == null) return null;
  switch (c) {
    case NodeComponent.roofTank:
    case NodeComponent.groundTank:
    case NodeComponent.expansionTank:
      final litres = node.tankCapacityLitres;
      if (litres == null || litres <= 0) return null;
      final m3 = litres / 1000.0;
      // Whole-m3 for big cisterns, one decimal for small tanks; strip a '.0'.
      // ASCII 'm3' — matching the plant-detail callout, the notes card and the
      // export (the PDF sanitizer would mangle a real superscript to '?').
      final s = m3 >= 100 ? m3.toStringAsFixed(0) : m3.toStringAsFixed(1);
      final clean = s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
      return '$clean m3';
    case NodeComponent.pump:
    case NodeComponent.boosterSet:
      // VERIFY: this is the SYSTEM supply-pump duty (one trunk pump), not a
      // per-node solve — a project with several independent pumps would show the
      // same duty on every pump node. Acceptable first pass (one supply pump is
      // the norm); the fire pump is deliberately NOT attached here (no node-kind
      // distinguishes a fire pump from a plumbing pump yet).
      if (supplyPump == null) return null;
      return '${supplyPump.selectedMotor.inKiloWatts.toStringAsFixed(1)} kW';
    case NodeComponent.ahu:
    case NodeComponent.fcu:
    case NodeComponent.supplyFan:
    case NodeComponent.exhaustFan:
      // VERIFY: same system-level caveat as the pump — the central duct-fan duty
      // is attached to every air-unit node of this kind (no per-unit fan solve).
      if (fan == null) return null;
      return '${fan.selectedMotor.inKiloWatts.toStringAsFixed(1)} kW';
    default:
      return null;
  }
}

// ── B2 stack-detail bookkeeping (drainage / vent riser conventions) ──────────
// Pure detections over the DRAWN network for the Diagram Air Kotor treatment:
// the cleanout at a drainage stack base, the vent-to-soil tee, and the
// vent-through-roof (VTR) termination. HONESTY: each returns only what the
// engineer actually drew — a missing cleanout is SURFACED (advisory), never
// fabricated into the drawing.

/// Node ids at the BASE of a drainage stack: the LOWER endpoint of a drainage
/// riser that is not itself the UPPER endpoint of another drainage riser (i.e.
/// the stack's lowest drawn point). Deterministic bookkeeping, no geometry.
Set<String> drainageStackBaseIds(Network net) {
  final lowerIds = <String>{};
  final upperIds = <String>{};
  for (final e in net.edges) {
    if (e.service != ServiceType.drainage || e.kind != EdgeKind.riser) continue;
    final a = net.nodeById(e.fromId);
    final b = net.nodeById(e.toId);
    if (a == null || b == null) continue;
    final lower = a.floorIndex <= b.floorIndex ? a : b;
    final upper = identical(lower, a) ? b : a;
    lowerIds.add(lower.id);
    upperIds.add(upper.id);
  }
  return lowerIds.difference(upperIds);
}

/// Whether stack base [nodeId] is served by a cleanout — the base node itself,
/// or an immediately drainage-connected neighbour, carries
/// [NodeComponent.cleanout] (the conventional rodding point beside the base).
bool _stackBaseHasCleanout(Network net, String nodeId) {
  if (net.nodeById(nodeId)?.component == NodeComponent.cleanout) return true;
  for (final e in net.edgesAt(nodeId)) {
    if (e.service != ServiceType.drainage) continue;
    final otherId = e.fromId == nodeId ? e.toId : e.fromId;
    if (net.nodeById(otherId)?.component == NodeComponent.cleanout) return true;
  }
  return false;
}

/// Drainage stack bases LACKING a cleanout at/beside the base — the advisory
/// feed ('Drainage stack has no cleanout at its base'). Sorted by node id so the
/// issue list is deterministic. Empty when every stack base is served (or there
/// are no drainage risers at all).
List<String> drainageStackBasesLackingCleanout(Network net) {
  final out = [
    for (final id in drainageStackBaseIds(net))
      if (!_stackBaseHasCleanout(net, id)) id,
  ]..sort();
  return out;
}

/// Ids of the CLEANOUT nodes that serve a drainage stack base (the base node
/// itself or a drainage-connected neighbour) — the nodes that carry the `CO`
/// tag on the riser drawing. Only cleanouts the engineer actually drew.
Set<String> cleanoutAtStackBaseIds(Network net) {
  final out = <String>{};
  for (final baseId in drainageStackBaseIds(net)) {
    if (net.nodeById(baseId)?.component == NodeComponent.cleanout) {
      out.add(baseId);
    }
    for (final e in net.edgesAt(baseId)) {
      if (e.service != ServiceType.drainage) continue;
      final otherId = e.fromId == baseId ? e.toId : e.fromId;
      if (net.nodeById(otherId)?.component == NodeComponent.cleanout) {
        out.add(otherId);
      }
    }
  }
  return out;
}

/// Node ids where a VENT riser tees into the soil stack: a vent-riser endpoint
/// that also touches a drainage edge (the drawn vent-to-soil connection).
Set<String> ventSoilTeeNodeIds(Network net) {
  final out = <String>{};
  for (final e in net.edges) {
    if (e.service != ServiceType.vent || e.kind != EdgeKind.riser) continue;
    for (final id in [e.fromId, e.toId]) {
      if (net.edgesAt(id).any((d) => d.service == ServiceType.drainage)) {
        out.add(id);
      }
    }
  }
  return out;
}

/// UPPER endpoints of vent risers that REACH [topFloor] — the vent-through-roof
/// (VTR) terminations. A vent riser stopping short of the top floor is NOT a
/// VTR (never fabricate the roof penetration).
Set<String> ventTopTerminalIds(Network net, {required int topFloor}) {
  final out = <String>{};
  for (final e in net.edges) {
    if (e.service != ServiceType.vent || e.kind != EdgeKind.riser) continue;
    final a = net.nodeById(e.fromId);
    final b = net.nodeById(e.toId);
    if (a == null || b == null) continue;
    final upper = a.floorIndex >= b.floorIndex ? a : b;
    if (upper.floorIndex == topFloor) out.add(upper.id);
  }
  return out;
}

/// Group the demand-bearing FIXTURE/terminal nodes per floor into a capped
/// fan-out — the per-floor branch list under each riser band. A node counts as a
/// distributed fixture when its [NodeRole] is `fixture` (a WC / lavatory /
/// diffuser / drain endpoint), which is what a floor's branch actually serves;
/// plant + plain junctions + inline valves are excluded (they aren't fixtures
/// the floor distributes to).
///
/// [visibleNodeIds] is the focus filter (null ⇒ all services). [labelOf] maps a
/// node to its short stub label (the painter passes its own fixture/component
/// label resolver). Deterministic ordering: by node x then id. Floors with no
/// fixtures are omitted. The legacy [FloorFanOut.labels] keeps at most [max]
/// per-fixture labels (overflow counted); the grouped [FloorFanOut.groups] tally
/// every fixture per TYPE with no truncation, capped only at [groupMax] distinct
/// types (a bound a real floor never reaches — surfaced via `groupOverflow`).
List<FloorFanOut> floorFanOuts(
  Network net, {
  Set<String>? visibleNodeIds,
  required String Function(NetNode) labelOf,
  int max = 4,
  int groupMax = 8,
}) {
  final byFloor = <int, List<NetNode>>{};
  for (final node in net.nodes) {
    if (node.role != NodeRole.fixture) continue;
    if (visibleNodeIds != null && !visibleNodeIds.contains(node.id)) continue;
    (byFloor[node.floorIndex] ??= []).add(node);
  }

  final out = <FloorFanOut>[];
  final floors = byFloor.keys.toList()..sort();
  for (final floor in floors) {
    final nodes = byFloor[floor]!
      ..sort((a, b) {
        final byX = a.x.compareTo(b.x);
        return byX != 0 ? byX : a.id.compareTo(b.id);
      });
    final shown = <String>[];
    for (final n in nodes) {
      if (shown.length >= max) break;
      shown.add(labelOf(n));
    }
    final overflow = nodes.length - shown.length;
    // Group every fixture on the floor by its type label — insertion order (a
    // LinkedHashMap over the x-then-id sorted nodes) keeps the display
    // deterministic and first-appearance ordered.
    final counts = <String, int>{};
    for (final n in nodes) {
      final l = labelOf(n);
      counts[l] = (counts[l] ?? 0) + 1;
    }
    final groups = <FanGroup>[];
    var groupOverflow = 0;
    for (final entry in counts.entries) {
      if (groups.length >= groupMax) {
        groupOverflow++;
        continue;
      }
      groups.add(FanGroup(entry.key, entry.value));
    }
    out.add(FloorFanOut(floor, shown, overflow,
        groups: groups, groupOverflow: groupOverflow));
  }
  return out;
}
