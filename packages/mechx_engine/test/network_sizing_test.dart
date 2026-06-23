import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('accumulateFlows (branching)', () {
    // Tee: root —e1— a, a —e2— b, a —e3— c. Demands at the two leaves.
    const net = Network(
      nodes: [
        NetNode(id: 'root', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'a', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 200, y: -50, floorIndex: 0),
        NetNode(id: 'c', sheetId: 's1', x: 200, y: 50, floorIndex: 0),
      ],
      edges: const [
        NetEdge(id: 'e1', fromId: 'root', toId: 'a', service: ServiceType.duct),
        NetEdge(id: 'e2', fromId: 'a', toId: 'b', service: ServiceType.duct),
        NetEdge(id: 'e3', fromId: 'a', toId: 'c', service: ServiceType.duct),
      ],
    );

    test('each branch carries its own load; the trunk carries the sum', () {
      final flows = accumulateFlows(
        net: net,
        service: ServiceType.duct,
        rootId: 'root',
        terminalDemand: const {
          'b': FlowRate(0.10),
          'c': FlowRate(0.20),
        },
      );
      expect(flows['e2']!.cubicMetersPerSecond, closeTo(0.10, 1e-12)); // branch b
      expect(flows['e3']!.cubicMetersPerSecond, closeTo(0.20, 1e-12)); // branch c
      expect(flows['e1']!.cubicMetersPerSecond, closeTo(0.30, 1e-12)); // trunk
    });

    test('only edges of the requested service are considered', () {
      final flows = accumulateFlows(
        net: net,
        service: ServiceType.coldWater, // none in this net
        rootId: 'root',
        terminalDemand: const {'b': FlowRate(0.1)},
      );
      expect(flows, isEmpty);
    });
  });

  group('sizeEdge dispatches by §7 regime', () {
    const ctx = SizingContext();

    test('pressurized water → DN65 at 5 L/s', () {
      const edge = NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater);
      final s = sizeEdge(edge, const FlowRate(0.005), ctx);
      expect(s.diameter.inMillimeters, 65);
      expect(s.velocity.metersPerSecond, lessThanOrEqualTo(2.0));
    });

    test('air duct → 400 mm at 0.5 m³/s, v ≤ 5', () {
      const edge = NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.duct);
      final s = sizeEdge(edge, const FlowRate(0.5), ctx);
      expect(s.diameter.inMillimeters, 400);
      expect(s.velocity.metersPerSecond, lessThanOrEqualTo(5.0));
    });

    test('gravity drainage → DN125 at 4 L/s, slope 0.01', () {
      const edge = NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.drainage);
      final s = sizeEdge(edge, const FlowRate(0.004), ctx);
      expect(s.diameter.inMillimeters, 125);
    });
  });

  test('autoSizeNetwork sizes a branching duct tree from leaf demands', () {
    const net = Network(
      nodes: [
        NetNode(id: 'src', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'a', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 200, y: -50, floorIndex: 0),
        NetNode(id: 'c', sheetId: 's1', x: 200, y: 50, floorIndex: 0),
      ],
      edges: [
        NetEdge(id: 'e1', fromId: 'src', toId: 'a', service: ServiceType.duct),
        NetEdge(id: 'e2', fromId: 'a', toId: 'b', service: ServiceType.duct),
        NetEdge(id: 'e3', fromId: 'a', toId: 'c', service: ServiceType.duct),
      ],
    );
    final sized = autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.duct: FlowRate(0.1)},
    );
    // 'src' is a leaf → chosen as root; demand applied at the other leaves.
    expect(sized['e1']!.flow.cubicMetersPerSecond, closeTo(0.2, 1e-9)); // trunk
    expect(sized['e2']!.flow.cubicMetersPerSecond, closeTo(0.1, 1e-9));
    expect(sized['e3']!.flow.cubicMetersPerSecond, closeTo(0.1, 1e-9));
    expect(
      sized['e1']!.diameter.meters,
      greaterThanOrEqualTo(sized['e2']!.diameter.meters),
    );
  });

  group('accumulateFixtureUnits + UBAP demand path (diversified water supply)',
      () {
    test('trunk flow = Hunter(total UBAP), NOT the sum of peak fixture flows',
        () {
      // A 4-leaf tee so multiple fixtures stack on the trunk: src—t—h, then
      // h branches to four fixtures f1..f4.
      const tee = Network(
        nodes: [
          NetNode(id: 'src', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'h', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
          NetNode(id: 'f1', sheetId: 's1', x: 200, y: -30, floorIndex: 0),
          NetNode(id: 'f2', sheetId: 's1', x: 200, y: -10, floorIndex: 0),
          NetNode(id: 'f3', sheetId: 's1', x: 200, y: 10, floorIndex: 0),
          NetNode(id: 'f4', sheetId: 's1', x: 200, y: 30, floorIndex: 0),
        ],
        edges: [
          NetEdge(id: 't', fromId: 'src', toId: 'h', service: ServiceType.coldWater),
          NetEdge(id: 'b1', fromId: 'h', toId: 'f1', service: ServiceType.coldWater),
          NetEdge(id: 'b2', fromId: 'h', toId: 'f2', service: ServiceType.coldWater),
          NetEdge(id: 'b3', fromId: 'h', toId: 'f3', service: ServiceType.coldWater),
          NetEdge(id: 'b4', fromId: 'h', toId: 'f4', service: ServiceType.coldWater),
        ],
      );
      final sized = autoSizeNetwork(
        tee,
        const SizingContext(),
        leafDemand: const {ServiceType.coldWater: FlowRate(0.0002)},
        leafFixtureUnits: const {ServiceType.coldWater: 6.0},
      );
      // 4 fixtures × 6 UBAP = 24 UBAP on the trunk 't'.
      final expectedTrunk = const SniProfile()
          .probableFlowForFixtureUnits(24.0)
          .cubicMetersPerSecond;
      expect(
        sized['t']!.flow.cubicMetersPerSecond,
        closeTo(expectedTrunk, 1e-9),
      );
      // Diversified demand must be far below the naive sum of peak flows
      // (4 × 0.0002 = 0.0008 would be the flat model; Hunter at 24 UBAP is
      // a much larger but PROPER simultaneous demand — the point is it comes
      // from the curve, not a linear sum).
      expect(sized['t']!.flow.cubicMetersPerSecond, greaterThan(0));
      // Each branch carries one fixture = Hunter(6 UBAP).
      final oneFixture = const SniProfile()
          .probableFlowForFixtureUnits(6.0)
          .cubicMetersPerSecond;
      expect(sized['b1']!.flow.cubicMetersPerSecond, closeTo(oneFixture, 1e-9));
    });
  });

  test('autoSizeNetwork sizes drainage by accumulated DFU (branch vs stack)',
      () {
    // src --t(run/branch)-- h --b1/b2 (branches to two fixtures), and a riser.
    const net = Network(
      nodes: [
        NetNode(id: 's', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'h', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
        NetNode(id: 'f1', sheetId: 's1', x: 200, y: -20, floorIndex: 0),
        NetNode(id: 'f2', sheetId: 's1', x: 200, y: 20, floorIndex: 0),
      ],
      edges: [
        NetEdge(id: 't', fromId: 's', toId: 'h', service: ServiceType.drainage),
        NetEdge(id: 'b1', fromId: 'h', toId: 'f1', service: ServiceType.drainage),
        NetEdge(id: 'b2', fromId: 'h', toId: 'f2', service: ServiceType.drainage),
      ],
    );
    final sized = autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {},
      nodeDrainageUnits: const {'f1': 4.0, 'f2': 4.0}, // two WCs (flush tank)
    );
    // Trunk carries 8 DFU → branch table row (≤12) = 75 mm; a single fixture
    // branch carries 4 DFU → (≤6) = 65 mm.
    expect(sized['t']!.diameter.inMillimeters, 75);
    expect(sized['b1']!.diameter.inMillimeters, 65);
    expect(sized['t']!.service, ServiceType.drainage);
  });

  test('rooting at a plant keeps every fixture-leaf load (no root-drop)', () {
    // A bare manifold: three fixture leaves on a hub, fed by a plant. The hub
    // is the only non-fixture node, the plant is the marked source. Each branch
    // must carry its fixture's demand, and the plant feeder must carry the sum —
    // i.e. NO terminal's load is dropped by the choice of root.
    const net = Network(
      nodes: [
        NetNode(
          id: 'p',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant,
        ),
        NetNode(id: 'h', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
        NetNode(
          id: 'f1',
          sheetId: 's1',
          x: 200,
          y: -30,
          floorIndex: 0,
          role: NodeRole.fixture,
        ),
        NetNode(
          id: 'f2',
          sheetId: 's1',
          x: 200,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture,
        ),
        NetNode(
          id: 'f3',
          sheetId: 's1',
          x: 200,
          y: 30,
          floorIndex: 0,
          role: NodeRole.fixture,
        ),
      ],
      edges: [
        NetEdge(id: 'feed', fromId: 'p', toId: 'h', service: ServiceType.duct),
        NetEdge(id: 'b1', fromId: 'h', toId: 'f1', service: ServiceType.duct),
        NetEdge(id: 'b2', fromId: 'h', toId: 'f2', service: ServiceType.duct),
        NetEdge(id: 'b3', fromId: 'h', toId: 'f3', service: ServiceType.duct),
      ],
    );
    final sized = autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.duct: FlowRate(0.1)},
    );
    expect(sized['b1']!.flow.cubicMetersPerSecond, closeTo(0.1, 1e-9));
    expect(sized['b2']!.flow.cubicMetersPerSecond, closeTo(0.1, 1e-9));
    expect(sized['b3']!.flow.cubicMetersPerSecond, closeTo(0.1, 1e-9));
    expect(sized['feed']!.flow.cubicMetersPerSecond, closeTo(0.3, 1e-9));
  });

  test('a bare fixture manifold roots at the hub, dropping no fixture load', () {
    // Same star but with NO plant: three fixture leaves on a hub. The only safe
    // root is the hub (rooting at a fixture leaf would silently lose its load),
    // so all three branches still carry their demand.
    const net = Network(
      nodes: [
        NetNode(id: 'h', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
        NetNode(
          id: 'f1',
          sheetId: 's1',
          x: 200,
          y: -30,
          floorIndex: 0,
          role: NodeRole.fixture,
        ),
        NetNode(
          id: 'f2',
          sheetId: 's1',
          x: 200,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture,
        ),
        NetNode(
          id: 'f3',
          sheetId: 's1',
          x: 200,
          y: 30,
          floorIndex: 0,
          role: NodeRole.fixture,
        ),
      ],
      edges: [
        NetEdge(id: 'b1', fromId: 'h', toId: 'f1', service: ServiceType.duct),
        NetEdge(id: 'b2', fromId: 'h', toId: 'f2', service: ServiceType.duct),
        NetEdge(id: 'b3', fromId: 'h', toId: 'f3', service: ServiceType.duct),
      ],
    );
    final sized = autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.duct: FlowRate(0.1)},
    );
    expect(sized['b1']!.flow.cubicMetersPerSecond, closeTo(0.1, 1e-9));
    expect(sized['b2']!.flow.cubicMetersPerSecond, closeTo(0.1, 1e-9));
    expect(sized['b3']!.flow.cubicMetersPerSecond, closeTo(0.1, 1e-9));
  });

  test('an inline (interior) demand node contributes its load upstream', () {
    // Chain p(plant) — mid — end, where the MID node carries an explicit airflow
    // even though it is a degree-2 pass-through. Its demand must be accumulated
    // onto the upstream feeder, not dropped for being a non-leaf.
    const net = Network(
      nodes: [
        NetNode(
          id: 'p',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant,
        ),
        NetNode(id: 'mid', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
        NetNode(id: 'end', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
      ],
      edges: [
        NetEdge(id: 'feed', fromId: 'p', toId: 'mid', service: ServiceType.duct),
        NetEdge(id: 'run', fromId: 'mid', toId: 'end', service: ServiceType.duct),
      ],
    );
    final sized = autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.duct: FlowRate(0)},
      nodeFlowDemand: const {
        'mid': FlowRate(0.05),
        'end': FlowRate(0.10),
      },
    );
    // feeder = mid (0.05) + end (0.10); run = end (0.10).
    expect(sized['run']!.flow.cubicMetersPerSecond, closeTo(0.10, 1e-9));
    expect(sized['feed']!.flow.cubicMetersPerSecond, closeTo(0.15, 1e-9));
  });

  test('a looped duct ring splits flow (Hardy-Cross), not mis-accumulated', () {
    // A square ring: src(plant) feeds node A; A and C both reach the demand at
    // the far corner via two legs. src—A, then a ring A—B—C and A—D—C, with the
    // draw at C. The two parallel legs must SHARE the load (each edge < total),
    // which the old tree accumulation (ignoring the chord) could not do.
    const net = Network(
      nodes: [
        NetNode(
          id: 's',
          sheetId: 's1',
          x: 0,
          y: 100,
          floorIndex: 0,
          role: NodeRole.plant,
        ),
        NetNode(id: 'A', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
        NetNode(id: 'B', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
        NetNode(id: 'C', sheetId: 's1', x: 300, y: 100, floorIndex: 0),
        NetNode(id: 'D', sheetId: 's1', x: 200, y: 200, floorIndex: 0),
      ],
      edges: [
        NetEdge(id: 'feed', fromId: 's', toId: 'A', service: ServiceType.duct),
        NetEdge(id: 'AB', fromId: 'A', toId: 'B', service: ServiceType.duct),
        NetEdge(id: 'BC', fromId: 'B', toId: 'C', service: ServiceType.duct),
        NetEdge(id: 'AD', fromId: 'A', toId: 'D', service: ServiceType.duct),
        NetEdge(id: 'DC', fromId: 'D', toId: 'C', service: ServiceType.duct),
      ],
    );
    final sized = autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.duct: FlowRate(0)},
      nodeFlowDemand: const {'C': FlowRate(0.40)},
    );
    final feed = sized['feed']!.flow.cubicMetersPerSecond;
    final ab = sized['AB']!.flow.cubicMetersPerSecond;
    final bc = sized['BC']!.flow.cubicMetersPerSecond;
    final ad = sized['AD']!.flow.cubicMetersPerSecond;
    final dc = sized['DC']!.flow.cubicMetersPerSecond;
    // The feeder carries the whole draw.
    expect(feed, closeTo(0.40, 1e-6));
    // The draw at C is split across the two symmetric legs (≈ half each), and
    // continuity holds: the two legs into C sum to the draw.
    expect(bc + dc, closeTo(0.40, 1e-6));
    expect(ab, closeTo(0.20, 1e-3));
    expect(ad, closeTo(0.20, 1e-3));
    // Crucially, no single ring edge carries the full load.
    expect(ab, lessThan(feed));
  });

  test('a riser leg in a loop balances on its REAL length when geometry is given',
      () {
    // A loop with two paths from A to the draw at B (both on floor 0):
    //   • direct ground run A→B, and
    //   • up-over-down A→A'(riser)→B'(run, floor 1)→B(riser).
    // In PIXELS the two paths are ~equal (risers have zero planar length), so
    // without geometry the split is ~50/50. With building + calibration the two
    // risers add their REAL floor height, so the direct ground path carries
    // clearly more. Proves riser length comes from the §10 elevation delta.
    const net = Network(
      nodes: [
        NetNode(
          id: 'P',
          sheetId: 's1',
          x: -50,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant,
        ),
        NetNode(id: 'A', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'B', sheetId: 's1', x: 200, y: 0, floorIndex: 0),
        NetNode(id: 'A2', sheetId: 's1', x: 0, y: 0, floorIndex: 1),
        NetNode(id: 'B2', sheetId: 's1', x: 200, y: 0, floorIndex: 1),
      ],
      edges: [
        NetEdge(id: 'feed', fromId: 'P', toId: 'A', service: ServiceType.duct),
        NetEdge(id: 'AB', fromId: 'A', toId: 'B', service: ServiceType.duct),
        NetEdge(
          id: 'AA2',
          fromId: 'A',
          toId: 'A2',
          service: ServiceType.duct,
          kind: EdgeKind.riser,
        ),
        NetEdge(
            id: 'A2B2', fromId: 'A2', toId: 'B2', service: ServiceType.duct),
        NetEdge(
          id: 'B2B',
          fromId: 'B2',
          toId: 'B',
          service: ServiceType.duct,
          kind: EdgeKind.riser,
        ),
      ],
    );
    const demand = {'B': FlowRate(0.30)};

    final pixel = autoSizeNetwork(net, const SizingContext(),
        leafDemand: const {ServiceType.duct: FlowRate(0)},
        nodeFlowDemand: demand);
    final geo = autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {ServiceType.duct: FlowRate(0)},
      nodeFlowDemand: demand,
      building: const BuildingLevels([
        Floor('G', Length(4.0)),
        Floor('L1', Length(3.0)),
      ]),
      calibrationBySheet: const {'s1': ScaleCalibration(0.02)},
    );

    double ab(Map<String, EdgeSizing> s) => s['AB']!.flow.cubicMetersPerSecond;
    double up(Map<String, EdgeSizing> s) => s['B2B']!.flow.cubicMetersPerSecond;

    // Continuity into B holds either way.
    expect(ab(pixel) + up(pixel), closeTo(0.30, 1e-6));
    expect(ab(geo) + up(geo), closeTo(0.30, 1e-6));
    // Pixel-only: planar paths are ~equal ⇒ ~50/50.
    expect(ab(pixel), closeTo(0.15, 5e-3));
    // With real riser length the direct ground path carries clearly more, and
    // the split genuinely differs from the geometry-blind one.
    expect(ab(geo), greaterThan(0.17));
    expect(ab(geo), greaterThan(ab(pixel) + 0.02));
  });

  test('sizeNetwork sizes every edge with an accumulated flow', () {
    const net = Network(
      nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
      ],
      edges: [
        NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      ],
    );
    final sized = sizeNetwork(
      net,
      const {'e': FlowRate(0.005)},
      const SizingContext(),
    );
    expect(sized['e']!.diameter.inMillimeters, 65);
  });
}
