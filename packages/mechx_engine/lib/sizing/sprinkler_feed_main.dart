/// Reference tower T2 (2026-11-13) — the SPRINKLER FEED MAIN of a combined
/// fire system is enlarged until the sprinkler stops driving the pump.
///
/// A combined system is one pump (set) serving a building standpipe AND
/// sprinkler heads. Its pump is rated on the larger of the standpipe point
/// (`designStandpipe` over the sized hydrant index friction) and the
/// sprinkler point (`sprinklerPumpRatedPoint` over the sized sprinkler index
/// friction) — the same two points `fireSystemBasesProvider` computes. A
/// velocity-sized sprinkler riser (DN32 at the 6 m/s fire cap) over many
/// storeys loses so much head that the sprinkler point sets the pump head
/// far above what the standpipe needs; no designer accepts that — the feed
/// main is enlarged instead.
///
/// The FEED MAIN is every sprinkler-service pipe of the system that carries
/// the full remote-area demand and touches no sprinkler head: the risers and
/// the runs joining the pump / header to the remote branch, never the branch
/// line with heads. A pipe with a hand-picked size, a parallel standby leg
/// and a pipe already at or above the cap are left as they are.
///
/// While the sprinkler point head exceeds the standpipe point head, every
/// feed-main pipe below the cap is raised ONE step on the pressurized pipe
/// ladder (all of them together), and the sprinkler point is recomputed on
/// the new bores. The cap is the system's largest sized standpipe riser
/// (`kMinRiserDiameterMm` when none is sized). At the cap the sprinkler head
/// may still govern — the pump is then rated on it as before (the existing
/// `combined-fire-sprinkler-governs` info). A sprinkler-only or
/// standpipe-only system is untouched (byte-identical).
///
/// One-directional: it reads the final sizing and returns the enlarged
/// sizing; nothing it produces feeds back into the sizer, so there is no
/// sizing ⇄ basis loop. Every consumer (friction, the pump point, BOM,
/// drawings) reads the returned sizing. Pure; order-independent (systems,
/// pumps and edges are visited in sorted / ranked order).
library;

import '../geometry/building.dart';
import '../hydraulics.dart' show velocityFromFlow;
import '../network/network.dart';
import '../units.dart';
import 'fire_index_friction.dart';
import 'fire_sprinkler_hydraulic.dart'
    show SprinklerRemoteAreaResult, sprinklerPumpRatedPoint;
import 'fire_standpipe.dart' show designStandpipe, kMinRiserDiameterMm;
import 'network_sizing.dart' show EdgeSizing;
import 'water_supply_sizing.dart' as water;

/// The result of [enlargeCombinedSprinklerFeedMains]: the (possibly)
/// enlarged sizing and the ids of the pipes it enlarged.
typedef SprinklerFeedEnlargement = ({
  Map<String, EdgeSizing> sizing,
  Set<String> enlarged,
});

