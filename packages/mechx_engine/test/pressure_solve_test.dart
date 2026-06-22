import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Pressure-solve correctness anchors. Expected friction/elevation/residual are
/// derived from the engine's own primitives (edgeLength, headLossHazenWilliams,
/// nodeElevation — each independently unit-tested) so the solve is checked on
/// what it must do: SUM friction + static-lift + target-residual along the tree.
/// Static lift and riser length use TRUE elevations (ceiling-level mains).
void main() {
  // Building: floor 0 is 4.0 m high, floor 1 is 3.0 m high, floor 2 is 3.0 m.
  //   floor surfaces: elevationOf(0)=0, (1)=4, (2)=7 m.
  //   ceiling mains:  ceiling(0)=3.7, ceiling(2)= 7+3−0.3 = 9.7 m.
  const building = BuildingLevels([
    Floor('G', Length(4.0)),
    Floor('L1', Length(3.0)),
    Floor('L2', Length(3.0)),
  ]);

  // 0.1 m per pixel → the 500-px run s→n1 is exactly 50 m of pipe.
  const calibration = <String, ScaleCalibration>{'s1': ScaleCalibration(0.1)};

  // Min faucet residual: 0.50 kgf/cm² = 49 033.25 Pa (= 4.9982925586 m head).
  const targetResidual = Pressure(49033.25);

  group('solvePressurized — three-node tree (run + riser)', () {
    // s (floor 0) --e1 (run, 50 m)--> n1 (floor 0) --r1 (riser, 6 m)--> n2 (floor 2)
    const net = Network(
      nodes: [
        NetNode(id: 's', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'n1', sheetId: 's1', x: 500, y: 0, floorIndex: 0),
        NetNode(id: 'n2', sheetId: 's1', x: 500, y: 0, floorIndex: 2),
      ],
      edges: [
        NetEdge(id: 'e1', fromId: 's', toId: 'n1', service: ServiceType.coldWater),
        NetEdge(
          id: 'r1',
          fromId: 'n1',
          toId: 'n2',
          service: ServiceType.coldWater,
          kind: EdgeKind.riser,
        ),
      ],
    );

    // 5 L/s through both edges, DN65 (0.065 m) PVC (C = 150).
    const flow = FlowRate(0.005);
    const edgeFlows = <String, FlowRate>{'e1': flow, 'r1': flow};
    final sizing = <String, EdgeSizing>{
      'e1': const EdgeSizing(
        edgeId: 'e1',
        service: ServiceType.coldWater,
        flow: flow,
        diameter: Diameter(0.065),
        velocity: Velocity(1.507),
      ),
      'r1': const EdgeSizing(
        edgeId: 'r1',
        service: ServiceType.coldWater,
        flow: flow,
        diameter: Diameter(0.065),
        velocity: Velocity(1.507),
      ),
    };

    // ── Engine-derived reference values ─────────────────────────────────────
    // Friction from the same Hazen–Williams kernel the solve uses (PVC C=150);
    // static lift from TRUE (ceiling-main) elevations. The riser r1 spans
    // ceiling(0)=3.7 → ceiling(2)=9.7 = 6.0 m, so elevation gain @ n2 is 6.0 m.
    final hwC = const SniProfile().hazenWilliamsC(PipeMaterial.pvc);
    const dn65 = Diameter(0.065);
    final lenE1 = edgeLength(net.edges[0], net,
        calibrationBySheet: calibration, building: building);
    final lenR1 = edgeLength(net.edges[1], net,
        calibrationBySheet: calibration, building: building);
    final hfE1 = headLossHazenWilliams(
            flow: flow, length: lenE1, diameter: dn65, hazenWilliamsC: hwC)
        .meters;
    final hfR1 = headLossHazenWilliams(
            flow: flow, length: lenR1, diameter: dn65, hazenWilliamsC: hwC)
        .meters;
    final elevGainN2 = nodeElevation(net.nodes[2], building).meters -
        nodeElevation(net.nodes[0], building).meters; // 6.0 m
    final targetHead = headFromPressure(targetResidual).meters;
    final pumpHead = hfE1 + hfR1 + elevGainN2 + targetHead;

    test('requiredPumpHead is set by the highest/furthest node', () {
      final sol = solvePressurized(
        net: net,
        service: ServiceType.coldWater,
        sourceId: 's',
        edgeFlows: edgeFlows,
        sizing: sizing,
        calibrationBySheet: calibration,
        building: building,
        targetResidual: targetResidual,
      );
      expect(sol.requiredPumpHead.meters, closeTo(pumpHead, 1e-6));
      expect(sol.criticalNodeId, 'n2');
    });

    test('critical node residual ≈ target; nearer nodes see more', () {
      final sol = solvePressurized(
        net: net,
        service: ServiceType.coldWater,
        sourceId: 's',
        edgeFlows: edgeFlows,
        sizing: sizing,
        calibrationBySheet: calibration,
        building: building,
        targetResidual: targetResidual,
      );

      // n2 (critical): residual ≈ targetResidual exactly.
      expect(
        sol.residualPressure['n2']!.pascals,
        closeTo(targetResidual.pascals, 1e-3),
      );

      // n1: residual = pump − h_f(e1) − 0 (n1 is at the source's elevation).
      expect(
        sol.residualPressure['n1']!.pascals,
        closeTo(pressureFromHead(Head(pumpHead - hfE1)).pascals, 1e-2),
      );
      expect(sol.residualPressure['n1']!.pascals,
          greaterThan(targetResidual.pascals));

      // source: residual = full pump head as pressure (no friction, no lift).
      expect(
        sol.residualPressure['s']!.pascals,
        closeTo(pressureFromHead(Head(pumpHead)).pascals, 1e-2),
      );
      expect(sol.residualPressure['s']!.pascals,
          greaterThan(targetResidual.pascals));
    });

    test('every reachable node (incl. source) has a residual', () {
      final sol = solvePressurized(
        net: net,
        service: ServiceType.coldWater,
        sourceId: 's',
        edgeFlows: edgeFlows,
        sizing: sizing,
        calibrationBySheet: calibration,
        building: building,
        targetResidual: targetResidual,
      );
      expect(sol.residualPressure.keys, containsAll(<String>['s', 'n1', 'n2']));
      expect(sol.residualPressure.length, 3);
    });

    test('an unsized edge contributes zero friction (skipped)', () {
      // Drop r1's sizing: the riser then adds NO friction, but its elevation
      // gain (via floorIndex) still applies. pump head loses only h_f(r1).
      final partialSizing = <String, EdgeSizing>{'e1': sizing['e1']!};
      final sol = solvePressurized(
        net: net,
        service: ServiceType.coldWater,
        sourceId: 's',
        edgeFlows: edgeFlows,
        sizing: partialSizing,
        calibrationBySheet: calibration,
        building: building,
        targetResidual: targetResidual,
      );
      expect(
        sol.requiredPumpHead.meters,
        closeTo(pumpHead - hfR1, 1e-6),
      );
      expect(sol.criticalNodeId, 'n2');
    });
  });

  group('solvePressurized — degenerate cases', () {
    test('single source node only → pump head == target residual', () {
      const net = Network(
        nodes: [
          NetNode(id: 's', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        ],
      );
      final sol = solvePressurized(
        net: net,
        service: ServiceType.coldWater,
        sourceId: 's',
        edgeFlows: const <String, FlowRate>{},
        sizing: const <String, EdgeSizing>{},
        calibrationBySheet: calibration,
        building: building,
        targetResidual: targetResidual,
      );
      // No friction, no lift → pump need == target-as-head; only node is source.
      expect(
        sol.requiredPumpHead.meters,
        closeTo(targetResidual.pascals / (1000.0 * 9.81), 1e-9),
      );
      expect(sol.criticalNodeId, 's');
      expect(
        sol.residualPressure['s']!.pascals,
        closeTo(targetResidual.pascals, 1e-6),
      );
      expect(sol.residualPressure.length, 1);
    });

    test('edges of other services are ignored', () {
      // A drainage edge hangs off the source; the cold-water solve must not
      // traverse it, so only the source is reachable.
      const net = Network(
        nodes: [
          NetNode(id: 's', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'd', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
        ],
        edges: [
          NetEdge(id: 'dx', fromId: 's', toId: 'd', service: ServiceType.drainage),
        ],
      );
      final sol = solvePressurized(
        net: net,
        service: ServiceType.coldWater,
        sourceId: 's',
        edgeFlows: const <String, FlowRate>{},
        sizing: const <String, EdgeSizing>{},
        calibrationBySheet: calibration,
        building: building,
        targetResidual: targetResidual,
      );
      expect(sol.residualPressure.keys, <String>['s']);
      expect(sol.criticalNodeId, 's');
    });
  });

  // ── Gravity downfeed (roof-tank strategy) ─────────────────────────────────
  group('solveDownfeed — roof tank gravity distribution', () {
    // tank (plant, roof = 10 m) --r (riser down)--> main on floor 2 ceiling
    // (9.7 m) --run--> a far fixture. Gravity head available shrinks as you
    // rise toward the tank, so the TOP node is worst-served.
    const tank = NetNode(
        id: 'tank', sheetId: 's1', x: 0, y: 0, floorIndex: 2,
        role: NodeRole.plant); // roof = totalHeight = 10 m
    const topMain =
        NetNode(id: 'm2', sheetId: 's1', x: 0, y: 0, floorIndex: 2); // 9.7 m
    const lowMain =
        NetNode(id: 'm0', sheetId: 's1', x: 0, y: 0, floorIndex: 0); // 3.7 m
    const net = Network(
      nodes: [tank, topMain, lowMain],
      edges: [
        NetEdge(
            id: 'dt', fromId: 'tank', toId: 'm2',
            service: ServiceType.coldWater, kind: EdgeKind.riser),
        NetEdge(
            id: 'dr', fromId: 'm2', toId: 'm0',
            service: ServiceType.coldWater, kind: EdgeKind.riser),
      ],
    );

    test('frictionless: residual = gravity head below the tank', () {
      // No sizing → zero friction. Tank at roof 10 m, outlet head 0.
      final sol = solveDownfeed(
        net: net,
        service: ServiceType.coldWater,
        tankId: 'tank',
        edgeFlows: const {},
        sizing: const {},
        calibrationBySheet: calibration,
        building: building,
        targetResidual: targetResidual,
      );
      // m2 at 9.7 m → head 0.3 m; m0 at 3.7 m → head 6.3 m.
      expect(sol.residualPressure['m2']!.pascals,
          closeTo(pressureFromHead(const Head(0.3)).pascals, 1e-3));
      expect(sol.residualPressure['m0']!.pascals,
          closeTo(pressureFromHead(const Head(6.3)).pascals, 1e-3));
      // Worst-served is the top main (least gravity head).
      expect(sol.criticalNodeId, 'm2');
    });

    test('booster head = shortfall of the critical node vs target', () {
      final sol = solveDownfeed(
        net: net,
        service: ServiceType.coldWater,
        tankId: 'tank',
        edgeFlows: const {},
        sizing: const {},
        calibrationBySheet: calibration,
        building: building,
        targetResidual: targetResidual,
      );
      // target head ≈ 4.998 m; top main only has 0.3 m by gravity →
      // booster ≈ 4.698 m. Gravity is NOT sufficient here.
      final targetHead = headFromPressure(targetResidual).meters;
      expect(sol.boosterHeadRequired.meters, closeTo(targetHead - 0.3, 1e-3));
      expect(sol.gravitySufficient, isFalse);
    });

    test('a high enough tank head makes gravity sufficient', () {
      final sol = solveDownfeed(
        net: net,
        service: ServiceType.coldWater,
        tankId: 'tank',
        edgeFlows: const {},
        sizing: const {},
        calibrationBySheet: calibration,
        building: building,
        targetResidual: targetResidual,
        tankStaticHead: const Head(10), // a tall tank / booster head allowance
      );
      // top main now has 0.3 + 10 = 10.3 m ≥ target → no booster needed.
      expect(sol.gravitySufficient, isTrue);
      expect(sol.boosterHeadRequired.meters, 0);
    });
  });
}
