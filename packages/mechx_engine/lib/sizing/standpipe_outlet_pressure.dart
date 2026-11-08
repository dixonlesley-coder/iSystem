/// Round 76 (fire-convergence-27-hose-outlet-static-over-175psi-unjudged) —
/// the pressure at every building HOSE OUTLET of a pumped standpipe, judged
/// against the NFPA 14 hose-connection limits (JUDGE-ONLY, never resizes):
///
///   * 7.2.3.2 — where the STATIC pressure at a hose connection exceeds
///     175 psi ([kStandpipeOutletMaxStaticKpa], 1207 kPa) a pressure-
///     regulating device is required. The static is taken at pump CHURN (the
///     NFPA 20 shut-off head, 140 % of rated — the highest pressure the valve
///     ever sees):
///       P_static(o) = rho g (H_churn(o) - (z_o - z_datum))
///   * 7.2.3.1 — where the RESIDUAL at a 1.5 in hose station (a hose reel)
///     exceeds 100 psi ([kHoseStationMaxResidualKpa], 690 kPa) at its rated
///     flow, a pressure-regulating device limits it:
///       P_residual(o) = rho g (H_rated(o) - (z_o - z_datum) - h_f(o))
///
/// H_churn(o) / H_rated(o) is the head the pumps put on the outlet's path:
/// walking the sized flow direction from the source, crossing a fire pump
/// adds its stage's churn / rated head (parallel duty / standby legs add the
/// same stage head once; series stages add up), a storage tank resets the
/// head to its own free surface, and a drawn PRV ([NodeComponent.prv]) on the
/// path REGULATES every outlet it feeds (cleared — the regulating device the
/// clause asks for). z_o = the outlet floor's FFL + [kHoseOutletHeightM]; the
/// datum is the system's pump datum floor ([FireSystem.datumFloor]), the same
/// basis the rated head's static lift is measured from. Both limits are
/// `// VERIFY notAnSniClause` (NFPA 14; SNI 03-1745 follows NFPA 14). Pure.
library;

import '../geometry/building.dart';
import '../hydraulics.dart' show defaultWaterDensity, standardGravity;
import '../network/network.dart';
import 'fire_index_friction.dart' show FireSystem;
import 'fire_standpipe.dart' show kHoseOutletHeightM;
import 'network_sizing.dart' show EdgeSizing;

/// NFPA 14 7.2.3.2 — 175 psi static at a hose connection (1207 kPa).
/// `// VERIFY notAnSniClause`.
const double kStandpipeOutletMaxStaticKpa = 1207;

/// NFPA 14 7.2.3.1 — 100 psi residual at a 1.5 in hose station (690 kPa).
/// `// VERIFY notAnSniClause`.
const double kHoseStationMaxResidualKpa = 690;

/// The judged pressure at one hose outlet.
class StandpipeOutletPressure {
  final String outletId;
  final int floorIndex;

  /// True for a 1.5 in hose station (hose reel): the residual limit applies.
  final bool hoseStation;

  /// Static at pump churn (kPa); null when no unregulated pump path reaches.
  final double staticKpa;

  /// Residual at the rated flow (kPa); null when the friction to the outlet
  /// is unmeasured (uncalibrated) — the residual is then not judged.
  final double? residualKpa;

  /// True when every pump path to the outlet passes a drawn PRV.
  final bool regulated;

  const StandpipeOutletPressure({
    required this.outletId,
    required this.floorIndex,
    required this.hoseStation,
    required this.staticKpa,
    required this.residualKpa,
    required this.regulated,
  });

  bool get overStatic =>
      !regulated && staticKpa > kStandpipeOutletMaxStaticKpa + 1e-9;

  bool get overResidual =>
      !regulated &&
      hoseStation &&
      residualKpa != null &&
      residualKpa! > kHoseStationMaxResidualKpa + 1e-9;

  bool get over => overStatic || overResidual;
}

