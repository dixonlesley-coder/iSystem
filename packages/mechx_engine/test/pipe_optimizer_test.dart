import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('stockLengthMForService', () {
    test('steel (fire) is 6 m, everything else 4 m', () {
      expect(stockLengthMForService(ServiceType.fireSprinkler), 6.0);
      expect(stockLengthMForService(ServiceType.fireHydrant), 6.0);
      expect(stockLengthMForService(ServiceType.coldWater), 4.0);
      expect(stockLengthMForService(ServiceType.drainage), 4.0);
    });
  });

  group('planStockCuts (cutting stock)', () {
    test('a single sub-stock piece uses one bar; waste is the offcut', () {
      final p = planStockCuts([2.5], 4.0);
      expect(p.fullBars, 0);
      expect(p.packedBars.length, 1);
      expect(p.totalBars, 1);
      expect(p.requiredM, closeTo(2.5, 1e-9));
      expect(p.wasteM, closeTo(1.5, 1e-9)); // 4 - 2.5
      expect(p.wastePercent, closeTo(100 * 1.5 / 4, 1e-9));
    });

    test('a run longer than a bar uses whole bars + a packed remainder', () {
      // 9 m of 4 m stock: 2 whole bars (8 m, no waste) + 1 m remainder in a 3rd.
      final p = planStockCuts([9.0], 4.0);
      expect(p.fullBars, 2);
      expect(p.packedBars.length, 1);
      expect(p.packedBars.single.pieces, [closeTo(1.0, 1e-9)]);
      expect(p.totalBars, 3);
      expect(p.wasteM, closeTo(3.0, 1e-9)); // 12 - 9
    });

    test('offcut reuse: two 1.5 m remainders share one 4 m bar', () {
      // First-fit-decreasing packs 1.5 + 1.5 into one bar (≤ 4).
      final p = planStockCuts([1.5, 1.5], 4.0);
      expect(p.fullBars, 0);
      expect(p.totalBars, 1);
      expect(p.packedBars.single.pieces.length, 2);
      expect(p.wasteM, closeTo(1.0, 1e-9)); // 4 - 3
    });

    test('two pieces that cannot combine need two bars', () {
      // 2.5 + 2.5 = 5 > 4 ⇒ two bars, 3 m total waste.
      final p = planStockCuts([2.5, 2.5], 4.0);
      expect(p.totalBars, 2);
      expect(p.wasteM, closeTo(3.0, 1e-9));
    });

    test('an exact multiple wastes nothing', () {
      final p = planStockCuts([8.0], 4.0);
      expect(p.fullBars, 2);
      expect(p.packedBars, isEmpty);
      expect(p.wasteM, closeTo(0.0, 1e-9));
    });
  });

  group('buildPipeChains (collinear merge)', () {
    // Helper: a sized cold-water run on sheet s1 floor 0.
    EdgeSizing sized(double mm, String edgeId) => EdgeSizing(
          edgeId: edgeId,
          service: ServiceType.coldWater,
          flow: const FlowRate(0.001),
          diameter: Diameter.mm(mm),
          velocity: const Velocity(1.0),
        );

    test('three collinear segments merge into ONE chain of the total length',
        () {
      // (0,0)-(100,0)-(200,0)-(300,0): straight, 3 segments, 1 chain.
      final nodes = [
        for (var i = 0; i < 4; i++)
          NetNode(id: 'n$i', sheetId: 's1', x: i * 100.0, y: 0, floorIndex: 0),
      ];
      final edges = [
        for (var i = 0; i < 3; i++)
          NetEdge(
              id: 'e$i',
              fromId: 'n$i',
              toId: 'n${i + 1}',
              service: ServiceType.coldWater),
      ];
      final net = Network(nodes: nodes, edges: edges);
      final sizing = {for (final e in edges) e.id: sized(25, e.id)};
      // 1 px = 0.05 m ⇒ each 100 px segment is 5 m, chain = 15 m.
      final chains = buildPipeChains(
        net: net,
        sizing: sizing,
        calibrationBySheet: const {'s1': ScaleCalibration(0.05)},
        building: const BuildingLevels([Floor('G', Length(3))]),
      );
      expect(chains, hasLength(1));
      expect(chains.single.lengthM, closeTo(15.0, 1e-6));
      expect(chains.single.edges, hasLength(3));
      // Arc-length coordinates run monotonically 0→15 across the chain.
      final offs = chains.single.edges
          .map((e) => [e.offsetAtFromM, e.offsetAtToM])
          .expand((x) => x)
          .toList();
      expect(offs.reduce((a, b) => a < b ? a : b), closeTo(0, 1e-6));
      expect(offs.reduce((a, b) => a > b ? a : b), closeTo(15, 1e-6));
    });

    test('a right-angle bend breaks the chain in two', () {
      // (0,0)-(100,0)-(100,100): an L ⇒ two chains.
      const net = Network(
        nodes: const [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
          NetNode(id: 'c', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
        ],
        edges: const [
          NetEdge(id: 'e0', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
          NetEdge(id: 'e1', fromId: 'b', toId: 'c', service: ServiceType.coldWater),
        ],
      );
      final sizing = {'e0': sized(25, 'e0'), 'e1': sized(25, 'e1')};
      final chains = buildPipeChains(
        net: net,
        sizing: sizing,
        calibrationBySheet: const {'s1': ScaleCalibration(0.05)},
        building: const BuildingLevels([Floor('G', Length(3))]),
      );
      expect(chains, hasLength(2));
    });

    test('a tee (branch) breaks the chain at the junction', () {
      // Straight main a-b-c with a branch b-d ⇒ b is a 3-way, not a pass-through.
      const net = Network(
        nodes: const [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
          NetNode(id: 'c', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
          NetNode(id: 'd', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
        ],
        edges: const [
          NetEdge(id: 'e0', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
          NetEdge(id: 'e1', fromId: 'b', toId: 'c', service: ServiceType.coldWater),
          NetEdge(id: 'e2', fromId: 'b', toId: 'd', service: ServiceType.coldWater),
        ],
      );
      final sizing = {'e0': sized(25, 'e0'), 'e1': sized(25, 'e1'), 'e2': sized(25, 'e2')};
      final chains = buildPipeChains(
        net: net,
        sizing: sizing,
        calibrationBySheet: const {'s1': ScaleCalibration(0.05)},
        building: const BuildingLevels([Floor('G', Length(3))]),
      );
      // Each of the three legs is its own chain (no straight pass-through at b).
      expect(chains, hasLength(3));
    });

    test('buildPipeCutPlan groups chains by service + diameter', () {
      // Two separate straight cold-water mains, 13 m and 5 m, same DN.
      const net = Network(
        nodes: const [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 260, y: 0, floorIndex: 0), // 13 m
          NetNode(id: 'c', sheetId: 's1', x: 0, y: 50, floorIndex: 0),
          NetNode(id: 'd', sheetId: 's1', x: 100, y: 50, floorIndex: 0), // 5 m
        ],
        edges: const [
          NetEdge(id: 'e0', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
          NetEdge(id: 'e1', fromId: 'c', toId: 'd', service: ServiceType.coldWater),
        ],
      );
      final sizing = {'e0': sized(25, 'e0'), 'e1': sized(25, 'e1')};
      final chains = buildPipeChains(
        net: net,
        sizing: sizing,
        calibrationBySheet: const {'s1': ScaleCalibration(0.05)},
        building: const BuildingLevels([Floor('G', Length(3))]),
      );
      final plan = buildPipeCutPlan(chains);
      expect(plan, hasLength(1)); // one (coldWater, DN25) group
      final g = plan.single;
      expect(g.stockLengthM, 4.0);
      // 13 m ⇒ 3 full bars + 1 m remainder; 5 m ⇒ 1 full bar + 1 m remainder;
      // the two 1 m remainders share one bar ⇒ 4 + 1 = 5 bars.
      expect(g.plan.fullBars, 4);
      expect(g.plan.totalBars, 5);
      expect(g.plan.requiredM, closeTo(18.0, 1e-6));
      expect(g.plan.wasteM, closeTo(2.0, 1e-6)); // 20 - 18
    });
  });
}
