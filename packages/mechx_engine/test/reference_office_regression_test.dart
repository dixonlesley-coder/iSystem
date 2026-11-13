// Reference building 3 (office) — engine regressions for the pass-2 fixes.
//
// O1 — the NFPA 20 discharge raise stops at the pump's own junction: FP
// feeds both the hydrant main and a sprinkler branch. The branch's run from
// the pump stays discharge piping (DN125, Round 62: it stores the pump's
// rated flow), but the sprinkler riser met further along it is that system's
// own riser: S0→S1 = S1→S2 = S2→S3 = DN32 at the 4.714 L/s remote-area
// demand, never DN125 at 31.545 L/s for one storey and DN32 above it.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart'
    show drainageFixtureUnit;
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/office.dart';

Map<String, EdgeSizing> _size(ReferenceBuilding b) {
  final net = b.network;
  const profile = SniProfile();
  final remote = remoteAreaHydraulics(
      design: designSprinklerSystem(hazard: FireHazardClass.lightHazard));
  final standpipe = designStandpipe(
      risers: drawnStandpipeRiserCount(net),
      buildingHeight: standpipeStaticLift(b.building));
  return autoSizeNetwork(
    net,
    const SizingContext(),
    leafDemand: {
      ServiceType.fireHydrant: const FlowRate(0.005),
      ServiceType.fireSprinkler: remote.remoteHeadFlow,
    },
    leafFixtureUnits: const {ServiceType.coldWater: 2.0},
    nodeFixtureUnits: {
      for (final n in net.nodes)
        if (n.fixture != null)
          n.id: profile.fixtureUnitLoad(n.fixture!, occupancy: b.occupancy),
    },
    nodeDrainageUnits: {
      for (final n in net.nodes)
        if (n.fixture != null) n.id: drainageFixtureUnit(n.fixture!),
    },
    nodeFlowDemand: {
      for (final n in net.nodes)
        if (n.airflow != null) n.id: n.airflow!,
    },
    sprinklerDemandCap: remote.remoteAreaDemand,
    hydrantDesignFlow: standpipe.requiredFlow,
    flushSystem: FlushSystem.flushValve,
    flushValveNodeIds: {
      for (final n in net.nodes)
        if (n.fixture == PlumbingFixture.waterClosetFlushValve) n.id,
    },
    building: b.building,
    calibrationBySheet: b.calibrations,
    mounting: b.mounting,
  );
}

void main() {
  test('O1: a sprinkler riser on a branch off a two-outlet fire pump keeps '
      'its own class size (no mid-run neck)', () {
    final sz = _size(buildOffice());
    // 5 heads x 80 sqrt(0.5) L/min = 4.71405 L/s; DN32 v = 5.861 m/s <= 6.
    for (final id in ['e_sp_S0_S1', 'e_sp_S1_S2', 'e_sp_S2_S3']) {
      expect(sz[id]!.diameter.inMillimeters, 32, reason: id);
      expect(sz[id]!.flow.inLitersPerSecond, closeTo(4.71405, 5e-5),
          reason: id);
      expect(sz[id]!.velocity.metersPerSecond, closeTo(5.861, 5e-4),
          reason: id);
    }
    // The run leaving the pump is still its NFPA 20 discharge pipe (500 gpm
    // row: DN125). Backlog A-5 (supersedes the Round-62 stored rated flow
    // for a branch) — it stores its OWN 4.71405 L/s, v = 4 x 4.71405e-3 /
    // (pi x 0.125^2) = 0.384 m/s.
    expect(sz['e_sp_FP_S0']!.diameter.inMillimeters, 125);
    expect(sz['e_sp_FP_S0']!.flow.inLitersPerSecond, closeTo(4.71405, 5e-5));
    expect(sz['e_sp_FP_S0']!.velocity.metersPerSecond, closeTo(0.384, 5e-4));
    // The hydrant main beside it is unchanged.
    expect(sz['e_fh_FP_H0']!.diameter.inMillimeters, 125);
    expect(sz['e_fh_H0_H1']!.diameter.inMillimeters, 100);
  });

  test('O1: a riser leaving a single-outlet pump directly is still its '
      'discharge pipe', () {
    // FT → FP → (riser) S0' … : drop the hydrant side so FP has ONE outlet.
    final b = buildOffice();
    final net = b.network;
    final keep = net.edges
        .where((e) => e.service != ServiceType.fireHydrant || e.id == 'e_fh_FT_FP')
        .toList();
    final one = ReferenceBuilding(
      name: b.name,
      building: b.building,
      sheets: b.sheets,
      calibrations: b.calibrations,
      network: Network(nodes: net.nodes, edges: keep),
      electrical: b.electrical,
      occupancy: b.occupancy,
    );
    final sz = _size(one);
    // Single outlet: no branch, so the Round-62 rule stands (a riser
    // reached through the bend S0 is the pump's discharge piping).
    expect(sz['e_sp_FP_S0']!.diameter.inMillimeters,
        greaterThanOrEqualTo(32));
    expect(sz['e_sp_S0_S1']!.diameter.inMillimeters,
        sz['e_sp_FP_S0']!.diameter.inMillimeters);
  });
}
