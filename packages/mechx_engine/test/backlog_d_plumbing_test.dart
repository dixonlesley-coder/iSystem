// Backlog D (2026-11-13) — plumbing / fire geometry and component modelling.
// Each group pins one item from first principles.
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/connectivity.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/apartment.dart';
import 'reference/office.dart';
import 'reference/shophouse.dart';
import 'reference/tower.dart';

const _cal = ScaleCalibration(0.02);

void main() {
  // Three storeys of 4.0 m; the ceiling main hangs 0.3 m below the slab.
  final building = BuildingLevels([
    for (var i = 0; i < 3; i++) Floor('L${i + 1}', const Length(4.0)),
  ]);

  group('D-1 — one hose-outlet height', () {
    NetNode at(String id, NodeComponent? c, int f, double x) => NetNode(
          id: id,
          sheetId: 's$f',
          x: x,
          y: 0,
          floorIndex: f,
          role: c?.role ?? NodeRole.main,
          component: c,
        );

    for (final c in [NodeComponent.hydrantBox, NodeComponent.hoseReel]) {
      test('${c.name}: elevation = floor + 1.2; leg = plan + ceiling drop',
          () {
        for (var f = 0; f < 3; f++) {
          final box = at('b', c, f, 100);
          // 4 f + kHoseOutletHeightM (1.2), the lift datum, not 4 f + 1.1.
          expect(nodeElevation(box, building).meters,
              closeTo(4.0 * f + 1.2, 1e-12));
          final net = Network(nodes: [at('m', null, f, 0), box], edges: const [
            NetEdge(
                id: 'e', fromId: 'm', toId: 'b', service: ServiceType.fireHydrant),
          ]);
          // 100 px x 0.02 = 2.0 m plan + (4 f + 3.7) − (4 f + 1.2) = 2.5 m.
          expect(
            edgeLength(net.edges.single, net,
                    calibrationBySheet: {'s$f': _cal}, building: building)
                .meters,
            closeTo(2.0 + 2.5, 1e-9),
          );
        }
      });
    }

    test('the standpipe lift reads the same height as the top box node', () {
      final nodes = [
        at('FT', NodeComponent.groundTank, 0, 0),
        at('FP', NodeComponent.pump, 0, 50),
        for (var f = 0; f < 3; f++) ...[
          at('H$f', null, f, 100),
          at('B$f', NodeComponent.hydrantBox, f, 200),
        ],
      ];
      final edges = [
        const NetEdge(
            id: 'a', fromId: 'FT', toId: 'FP', service: ServiceType.fireHydrant),
        const NetEdge(
            id: 'b', fromId: 'FP', toId: 'H0', service: ServiceType.fireHydrant),
        for (var f = 1; f < 3; f++)
          NetEdge(
              id: 'r$f',
              fromId: 'H${f - 1}',
              toId: 'H$f',
              service: ServiceType.fireHydrant,
              kind: EdgeKind.riser),
        for (var f = 0; f < 3; f++)
          NetEdge(
              id: 'l$f',
              fromId: 'H$f',
              toId: 'B$f',
              service: ServiceType.fireHydrant),
      ];
      final net = Network(nodes: nodes, edges: edges);
      final sys = fireSystems(net).single;
      final lift = sys.staticLiftM(net, building, FireTerminalKind.hydrant);
      // The pump sits on L1's slab (0.0): lift = 8.0 + 1.2 = 9.2 m, and the
      // top box node reads the same 9.2 m.
      expect(lift, closeTo(9.2, 1e-12));
      expect(nodeElevation(net.nodeById('B2')!, building).meters,
          closeTo(lift, 1e-12));
    });

    test('an explicit mounting height still wins', () {
      const box = NetNode(
        id: 'b',
        sheetId: 's0',
        x: 0,
        y: 0,
        floorIndex: 1,
        role: NodeRole.fixture,
        component: NodeComponent.hydrantBox,
        mountHeight: const Length(0.9),
      );
      expect(nodeElevation(box, building).meters, closeTo(4.9, 1e-12));
    });
  });

  group('D-2 — a sprinkler head sits at its ceiling plane', () {
    test('elevation = ceiling; a run from the ceiling main has no drop', () {
      for (var f = 0; f < 3; f++) {
        final main = NetNode(
            id: 'm', sheetId: 's$f', x: 0, y: 0, floorIndex: f);
        final head = NetNode(
          id: 'h',
          sheetId: 's$f',
          x: 150,
          y: 0,
          floorIndex: f,
          role: NodeRole.fixture,
          component: NodeComponent.sprinklerHead,
        );
        // 4 f + 4.0 − 0.3 = 4 f + 3.7 — the bare main's datum (was 4 f + 1.1).
        expect(nodeElevation(head, building).meters,
            closeTo(4.0 * f + 3.7, 1e-12));
        expect(nodeElevation(head, building).meters,
            nodeElevation(main, building).meters);
        final net = Network(nodes: [main, head], edges: const [
          NetEdge(
              id: 'e',
              fromId: 'm',
              toId: 'h',
              service: ServiceType.fireSprinkler),
        ]);
        // 150 px x 0.02 = 3.0 m, no vertical leg.
        expect(
          edgeLength(net.edges.single, net,
                  calibrationBySheet: {'s$f': _cal}, building: building)
              .meters,
          closeTo(3.0, 1e-9),
        );
      }
    });

    // The displayed head elevation in the reference buildings is the top
    // floor's ceiling (the sprinkler lift's datum): office 3 x 4.0 + 3.7 =
    // 15.7 m (was 13.1), apartment 11 x 3.5 + 3.2 = 41.7 m (was 39.6), tower
    // 29 x 4.0 + 3.7 = 119.7 m (was 117.1).
    for (final (name, build, expected) in <(String, ReferenceBuilding Function(), double)>[
      ('office', buildOffice, 15.7),
      ('apartment', buildApartment, 41.7),
      ('tower', buildTower, 119.7),
    ]) {
      test('$name: SP1..SP6 at the top ceiling ($expected m)', () {
        final b = build();
        for (var i = 1; i <= 6; i++) {
          final n = b.network.nodeById('SP$i')!;
          expect(displayedNodeElevation(b.network, n, b.building, b.mounting)
              .meters, closeTo(expected, 1e-9));
          expect(nodeElevation(n, b.building, b.mounting).meters,
              closeTo(expected, 1e-9));
        }
      });
    }
  });

  group('D-3 — a water meter sits near its floor', () {
    test('elevation = floor + kWaterMeterHeightM (0.5), not the ceiling', () {
      const m = NetNode(
        id: 'm',
        sheetId: 's1',
        x: 0,
        y: 0,
        floorIndex: 1,
        component: NodeComponent.waterMeter,
      );
      expect(kWaterMeterHeightM, 0.5);
      expect(nodeElevation(m, building).meters, closeTo(4.0 + 0.5, 1e-12));
    });

    // Every reference meter stub WM → GT: 150 px x 0.02 = 3.0 m plan + the
    // drop from the meter (0.5) to the ground tank on the L1 slab (0.0) =
    // 3.5 m. Before: 3.0 + the L1 ceiling (shophouse / office / tower 3.7,
    // apartment 3.2) = 6.7 / 6.7 / 6.7 / 6.2 m.
    for (final (name, build, stub) in <(String, ReferenceBuilding Function(), String)>[
      ('shophouse', buildShophouse, 'e_cw_${shopId('WM', 'A')}_${shopId('GT', 'A')}'),
      ('office', buildOffice, 'e_cw_WM_GT'),
      ('apartment', buildApartment, 'e_cw_WM_GT'),
      ('tower', buildTower, 'e_cw_WM_GT'),
    ]) {
      test('$name: WM → GT = 3.0 + 0.5 = 3.5 m', () {
        final b = build();
        final e = b.network.edgeById(stub)!;
        expect(
          edgeLength(e, b.network,
                  calibrationBySheet: b.calibrations,
                  building: b.building,
                  mounting: b.mounting)
              .meters,
          closeTo(3.5, 1e-9),
        );
      });
    }
  });

  group('D-5 — the flush-valve urinal', () {
    const sni = SniProfile();
    const ur = PlumbingFixture.urinalFlushValve;
    test('UBAP 5 / 5 / 6, DFU 4, DN50 trap, a flush-valve fixture', () {
      expect(sni.fixtureUnitLoad(ur), 5.0);
      expect(sni.fixtureUnitLoad(ur, occupancy: Occupancy.public), 5.0);
      expect(sni.fixtureUnitLoad(ur, occupancy: Occupancy.assembly), 6.0);
      // Never below the flush-TANK urinal it replaces (2 / 2 / 3).
      for (final o in Occupancy.values) {
        expect(sni.fixtureUnitLoad(ur, occupancy: o),
            greaterThan(sni.fixtureUnitLoad(
                PlumbingFixture.urinalFlushTank,
                occupancy: o)));
      }
      expect(drainageFixtureUnit(ur), 4);
      expect(isDn50TrapFixture(ur), isTrue);
      expect(isFlushValveFixture(ur), isTrue);
      expect(isFlushValveFixture(PlumbingFixture.waterClosetFlushValve), isTrue);
      expect(isFlushValveFixture(PlumbingFixture.urinalFlushTank), isFalse);
      expect(isWaterCloset(ur), isFalse);
    });

    test('on the valve branch: 5 UBAP → 5 x 0.88333 / 10 = 0.44167 L/s', () {
      expect(
          sni
              .probableFlowForFixtureUnits(5,
                  system: FlushSystem.flushValve)
              .inLitersPerSecond,
          closeTo(0.441665, 1e-6));
    });

    test('listed in the verify checklist (not an SNI clause)', () {
      final v = sni.verifyChecklist
          .where((x) => x.citation.contains('urinal with flushometer'));
      expect(v, hasLength(1));
      expect(v.single.status, VerificationStatus.notAnSniClause);
    });
  });

  group('D-6 — the AC orphan exemption needs the room', () {
    final net = Network(nodes: [
      for (final c in [NodeComponent.acCassette, NodeComponent.acSplitWall])
        NetNode(
            id: c.name,
            sheetId: 's0',
            x: 0,
            y: 0,
            floorIndex: 0,
            role: c.role,
            component: c),
    ]);
    Set<String> orphans(Set<String> inRooms) => {
          for (final d in networkElementDefects(net,
              selfContainedUnitsInRooms: inRooms))
            if (d.kind == NetworkElementDefectKind.orphan) d.nodeId,
        };
    test('outside a room (or no rooms passed) both units are orphans', () {
      expect(orphans(const {}), {'acCassette', 'acSplitWall'});
    });
    test('inside a room the unit is exempt', () {
      expect(orphans({'acCassette'}), {'acSplitWall'});
      expect(orphans({'acCassette', 'acSplitWall'}), isEmpty);
    });
  });
}
