import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
import 'package:mechx_engine/standards/duct_products.dart';
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

  group('duct sections (BJLS / PU)', () {
    test('ductSectionLengthM: BJLS (and null) 1.2 m, PU 4 m', () {
      expect(ductSectionLengthM(DuctProduct.bjls), 1.2);
      expect(ductSectionLengthM(DuctProduct.pu), 4.0);
      expect(ductSectionLengthM(null), 1.2);
    });

    test('stockLengthForEdge: pipe by service, duct by service-default product',
        () {
      NetEdge e(ServiceType s, {DuctProduct? d}) =>
          NetEdge(id: 'e', fromId: 'a', toId: 'b', service: s, ductProduct: d);
      expect(stockLengthForEdge(e(ServiceType.coldWater)), 4.0);
      expect(stockLengthForEdge(e(ServiceType.fireSprinkler)), 6.0);
      // AC supply/return default to PU (4 m); exhaust to BJLS (1.2 m).
      expect(stockLengthForEdge(e(ServiceType.duct)), 4.0); // null ⇒ PU
      expect(stockLengthForEdge(e(ServiceType.returnAir)), 4.0); // null ⇒ PU
      expect(stockLengthForEdge(e(ServiceType.exhaust)), 1.2); // null ⇒ BJLS
      // An explicit product overrides the service default.
      expect(stockLengthForEdge(e(ServiceType.duct, d: DuctProduct.bjls)), 1.2);
      expect(stockLengthForEdge(e(ServiceType.exhaust, d: DuctProduct.pu)), 4.0);
    });

    EdgeSizing ductSized(double mm, String id) => EdgeSizing(
          edgeId: id,
          service: ServiceType.duct,
          flow: const FlowRate(0.05),
          diameter: Diameter.mm(mm),
          velocity: const Velocity(4.0),
        );

    test('an exhaust duct defaults to BJLS, sectioned at 1.2 m', () {
      // 120 px x 0.05 = 6 m straight exhaust duct, default product (BJLS).
      const net = Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 120, y: 0, floorIndex: 0),
        ],
        edges: [
          NetEdge(
              id: 'e0', fromId: 'a', toId: 'b', service: ServiceType.exhaust),
        ],
      );
      final chains = buildPipeChains(
        net: net,
        sizing: {'e0': ductSized(300, 'e0')},
        calibrationBySheet: const {'s1': ScaleCalibration(0.05)},
        building: const BuildingLevels([Floor('G', Length(3))]),
      );
      final plan = buildPipeCutPlan(chains);
      expect(plan.single.stockLengthM, 1.2);
      // 6 m / 1.2 m = exactly 5 sections, no waste.
      expect(plan.single.plan.totalBars, 5);
      expect(plan.single.plan.wasteM, closeTo(0.0, 1e-6));
    });

    test('an AC supply duct defaults to PU, sectioned at 4 m (offcut waste)',
        () {
      // No explicit product → supply defaults to PU panel (4 m sections).
      const net = Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 120, y: 0, floorIndex: 0),
        ],
        edges: [
          NetEdge(id: 'e0', fromId: 'a', toId: 'b', service: ServiceType.duct),
        ],
      );
      final chains = buildPipeChains(
        net: net,
        sizing: {'e0': ductSized(300, 'e0')},
        calibrationBySheet: const {'s1': ScaleCalibration(0.05)},
        building: const BuildingLevels([Floor('G', Length(3))]),
      );
      final plan = buildPipeCutPlan(chains);
      expect(plan.single.stockLengthM, 4.0);
      // 6 m ⇒ 1 full 4 m panel + a 2 m remainder ⇒ 2 sections, 2 m waste.
      expect(plan.single.plan.fullBars, 1);
      expect(plan.single.plan.totalBars, 2);
      expect(plan.single.plan.wasteM, closeTo(2.0, 1e-6));
    });
  });

  group('duct sheet-material takeoff', () {
    test('ductSheetAreaM2: BJLS 4x8 ft sheet, PU 1.2x4 m panel', () {
      expect(ductSheetAreaM2(DuctProduct.bjls), closeTo(1.22 * 2.44, 1e-9));
      expect(ductSheetAreaM2(DuctProduct.pu), closeTo(4.8, 1e-9));
    });

    test('rectangular exhaust (BJLS): developed area = perimeter x length', () {
      const e =
          NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.exhaust);
      const s = EdgeSizing(
        edgeId: 'e',
        service: ServiceType.exhaust,
        flow: FlowRate(0.5),
        diameter: Diameter(0.38),
        velocity: Velocity(5),
        width: Length(0.4),
        height: Length(0.3),
      );
      final t = ductSheetTakeoff(e, s, 10.0)!;
      expect(t.product, DuctProduct.bjls);
      // 2·(0.4+0.3)·10 = 14 m²; ceil(14 / 2.9768) = 5 sheets.
      expect(t.developedAreaM2, closeTo(14.0, 1e-6));
      expect(t.sheets, 5);
      expect(t.sheetAreaM2, closeTo(2.9768, 1e-6));
    });

    test('round supply (PU): developed area = πD x length, panels', () {
      const e =
          NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.duct);
      const s = EdgeSizing(
        edgeId: 'e',
        service: ServiceType.duct,
        flow: FlowRate(0.5),
        diameter: Diameter(0.4),
        velocity: Velocity(5),
      );
      final t = ductSheetTakeoff(e, s, 10.0)!;
      expect(t.product, DuctProduct.pu);
      expect(t.developedAreaM2, closeTo(math.pi * 0.4 * 10, 1e-6));
      // ceil(12.566 / 4.8) = 3 panels.
      expect(t.sheets, 3);
      expect(t.thicknessMm, 20); // PU panel default
    });

    test('a pipe segment has no duct takeoff', () {
      const e = NetEdge(
          id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater);
      const s = EdgeSizing(
        edgeId: 'e',
        service: ServiceType.coldWater,
        flow: FlowRate(0.5),
        diameter: Diameter(0.025),
        velocity: Velocity(1.5),
      );
      expect(ductSheetTakeoff(e, s, 5.0), isNull);
    });
  });
}
