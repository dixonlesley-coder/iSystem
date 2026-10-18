// Audit 2026-10 — GROUP A (plumbing / fire sizing + pressure solve).
//
// One group per confirmed finding. Every expected value is hand-derived from
// first principles in the comments (or from an independently unit-tested
// engine primitive where the orchestration is what is under test).
import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart' as drain;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/storm_sizing.dart' as storm;
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetEdge _run(String id, String a, String b, ServiceType s) =>
    NetEdge(id: id, fromId: a, toId: b, service: s);
NetEdge _riser(String id, String a, String b, ServiceType s) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: EdgeKind.riser);

void main() {
  // 4 floors × 4.0 m: elevationOf(i) = 4i; roof = 16.0 m.
  //   ceiling main (default 0.3 m drop) on floor i = 4i + 4 − 0.3;
  //   fixture (default 1.1 m) on floor i = 4i + 1.1.
  const building4 = BuildingLevels([
    Floor('G', Length(4.0)),
    Floor('L1', Length(4.0)),
    Floor('L2', Length(4.0)),
    Floor('L3', Length(4.0)),
  ]);
  const cal = <String, ScaleCalibration>{'s1': ScaleCalibration(0.01)};
  // 0.50 kgf/cm² = 49 033.25 Pa → head = 49 033.25 / (1000 × 9.80665)
  //   = 5.0 m water column under the engine's ρg (headFromPressure).
  const target = Pressure(49033.25);
  final targetHead = headFromPressure(target).meters;

  // pump (floor 0) —run→ m0 (floor-0 ceiling main) —riser→ m3 (floor-3
  // ceiling main) —run→ fx (lavatory on floor 3).
  const pump = NetNode(
      id: 'pump',
      sheetId: 's1',
      x: 0,
      y: 0,
      floorIndex: 0,
      role: NodeRole.plant,
      component: NodeComponent.pump);
  const m0 = NetNode(id: 'm0', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
  const m3 = NetNode(id: 'm3', sheetId: 's1', x: 100, y: 0, floorIndex: 3);
  const fx = NetNode(
      id: 'fx',
      sheetId: 's1',
      x: 200,
      y: 0,
      floorIndex: 3,
      role: NodeRole.fixture,
      fixture: PlumbingFixture.lavatory);
  final upNet = Network(
    nodes: const [pump, m0, m3, fx],
    edges: [
      _run('a', 'pump', 'm0', ServiceType.coldWater),
      _riser('r', 'm0', 'm3', ServiceType.coldWater),
      _run('b', 'm3', 'fx', ServiceType.coldWater),
    ],
  );

  // ── water-drainage-1 — plant elevation follows WHAT the plant is ──────────
  group('water-drainage-1 · a ground-floor pump is not at the roof', () {
    test('pump / groundTank / boosterSet sit on their own floor surface', () {
      for (final c in [
        NodeComponent.pump,
        NodeComponent.groundTank,
        NodeComponent.boosterSet,
      ]) {
        final n = NetNode(
            id: 'p',
            sheetId: 's1',
            x: 0,
            y: 0,
            floorIndex: 1,
            role: NodeRole.plant,
            component: c);
        // floor 1 surface = 4.0 m.
        expect(nodeElevation(n, building4).meters, closeTo(4.0, 1e-12));
      }
      expect(nodeElevation(pump, building4).meters, 0.0);
    });

    test('roofTank keeps the roof; an untyped plant only on the top storey', () {
      const roofTank = NetNode(
          id: 't',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 3,
          role: NodeRole.plant,
          component: NodeComponent.roofTank);
      const untyped = NetNode(
          id: 'u',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant);
      expect(nodeElevation(roofTank, building4).meters, closeTo(16.0, 1e-12));
      // Round 17 — an untyped plant on L0 sits on L0's surface (0.0 m), so an
      // upfeed source drawn there lifts the whole building; on the TOP storey
      // it keeps the legacy roof datum (16.0 m).
      expect(nodeElevation(untyped, building4).meters, closeTo(0.0, 1e-12));
      expect(
          nodeElevation(untyped.copyWith(floorIndex: 3), building4).meters,
          closeTo(16.0, 1e-12));
    });

    test('air plant: AHU / fans on the floor, FCU / AC at the ceiling', () {
      NetNode air(NodeComponent c) => NetNode(
          id: 'x',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 2,
          role: NodeRole.plant,
          component: c);
      // floor 2 surface = 8.0; ceiling = 8 + 4 − 0.3 = 11.7.
      for (final c in [
        NodeComponent.ahu,
        NodeComponent.supplyFan,
        NodeComponent.exhaustFan,
      ]) {
        expect(nodeElevation(air(c), building4).meters, closeTo(8.0, 1e-12));
      }
      for (final c in [
        NodeComponent.fcu,
        NodeComponent.acCassette,
        NodeComponent.acSplitWall,
        NodeComponent.acDucted,
      ]) {
        expect(nodeElevation(air(c), building4).meters, closeTo(11.7, 1e-12));
      }
    });

    test('an explicit elevation still wins', () {
      final raised = pump.copyWith(elevation: const Length(2.5));
      expect(nodeElevation(raised, building4).meters, 2.5);
    });

    test('upfeed pump head includes the full static lift to the top fixture',
        () {
      // Frictionless (no sizing): head = (fx − pump) + target
      //   = (12 + 1.1 − 0) + 5.0 = 13.1 + target.
      // Before the fix the pump sat at the roof (16.0 m), the fixture's gain
      // was 13.1 − 16 = −2.9 m and the head collapsed to ≈ target alone.
      final sol = solvePressurized(
        net: upNet,
        service: ServiceType.coldWater,
        sourceId: 'pump',
        edgeFlows: const {},
        sizing: const {},
        calibrationBySheet: cal,
        building: building4,
        targetResidual: target,
      );
      expect(sol.requiredPumpHead.meters, closeTo(13.1 + targetHead, 1e-9));
      expect(sol.requiredPumpHead.meters, greaterThanOrEqualTo(13.1 + 4.99));
    });

    test('with real sizing the head is static + target + friction (> 18.1 m)',
        () {
      final sizing = autoSizeNetwork(
        upNet,
        const SizingContext(),
        leafDemand: const {ServiceType.coldWater: FlowRate(0)},
        nodeFixtureUnits: const {'fx': 1.0},
        leafFixtureUnits: const {ServiceType.coldWater: 1.0},
        building: building4,
        calibrationBySheet: cal,
      );
      final sol = solvePressurized(
        net: upNet,
        service: ServiceType.coldWater,
        sourceId: 'pump',
        edgeFlows: {for (final e in sizing.entries) e.key: e.value.flow},
        sizing: sizing,
        calibrationBySheet: cal,
        building: building4,
        targetResidual: target,
      );
      expect(sol.requiredPumpHead.meters, greaterThan(13.1 + targetHead));
    });

    test('a ground tank now sorts BELOW a roof tank (source pick contract)',
        () {
      // The app's _pickSource sorts plant nodes by nodeElevation: lowest for
      // upfeed, highest for downfeed. With every plant at the roof it could
      // not tell them apart; now groundTank (0 m) < roofTank (16 m).
      const ground = NetNode(
          id: 'gt',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant,
          component: NodeComponent.groundTank);
      const roof = NetNode(
          id: 'rt',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 3,
          role: NodeRole.plant,
          component: NodeComponent.roofTank);
      final plants = [roof, ground];
      double e(NetNode n) => nodeElevation(n, building4).meters;
      final up = [...plants]..sort((a, b) => e(a).compareTo(e(b)));
      final down = [...plants]..sort((a, b) => e(b).compareTo(e(a)));
      expect(up.first.id, 'gt');
      expect(down.first.id, 'rt');
    });
  });

  // ── water-drainage-5 — the target is owed at DELIVERY nodes only ──────────
  group('water-drainage-5 · critical node is a fixture, not a ceiling main',
      () {
    test('upfeed: critical = the fixture, its residual = target', () {
      final sol = solvePressurized(
        net: upNet,
        service: ServiceType.coldWater,
        sourceId: 'pump',
        edgeFlows: const {},
        sizing: const {},
        calibrationBySheet: cal,
        building: building4,
        targetResidual: target,
      );
      expect(sol.criticalNodeId, 'fx');
      expect(
          sol.residualPressure['fx']!.pascals, closeTo(target.pascals, 1e-6));
      // m3 is at 15.7 m, 2.6 m ABOVE the fixture: residual
      //   = (13.1 + target) − 15.7 = target − 2.6 m — reported, not owed.
      expect(sol.residualPressure['m3']!.pascals,
          closeTo(pressureFromHead(Head(targetHead - 2.6)).pascals, 1e-6));
    });

    test('downfeed: booster derives from the fixture residual', () {
      // roof tank (16.0) —riser→ m3 (15.7) —run→ fx (13.1), frictionless.
      //   residual(m3) = 0.3 m; residual(fx) = 16 − 13.1 = 2.9 m.
      //   booster = target − 2.9 (was target − 0.3 judged at m3).
      const tank = NetNode(
          id: 'tank',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 3,
          role: NodeRole.plant,
          component: NodeComponent.roofTank);
      final net = Network(
        nodes: const [tank, m3, fx],
        edges: [
          _riser('t', 'tank', 'm3', ServiceType.coldWater),
          _run('b', 'm3', 'fx', ServiceType.coldWater),
        ],
      );
      final sol = solveDownfeed(
        net: net,
        service: ServiceType.coldWater,
        tankId: 'tank',
        edgeFlows: const {},
        sizing: const {},
        calibrationBySheet: cal,
        building: building4,
        targetResidual: target,
      );
      expect(sol.criticalNodeId, 'fx');
      expect(sol.residualPressure['m3']!.pascals,
          closeTo(pressureFromHead(const Head(0.3)).pascals, 1e-6));
      expect(sol.boosterHeadRequired.meters, closeTo(targetHead - 2.9, 1e-9));
    });

    test('no fixture reachable ⇒ open leaves are the delivery points', () {
      // tank —riser→ mA (floor 3, interior) —riser→ mB (floor 0, leaf).
      //   mB residual = 16 − 3.7 = 12.3 m ≥ target ⇒ no booster; mA (0.3 m)
      //   is a pass-through junction.
      const tank = NetNode(
          id: 'tank',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 3,
          role: NodeRole.plant,
          component: NodeComponent.roofTank);
      const mA = NetNode(id: 'mA', sheetId: 's1', x: 0, y: 0, floorIndex: 3);
      const mB = NetNode(id: 'mB', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
      final net = Network(
        nodes: const [tank, mA, mB],
        edges: [
          _riser('t', 'tank', 'mA', ServiceType.coldWater),
          _riser('u', 'mA', 'mB', ServiceType.coldWater),
        ],
      );
      final sol = solveDownfeed(
        net: net,
        service: ServiceType.coldWater,
        tankId: 'tank',
        edgeFlows: const {},
        sizing: const {},
        calibrationBySheet: cal,
        building: building4,
        targetResidual: target,
      );
      expect(sol.criticalNodeId, 'mB');
      expect(sol.minResidual.pascals,
          closeTo(pressureFromHead(const Head(12.3)).pascals, 1e-6));
      expect(sol.gravitySufficient, isTrue);
    });
  });

  // ── water-drainage-8 — the solves honour the project MountingHeights ──────
  group('water-drainage-8 · project mounting heights reach the solves', () {
    // floor-0 main —riser→ floor-1 fixture, mounting (drop 0.8, fixture 0.3):
    //   main = 0 + 4 − 0.8 = 3.2 m; fixture = 4 + 0.3 = 4.3 m ⇒ Δ = 1.10 m
    //   (default mounting: 3.7 → 5.1 ⇒ 1.40 m).
    const mounting =
        MountingHeights(ceilingDrop: Length(0.8), fixtureHeight: Length(0.3));
    const src = NetNode(id: 's', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
    const f1 = NetNode(
        id: 'f1',
        sheetId: 's1',
        x: 0,
        y: 0,
        floorIndex: 1,
        role: NodeRole.fixture);
    final net = Network(
      nodes: const [src, f1],
      edges: [_riser('r', 's', 'f1', ServiceType.coldWater)],
    );

    test('edgeLength basis: 1.10 m with the project mounting', () {
      expect(
          edgeLength(net.edges.single, net,
                  calibrationBySheet: cal,
                  building: building4,
                  mounting: mounting)
              .meters,
          closeTo(1.10, 1e-12));
    });

    test('upfeed static lift uses the project mounting (1.10 m, not 1.40)', () {
      final sol = solvePressurized(
        net: net,
        service: ServiceType.coldWater,
        sourceId: 's',
        edgeFlows: const {},
        sizing: const {},
        calibrationBySheet: cal,
        building: building4,
        targetResidual: target,
        mounting: mounting,
      );
      expect(sol.requiredPumpHead.meters, closeTo(1.10 + targetHead, 1e-9));
      final dflt = solvePressurized(
        net: net,
        service: ServiceType.coldWater,
        sourceId: 's',
        edgeFlows: const {},
        sizing: const {},
        calibrationBySheet: cal,
        building: building4,
        targetResidual: target,
      );
      expect(dflt.requiredPumpHead.meters, closeTo(1.40 + targetHead, 1e-9));
    });

    test('riser friction length uses the project mounting', () {
      // One sized riser carrying 1 L/s in DN25: h_f ∝ L, so the friction with
      // the project mounting is (1.10 / 1.40) × the default-mounting friction.
      const flow = FlowRate(0.001);
      const sizing = {
        'r': EdgeSizing(
            edgeId: 'r',
            service: ServiceType.coldWater,
            flow: flow,
            diameter: Diameter(0.025),
            velocity: Velocity(2.04)),
      };
      Head head(MountingHeights m) => solvePressurized(
            net: net,
            service: ServiceType.coldWater,
            sourceId: 's',
            edgeFlows: const {'r': flow},
            sizing: sizing,
            calibrationBySheet: cal,
            building: building4,
            targetResidual: target,
            mounting: m,
          ).requiredPumpHead;
      final fProject = head(mounting).meters - 1.10 - targetHead;
      final fDefault = head(const MountingHeights()).meters - 1.40 - targetHead;
      expect(fDefault, greaterThan(0));
      expect(fProject, closeTo(fDefault * 1.10 / 1.40, 1e-9));
    });
  });

  // ── water-drainage-2 — horizontal rainwater runs are gravity drains ────────
  group('water-drainage-2 · rainwater collectors size by Manning', () {
    // rd (roof drain, floor 3) —run→ top (main) —riser→ out (floor 0).
    const rd = NetNode(
        id: 'rd',
        sheetId: 's1',
        x: 0,
        y: 0,
        floorIndex: 3,
        role: NodeRole.fixture,
        component: NodeComponent.roofDrain);
    const top = NetNode(id: 'top', sheetId: 's1', x: 500, y: 0, floorIndex: 3);
    const out = NetNode(id: 'out', sheetId: 's1', x: 500, y: 0, floorIndex: 0);
    final net = Network(
      nodes: const [rd, top, out],
      edges: [
        _run('h', 'rd', 'top', ServiceType.rainwater),
        _riser('dp', 'top', 'out', ServiceType.rainwater),
      ],
    );

    test(
        'a 10 L/s collector is DN200; its downpipe (table DN100) is raised '
        'to DN200 so it never necks down (Round 12)', () {
      // Manning full bore, n = 0.010, S = 0.01, Q = (1/n)·A·R^(2/3)·√S:
      //   DN100: R = 0.025, R^(2/3) = 0.08550, A = 7.854e-3
      //          Q = 100 × 7.854e-3 × 0.08550 × 0.1 = 6.715 L/s full bore —
      //          already below 10 L/s (the old table pick was DN100).
      //   DN150: R = 0.0375, R^(2/3) = 0.11204, A = 0.017671
      //          Q_full = 19.80 L/s → half-full 9.90 L/s < 10 ✗
      //   DN200: R = 0.05, R^(2/3) = 0.13572, A = 0.031416
      //          Q_full = 42.64 L/s → half-full 21.32 L/s ≥ 10 ✓ ⇒ DN200.
      // Downpipe table row (10.5 L/s, DN100) is the riser's OWN pick, but the
      // DN200 collector discharges into it — Round 12 (mech-props-2
      // rain-downpipe-shrinks) clamps the downpipe ≥ that collector: DN200.
      final dn100Full = 100 *
          (math.pi * 0.1 * 0.1 / 4) *
          math.pow(0.025, 2 / 3) *
          math.sqrt(0.01);
      expect(dn100Full * 1000, closeTo(6.715, 1e-2));

      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.rainwater: FlowRate(0.010)},
      );
      expect(sized['h']!.flow.inLitersPerSecond, closeTo(10.0, 1e-9));
      expect(sized['h']!.diameter.inMillimeters, closeTo(200, 1e-9));
      expect(sized['h']!.overCapacity, isFalse);
      expect(
          sized['h']!.diameter.inMillimeters,
          drain
              .sizeForFlow(flow: const FlowRate(0.010), slope: 0.01)
              .diameter
              .inMillimeters);
      expect(
          storm
              .sizeRainwaterDownpipe(const FlowRate(0.010))
              .diameter
              .inMillimeters,
          closeTo(100, 1e-9));
      expect(sized['dp']!.diameter.inMillimeters, closeTo(200, 1e-9));
      expect(sized['dp']!.stackRaisedForBranch, isTrue);
    });

    test('a collector past DN300 half-full is flagged overCapacity', () {
      // DN300 half-full: R = 0.075, R^(2/3) = 0.17784, A = 0.070686
      //   Q_full = 100 × 0.070686 × 0.17784 × 0.1 = 125.7 L/s → half 62.9 L/s.
      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.rainwater: FlowRate(0.070)},
      );
      expect(sized['h']!.diameter.inMillimeters, closeTo(300, 1e-9));
      expect(sized['h']!.overCapacity, isTrue);
    });

    // Residual — the collector carries the Manning sizer's self-cleansing
    // verdict (M5 mirror); the downpipe keeps `true` (no Manning velocity).
    //   v_full = (1/n)·R^(2/3)·√S, R = D/4, n = 0.010; floor 0.6 m/s.
    test('1 L/s at S = 0.01: DN75 at 0.706 m/s self-cleanses', () {
      // DN50 half-full: 100 × 1.9635e-3 × 0.0125^(2/3) × 0.1 / 2 = 0.529 L/s ✗
      // DN75 half-full: 100 × 4.418e-3 × 0.01875^(2/3) × 0.1 / 2 = 1.559 L/s ✓
      //   v = 100 × 0.01875^(2/3) × 0.1 = 0.706 m/s ≥ 0.6 ⇒ OK.
      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.rainwater: FlowRate(0.001)},
      );
      final v = 100 * math.pow(0.075 / 4, 2 / 3) * math.sqrt(0.01);
      expect(v, closeTo(0.706, 1e-3));
      expect(sized['h']!.diameter.inMillimeters, closeTo(75, 1e-9));
      expect(sized['h']!.velocity.metersPerSecond, closeTo(v, 1e-9));
      expect(sized['h']!.selfCleansingOk, isTrue);
      expect(sized['dp']!.selfCleansingOk, isTrue);
    });

    test('1 L/s laid flat (S = 0.002): DN100 at 0.382 m/s is flagged', () {
      // √0.002 = 0.044721:
      //   DN75  half-full: 3.118 × 0.44721 / 2 = 0.697 L/s ✗
      //   DN100 half-full: 100 × 7.854e-3 × 0.025^(2/3) × 0.044721 / 2
      //                    = 1.50 L/s ✓ ⇒ DN100,
      //   v = 100 × 0.025^(2/3) × 0.044721 = 0.382 m/s < 0.6 ⇒ NOT OK.
      const flat = SizingContext(drainageSlope: 0.002);
      final sized = autoSizeNetwork(
        net,
        flat,
        leafDemand: const {ServiceType.rainwater: FlowRate(0.001)},
      );
      final v = 100 * math.pow(0.1 / 4, 2 / 3) * math.sqrt(0.002);
      expect(v, closeTo(0.382, 1e-3));
      expect(sized['h']!.diameter.inMillimeters, closeTo(100, 1e-9));
      expect(sized['h']!.selfCleansingOk, isFalse);
      // Same verdict as the gravity sizer it came from.
      expect(
          drain
              .sizeForFlow(flow: const FlowRate(0.001), slope: 0.002)
              .selfCleansing,
          isFalse);
      // The vertical downpipe still forms no self-cleansing verdict.
      expect(sized['dp']!.selfCleansingOk, isTrue);
    });

    test('a collector override is re-judged on the Manning basis', () {
      // DN150 at S = 0.002: v = 100 × 0.0375^(2/3) × 0.044721 = 0.501 m/s ✗;
      // at the default S = 0.01: v = 100 × 0.0375^(2/3) × 0.1 = 1.120 m/s ✓.
      final v002 = 100 * math.pow(0.15 / 4, 2 / 3) * math.sqrt(0.002);
      final flat = autoSizeNetwork(
        net,
        const SizingContext(drainageSlope: 0.002),
        leafDemand: const {ServiceType.rainwater: FlowRate(0.001)},
        sizeOverrides: {'h': Diameter.mm(150)},
      );
      expect(flat['h']!.velocity.metersPerSecond, closeTo(v002, 1e-9));
      expect(flat['h']!.selfCleansingOk, isFalse);
      final steep = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.rainwater: FlowRate(0.001)},
        sizeOverrides: {'h': Diameter.mm(150)},
      );
      expect(steep['h']!.selfCleansingOk, isTrue);
    });
  });

  // ── water-drainage-3 + fire-1 — inline terminals bear demand ──────────────
  group('water-drainage-3 · inline (degree-2) terminals contribute demand', () {
    test('rd1–rd2–rd3–top → riser: the downpipe carries 3 drains', () {
      NetNode drainAt(String id, double x) => NetNode(
          id: id,
          sheetId: 's1',
          x: x,
          y: 0,
          floorIndex: 3,
          role: NodeRole.fixture,
          component: NodeComponent.roofDrain);
      final net = Network(
        nodes: [
          drainAt('rd1', 0),
          drainAt('rd2', 100),
          drainAt('rd3', 200),
          const NetNode(id: 'top', sheetId: 's1', x: 300, y: 0, floorIndex: 3),
          const NetNode(id: 'out', sheetId: 's1', x: 300, y: 0, floorIndex: 0),
        ],
        edges: [
          _run('a', 'rd1', 'rd2', ServiceType.rainwater),
          _run('b', 'rd2', 'rd3', ServiceType.rainwater),
          _run('c', 'rd3', 'top', ServiceType.rainwater),
          _riser('dp', 'top', 'out', ServiceType.rainwater),
        ],
      );
      // q = 5 L/s per drain: a = q, b = 2q, c = dp = 3q = 15 L/s.
      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.rainwater: FlowRate(0.005)},
      );
      expect(sized['a']!.flow.inLitersPerSecond, closeTo(5, 1e-9));
      expect(sized['b']!.flow.inLitersPerSecond, closeTo(10, 1e-9));
      expect(sized['c']!.flow.inLitersPerSecond, closeTo(15, 1e-9));
      expect(sized['dp']!.flow.inLitersPerSecond, closeTo(15, 1e-9));
      // Downpipe table: 15 L/s → first row ≥ 15 is (19.0, DN125) — its own
      // pick. The collector c (15 L/s, Manning half-full: DN150 9.90 L/s ✗,
      // DN200 21.32 L/s ✓ ⇒ DN200) discharges into it, so Round 12 raises
      // the downpipe to DN200 (never smaller than its collector).
      expect(
          storm
              .sizeRainwaterDownpipe(const FlowRate(0.015))
              .diameter
              .inMillimeters,
          closeTo(125, 1e-9));
      expect(sized['c']!.diameter.inMillimeters, closeTo(200, 1e-9));
      expect(sized['dp']!.diameter.inMillimeters, closeTo(200, 1e-9));
    });

    test('src–o1–o2 untyped water outlets: a carries f(2 × fuPerLeaf)', () {
      NetNode outlet(String id, double x) => NetNode(
          id: id,
          sheetId: 's1',
          x: x,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture,
          component: NodeComponent.waterOutlet);
      final net = Network(
        nodes: [
          const NetNode(id: 'src', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          outlet('o1', 100),
          outlet('o2', 200),
        ],
        edges: [
          _run('a', 'src', 'o1', ServiceType.coldWater),
          _run('b', 'o1', 'o2', ServiceType.coldWater),
        ],
      );
      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.coldWater: FlowRate(0)},
        leafFixtureUnits: const {ServiceType.coldWater: 2.0},
      );
      // Curve (flush tank) 0 → 10 UBAP is linear 0 → 0.5 L/s:
      //   f(4) = 0.05 × 4 = 0.2 L/s (was f(2) = 0.1 with o1 dropped);
      //   f(2) = 0.1 L/s on b.
      expect(sized['a']!.flow.inLitersPerSecond, closeTo(0.2, 1e-9));
      expect(sized['b']!.flow.inLitersPerSecond, closeTo(0.1, 1e-9));
    });

    test('an untyped inline floor drain adds kDefaultLeafDfu', () {
      // src —a→ fd (floor drain, inline) —b→ lav (1 DFU).
      //   a carries 1 + 2 (kDefaultLeafDfu) = 3 DFU → branch row (3, DN50);
      //   b carries 1 DFU → (1, DN40). Dropping fd would leave a at DN40.
      expect(kDefaultLeafDfu, 2.0);
      final net = Network(
        nodes: const [
          NetNode(id: 'src', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(
              id: 'fd',
              sheetId: 's1',
              x: 100,
              y: 0,
              floorIndex: 0,
              role: NodeRole.fixture,
              component: NodeComponent.floorDrain),
          NetNode(
              id: 'lav',
              sheetId: 's1',
              x: 200,
              y: 0,
              floorIndex: 0,
              role: NodeRole.fixture),
        ],
        edges: [
          _run('a', 'src', 'fd', ServiceType.drainage),
          _run('b', 'fd', 'lav', ServiceType.drainage),
        ],
      );
      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.drainage: FlowRate(0)},
        nodeDrainageUnits: const {'lav': 1.0},
      );
      expect(sized['a']!.diameter.inMillimeters, closeTo(50, 1e-9));
      expect(sized['b']!.diameter.inMillimeters, closeTo(40, 1e-9));
    });

    test('an inline cleanout is an access fitting, not a demand point', () {
      final net = Network(
        nodes: const [
          NetNode(id: 'src', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(
              id: 'co',
              sheetId: 's1',
              x: 100,
              y: 0,
              floorIndex: 0,
              role: NodeRole.fixture,
              component: NodeComponent.cleanout),
          NetNode(
              id: 'lav',
              sheetId: 's1',
              x: 200,
              y: 0,
              floorIndex: 0,
              role: NodeRole.fixture),
        ],
        edges: [
          _run('a', 'src', 'co', ServiceType.drainage),
          _run('b', 'co', 'lav', ServiceType.drainage),
        ],
      );
      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.drainage: FlowRate(0)},
        nodeDrainageUnits: const {'lav': 1.0},
      );
      // a carries only lav's 1 DFU → DN40.
      expect(sized['a']!.diameter.inMillimeters, closeTo(40, 1e-9));
    });
  });

  // ── water-drainage-3 residual — UNTYPED air terminals bear the default ────
  // Decided deliberately: an air terminal (supply diffuser / return grille)
  // with no assigned airflow carries the flat per-terminal default
  // (`kDefaultLeafDemand` in the app, the `leafDemand` map here) WHEREVER it
  // sits — a leaf already did, and an inline (degree-2) one now does too, so a
  // duct through three diffusers carries three diffusers' air. An explicit
  // airflow (`nodeFlowDemand`) always wins.
  group('water-drainage-3 residual · untyped air terminals', () {
    NetNode term(String id, double x, NodeComponent c) => NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: 0,
        role: NodeRole.fixture,
        component: c);
    const ahu = NetNode(
        id: 'ahu',
        sheetId: 's1',
        x: 0,
        y: 0,
        floorIndex: 0,
        role: NodeRole.plant,
        component: NodeComponent.ahu);

    test('ahu → d1 (inline) → d2 (leaf), no airflow: a = 2q, b = q', () {
      final net = Network(
        nodes: [
          ahu,
          term('d1', 100, NodeComponent.supplyDiffuser),
          term('d2', 200, NodeComponent.supplyDiffuser),
        ],
        edges: [
          _run('a', 'ahu', 'd1', ServiceType.duct),
          _run('b', 'd1', 'd2', ServiceType.duct),
        ],
      );
      // q = 50 L/s (the app's kDefaultLeafDemand for ServiceType.duct).
      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.duct: FlowRate(0.05)},
      );
      expect(sized['b']!.flow.inLitersPerSecond, closeTo(50, 1e-9)); // leaf
      expect(sized['a']!.flow.inLitersPerSecond, closeTo(100, 1e-9)); // +inline
    });

    test('inline return grille, no airflow, also bears the default', () {
      final net = Network(
        nodes: [
          ahu,
          term('g1', 100, NodeComponent.returnGrille),
          term('g2', 200, NodeComponent.returnGrille),
        ],
        edges: [
          _run('a', 'ahu', 'g1', ServiceType.returnAir),
          _run('b', 'g1', 'g2', ServiceType.returnAir),
        ],
      );
      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.returnAir: FlowRate(0.05)},
      );
      expect(sized['b']!.flow.inLitersPerSecond, closeTo(50, 1e-9));
      expect(sized['a']!.flow.inLitersPerSecond, closeTo(100, 1e-9));
    });

    test('an explicit inline airflow wins over the default', () {
      final net = Network(
        nodes: [
          ahu,
          term('d1', 100, NodeComponent.supplyDiffuser),
          term('d2', 200, NodeComponent.supplyDiffuser),
        ],
        edges: [
          _run('a', 'ahu', 'd1', ServiceType.duct),
          _run('b', 'd1', 'd2', ServiceType.duct),
        ],
      );
      // d1 = 120 L/s explicit, d2 = default 50 ⇒ a = 170, b = 50.
      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.duct: FlowRate(0.05)},
        nodeFlowDemand: const {'d1': FlowRate(0.12)},
      );
      expect(sized['b']!.flow.inLitersPerSecond, closeTo(50, 1e-9));
      expect(sized['a']!.flow.inLitersPerSecond, closeTo(170, 1e-9));
    });
  });

  group('fire-1 · inline sprinkler heads / hydrant boxes bear demand', () {
    test('plant → h1..h5 in series: first edge 5 heads, last edge 1', () {
      final nodes = <NetNode>[
        const NetNode(
            id: 'p',
            sheetId: 's1',
            x: 0,
            y: 0,
            floorIndex: 0,
            role: NodeRole.plant),
        for (var i = 1; i <= 5; i++)
          NetNode(
              id: 'h$i',
              sheetId: 's1',
              x: 100.0 * i,
              y: 0,
              floorIndex: 0,
              role: NodeRole.fixture,
              component: NodeComponent.sprinklerHead),
      ];
      final net = Network(nodes: nodes, edges: [
        for (var i = 1; i <= 5; i++)
          _run('e$i', i == 1 ? 'p' : 'h${i - 1}', 'h$i',
              ServiceType.fireSprinkler),
      ]);
      const ctx = SizingContext();
      final sized = autoSizeNetwork(
        net,
        ctx,
        leafDemand: const {ServiceType.fireSprinkler: FlowRate(0.0005)},
      );
      // Edge e_i carries the heads beyond it: (6 − i) × 0.5 L/s.
      for (var i = 1; i <= 5; i++) {
        expect(
            sized['e$i']!.flow.inLitersPerSecond, closeTo((6 - i) * 0.5, 1e-9));
      }
      // e1 = 2.5 L/s at the Round 21 6 m/s fire cap needs d ≥ √(4Q/πv)
      //   = √(4 × 0.0025 / (π × 6)) = 23.0 mm ⇒ the DN25 sprinkler floor
      // governs (DN25 v = 0.0025/4.9087e-4 = 5.09 ≤ 6) — never smaller than
      // e5 (0.5 L/s, also on the floor).
      final e1 = sized['e1']!;
      expect(e1.diameter.inMillimeters,
          greaterThanOrEqualTo(sized['e5']!.diameter.inMillimeters));
      expect(e1.diameter.inMillimeters, closeTo(25, 1e-9));
      expect(e1.diameter.inMillimeters,
          greaterThanOrEqualTo(math.sqrt(4 * 0.0025 / (math.pi * 6)) * 1000));
      expect(e1.diameter.inMillimeters,
          sizeEdge(net.edgeById('e1')!, e1.flow, ctx).diameter.inMillimeters);
    });

    test('3-storey hydrant riser: the base carries 3 boxes', () {
      final net = Network(
        nodes: [
          const NetNode(
              id: 'p',
              sheetId: 's1',
              x: 0,
              y: 0,
              floorIndex: 0,
              role: NodeRole.plant),
          for (var i = 1; i <= 3; i++)
            NetNode(
                id: 'hb$i',
                sheetId: 's1',
                x: 0,
                y: 0,
                floorIndex: i - 1,
                role: NodeRole.fixture,
                component: NodeComponent.hydrantBox),
        ],
        edges: [
          _riser('r1', 'p', 'hb1', ServiceType.fireHydrant),
          _riser('r2', 'hb1', 'hb2', ServiceType.fireHydrant),
          _riser('r3', 'hb2', 'hb3', ServiceType.fireHydrant),
        ],
      );
      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
      );
      expect(sized['r1']!.flow.inLitersPerSecond, closeTo(15, 1e-9));
      expect(sized['r2']!.flow.inLitersPerSecond, closeTo(10, 1e-9));
      expect(sized['r3']!.flow.inLitersPerSecond, closeTo(5, 1e-9));
    });
  });

  // ── water-drainage-4 — DFU table overload is flagged ─────────────────────
  group('water-drainage-4 · DFU past the table top raises overCapacity', () {
    Network one(ServiceType s, EdgeKind k) => Network(
          nodes: const [
            NetNode(id: 'r', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            NetNode(
                id: 'd',
                sheetId: 's1',
                x: 0,
                y: 0,
                floorIndex: 1,
                role: NodeRole.fixture),
          ],
          edges: [
            NetEdge(id: 'e', fromId: 'r', toId: 'd', service: s, kind: k),
          ],
        );
    EdgeSizing size(ServiceType s, EdgeKind k, double dfu) => autoSizeNetwork(
          one(s, k),
          const SizingContext(),
          leafDemand: {s: const FlowRate(0)},
          nodeDrainageUnits: {'d': dfu},
        )['e']!;

    // Round 17 (gravity-3-2) — the tables continue to the IPC DN300 rows
    // (stack top 6000 DFU, branch top 3900 DFU); 1200 DFU on a stack is the
    // DN200 row (960 < 1200 ≤ 2200), only past the DN300 row is it a clamp.
    test('stack: 7000 DFU > 6000 top row ⇒ DN300 flagged; 1200 → DN200', () {
      final over = size(ServiceType.drainage, EdgeKind.riser, 7000);
      expect(over.diameter.inMillimeters, closeTo(300, 1e-9));
      expect(over.overCapacity, isTrue);
      final ok = size(ServiceType.drainage, EdgeKind.riser, 1200);
      expect(ok.diameter.inMillimeters, closeTo(200, 1e-9));
      expect(ok.overCapacity, isFalse);
      final ok900 = size(ServiceType.drainage, EdgeKind.riser, 900);
      expect(ok900.diameter.inMillimeters, closeTo(150, 1e-9));
    });

    test('branch: 5000 DFU > 3900 top row ⇒ flagged; 2000 → DN250', () {
      expect(
          size(ServiceType.drainage, EdgeKind.run, 5000).overCapacity, isTrue);
      final b = size(ServiceType.drainage, EdgeKind.run, 2000);
      expect(b.overCapacity, isFalse);
      expect(b.diameter.inMillimeters, closeTo(250, 1e-9));
      // 840 DFU (12-storey office building drain): 620 < 840 ≤ 1400 ⇒ DN200.
      final bd = size(ServiceType.drainage, EdgeKind.run, 840);
      expect(bd.diameter.inMillimeters, closeTo(200, 1e-9));
      expect(bd.overCapacity, isFalse);
    });

    // Round 9 — the vent table is UPC 703.2 (top row 1380 DFU → DN150).
    test('vent: 1500 DFU > 1380 top row ⇒ DN150 flagged; 1000 not', () {
      final over = size(ServiceType.vent, EdgeKind.run, 1500);
      expect(over.diameter.inMillimeters, closeTo(150, 1e-9));
      expect(over.overCapacity, isTrue);
      expect(size(ServiceType.vent, EdgeKind.run, 1000).overCapacity, isFalse);
    });

    test('pure predicates', () {
      expect(drain.drainDfuExceedsTable(6000, isStack: true), isFalse);
      expect(drain.drainDfuExceedsTable(6000.5, isStack: true), isTrue);
      expect(drain.drainDfuExceedsTable(3900, isStack: false), isFalse);
      expect(drain.drainDfuExceedsTable(3901, isStack: false), isTrue);
      expect(drain.ventDfuExceedsTable(1380), isFalse);
      expect(drain.ventDfuExceedsTable(1381), isTrue);
    });
  });

  // ── water-drainage-6 — the demand curve extrapolates (and flags) ─────────
  group('water-drainage-6 · demand curve beyond 3000 UBAP', () {
    const sni = SniProfile();
    double q(double u) => sni.probableFlowForFixtureUnits(u).inLitersPerSecond;

    test('strictly increasing past the last charted point', () {
      expect(q(4000), greaterThan(q(3000)));
      expect(q(3000), greaterThan(q(2000)));
      expect(q(6000), greaterThan(q(4000)));
    });

    test('4000 UBAP = 27.2333 + 1000 × 6.98333e-3 = 34.2167 L/s', () {
      // Last segment slope: (1634 − 1215) L/min / 1000 UBAP
      //   = (27.23333 − 20.25) / 1000 = 6.98333e-3 L/s per UBAP.
      expect(q(4000), closeTo(27.23333 + 1000 * 6.98333e-3, 1e-4));
      // 6000 UBAP ≈ 48.18 L/s (the audit's ≈ 48 L/s).
      expect(q(6000), closeTo(27.23333 + 3000 * 6.98333e-3, 1e-4));
      // Flush-valve branch shares the 2000/3000 points ⇒ same continuation.
      expect(
          sni
              .probableFlowForFixtureUnits(4000, system: FlushSystem.flushValve)
              .inLitersPerSecond,
          closeTo(q(4000), 1e-9));
    });

    test('out-of-range predicate', () {
      expect(sni.demandCurveExceeded(3000), isFalse);
      expect(sni.demandCurveExceeded(3000.5), isTrue);
      expect(sni.demandCurveExceeded(3001, system: FlushSystem.flushValve),
          isTrue);
    });

    test('autoSizeNetwork flags an edge carrying > 3000 UBAP', () {
      Network net() => const Network(
            nodes: [
              NetNode(id: 's', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
              NetNode(
                  id: 'f',
                  sheetId: 's1',
                  x: 100,
                  y: 0,
                  floorIndex: 0,
                  role: NodeRole.fixture),
            ],
            edges: [
              NetEdge(
                  id: 'e',
                  fromId: 's',
                  toId: 'f',
                  service: ServiceType.coldWater),
            ],
          );
      EdgeSizing at(double ubap, {Map<String, Diameter> ov = const {}}) =>
          autoSizeNetwork(
            net(),
            const SizingContext(),
            leafDemand: const {ServiceType.coldWater: FlowRate(0)},
            leafFixtureUnits: const {ServiceType.coldWater: 1},
            nodeFixtureUnits: {'f': ubap},
            sizeOverrides: ov,
          )['e']!;
      final big = at(4000);
      expect(big.demandCurveExtrapolated, isTrue);
      expect(big.flow.inLitersPerSecond, closeTo(q(4000), 1e-9));
      expect(at(2000).demandCurveExtrapolated, isFalse);
      // The flag survives a manual size override.
      expect(at(4000, ov: {'e': Diameter.mm(200)}).demandCurveExtrapolated,
          isTrue);
    });
  });

  // ── water-drainage-7 — a drain carrying a WC is ≥ DN75 ───────────────────
  group('water-drainage-7 · water-closet minimum drain size', () {
    // src —branch→ j (floor 1 main) ... a single flush-tank WC = 4 DFU:
    //   DFU tables alone: branch (6, DN65), stack (10, DN50).
    //   UPC/IPC floor: ≥ DN75 for any drain carrying a closet.
    test('premises: a flush-tank WC is 4 DFU; the floor is DN75', () {
      expect(
          drain.drainageFixtureUnit(PlumbingFixture.waterClosetFlushTank), 4);
      expect(drain.kMinWcDrainMm, 75.0);
      // The tables alone would issue DN65 / DN50 for that one WC.
      expect(drain.drainDiameterForDfu(4, isStack: false).inMillimeters, 65);
      expect(drain.drainDiameterForDfu(4, isStack: true).inMillimeters, 50);
    });

    Network wcNet(PlumbingFixture fixture) => Network(
          nodes: [
            const NetNode(id: 'out', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
            const NetNode(id: 'j', sheetId: 's1', x: 0, y: 0, floorIndex: 1),
            NetNode(
                id: 'fx',
                sheetId: 's1',
                x: 100,
                y: 0,
                floorIndex: 1,
                role: NodeRole.fixture,
                fixture: fixture),
          ],
          edges: [
            _riser('stack', 'out', 'j', ServiceType.drainage),
            _run('branch', 'j', 'fx', ServiceType.drainage),
          ],
        );

    test('one flush-tank WC: branch and stack both ≥ DN75', () {
      final sized = autoSizeNetwork(
        wcNet(PlumbingFixture.waterClosetFlushTank),
        const SizingContext(),
        leafDemand: const {ServiceType.drainage: FlowRate(0)},
        nodeDrainageUnits: const {'fx': 4.0},
      );
      expect(sized['branch']!.diameter.inMillimeters, closeTo(75, 1e-9));
      expect(sized['stack']!.diameter.inMillimeters, closeTo(75, 1e-9));
      // The floor IS the code minimum (G1): no not-self-cleansing verdict.
      expect(sized['branch']!.selfCleansingOk, isTrue);
    });

    // Residual — a CUSTOM fixture flagged isWaterCloset (no built-in WC type
    // on the node) reaches the engine as a waterClosetNodeIds entry and gets
    // the same DN75 floor: 4 DFU alone ⇒ branch DN65 / stack DN50 (premises).
    test('a custom WC (waterClosetNodeIds) is floored at DN75 too', () {
      final net = Network(
        nodes: const [
          NetNode(id: 'out', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'j', sheetId: 's1', x: 0, y: 0, floorIndex: 1),
          NetNode(
              id: 'fx',
              sheetId: 's1',
              x: 100,
              y: 0,
              floorIndex: 1,
              role: NodeRole.fixture,
              customFixtureId: 'squat'),
        ],
        edges: [
          _riser('stack', 'out', 'j', ServiceType.drainage),
          _run('branch', 'j', 'fx', ServiceType.drainage),
        ],
      );
      final flagged = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.drainage: FlowRate(0)},
        nodeDrainageUnits: const {'fx': 4.0},
        waterClosetNodeIds: const {'fx'},
      );
      expect(flagged['branch']!.diameter.inMillimeters, closeTo(75, 1e-9));
      expect(flagged['stack']!.diameter.inMillimeters, closeTo(75, 1e-9));
      // Unflagged (default) ⇒ the bare DFU tables: DN65 branch; the stack's
      // table DN50 is then raised to its branch's DN65 (N17 stack ≥ branch).
      final bare = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.drainage: FlowRate(0)},
        nodeDrainageUnits: const {'fx': 4.0},
      );
      expect(bare['branch']!.diameter.inMillimeters, closeTo(65, 1e-9));
      expect(bare['stack']!.diameter.inMillimeters, closeTo(65, 1e-9));
      expect(bare['stack']!.stackRaisedForBranch, isTrue);
    });

    test('a lavatory-only branch still sizes at DN40', () {
      final sized = autoSizeNetwork(
        wcNet(PlumbingFixture.lavatory),
        const SizingContext(),
        leafDemand: const {ServiceType.drainage: FlowRate(0)},
        nodeDrainageUnits: const {'fx': 1.0},
      );
      expect(sized['branch']!.diameter.inMillimeters, closeTo(40, 1e-9));
      expect(sized['stack']!.diameter.inMillimeters, closeTo(40, 1e-9));
    });

    // Round 9 — UPC 703.2 puts 4 DFU in the DN40 row, and the vent is never
    // below ½ the DN75 WC drain it serves (37.5 mm ⇒ DN40).
    test('a vent serving a WC sizes DN40 (UPC row + half-drain floor)', () {
      final net = Network(
        nodes: const [
          NetNode(id: 'v0', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(
              id: 'fx',
              sheetId: 's1',
              x: 100,
              y: 0,
              floorIndex: 0,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.waterClosetFlushTank),
        ],
        edges: [_run('v', 'v0', 'fx', ServiceType.vent)],
      );
      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.vent: FlowRate(0)},
        nodeDrainageUnits: const {'fx': 4.0},
      );
      expect(sized['v']!.diameter.inMillimeters, closeTo(40, 1e-9));
    });
  });
}
