import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const building = BuildingLevels([
    Floor('Ground', Length(4.0)),
    Floor('Level 1', Length(3.5)),
    Floor('Level 2', Length(3.5)),
  ]);

  group('service regime mapping (§7 separate code paths)', () {
    test('pressurized / gravity / air', () {
      expect(ServiceType.coldWater.regime, FlowRegime.pressurized);
      expect(ServiceType.fireSprinkler.regime, FlowRegime.pressurized);
      expect(ServiceType.drainage.regime, FlowRegime.gravity);
      expect(ServiceType.vent.regime, FlowRegime.gravity);
      expect(ServiceType.rainwater.regime, FlowRegime.gravity);
      expect(ServiceType.duct.regime, FlowRegime.air);
    });
  });

  group('edge length from the §10 sources of truth', () {
    const net = Network(
      nodes: const [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 300, y: 400, floorIndex: 0), // 500 px
        NetNode(id: 'c', sheetId: 's3', x: 10, y: 10, floorIndex: 2),
      ],
      edges: const [
        NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
        NetEdge(
          id: 'r1',
          fromId: 'a',
          toId: 'c',
          service: ServiceType.coldWater,
          kind: EdgeKind.riser,
        ),
      ],
    );
    const calib = {'s1': ScaleCalibration(0.01)}; // 1 px = 1 cm

    test('run length = pixels × calibration', () {
      expect(runPixelLength(net.edges[0], net), closeTo(500.0, 1e-9));
      final len = edgeLength(net.edges[0], net,
          calibrationBySheet: calib, building: building);
      expect(len.meters, closeTo(5.0, 1e-9)); // 500 px × 0.01
    });

    test('riser length = ceiling-to-ceiling elevation delta (not drawn)', () {
      // Both nodes are default mains (ceiling level). Ceiling of floor 0 =
      // 4.0 − 0.3 = 3.7 m; ceiling of floor 2 = (4.0+3.5) + 3.5 − 0.3 = 10.7 m;
      // riser spans 10.7 − 3.7 = 7.0 m (= heights of the two floors above).
      final len = edgeLength(net.edges[1], net,
          calibrationBySheet: calib, building: building);
      expect(len.meters, closeTo(7.0, 1e-9));
      expect(runPixelLength(net.edges[1], net), 0); // riser has no pixel run
    });

    test('a fixture drop is the ceiling-main → fixture-height delta', () {
      // main at ceiling of floor 0 (3.7 m) down to a fixture at 1.1 m on the
      // same floor: drop = 3.7 − 1.1 = 2.6 m (modelled as a riser/drop edge).
      const dropNet = Network(
        nodes: [
          NetNode(id: 'm', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(
            id: 'f',
            sheetId: 's1',
            x: 0,
            y: 0,
            floorIndex: 0,
            role: NodeRole.fixture,
          ),
        ],
        edges: [
          NetEdge(
            id: 'd',
            fromId: 'm',
            toId: 'f',
            service: ServiceType.coldWater,
            kind: EdgeKind.riser,
          ),
        ],
      );
      final len = edgeLength(dropNet.edges.single, dropNet,
          calibrationBySheet: const {}, building: building);
      expect(len.meters, closeTo(2.6, 1e-9));
    });

    test('nodeElevation: main=ceiling, fixture=+1.1, plant=roof', () {
      const main = NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 1);
      const fixture = NetNode(
          id: 'b', sheetId: 's1', x: 0, y: 0, floorIndex: 1,
          role: NodeRole.fixture);
      const plant = NetNode(
          id: 'c', sheetId: 's1', x: 0, y: 0, floorIndex: 0,
          role: NodeRole.plant);
      // floor 1 surface = 4.0; ceiling = 4.0 + 3.5 − 0.3 = 7.2; fixture = 5.1.
      expect(nodeElevation(main, building).meters, closeTo(7.2, 1e-9));
      expect(nodeElevation(fixture, building).meters, closeTo(5.1, 1e-9));
      // plant defaults to roof = total height = 11.0 m.
      expect(nodeElevation(plant, building).meters, closeTo(11.0, 1e-9));
    });

    test('nodeElevation: per-node mountHeight places it on its floor wall', () {
      // A fixture on floor 1 (surface 4.0 m) mounted 1.5 m up the wall sits at
      // 4.0 + 1.5 = 5.5 m — overriding the 1.1 m role default.
      const mounted = NetNode(
          id: 'm', sheetId: 's1', x: 0, y: 0, floorIndex: 1,
          role: NodeRole.fixture, mountHeight: Length(1.5));
      expect(nodeElevation(mounted, building).meters, closeTo(5.5, 1e-9));
      // An explicit absolute elevation still wins over mountHeight.
      const both = NetNode(
          id: 'm2', sheetId: 's1', x: 0, y: 0, floorIndex: 1,
          role: NodeRole.fixture,
          elevation: Length(9.0), mountHeight: Length(1.5));
      expect(nodeElevation(both, building).meters, closeTo(9.0, 1e-9));
    });

    test('NodeComponent maps to the expected role + label', () {
      expect(NodeComponent.pump.role, NodeRole.plant);
      expect(NodeComponent.roofTank.role, NodeRole.plant);
      expect(NodeComponent.gateValve.role, NodeRole.main);
      expect(NodeComponent.waterMeter.role, NodeRole.main);
      expect(NodeComponent.roofDrain.role, NodeRole.fixture);
      expect(NodeComponent.airVent.role, NodeRole.fixture);
      // Fire-protection points are fixtures; the FDC inlet is an inline main.
      expect(NodeComponent.sprinklerHead.role, NodeRole.fixture);
      expect(NodeComponent.fireExtinguisher.role, NodeRole.fixture);
      expect(NodeComponent.hydrantBox.role, NodeRole.fixture);
      expect(NodeComponent.fireDeptConnection.role, NodeRole.main);
      expect(NodeComponent.pump.label, 'Pump');
      // Every component carries a non-empty label (UI never shows a blank).
      for (final c in NodeComponent.values) {
        expect(c.label, isNotEmpty);
      }
      // copyWith carries the component and can clear it.
      const n = NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
      final withC = n.copyWith(component: NodeComponent.pump);
      expect(withC.component, NodeComponent.pump);
      expect(withC.copyWith(clearComponent: true).component, isNull);
      // A prebuilt tank node carries an editable capacity (litres).
      final tank = n.copyWith(
          component: NodeComponent.roofTank, tankCapacityLitres: 5000);
      expect(tank.tankCapacityLitres, 5000);
      expect(tank.copyWith(clearTankCapacity: true).tankCapacityLitres, isNull);
    });

    test('uncalibrated run yields zero length (flagged elsewhere)', () {
      final len = edgeLength(net.edges[0], net,
          calibrationBySheet: const {}, building: building);
      expect(len.meters, 0);
    });
  });

  group('connectivity', () {
    const net = Network(
      nodes: const [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 1, y: 1, floorIndex: 0),
      ],
      edges: const [
        NetEdge(id: 'e1', fromId: 'a', toId: 'b', service: ServiceType.duct),
      ],
    );

    test('nodeById and edgesAt', () {
      expect(net.nodeById('a')?.sheetId, 's1');
      expect(net.nodeById('z'), isNull);
      expect(net.edgesAt('a').length, 1);
      expect(net.edgesAt('b').single.id, 'e1');
    });
  });

  group('NetEdge additive material/override fields + copyWith', () {
    test('defaults are null (back-compat)', () {
      const e = NetEdge(
          id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater);
      expect(e.pipeProduct, isNull);
      expect(e.ductProduct, isNull);
      expect(e.sizeOverride, isNull);
    });

    test('copyWith carries id + every field, replacing only what is passed', () {
      const e = NetEdge(
        id: 'e1',
        fromId: 'a',
        toId: 'b',
        service: ServiceType.coldWater,
        kind: EdgeKind.riser,
        pipeProduct: PipeProduct.pprPn16,
        sizeOverride: Diameter(0.05),
      );
      // No-arg copy is value-identical.
      final same = e.copyWith();
      expect(same.id, 'e1');
      expect(same.fromId, 'a');
      expect(same.toId, 'b');
      expect(same.service, ServiceType.coldWater);
      expect(same.kind, EdgeKind.riser);
      expect(same.pipeProduct, PipeProduct.pprPn16);
      expect(same.sizeOverride?.meters, 0.05);
      expect(same.ductProduct, isNull);

      // Replace selected fields; the rest carry through.
      final moved = e.copyWith(fromId: 'x', toId: 'y');
      expect(moved.id, 'e1');
      expect(moved.fromId, 'x');
      expect(moved.toId, 'y');
      expect(moved.pipeProduct, PipeProduct.pprPn16); // carried
      expect(moved.sizeOverride?.meters, 0.05); // carried

      // Set a duct product.
      final ducted = e.copyWith(ductProduct: DuctProduct.bjls);
      expect(ducted.ductProduct, DuctProduct.bjls);
      expect(ducted.pipeProduct, PipeProduct.pprPn16); // still carried
    });

    test('clear flags null out optional fields', () {
      const e = NetEdge(
        id: 'e1',
        fromId: 'a',
        toId: 'b',
        service: ServiceType.duct,
        pipeProduct: PipeProduct.pprPn16,
        ductProduct: DuctProduct.bjls,
        sizeOverride: Diameter(0.08),
      );
      final cleared = e.copyWith(
        clearPipeProduct: true,
        clearDuctProduct: true,
        clearSizeOverride: true,
      );
      expect(cleared.pipeProduct, isNull);
      expect(cleared.ductProduct, isNull);
      expect(cleared.sizeOverride, isNull);
      // Untouched structural fields survive.
      expect(cleared.id, 'e1');
      expect(cleared.service, ServiceType.duct);
    });
  });
}