/// See the library doc. [lengthOf] is the §10 edge length the fire index
/// friction is measured over; [parallelLegEdgeIds] the sizer's mirrored
/// standby legs (the duty-pump rank, as `fireSystemBasesProvider`).
SprinklerFeedEnlargement enlargeCombinedSprinklerFeedMains({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required SprinklerRemoteAreaResult remote,
  required BuildingLevels building,
  required double Function(NetEdge e) lengthOf,
  Set<String> parallelLegEdgeIds = const {},
  Set<String> overridden = const {},
}) {
  final systems = fireRatingSystems(net);
  if (systems.isEmpty) return (sizing: sizing, enlarged: const <String>{});
  Map<String, EdgeSizing>? out;
  final enlarged = <String>{};
  final demand = remote.remoteAreaDemand.cubicMetersPerSecond;
  const ladder = water.standardPipeDiametersMm;
  for (final sys in systems) {
    final cur = out ?? sizing;
    final pumps = [
      for (final n in net.nodes)
        if (sys.nodeIds.contains(n.id) &&
            (n.component == NodeComponent.pump ||
                n.component == NodeComponent.boosterSet))
          n.id,
    ]..sort();
    if (pumps.isEmpty) continue;
    if (!sys.standpipeTermApplies(net)) continue;
    if (sys.topTerminalFloor(net, FireTerminalKind.hydrant) == null) continue;
    if (!sys.hasSprinklerHead(net)) continue;
    // The duty pump, ranked exactly as `fireSystemBasesProvider` ranks it:
    // the largest incident bore, then off a mirrored standby leg, then the
    // draw order.
    double boreOf(String p) {
      var bore = 0.0;
      for (final e in sys.edges) {
        if (e.fromId != p && e.toId != p) continue;
        final d = cur[e.id]?.diameter.inMillimeters ?? 0.0;
        if (d > bore) bore = d;
      }
      return bore;
    }

    bool onLeg(String p) => sys.edges.any((e) =>
        (e.fromId == p || e.toId == p) && parallelLegEdgeIds.contains(e.id));
    final ranked = [...pumps]..sort((a, b) {
        final d = boreOf(b).compareTo(boreOf(a));
        if (d != 0) return d;
        final la = onLeg(a) ? 1 : 0, lb = onLeg(b) ? 1 : 0;
        if (la != lb) return la - lb;
        final na = net.nodeById(a), nb = net.nodeById(b);
        if (na == null || nb == null) return naturalIdCompare(a, b);
        return drawOrderCompare(na, nb);
      });
    final duty = ranked.first;
    double? frictionTo(Map<String, EdgeSizing> s, FireTerminalKind kind) =>
        fireIndexPathFrictionM(
          net: net,
          system: sys,
          pumpId: duty,
          sizing: s,
          lengthOf: lengthOf,
          terminals: kind,
        );
    final hf = frictionTo(cur, FireTerminalKind.hydrant);
    final standpipeHead = designStandpipe(
      risers: sys.standpipeRisers(net),
      buildingHeight:
          Length(sys.staticLiftM(net, building, FireTerminalKind.hydrant)),
      standpipeClass: sys.standpipeClass(net),
      indexPathFriction: hf == null ? null : Head(hf),
    ).pumpHead.meters;
    final sprinklerLift =
        sys.staticLiftM(net, building, FireTerminalKind.sprinkler);
    double sprinklerHead(Map<String, EdgeSizing> s) {
      final f = frictionTo(s, FireTerminalKind.sprinkler);
      return sprinklerPumpRatedPoint(
        remote: remote,
        staticLiftM: sprinklerLift,
        indexPathFriction: f == null ? null : Head(f),
      ).head.meters;
    }

    if (sprinklerHead(cur) <= standpipeHead + 1e-9) continue;
    var capMm = 0.0;
    for (final e in sys.edges) {
      if (e.service != ServiceType.fireHydrant || e.kind != EdgeKind.riser) {
        continue;
      }
      final d = cur[e.id]?.diameter.inMillimeters ?? 0.0;
      if (d > capMm) capMm = d;
    }
    if (capMm <= 0) capMm = kMinRiserDiameterMm;
    bool isHead(String id) =>
        net.nodeById(id)?.component == NodeComponent.sprinklerHead;
    final feed = [
      for (final e in sys.edges)
        if (e.service == ServiceType.fireSprinkler &&
            !overridden.contains(e.id) &&
            !parallelLegEdgeIds.contains(e.id) &&
            !isHead(e.fromId) &&
            !isHead(e.toId) &&
            (cur[e.id]?.flow.cubicMetersPerSecond ?? 0) >=
                demand * (1 - 1e-9) &&
            demand > 0)
          e.id,
    ]..sort();
    if (feed.isEmpty) continue;
    final work = Map<String, EdgeSizing>.of(cur);
    var changed = false;
    while (sprinklerHead(work) > standpipeHead + 1e-9) {
      var stepped = false;
      for (final id in feed) {
        final s = work[id]!;
        final dMm = s.diameter.inMillimeters;
        if (dMm >= capMm - 1e-9) continue;
        double? next;
        for (final d in ladder) {
          if (d > dMm + 1e-9) {
            next = d;
            break;
          }
        }
        if (next == null) continue;
        final nd = Diameter.mm(next > capMm ? capMm : next);
        work[id] = s.withBore(nd, velocityFromFlow(s.flow, nd));
        enlarged.add(id);
        stepped = true;
      }
      if (!stepped) break;
      changed = true;
    }
    if (changed) out = work;
  }
  return (sizing: out ?? sizing, enlarged: enlarged);
}
