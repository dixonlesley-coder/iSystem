import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Pressure-solve correctness anchors. Every expected number is hand-computed
/// from Hazen–Williams (SI) + static-lift + target-residual, then checked with
/// `closeTo`. Hazen–Williams (SI, water):
///   h_f = 10.67 · L · Q^1.852 / (C^1.852 · D^4.8704).
void main() {
  // Building: floor 0 is 4.0 m high, floor 1 is 3.0 m high, floor 2 is 3.0 m.
  //   elevationOf(0) = 0 m, elevationOf(1) = 4 m, elevationOf(2) = 7 m.
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
    // s (floor 0) --e1 (run, 50 m)--> n1 (floor 0) --r1 (riser, 7 m)--> n2 (floor 2)
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

    // ── Hand-computed reference values ──────────────────────────────────────
    // h_f(e1, L=50 m) = 1.6485140307 m
    // h_f(r1, L= 7 m) = 0.2307919643 m
    // elevation gain: s=0, n1=0, n2 = elevationOf(2)-elevationOf(0) = 7 m
    // target head    = 49 033.25 / (1000·9.81) = 4.9982925586 m
    // required head @ s  = 0      + 0 + 4.9982925586 =  4.9982925586 m
    // required head @ n1 = 1.6485 + 0 + 4.9982925586 =  6.6468065893 m
    // required head @ n2 = 1.8793 + 7 + 4.9982925586 = 13.8775985536 m  ← max
    const hfE1 = 1.6485140307;
    const hfR1 = 0.2307919643;
    const targetHead = 4.9982925586;
    const pumpHead = hfE1 + hfR1 + 7.0 + targetHead; // 13.8775985536

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

      // n1: residual = pump - h_f(e1) - 0, as pressure.
      //   = (13.8775985536 - 1.6485140307) m · 1000 · 9.81
      //   = 12.2290845229 m → 119 967.319 Pa
      expect(
        sol.residualPressure['n1']!.pascals,
        closeTo(119967.319, 1e-2),
      );
      expect(sol.residualPressure['n1']!.pascals,
          greaterThan(targetResidual.pascals));

      // source: residual = pump - 0 - 0 = full pump head as pressure.
      //   = 13.8775985536 m · 1000 · 9.81 = 136 139.242 Pa
      expect(
        sol.residualPressure['s']!.pascals,
        closeTo(136139.242, 1e-2),
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
}
