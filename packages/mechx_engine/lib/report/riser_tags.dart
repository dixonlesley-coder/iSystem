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
/// a tolerance bucket, then numbered in ascending-x order per service. When
/// [focus] is non-null only that service's risers are tagged.
Map<String, String> riserTags(Network net, ServiceType? focus) {
  const xBucket = 12.0; // px tolerance for "same vertical stack".
  final out = <String, String>{};

  final services =
      focus != null ? [focus] : ServiceType.values.toList(growable: false);

  for (final service in services) {
    // Collect this service's riser edges with their lower-node x + floor.
    final risers = <_RiserRef>[];
    for (final e in net.edges) {
      if (e.service != service || e.kind != EdgeKind.riser) continue;
      final a = net.nodeById(e.fromId);
      final b = net.nodeById(e.toId);
      if (a == null || b == null) continue;
      final lower = a.floorIndex <= b.floorIndex ? a : b;
      risers.add(_RiserRef(e.id, lower.x, lower.floorIndex));
    }
    if (risers.isEmpty) continue;

    // Deterministic order: by x then floor.
    risers.sort((p, q) {
      final byX = p.x.compareTo(q.x);
      return byX != 0 ? byX : p.floorIndex.compareTo(q.floorIndex);
    });

    // Assign one index per DISTINCT x-bucket (co-linear risers share it).
    final code = riserServiceCode(service);
    var index = 0;
    double? lastBucketX;
    for (final r in risers) {
      final bucket = (r.x / xBucket).round() * xBucket;
      if (lastBucketX == null || (bucket - lastBucketX).abs() > 0.0001) {
        index++;
        lastBucketX = bucket;
      }
      out[r.edgeId] = '$code-R$index';
    }
  }
  return out;
}

class _RiserRef {
  final String edgeId;
  final double x;
  final int floorIndex;
  const _RiserRef(this.edgeId, this.x, this.floorIndex);
}

/// One floor's branch fan-out for the riser single-line: the short labels of the
/// fixtures/terminals that floor DISTRIBUTES, capped at [max] with the overflow
/// count surfaced (never silently dropped — the painter renders it as a
/// `+N more` row). Pure bookkeeping over the network (no fabricated value).
class FloorFanOut {
  /// The floor index this fan-out belongs to.
  final int floorIndex;

  /// The shown stub labels (length <= max).
  final List<String> labels;

  /// How many fixtures were elided past the cap (0 when none). Surfaced so the
  /// cap is LOGGED, not silently dropped.
  final int overflow;

  const FloorFanOut(this.floorIndex, this.labels, this.overflow);
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
/// fixtures are omitted. Each floor keeps at most [max] labels; the rest are
/// counted into [FloorFanOut.overflow].
List<FloorFanOut> floorFanOuts(
  Network net, {
  Set<String>? visibleNodeIds,
  required String Function(NetNode) labelOf,
  int max = 4,
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
    out.add(FloorFanOut(floor, shown, overflow));
  }
  return out;
}
