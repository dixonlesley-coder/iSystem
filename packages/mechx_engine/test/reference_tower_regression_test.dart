// Reference building 5 (tower) — engine regressions for the pass-2 fixes.
//
// T1 — the NFPA 20 discharge raise ends at the discharge HEADER FH. Past it
// an outflow is discharge pipe only when its own flow is the pump's full
// rated flow (a single main). Two standpipes split the 750 gpm (47.3176
// L/s) pump flow into one 500 gpm (31.5451 L/s) trunk each, and the
// sprinkler feed carries its 4.714 L/s remote-area demand: none of the three
// header outflows is raised to the pump's DN150 / 47.3176 L/s, and the
// sprinkler riser is one size, one flow, all the way up.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart'
    show drainageFixtureUnit;
import 'package:mechx_engine/sizing/fire_pump_rating.dart'
    show kJockeyFlowFraction;
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/tower.dart';

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
    const SizingContext(
        ductShape: kTowerDuctShape, ductMethod: kTowerDuctMethod),
    leafDemand: {
      ServiceType.fireHydrant: const FlowRate(0.005),
      ServiceType.fireSprinkler: remote.remoteHeadFlow,
    },
    leafFixtureUnits: const {
      ServiceType.coldWater: 2.0,
      ServiceType.hotWater: 2.0,
    },
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
    sizeOverrides: {
      for (final e in net.edges)
        if (e.sizeOverride != null) e.id: e.sizeOverride!,
    },
    sprinklerDemandCap: remote.remoteAreaDemand,
    hydrantDesignFlow: standpipe.requiredFlow,
    flushSystem: FlushSystem.flushValve,
    flushValveNodeIds: {
      for (final n in net.nodes)
        if (n.fixture == PlumbingFixture.waterClosetFlushValve) n.id,
    },
    jockeyLegFlows: {
      kTowerJockeyPump: FlowRate(
          standpipe.requiredFlow.cubicMetersPerSecond * kJockeyFlowFraction),
    },
    building: b.building,
    calibrationBySheet: b.calibrations,
    mounting: b.mounting,
  );
}

void main() {
  group('T1 — the discharge raise ends at the header', () {
    final sz = _size(buildTower());
    double q(String id) => sz[id]!.flow.inLitersPerSecond;
    double dn(String id) => sz[id]!.diameter.inMillimeters;

    test('the pump discharge to the header is the 750 gpm NFPA 20 pipe', () {
      // 500 + 250 gpm = 750 gpm = 47.3176 L/s; Table 4.28(a) 750 → DN150.
      expect(q('e_fh_FP_FH'), closeTo(47.3176, 5e-5));
      expect(dn('e_fh_FP_FH'), 150);
    });

    test('each standpipe trunk keeps its own 500 gpm at its class size', () {
      for (final id in ['e_fh_FH_Ha0', 'e_fh_FH_Hb0']) {
        // 500 gpm = 31.5451 L/s; first DN with v <= 6 m/s and >= 65 mm:
        // DN100 (4.016 m/s), never the pump's DN150 / 47.3176.
        expect(q(id), closeTo(31.5451, 5e-5), reason: id);
        expect(dn(id), 100, reason: id);
      }
    });

    test('the sprinkler feed and riser are one size and one flow', () {
      final ids = [
        'e_sp_FH_S0',
        for (var f = 1; f < kTowerFloors; f++) 'e_sp_S${f - 1}_S$f',
      ];
      final d0 = dn(ids.first);
      for (final id in ids) {
        expect(q(id), closeTo(4.7140, 5e-5), reason: id);
        expect(dn(id), d0, reason: id);
      }
    });
  });
}
