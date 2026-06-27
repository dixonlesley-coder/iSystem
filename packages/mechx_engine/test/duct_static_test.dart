/// Tests for the fan total-static-pressure solve. Expected static is composed
/// from the engine's own ductFrictionPaPerMetre kernel so the solve is checked
/// on what it must do: sum friction × length × fittings along the index run and
/// add the terminal loss.
library;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/duct_static.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/duct_sizing.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const building = BuildingLevels([Floor('G', Length(4.0))]);
  const calibration = {'s1': ScaleCalibration(0.1)}; // 0.1 m/px

  // fan (f) --e (run)--> diffuser (d). 1000 px × 0.1 = 100 m of duct.
  const net = Network(
    nodes: [
      NetNode(id: 'f', sheetId: 's1', x: 0, y: 0, floorIndex: 0, role: NodeRole.plant),
      NetNode(id: 'd', sheetId: 's1', x: 1000, y: 0, floorIndex: 0, role: NodeRole.fixture),
    ],
    edges: [
      NetEdge(id: 'e', fromId: 'f', toId: 'd', service: ServiceType.duct),
    ],
  );

  const flow = FlowRate(1.0);
  const dia = Diameter(0.4);
  const edgeFlows = {'e': flow};
  const sizing = {
    'e': EdgeSizing(
      edgeId: 'e',
      service: ServiceType.duct,
      flow: flow,
      diameter: dia,
      velocity: Velocity(7.96),
    ),
  };

  test('fan static = friction·L·fittings + terminal loss', () {
    final sol = solveDuctStatic(
      net: net,
      service: ServiceType.duct,
      fanNodeId: 'f',
      edgeFlows: edgeFlows,
      sizing: sizing,
      calibrationBySheet: calibration,
      building: building,
    );
    // A supply (AC) duct with no explicit product now defaults to PU panel.
    final perM = ductFrictionPaPerMetre(flow, dia,
        roughness: ductRoughnessFor(DuctProduct.pu));
    const length = 100.0; // 1000 px × 0.1
    final expected = perM * length * 1.3 + 30.0; // defaults: fitting 1.3, term 30
    expect(sol.totalStaticPressure.pascals, closeTo(expected, 1e-6));
    expect(sol.criticalNodeId, 'd');
  });

  test('single fan node → static is just the terminal loss', () {
    const lone = Network(nodes: [
      NetNode(id: 'f', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
    ]);
    final sol = solveDuctStatic(
      net: lone,
      service: ServiceType.duct,
      fanNodeId: 'f',
      edgeFlows: const {},
      sizing: const {},
      calibrationBySheet: calibration,
      building: building,
      terminalLoss: const Pressure(25),
    );
    expect(sol.totalStaticPressure.pascals, closeTo(25.0, 1e-9));
  });

  test('unsized edge contributes zero friction', () {
    final sol = solveDuctStatic(
      net: net,
      service: ServiceType.duct,
      fanNodeId: 'f',
      edgeFlows: edgeFlows,
      sizing: const {}, // edge unsized → skipped
      calibrationBySheet: calibration,
      building: building,
      terminalLoss: const Pressure(30),
    );
    expect(sol.totalStaticPressure.pascals, closeTo(30.0, 1e-9));
  });

  // ── Per-edge duct-material fold + service defaults (product → roughness ε) ──
  group('duct product folds into Darcy roughness; defaults by service', () {
    Network netWith(
            {DuctProduct? product, ServiceType service = ServiceType.duct}) =>
        Network(
          nodes: const [
            NetNode(
                id: 'f',
                sheetId: 's1',
                x: 0,
                y: 0,
                floorIndex: 0,
                role: NodeRole.plant),
            NetNode(
                id: 'd',
                sheetId: 's1',
                x: 1000,
                y: 0,
                floorIndex: 0,
                role: NodeRole.fixture),
          ],
          edges: [
            NetEdge(
              id: 'e',
              fromId: 'f',
              toId: 'd',
              service: service,
              ductProduct: product,
            ),
          ],
        );

    DuctStaticSolution solveFor(Network n, ServiceType service) =>
        solveDuctStatic(
          net: n,
          service: service,
          fanNodeId: 'f',
          edgeFlows: edgeFlows,
          sizing: sizing,
          calibrationBySheet: calibration,
          building: building,
        );

    const length = 100.0; // 1000 px × 0.1
    double composed(DuctProduct p) =>
        ductFrictionPaPerMetre(flow, dia, roughness: ductRoughnessFor(p)) *
            length *
            1.3 +
        30.0;

    test('AC supply with no product defaults to PU', () {
      final noProduct = solveFor(netWith(), ServiceType.duct);
      final pu = solveFor(
          netWith(product: DuctProduct.pu), ServiceType.duct);
      expect(noProduct.totalStaticPressure.pascals,
          equals(pu.totalStaticPressure.pascals));
      expect(noProduct.totalStaticPressure.pascals,
          closeTo(composed(DuctProduct.pu), 1e-6));
    });

    test('return air also defaults to PU', () {
      final ret = solveFor(
          netWith(service: ServiceType.returnAir), ServiceType.returnAir);
      expect(ret.totalStaticPressure.pascals,
          closeTo(composed(DuctProduct.pu), 1e-6));
    });

    test('exhaust with no product defaults to BJLS (galvanised steel)', () {
      final exh = solveFor(
          netWith(service: ServiceType.exhaust), ServiceType.exhaust);
      final bjls = solveFor(
          netWith(product: DuctProduct.bjls, service: ServiceType.exhaust),
          ServiceType.exhaust);
      expect(exh.totalStaticPressure.pascals,
          equals(bjls.totalStaticPressure.pascals));
      expect(exh.totalStaticPressure.pascals,
          closeTo(composed(DuctProduct.bjls), 1e-6));
    });

    test('an explicit BJLS overrides the supply PU default (higher static)', () {
      final pu = solveFor(netWith(), ServiceType.duct); // default PU
      final bjls = solveFor(
          netWith(product: DuctProduct.bjls), ServiceType.duct);
      expect(bjls.totalStaticPressure.pascals,
          greaterThan(pu.totalStaticPressure.pascals));
      expect(bjls.totalStaticPressure.pascals,
          closeTo(composed(DuctProduct.bjls), 1e-6));
    });
  });

  group('ductRoughnessFor + verify checklist', () {
    test('ductRoughnessFor(bjls) matches the galvanised-steel kernel default',
        () {
      // The kernel's default ε is 9.0e-5 m (galvanised steel). BJLS must equal
      // it so a BJLS segment reproduces the existing result. Cross-check by
      // computing the friction both ways at one diameter.
      expect(ductRoughnessFor(DuctProduct.bjls).meters, closeTo(9.0e-5, 0));
      final viaDefault = ductFrictionPaPerMetre(const FlowRate(1.0), dia);
      final viaBjls = ductFrictionPaPerMetre(const FlowRate(1.0), dia,
          roughness: ductRoughnessFor(DuctProduct.bjls));
      expect(viaBjls, equals(viaDefault));
    });

    test('ductRoughnessFor(pu) is the smoother PU value (0.03 mm)', () {
      expect(ductRoughnessFor(DuctProduct.pu).meters, closeTo(3.0e-5, 0));
      expect(ductRoughnessFor(DuctProduct.pu).meters,
          lessThan(ductRoughnessFor(DuctProduct.bjls).meters));
    });

    test('the PU roughness surfaces in the duct-products verify checklist', () {
      // The fold changes hydraulics ⇒ the unverified PU ε MUST surface
      // (golden rule 6 / §12.6).
      final hasPuRoughness = ductProductsVerifyChecklist.any(
        (v) {
          final name = v.value.toString().toLowerCase();
          return name.contains('pu') && name.contains('roughness');
        },
      );
      expect(hasPuRoughness, isTrue,
          reason: 'PU roughness must appear in ductProductsVerifyChecklist');
    });
  });

  test('an inline damper adds its C·ρv²/2 static loss to the fan total', () {
    // Same fan→diffuser run, but the diffuser node carries a VAV box (C=1.5).
    const damperNet = Network(
      nodes: [
        NetNode(
            id: 'f', sheetId: 's1', x: 0, y: 0, floorIndex: 0,
            role: NodeRole.plant),
        NetNode(
            id: 'd', sheetId: 's1', x: 1000, y: 0, floorIndex: 0,
            role: NodeRole.main, component: NodeComponent.vavBox),
      ],
      edges: [
        NetEdge(id: 'e', fromId: 'f', toId: 'd', service: ServiceType.duct),
      ],
    );
    DuctStaticSolution run(Network n) => solveDuctStatic(
          net: n,
          service: ServiceType.duct,
          fanNodeId: 'f',
          edgeFlows: edgeFlows,
          sizing: sizing,
          calibrationBySheet: calibration,
          building: building,
        );
    // Plain reference (the 'd' node above is role main, no component).
    const plainNet = Network(
      nodes: [
        NetNode(
            id: 'f', sheetId: 's1', x: 0, y: 0, floorIndex: 0,
            role: NodeRole.plant),
        NetNode(
            id: 'd', sheetId: 's1', x: 1000, y: 0, floorIndex: 0,
            role: NodeRole.main),
      ],
      edges: [
        NetEdge(id: 'e', fromId: 'f', toId: 'd', service: ServiceType.duct),
      ],
    );
    final expectedExtra =
        ductFittingLossPa(c: 1.5, flow: flow, diameter: dia);
    expect(expectedExtra, greaterThan(0));
    expect(
      run(damperNet).totalStaticPressure.pascals -
          run(plainNet).totalStaticPressure.pascals,
      closeTo(expectedExtra, 1e-9),
    );
  });
}
