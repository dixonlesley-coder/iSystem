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
    final perM = ductFrictionPaPerMetre(flow, dia);
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

  // ── Per-edge duct-material fold (NetEdge.ductProduct → wall roughness ε) ────
  group('per-edge ductProduct folds into the Darcy roughness', () {
    Network netWith({DuctProduct? product}) => Network(
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
              service: ServiceType.duct,
              ductProduct: product,
            ),
          ],
        );

    DuctStaticSolution solve(Network net) => solveDuctStatic(
          net: net,
          service: ServiceType.duct,
          fanNodeId: 'f',
          edgeFlows: edgeFlows,
          sizing: sizing,
          calibrationBySheet: calibration,
          building: building,
        );

    test('no product → byte-identical to the galvanised-steel default', () {
      final plain = solve(net); // existing const net, no ductProduct
      final noProduct = solve(netWith(product: null));
      expect(noProduct.totalStaticPressure.pascals,
          equals(plain.totalStaticPressure.pascals));
    });

    test('BJLS equals the galvanised default exactly', () {
      // BJLS roughness matches the kernel's galvanised-steel default ε, so the
      // per-edge swap is a no-op.
      final plain = solve(net);
      final bjls = solve(netWith(product: DuctProduct.bjls));
      expect(bjls.totalStaticPressure.pascals,
          equals(plain.totalStaticPressure.pascals));
    });

    test('PU (smoother) gives strictly LOWER total static than the default', () {
      final plain = solve(net);
      final pu = solve(netWith(product: DuctProduct.pu));
      expect(pu.totalStaticPressure.pascals,
          lessThan(plain.totalStaticPressure.pascals));

      // The PU static equals the hand-composed friction at the PU roughness:
      // perM(ε_PU) · L · fittings + terminal.
      final perMPu = ductFrictionPaPerMetre(flow, dia,
          roughness: ductRoughnessFor(DuctProduct.pu));
      const length = 100.0; // 1000 px × 0.1
      final expected = perMPu * length * 1.3 + 30.0; // defaults
      expect(pu.totalStaticPressure.pascals, closeTo(expected, 1e-6));
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
}
