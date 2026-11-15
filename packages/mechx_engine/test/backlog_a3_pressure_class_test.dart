// Backlog A-3 (2026-11-13) — standpipe pressure classes and designated
// pressure-regulating hose valves instead of blanket over-pressure warnings.
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/standpipe_outlet_pressure.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  test('class thresholds: 1210 standard, 1600 PN16, 2413 PN25, above: zone',
      () {
    expect(firePressureClassFor(1210), FirePressureClass.standard);
    expect(firePressureClassFor(1210.1), FirePressureClass.pn16);
    // Office: 1.4 x 98.536 x 9.81 = 1353.3 kPa.
    expect(firePressureClassFor(1.4 * 98.536 * 9.81), FirePressureClass.pn16);
    expect(firePressureClassFor(1600), FirePressureClass.pn16);
    // Apartment: 175.051 x 9.81 = 1717.2 kPa.
    expect(firePressureClassFor(175.051 * 9.81), FirePressureClass.pn25);
    expect(firePressureClassFor(2413), FirePressureClass.pn25);
    // Tower: 1.4 x 210.681 x 9.81 = 2893.5 kPa (backlog D-1).
    expect(firePressureClassFor(1.4 * 210.681 * 9.81),
        FirePressureClass.zoneRequired);
    expect(kFirePressureClassPn16Kpa, 1600);
    expect(kStandpipeMaxSystemPressureKpa, 2413);
    expect(kFireComponentMaxPressureKpa, 1210);
  });

  test('a hose valve above 1207 kPa static (unregulated) is designated PRV',
      () {
    StandpipeOutletPressure o(double kpa, {bool regulated = false}) =>
        StandpipeOutletPressure(
          outletId: 'HB',
          floorIndex: 0,
          hoseStation: false,
          staticKpa: kpa,
          residualKpa: null,
          regulated: regulated,
        );
    expect(o(1341.5).prvHoseValve, isTrue);
    expect(o(1207).prvHoseValve, isFalse);
    expect(o(1341.5, regulated: true).prvHoseValve, isFalse);
    expect(kStandpipePrvSetResidualKpa, 690);
  });

  group('downstream edges, BOM class and take-off variant', () {
    // GT -> FP -> J -> HB0 ; J riser -> J1 -> HB1.
    NetNode n(String id, int f, {NodeComponent? c, NodeRole? r}) => NetNode(
        id: id,
        sheetId: 's$f',
        x: id.length * 10.0,
        y: 0,
        floorIndex: f,
        role: r ?? c?.role ?? NodeRole.main,
        component: c);
    final net = Network(nodes: [
      n('GT', 0, c: NodeComponent.groundTank),
      n('FP', 0, c: NodeComponent.pump),
      n('J', 0),
      n('J1', 1),
      n('HB0', 0, c: NodeComponent.hydrantBox, r: NodeRole.fixture),
      n('HB1', 1, c: NodeComponent.hydrantBox, r: NodeRole.fixture),
    ], edges: const [
      NetEdge(id: 's', fromId: 'GT', toId: 'FP', service: ServiceType.fireHydrant),
      NetEdge(id: 'd', fromId: 'FP', toId: 'J', service: ServiceType.fireHydrant),
      NetEdge(id: 'b0', fromId: 'J', toId: 'HB0', service: ServiceType.fireHydrant),
      NetEdge(
          id: 'r',
          fromId: 'J',
          toId: 'J1',
          service: ServiceType.fireHydrant,
          kind: EdgeKind.riser),
      NetEdge(id: 'b1', fromId: 'J1', toId: 'HB1', service: ServiceType.fireHydrant),
    ]);
    EdgeSizing es(String id, String from, double mm) => EdgeSizing(
          edgeId: id,
          service: ServiceType.fireHydrant,
          flow: FlowRate.litersPerSecond(5),
          diameter: Diameter.mm(mm),
          velocity: const Velocity(1),
          flowFromId: from,
        );
    final sizing = {
      's': es('s', 'GT', 150),
      'd': es('d', 'FP', 125),
      'b0': es('b0', 'J', 65),
      'r': es('r', 'J', 100),
      'b1': es('b1', 'J1', 65),
    };

    test('every pipe downstream of the pump, never its suction', () {
      final sys = fireSystems(net).single;
      expect(firePumpDownstreamEdgeIds(net: net, system: sys, sizing: sizing),
          ['b0', 'b1', 'd', 'r']);
    });

    test('buildBom keys and prints the class; none given ⇒ unchanged', () {
      final plain = buildBom(
          net: net,
          sizing: sizing,
          calibrationBySheet: const {},
          building: const BuildingLevels([Floor('L1', Length(4)), Floor('L2', Length(4))]));
      expect(plain.every((l) => l.pressureClass.isEmpty), isTrue);
      final classed = buildBom(
          net: net,
          sizing: sizing,
          calibrationBySheet: const {},
          building: const BuildingLevels([Floor('L1', Length(4)), Floor('L2', Length(4))]),
          pressureClassByEdgeId: {
            for (final id in ['b0', 'b1', 'd', 'r']) id: 'PN16',
          });
      final pn = classed.where((l) => l.pressureClass == 'PN16').toList();
      expect(pn.fold<int>(0, (a, l) => a + l.segmentCount), 4);
      expect(classed.where((l) => l.pressureClass.isEmpty).single.diameterMm,
          150); // the suction
    });

    test('the take-off splits designated hose valves into their own line', () {
      final lines = buildComponentTakeoff(
          net: net,
          sizing: sizing,
          variantByNodeId: {'HB0': 'pressure-regulating, inlet 1342 kPa'});
      final hb = lines
          .where((l) => l.component == NodeComponent.hydrantBox)
          .toList();
      expect(hb, hasLength(2));
      expect(hb.where((l) => l.variant.isEmpty).single.count, 1);
      expect(hb.where((l) => l.variant.startsWith('pressure-regulating'))
          .single
          .count, 1);
    });
  });
}
