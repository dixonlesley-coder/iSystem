import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
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

  // ── Per-edge pipe-material fold (NetEdge.pipeProduct → Hazen–Williams C) ────
  //
  // A two-edge supply tree: s --e1 (run, 50 m)--> n1 --r1 (riser, 6 m)--> n2.
  // Both DN65, 5 L/s. The fold swaps ONLY the Hazen–Williams C per edge:
  //   • no product set      → service-wide C (PVC C=150) — byte-identical today.
  //   • castIron on e1      → e1 uses C=110 (rougher) → MORE friction.
  //   • a C=150 product     → equals the default PVC C=150 exactly.
  group('per-edge pipeProduct folds into the Hazen–Williams C', () {
    const flow = FlowRate(0.005);
    const dn65 = Diameter(0.065);
    const edgeFlows = <String, FlowRate>{'e1': flow, 'r1': flow};
    final sizing = <String, EdgeSizing>{
      'e1': const EdgeSizing(
        edgeId: 'e1',
        service: ServiceType.coldWater,
        flow: flow,
        diameter: dn65,
        velocity: Velocity(1.507),
      ),
      'r1': const EdgeSizing(
        edgeId: 'r1',
        service: ServiceType.coldWater,
        flow: flow,
        diameter: dn65,
        velocity: Velocity(1.507),
      ),
    };

    // Build a net whose e1 optionally carries a pipe product.
    Network netWith({PipeProduct? e1Product}) => Network(
          nodes: const [
            NetNode(id: 's', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            NetNode(id: 'n1', sheetId: 's1', x: 500, y: 0, floorIndex: 0),
            NetNode(id: 'n2', sheetId: 's1', x: 500, y: 0, floorIndex: 2),
          ],
          edges: [
            NetEdge(
              id: 'e1',
              fromId: 's',
              toId: 'n1',
              service: ServiceType.coldWater,
              pipeProduct: e1Product,
            ),
            const NetEdge(
              id: 'r1',
              fromId: 'n1',
              toId: 'n2',
              service: ServiceType.coldWater,
              kind: EdgeKind.riser,
            ),
          ],
        );

    PressureSolution solve(Network net) => solvePressurized(
          net: net,
          service: ServiceType.coldWater,
          sourceId: 's',
          edgeFlows: edgeFlows,
          sizing: sizing,
          calibrationBySheet: calibration,
          building: building,
          targetResidual: targetResidual,
        );

    test('no product set → byte-identical to the service-wide C default', () {
      // The default-path solve (param material = PVC) vs the same net with no
      // edge products — every node residual + pump head must match exactly.
      final plain = solve(netWith());
      final noProduct = solve(netWith(e1Product: null));
      expect(noProduct.requiredPumpHead.meters,
          equals(plain.requiredPumpHead.meters));
      expect(noProduct.criticalNodeId, plain.criticalNodeId);
      for (final id in const ['s', 'n1', 'n2']) {
        expect(noProduct.residualPressure[id]!.pascals,
            equals(plain.residualPressure[id]!.pascals));
      }
    });

    test('a lower-C product on e1 (cast iron, C≈110) raises friction', () {
      final plain = solve(netWith()); // PVC C=150 default
      final cast = solve(netWith(e1Product: PipeProduct.castIron));

      // Cast iron is rougher → strictly higher required pump head.
      expect(cast.requiredPumpHead.meters,
          greaterThan(plain.requiredPumpHead.meters));

      // The required pump head with cast iron equals: hand-computed
      // h_f(e1 @ C=110) + h_f(r1 @ PVC 150) + elevation gain @ n2 + target head.
      final cElev = nodeElevation(netWith().nodes[2], building).meters -
          nodeElevation(netWith().nodes[0], building).meters; // 6.0 m
      final lenE1 = edgeLength(netWith().edges[0], netWith(),
          calibrationBySheet: calibration, building: building);
      final lenR1 = edgeLength(netWith().edges[1], netWith(),
          calibrationBySheet: calibration, building: building);
      final cCast = hazenWilliamsCFor(PipeProduct.castIron); // 110
      final cPvc = const SniProfile().hazenWilliamsC(PipeMaterial.pvc); // 150
      final hfE1 = headLossHazenWilliams(
              flow: flow, length: lenE1, diameter: dn65, hazenWilliamsC: cCast)
          .meters;
      final hfR1 = headLossHazenWilliams(
              flow: flow, length: lenR1, diameter: dn65, hazenWilliamsC: cPvc)
          .meters;
      final targetHead = headFromPressure(targetResidual).meters;
      expect(cast.requiredPumpHead.meters,
          closeTo(hfE1 + hfR1 + cElev + targetHead, 1e-9));
    });

    test('a C=150 product (PPR PN16) equals the default PVC C=150', () {
      // PPR PN16 has HW-C=150, the same as the PVC service default, so the
      // per-edge C swap is a no-op: identical result.
      expect(hazenWilliamsCFor(PipeProduct.pprPn16),
          const SniProfile().hazenWilliamsC(PipeMaterial.pvc));
      final plain = solve(netWith());
      final ppr = solve(netWith(e1Product: PipeProduct.pprPn16));
      expect(ppr.requiredPumpHead.meters,
          closeTo(plain.requiredPumpHead.meters, 1e-12));
    });
  });

  // ── Per-edge pipe-material fold in the gravity DOWNFEED solve ───────────────
  group('per-edge pipeProduct folds into solveDownfeed friction', () {
    const flow = FlowRate(0.005);
    const dn65 = Diameter(0.065);
    // tank (roof) --dt (riser)--> m2, with a 50 m horizontal run dr to a far
    // fixture m0r where the per-edge product is applied (a sized run carries
    // friction; a riser of equal-elevation nodes would not).
    Network netWith({PipeProduct? runProduct}) => Network(
          nodes: const [
            NetNode(
                id: 'tank',
                sheetId: 's1',
                x: 0,
                y: 0,
                floorIndex: 2,
                role: NodeRole.plant),
            NetNode(id: 'm2', sheetId: 's1', x: 0, y: 0, floorIndex: 2),
            NetNode(id: 'm0r', sheetId: 's1', x: 500, y: 0, floorIndex: 2),
          ],
          edges: [
            const NetEdge(
                id: 'dt',
                fromId: 'tank',
                toId: 'm2',
                service: ServiceType.coldWater,
                kind: EdgeKind.riser),
            NetEdge(
              id: 'dr',
              fromId: 'm2',
              toId: 'm0r',
              service: ServiceType.coldWater,
              pipeProduct: runProduct,
            ),
          ],
        );
    const edgeFlows = <String, FlowRate>{'dt': flow, 'dr': flow};
    final sizing = <String, EdgeSizing>{
      'dr': const EdgeSizing(
        edgeId: 'dr',
        service: ServiceType.coldWater,
        flow: flow,
        diameter: dn65,
        velocity: Velocity(1.507),
      ),
    };

    DownfeedSolution solve(Network net) => solveDownfeed(
          net: net,
          service: ServiceType.coldWater,
          tankId: 'tank',
          edgeFlows: edgeFlows,
          sizing: sizing,
          calibrationBySheet: calibration,
          building: building,
          targetResidual: targetResidual,
        );

    test('no product → byte-identical to the default C', () {
      final plain = solve(netWith());
      final noProduct = solve(netWith(runProduct: null));
      for (final id in const ['tank', 'm2', 'm0r']) {
        expect(noProduct.residualPressure[id]!.pascals,
            equals(plain.residualPressure[id]!.pascals));
      }
      expect(noProduct.boosterHeadRequired.meters,
          equals(plain.boosterHeadRequired.meters));
    });

    test('cast iron on the run lowers the far-node residual (more friction)',
        () {
      final plain = solve(netWith());
      final cast = solve(netWith(runProduct: PipeProduct.castIron));
      // More friction along dr → m0r residual strictly lower with cast iron.
      expect(cast.residualPressure['m0r']!.pascals,
          lessThan(plain.residualPressure['m0r']!.pascals));

      // m0r residual = (tankElev − m0rElev) − h_f(dr @ C=110). Both at floor 2,
      // so the tank-to-m2 elevation is the only gravity head; the run is level.
      final lenDr = edgeLength(netWith().edges[1], netWith(),
          calibrationBySheet: calibration, building: building);
      final hfCast = headLossHazenWilliams(
              flow: flow,
              length: lenDr,
              diameter: dn65,
              hazenWilliamsC: hazenWilliamsCFor(PipeProduct.castIron))
          .meters;
      final hfPvc = headLossHazenWilliams(
              flow: flow,
              length: lenDr,
              diameter: dn65,
              hazenWilliamsC: const SniProfile().hazenWilliamsC(PipeMaterial.pvc))
          .meters;
      // The residual drop from PVC→cast equals the extra friction (hfCast−hfPvc)
      // expressed as a pressure.
      final dropHead = hfCast - hfPvc;
      expect(
        plain.residualPressure['m0r']!.pascals -
            cast.residualPressure['m0r']!.pascals,
        closeTo(pressureFromHead(Head(dropHead)).pascals, 1e-6),
      );
    });
  });

  group('solvePressurized — inline valve minor loss (K·v²/2g)', () {
    // s --e1(50 m)--> n1(GATE VALVE) --r1(riser)--> n2.  Same geometry/flows as
    // the headline tree; only n1 carries a component, so the valve's local loss
    // must lift the required pump head by exactly K·v²/2g and nothing else.
    const flow = FlowRate(0.005);
    const dn65 = Diameter(0.065);
    const edgeFlows = <String, FlowRate>{'e1': flow, 'r1': flow};
    final sizing = <String, EdgeSizing>{
      'e1': const EdgeSizing(
          edgeId: 'e1',
          service: ServiceType.coldWater,
          flow: flow,
          diameter: dn65,
          velocity: Velocity(1.507)),
      'r1': const EdgeSizing(
          edgeId: 'r1',
          service: ServiceType.coldWater,
          flow: flow,
          diameter: dn65,
          velocity: Velocity(1.507)),
    };

    // Build the tree with n1 carrying an explicit [role] + optional [c]omponent,
    // so a comparison can hold the ROLE (and therefore the riser geometry)
    // constant and vary ONLY the component — isolating the K·v²/2g effect.
    Network netWith({NodeComponent? c, NodeRole role = NodeRole.main}) =>
        Network(
          nodes: [
            const NetNode(id: 's', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            NetNode(
                id: 'n1',
                sheetId: 's1',
                x: 500,
                y: 0,
                floorIndex: 0,
                role: role,
                component: c),
            const NetNode(id: 'n2', sheetId: 's1', x: 500, y: 0, floorIndex: 2),
          ],
          edges: const [
            NetEdge(
                id: 'e1', fromId: 's', toId: 'n1', service: ServiceType.coldWater),
            NetEdge(
                id: 'r1',
                fromId: 'n1',
                toId: 'n2',
                service: ServiceType.coldWater,
                kind: EdgeKind.riser),
          ],
        );

    test('a gate valve adds exactly K·v²/2g to the required pump head', () {
      PressureSolution run(Network net) => solvePressurized(
            net: net,
            service: ServiceType.coldWater,
            sourceId: 's',
            edgeFlows: edgeFlows,
            sizing: sizing,
            calibrationBySheet: calibration,
            building: building,
            targetResidual: targetResidual,
          );
      // gateValve.role is `main`, so both nets share n1's role + geometry.
      final plain = run(netWith());
      final withValve = run(netWith(c: NodeComponent.gateValve));

      final v = velocityFromFlow(flow, dn65);
      final expected =
          minorLossHead(k: NodeComponent.gateValve.minorLossK, velocity: v)
              .meters;
      expect(expected, greaterThan(0));
      expect(
        withValve.requiredPumpHead.meters - plain.requiredPumpHead.meters,
        closeTo(expected, 1e-9),
      );
    });

    test('a non-restrictor component (roof drain) changes nothing', () {
      PressureSolution run(Network net) => solvePressurized(
            net: net,
            service: ServiceType.coldWater,
            sourceId: 's',
            edgeFlows: edgeFlows,
            sizing: sizing,
            calibrationBySheet: calibration,
            building: building,
            targetResidual: targetResidual,
          );
      // roofDrain has K = 0. Hold the role at `fixture` (roofDrain's own role)
      // in BOTH nets so geometry is constant and only the K=0 component varies —
      // the pump head must be byte-identical.
      expect(
        run(netWith(c: NodeComponent.roofDrain, role: NodeRole.fixture))
            .requiredPumpHead
            .meters,
        closeTo(
            run(netWith(role: NodeRole.fixture)).requiredPumpHead.meters,
            1e-12),
      );
    });
  });
}
