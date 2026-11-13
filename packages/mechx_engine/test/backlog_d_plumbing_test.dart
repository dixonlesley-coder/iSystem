// Backlog D (2026-11-13) — plumbing / fire geometry and component modelling.
// Each group pins one item from first principles.
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

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
}