/// The hose outlets of [system] (a hydrant box / hose reel on a hydrant
/// pipe, never a yard pillar or an inlet) and the pressure each one sees.
/// [churnHeadByPump] / [ratedHeadByPump] give each drawn pump's STAGE churn /
/// rated head (m); [frictionToOutletM] the sized friction from the root duty
/// pump to each outlet (an outlet missing from it is not residual-judged).
/// Outlets no oriented pump path reaches are omitted. Sorted by floor, id.
List<StandpipeOutletPressure> standpipeOutletPressures({
  required Network net,
  required FireSystem system,
  required Map<String, EdgeSizing> sizing,
  required BuildingLevels building,
  required Map<String, double> churnHeadByPump,
  required Map<String, double> ratedHeadByPump,
  Map<String, double> frictionToOutletM = const {},
}) {
  final nF = building.floors.length;
  if (nF == 0) return const [];
  int clampF(int f) => f < 0 ? 0 : (f >= nF ? nF - 1 : f);
  final zDatum = building.elevationOf(clampF(system.datumFloor(net))).meters;
  double lift(int floor) => building.elevationOf(clampF(floor)).meters - zDatum;

  bool isTank(NodeComponent? c) =>
      c == NodeComponent.groundTank || c == NodeComponent.roofTank;

  // Oriented edges (sized flow direction), positive-flow first.
  final flowing = <(String, String)>[];
  final still = <(String, String)>[];
  final hydrantAt = <String>{};
  for (final e in system.edges) {
    if (e.service == ServiceType.fireHydrant) {
      hydrantAt
        ..add(e.fromId)
        ..add(e.toId);
    }
    final s = sizing[e.id];
    final f = s?.flowFromId;
    if (f == null || (f != e.fromId && f != e.toId)) continue;
    final to = f == e.fromId ? e.toId : e.fromId;
    if ((s!.flow.cubicMetersPerSecond) > 0) {
      flowing.add((f, to));
    } else {
      still.add((f, to));
    }
  }

  // Unregulated head (churn, rated) at each node: the max over pump paths
  // that pass no PRV; [reached] marks nodes any path reaches.
  final churn = <String, double>{};
  final rated = <String, double>{};
  final reached = <String>{};
  final incoming = <String>{for (final (_, to) in flowing) to};
  for (final (from, _) in [...flowing, ...still]) {
    if (!incoming.contains(from)) {
      reached.add(from);
      final n = net.nodeById(from);
      final h = n != null && isTank(n.component) ? lift(n.floorIndex) : 0.0;
      churn.putIfAbsent(from, () => h);
      rated.putIfAbsent(from, () => h);
    }
  }
  // What leaving node [u] carries downstream (null = regulated / unknown).
  (double, double)? out(String u) {
    final n = net.nodeById(u);
    if (n?.component == NodeComponent.prv) return null;
    if (n != null && isTank(n.component)) {
      final h = lift(n.floorIndex);
      return (h, h);
    }
    final c = churn[u];
    final r = rated[u];
    if (c == null || r == null) return null;
    return (c + (churnHeadByPump[u] ?? 0), r + (ratedHeadByPump[u] ?? 0));
  }

  bool relax((String, String) edge) {
    final (u, v) = edge;
    if (!reached.contains(u)) return false;
    var changed = reached.add(v);
    final o = out(u);
    if (o == null) return changed;
    final (c, r) = o;
    if (churn[v] == null || c > churn[v]! + 1e-9) {
      churn[v] = c;
      changed = true;
    }
    if (rated[v] == null || r > rated[v]! + 1e-9) {
      rated[v] = r;
      changed = true;
    }
    return changed;
  }

  // The flowing edges are acyclic (a solved flow); bounded passes regardless.
  for (var pass = 0; pass <= net.nodes.length; pass++) {
    var changed = false;
    for (final e in flowing) {
      if (relax(e)) changed = true;
    }
    if (!changed) break;
  }
  // Zero-flow pipes (standby pockets, closed branches) only reach nodes no
  // flowing path reached — never a loop round a pump.
  for (var pass = 0; pass <= net.nodes.length; pass++) {
    var changed = false;
    for (final e in still) {
      final (_, v) = e;
      if (reached.contains(v)) continue;
      if (relax(e)) changed = true;
    }
    if (!changed) break;
  }

  const rhoG = defaultWaterDensity * standardGravity;
  final outlets = <StandpipeOutletPressure>[];
  for (final n in net.nodes) {
    if (!system.nodeIds.contains(n.id) || n.role != NodeRole.fixture) {
      continue;
    }
    if (n.component != NodeComponent.hydrantBox &&
        n.component != NodeComponent.hoseReel) {
      continue;
    }
    if (!hydrantAt.contains(n.id) || !reached.contains(n.id)) continue;
    final z = lift(n.floorIndex) + kHoseOutletHeightM;
    final c = churn[n.id];
    final r = rated[n.id];
    final f = frictionToOutletM[n.id];
    outlets.add(StandpipeOutletPressure(
      outletId: n.id,
      floorIndex: n.floorIndex,
      hoseStation: n.component == NodeComponent.hoseReel,
      staticKpa: c == null ? 0 : rhoG * (c - z) / 1000,
      residualKpa: r == null || f == null ? null : rhoG * (r - z - f) / 1000,
      regulated: c == null,
    ));
  }
  outlets.sort((a, b) {
    final f = a.floorIndex.compareTo(b.floorIndex);
    return f != 0 ? f : naturalIdCompare(a.outletId, b.outletId);
  });
  return outlets;
}
