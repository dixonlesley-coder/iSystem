/// Round 27 — engine fixes outside the network sizer:
///
/// * hvac-4-1 — an AHU's outdoor-air intake is in SERIES with the supply
///   index run through the fan: the fan static is the SUM of the two path
///   frictions (+ the terminal loss), never their maximum.
/// * hvac-4-4 — a room trunk clamped over capacity is reported
///   (`RoomAirResult.trunkOverCapacity`), never silently "sized".
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/duct_static.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/duct_sizing.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _an(String id, double x, double y,
        {NodeRole role = NodeRole.main, NodeComponent? c, FlowRate? q}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: 0,
        role: role,
        component: c,
        airflow: q);

void main() {
  group('hvac-4-1 — AHU intake + supply in series through the fan', () {
    const building = BuildingLevels([Floor('L1', Length(3.0))]);
    const cal = {'s1': ScaleCalibration(0.01)};
    const q = FlowRate(0.5);

    /// AHU u -> j (10 m) -> d1 / d2 (500 L/s each); [intakePx] > 0 adds the
    /// outdoor-air leaf oa -> u of that pixel length (0.01 m/px).
    Network build({double intakePx = 0}) => Network(nodes: [
          _an('u', 0, 0, role: NodeRole.plant, c: NodeComponent.ahu),
          _an('j', 1000, 0),
          _an('d1', 1200, -100,
              role: NodeRole.fixture, c: NodeComponent.supplyDiffuser, q: q),
          _an('d2', 1200, 100,
              role: NodeRole.fixture, c: NodeComponent.supplyDiffuser, q: q),
          if (intakePx > 0) _an('oa', -intakePx, 0),
        ], edges: [
          const NetEdge(id: 'e1', fromId: 'u', toId: 'j', service: ServiceType.duct),
          const NetEdge(id: 'j1', fromId: 'j', toId: 'd1', service: ServiceType.duct),
          const NetEdge(id: 'j2', fromId: 'j', toId: 'd2', service: ServiceType.duct),
          if (intakePx > 0)
            const NetEdge(
                id: 'oa1', fromId: 'oa', toId: 'u', service: ServiceType.duct),
        ]);

    DuctStaticSolution solve(Network net, Map<String, EdgeSizing> s) =>
        solveDuctStatic(
          net: net,
          service: ServiceType.duct,
          fanNodeId: 'u',
          edgeFlows: {for (final e in s.entries) e.key: e.value.flow},
          sizing: s,
          calibrationBySheet: cal,
          building: building,
        );

    test('static = supply index + intake path + terminal (hand-derived)', () {
      for (final px in [3000.0, 6000.0]) {
        final net = build(intakePx: px);
        final s = autoSizeNetwork(net, const SizingContext(),
            leafDemand: const {ServiceType.duct: FlowRate(0)},
            nodeFlowDemand: const {'d1': q, 'd2': q},
            building: building,
            calibrationBySheet: cal);
        // The intake is sized on the delivered 1.0 m3/s, flowing INTO u.
        expect(s['oa1']!.flow.cubicMetersPerSecond, closeTo(1.0, 1e-12));
        expect(s['oa1']!.flowFromId, 'oa');
        final withIntake = solve(net, s);
        final supplyOnly = solve(build(), {
          for (final e in s.entries)
            if (e.key != 'oa1') e.key: e.value,
        });
        // The intake path friction from first principles: Darcy (PU duct)
        // per metre x its §10 length x the 1.3 fitting factor.
        final oa = s['oa1']!;
        final len = edgeLength(net.edgeById('oa1')!, net,
            calibrationBySheet: cal, building: building);
        final intakePa = ductFrictionPaPerMetre(oa.flow, oa.diameter,
                roughness: ductRoughnessFor(DuctProduct.pu)) *
            len.meters *
            1.3;
        // Plan span px x 0.01 m, plus the §10 vertical leg from the AHU on
        // its floor surface to the bare intake leaf at the ceiling.
        expect(len.meters, greaterThanOrEqualTo(px * 0.01));
        expect(withIntake.totalStaticPressure.pascals,
            closeTo(supplyOnly.totalStaticPressure.pascals + intakePa, 1e-9),
            reason: 'px=$px');
        // Never the max of the two (the old reading).
        final index = supplyOnly.totalStaticPressure.pascals - 30;
        expect(withIntake.totalStaticPressure.pascals,
            greaterThan(30 + math.max(index, intakePa) + 1e-6));
      }
    });

    test('no intake drawn => byte-identical supply static', () {
      final net = build();
      final s = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.duct: FlowRate(0)},
          nodeFlowDemand: const {'d1': q, 'd2': q},
          building: building,
          calibrationBySheet: cal);
      final sol = solve(net, s);
      // Index: e1 then the longer of j1 / j2 (equal) + 30 Pa terminal.
      double pa(String id) {
        final e = s[id]!;
        return ductFrictionPaPerMetre(e.flow, e.diameter,
                roughness: ductRoughnessFor(DuctProduct.pu)) *
            edgeLength(net.edgeById(id)!, net,
                    calibrationBySheet: cal, building: building)
                .meters *
            1.3;
      }

      expect(sol.totalStaticPressure.pascals,
          closeTo(30 + pa('e1') + math.max(pa('j1'), pa('j2')), 1e-9));
    });
  });

  group('hvac-4-4 — a clamped room trunk is flagged', () {
    test('1200 m2 x 10 m x 6 ACH atrium: 20 m3/s over the largest duct', () {
      // Q = 1200 x 10 x 6 / 3600 = 20 m3/s; the largest round duct (1000 mm)
      // runs at v = 20 / (pi x 0.5^2) = 25.46 m/s => clamped.
      final r = sizeRoomAir(
          floorArea: const Area(1200),
          ceilingHeight: const Length(10),
          airChangesPerHour: 6,
          equipmentKind: AirEquipmentKind.ahu);
      expect(r.airflow.cubicMetersPerSecond, closeTo(20, 1e-12));
      expect(r.supplyDuctVelocity.metersPerSecond,
          closeTo(20 / (math.pi * 0.25), 1e-6));
      expect(r.trunkOverCapacity, isTrue);
      // An ordinary office is in range.
      final ok = sizeRoomAir(
          floorArea: const Area(50),
          ceilingHeight: const Length(3),
          airChangesPerHour: 6,
          equipmentKind: AirEquipmentKind.ahu);
      expect(ok.trunkOverCapacity, isFalse);
    });
  });
}
