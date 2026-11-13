// Reference building 5 (tower) — engine regressions for the pass-2 fixes.
//
// T1 — the NFPA 20 discharge raise ends at the discharge HEADER FH. Past it
// an outflow is discharge pipe only when its own flow is the pump's full
// rated flow (a single main). Two standpipes split the 750 gpm (47.3176
// L/s) pump flow into one 500 gpm (31.5451 L/s) trunk each, and the
// sprinkler feed carries its 4.714 L/s remote-area demand: none of the three
// header outflows is raised to the pump's DN150 / 47.3176 L/s, and the
// sprinkler riser is one size, one flow, all the way up.
//
// T2 — in a COMBINED system the sprinkler feed main (FH→S0 and the 29-storey
// riser) is enlarged one ladder step at a time until the sprinkler point no
// longer exceeds the standpipe head: DN32 (index friction 178.7 m, 303.5 m
// pump) → DN40, capped at the DN100 standpipe riser. The heads' line is not
// touched; a sprinkler-only system is unchanged; shuffling the drawing never
// changes the result.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart'
    show drainageFixtureUnit;
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart'
    show kJockeyFlowFraction;
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/fire_sprinkler_hydraulic.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/sprinkler_feed_main.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/tower.dart';

Map<String, EdgeSizing> _size(ReferenceBuilding b, [Network? drawn]) {
  final net = drawn ?? b.network;
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

  group('T2 — the combined system enlarges its sprinkler feed main', () {
    final tower = buildTower();
    final remote = remoteAreaHydraulics(
        design: designSprinklerSystem(hazard: FireHazardClass.lightHazard));
    SprinklerFeedEnlargement run(Network net) =>
        enlargeCombinedSprinklerFeedMains(
          net: net,
          sizing: _size(tower, net),
          remote: remote,
          building: tower.building,
          lengthOf: (e) => edgeLength(e, net,
                  calibrationBySheet: tower.calibrations,
                  building: tower.building,
                  mounting: tower.mounting)
              .meters,
        );
    final feedIds = {
      'e_sp_FH_S0',
      for (var f = 1; f < kTowerFloors; f++) 'e_sp_S${f - 1}_S$f',
    };

    test('DN32 → DN40 on every feed-main pipe, the heads\' line kept', () {
      final r = run(tower.network);
      expect(r.enlarged, feedIds);
      for (final id in feedIds) {
        expect(r.sizing[id]!.diameter.inMillimeters, 40, reason: id);
        expect(r.sizing[id]!.flow.inLitersPerSecond, closeTo(4.7140, 5e-5));
      }
      expect(r.sizing['e_sp_S29_SP1']!.diameter.inMillimeters, 32);
      // Index friction from FP to SP6 on the enlarged main.
      final net = tower.network;
      final sys = fireRatingSystems(net).single;
      final f = fireIndexPathFrictionM(
        net: net,
        system: sys,
        pumpId: kTowerDutyFirePump,
        sizing: r.sizing,
        lengthOf: (e) => edgeLength(e, net,
                calibrationBySheet: tower.calibrations,
                building: tower.building,
                mounting: tower.mounting)
            .meters,
        terminals: FireTerminalKind.sprinkler,
      )!;
      expect(f, closeTo(77.389, 5e-4));
    });

    test('a sprinkler-only system is unchanged', () {
      final net = tower.network;
      bool hydrant(String id) =>
          RegExp(r'^(H[ab]\d+|HYD[ab]\d+)$').hasMatch(id);
      final only = Network(nodes: [
        for (final n in net.nodes)
          if (!hydrant(n.id)) n,
      ], edges: [
        for (final e in net.edges)
          if (!hydrant(e.fromId) && !hydrant(e.toId)) e,
      ]);
      final r = run(only);
      expect(r.enlarged, isEmpty);
      final base = _size(tower, only);
      for (final id in feedIds) {
        expect(r.sizing[id]!.diameter.inMillimeters,
            base[id]!.diameter.inMillimeters,
            reason: id);
      }
    });

    test('order-independent: shuffled lists give the same sizes', () {
      final net = tower.network;
      final shuffled = Network(
        nodes: [...net.nodes.skip(41), ...net.nodes.take(41)],
        edges: [...net.edges.reversed.skip(17), ...net.edges.reversed.take(17)],
      );
      final a = run(net), b = run(shuffled);
      expect(b.enlarged, a.enlarged);
      for (final id in feedIds) {
        expect(b.sizing[id]!.diameter.inMillimeters,
            a.sizing[id]!.diameter.inMillimeters);
      }
    });
  });
}
