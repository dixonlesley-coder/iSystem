// reports-4 — a RUN whose two endpoints sit at different solved §10
// elevations (a ceiling main dropping to a WC, a floor pump rising to the
// ceiling main) includes that vertical leg in its length, so the BOM, the run
// schedule and the friction term all carry the pipe the installer actually
// pulls; the plan label states the horizontal leg's hanging height plus the
// drop instead of the mean of the two ends.
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // Two 4.0 m storeys. Defaults: ceiling drop 0.3 m, fixture height 1.1 m.
  //   main on floor 1  → 4.0 + 4.0 − 0.3 = 7.70 m
  //   WC on floor 1    → 4.0 + 1.1       = 5.10 m
  //   pump (explicit 0.0, ground floor) → main on floor 0 at 4.0 − 0.3 = 3.70
  const building =
      BuildingLevels([Floor('G', Length(4)), Floor('1', Length(4))]);
  const cal = {'s0': ScaleCalibration(0.01), 's1': ScaleCalibration(0.01)};

  const net = Network(
    nodes: [
      NetNode(
          id: 'pump',
          sheetId: 's0',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant,
          elevation: Length(0)),
      NetNode(id: 'm0', sheetId: 's0', x: 440, y: 0, floorIndex: 0),
      NetNode(id: 'm1a', sheetId: 's1', x: 0, y: 0, floorIndex: 1),
      NetNode(id: 'm1b', sheetId: 's1', x: 300, y: 0, floorIndex: 1),
      NetNode(
          id: 'wc',
          sheetId: 's1',
          x: 300,
          y: 23,
          floorIndex: 1,
          role: NodeRole.fixture,
          fixture: PlumbingFixture.waterClosetFlushTank),
    ],
    edges: [
      // pump → ceiling main: 440 px × 0.01 = 4.40 m on plan, +3.70 m rise.
      NetEdge(
          id: 'pm', fromId: 'pump', toId: 'm0', service: ServiceType.coldWater),
      // level main on floor 1: 300 px × 0.01 = 3.00 m, no leg.
      NetEdge(
          id: 'mm', fromId: 'm1a', toId: 'm1b', service: ServiceType.coldWater),
      // main → WC branch: 23 px × 0.01 = 0.23 m on plan, 7.70 − 5.10 = 2.60 drop.
      NetEdge(
          id: 'mw', fromId: 'm1b', toId: 'wc', service: ServiceType.coldWater),
    ],
  );

  double len(String id) => edgeLength(net.edgeById(id)!, net,
          calibrationBySheet: cal, building: building)
      .meters;

  test('a run length = horizontal span + the endpoints\' elevation delta', () {
    expect(len('pm'), closeTo(4.40 + 3.70, 1e-9));
    expect(len('mm'), closeTo(3.00, 1e-9));
    expect(len('mw'), closeTo(0.23 + 2.60, 1e-9));
    expect(
        runVerticalLeg(net.edgeById('mm')!, net, building: building).meters, 0);
  });

  test('an uncalibrated run stays zero (never a vertical-only figure)', () {
    final l = edgeLength(net.edgeById('mw')!, net,
        calibrationBySheet: const {}, building: building);
    expect(l.meters, 0);
  });

  test('the BOM metres include every vertical leg', () {
    final sizing = {
      for (final e in net.edges)
        e.id: EdgeSizing(
          edgeId: e.id,
          service: e.service,
          flow: const FlowRate(0.0005),
          diameter: const Diameter(0.025),
          velocity: const Velocity(1.0),
        ),
    };
    final lines = buildBom(
        net: net, sizing: sizing, calibrationBySheet: cal, building: building);
    final total = lines.fold<double>(0, (s, l) => s + l.totalLength.meters);
    // 8.10 + 3.00 + 2.83 = 13.93 m (was 4.40 + 3.00 + 0.23 = 7.63 m).
    expect(total, closeTo(8.10 + 3.00 + 2.83, 1e-9));
  });

  test('plan CL label: the main\'s hanging height + the drop', () {
    final labels = runCentrelineLabels(net, building);
    // Ground-floor main at 3.70 above FFL 0.00; the pump leg is 3.70 m.
    expect(labels['pm'], 'CL +3.70 drop 3.70 m');
    // Level run: bare token (byte-identical to the old mean form).
    expect(labels['mm'], 'CL +3.70');
    // Floor-1 main 7.70 − FFL 4.00 = 3.70; the WC drop 2.60 m.
    expect(labels['mw'], 'CL +3.70 drop 2.60 m');
  });

  group('r4: the leg is component-aware (ceiling terminals, gravity)', () {
    // One 4.0 m storey: main / ceiling 3.70, plumbing fixture 1.10.
    const one = BuildingLevels([Floor('G', Length(4))]);
    const c0 = {'s0': ScaleCalibration(0.02)};
    NetNode term(String id, NodeComponent c, double x, double y) => NetNode(
        id: id,
        sheetId: 's0',
        x: x,
        y: y,
        floorIndex: 0,
        role: c.role,
        component: c);
    final n = Network(nodes: [
      const NetNode(id: 'sa', sheetId: 's0', x: 940, y: 320, floorIndex: 0),
      term('sd', NodeComponent.supplyDiffuser, 1040, 320),
      term('sp', NodeComponent.sprinklerHead, 940, 420),
      const NetNode(id: 'dm', sheetId: 's0', x: 0, y: 0, floorIndex: 0),
      term('fd', NodeComponent.floorDrain, 100, 0),
      term('ho', NodeComponent.hoseReel, 0, 100),
      const NetNode(
          id: 'rt',
          sheetId: 's0',
          x: 0,
          y: 300,
          floorIndex: 0,
          role: NodeRole.plant,
          component: NodeComponent.roofTank),
    ], edges: const [
      // 100 px × 0.02 = 2.00 m; diffuser hangs at the ceiling ⇒ no leg.
      NetEdge(id: 'sad', fromId: 'sa', toId: 'sd', service: ServiceType.duct),
      // 100 px = 2.00 m; sprinkler head at the ceiling ⇒ no leg.
      NetEdge(
          id: 'sps',
          fromId: 'sa',
          toId: 'sp',
          service: ServiceType.fireSprinkler),
      // 100 px = 2.00 m gravity branch to a floor drain ⇒ no leg (no datum).
      NetEdge(
          id: 'dfd', fromId: 'dm', toId: 'fd', service: ServiceType.drainage),
      // A hose reel keeps the fixture height: 2.00 + (3.70 − 1.10) = 4.60 m.
      NetEdge(
          id: 'dho',
          fromId: 'dm',
          toId: 'ho',
          service: ServiceType.fireHydrant),
    ]);
    double l(String id) =>
        edgeLength(n.edgeById(id)!, n, calibrationBySheet: c0, building: one)
            .meters;

    test('a diffuser branch lengths to its calibrated span', () {
      expect(l('sad'), closeTo(2.0, 1e-9));
      expect(runCentrelineLabels(n, one)['sad'], 'CL +3.70');
    });

    test('a sprinkler branch lengths to its calibrated span', () {
      expect(l('sps'), closeTo(2.0, 1e-9));
      expect(runCentrelineLabels(n, one)['sps'], 'CL +3.70');
    });

    test('a gravity fixture branch carries no phantom leg', () {
      expect(l('dfd'), closeTo(2.0, 1e-9));
      // R5: a GRAVITY run prints NO `CL` — the model has no below-slab /
      // invert datum for a drain main (it resolves to its own ceiling), so the
      // ceiling figure would be a fabricated set-out height (see
      // `runCentrelineLabels`). The fall token carries the gravity set-out.
      expect(runCentrelineLabels(n, one).containsKey('dfd'), isFalse);
    });

    test('a hose reel still drops to its fixture height', () {
      expect(l('dho'), closeTo(2.0 + 2.6, 1e-9));
      expect(runCentrelineLabels(n, one)['dho'], 'CL +3.70 drop 2.60 m');
    });

    test('an explicit mount height on a terminal still wins', () {
      const wall = NetNode(
          id: 'w',
          sheetId: 's0',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture,
          component: NodeComponent.returnGrille,
          mountHeight: Length(0.3));
      expect(runConnectionElevation(wall, one).meters, closeTo(0.3, 1e-9));
    });
  });

  group('r4: the CL drop and edgeLength share runVerticalLeg', () {
    // 3 × 4.0 m: roof 12.0, Lantai 2 ceiling 11.70, ground ceiling 3.70.
    const three = BuildingLevels(
        [Floor('G', Length(4)), Floor('1', Length(4)), Floor('2', Length(4))]);
    const c = {'s': ScaleCalibration(0.01)};
    Network tankRun(int floor) => Network(nodes: [
          NetNode(
              id: 'rt',
              sheetId: 's',
              x: 0,
              y: 0,
              floorIndex: floor,
              role: NodeRole.plant,
              component: NodeComponent.roofTank),
          NetNode(id: 'm', sheetId: 's', x: 200, y: 0, floorIndex: floor),
        ], edges: const [
          NetEdge(
              id: 'e', fromId: 'rt', toId: 'm', service: ServiceType.coldWater),
        ]);

    test('roof tank on the top sheet: tag and label agree on the 0.30 m leg',
        () {
      final n = tankRun(2);
      final len = edgeLength(n.edgeById('e')!, n,
              calibrationBySheet: c, building: three)
          .meters;
      // 2.00 m on plan + (12.0 − 11.7) = 2.30 m.
      expect(len, closeTo(2.3, 1e-9));
      expect(runCentrelineLabels(n, three)['e'], 'CL +3.70 drop 0.30 m');
    });

    test('roof tank on a lower sheet: the 8.30 m leg is omitted, not level',
        () {
      final n = tankRun(0);
      final len = edgeLength(n.edgeById('e')!, n,
              calibrationBySheet: c, building: three)
          .meters;
      expect(len, closeTo(2.0 + 8.3, 1e-9));
      expect(runCentrelineLabels(n, three).containsKey('e'), isFalse);
    });
  });

  // Round 34 (fire-hvac-drawings-ahu-duct-drops-to-floor) — a floor-standing
  // AHU / fan takes its ducts at the top of its casing, not at the slab.
  group('air units connect at the casing top', () {
    // L2-like storey: 4.0 m floor-to-floor, ceiling drop 0.3 ⇒ ceiling main at
    // 3.70 m above the floor surface. AHU connection = 0 + 2.0 = 2.0 m
    // (default airUnitConnection) ⇒ vertical leg 3.70 − 2.00 = 1.70 m.
    const one = BuildingLevels([Floor('L2', Length(4))]);
    for (final c in const [
      NodeComponent.ahu,
      NodeComponent.supplyFan,
      NodeComponent.exhaustFan,
    ]) {
      test('${c.name}: 4.0 m duct + a 1.70 m leg (never the 3.70 m drop)', () {
        final n = Network(nodes: [
          NetNode(
              id: 'u',
              sheetId: 's0',
              x: 0,
              y: 0,
              floorIndex: 0,
              role: NodeRole.plant,
              component: c),
          const NetNode(id: 'm', sheetId: 's0', x: 400, y: 0, floorIndex: 0),
        ], edges: const [
          NetEdge(
              id: 'd', fromId: 'u', toId: 'm', service: ServiceType.duct),
        ]);
        final e = n.edgeById('d')!;
        expect(runVerticalLeg(e, n, building: one).meters, closeTo(1.70, 1e-9));
        expect(
            edgeLength(e, n, calibrationBySheet: cal, building: one).meters,
            closeTo(4.0 + 1.70, 1e-9));
        // The static datum (pump-head / riser physics) is unchanged.
        expect(nodeElevation(n.nodeById('u')!, one).meters, 0);
      });
    }

    test('a low storey caps the connection at the ceiling main (no leg)', () {
      // 2.2 m storey ⇒ ceiling 1.90 m < 0 + 2.0 ⇒ connection 1.90 ⇒ leg 0.
      const low = BuildingLevels([Floor('P', Length(2.2))]);
      const n = Network(nodes: [
        NetNode(
            id: 'u',
            sheetId: 's0',
            x: 0,
            y: 0,
            floorIndex: 0,
            role: NodeRole.plant,
            component: NodeComponent.ahu),
        NetNode(id: 'm', sheetId: 's0', x: 400, y: 0, floorIndex: 0),
      ], edges: [
        NetEdge(id: 'd', fromId: 'u', toId: 'm', service: ServiceType.duct),
      ]);
      expect(runVerticalLeg(n.edgeById('d')!, n, building: low).meters, 0);
    });

    test('an explicit unit elevation still wins', () {
      const n = Network(nodes: [
        NetNode(
            id: 'u',
            sheetId: 's0',
            x: 0,
            y: 0,
            floorIndex: 0,
            role: NodeRole.plant,
            component: NodeComponent.ahu,
            elevation: Length(0.5)),
        NetNode(id: 'm', sheetId: 's0', x: 400, y: 0, floorIndex: 0),
      ], edges: [
        NetEdge(id: 'd', fromId: 'u', toId: 'm', service: ServiceType.duct),
      ]);
      expect(runVerticalLeg(n.edgeById('d')!, n, building: one).meters,
          closeTo(3.70 - 0.5, 1e-9));
    });
  });

  // Round 35 (regression-1) — a duct RISER drawn straight from a datum-less
  // AHU / fan reads the SAME casing-top connection a run leg does, so the one
  // physical duct has one length however it is drawn.
  group('air-unit risers measure from the casing top', () {
    // Two 4.0 m storeys, ceiling drop 0.3:
    //   L1 ceiling main = 4.0 − 0.3 = 3.70 m; L2 ceiling main = 8.0 − 0.3 = 7.70
    //   AHU on L1 (surface 0.0) connects at 0.0 + 2.0 = 2.0 m
    //   AHU on L2 (surface 4.0) connects at 4.0 + 2.0 = 6.0 m
    const two = BuildingLevels([Floor('L1', Length(4)), Floor('L2', Length(4))]);
    Network build(int ahuFloor) => Network(nodes: [
          NetNode(
              id: 'u',
              sheetId: 's$ahuFloor',
              x: 0,
              y: 0,
              floorIndex: ahuFloor,
              role: NodeRole.plant,
              component: NodeComponent.ahu),
          const NetNode(id: 'm0', sheetId: 's0', x: 0, y: 0, floorIndex: 0),
          const NetNode(id: 'm1', sheetId: 's1', x: 0, y: 0, floorIndex: 1),
        ], edges: const [
          // direct: AHU → L2 main as one riser
          NetEdge(
              id: 'direct',
              fromId: 'u',
              toId: 'm1',
              service: ServiceType.duct,
              kind: EdgeKind.riser),
          // two-step: AHU -run-> L1 main (zero plan span) -riser-> L2 main
          NetEdge(id: 'run', fromId: 'u', toId: 'm0', service: ServiceType.duct),
          NetEdge(
              id: 'up',
              fromId: 'm0',
              toId: 'm1',
              service: ServiceType.duct,
              kind: EdgeKind.riser),
          NetEdge(
              id: 'down',
              fromId: 'u',
              toId: 'm0',
              service: ServiceType.duct,
              kind: EdgeKind.riser),
        ]);
    double l(Network n, String id, BuildingLevels b) =>
        edgeLength(n.edgeById(id)!, n, calibrationBySheet: cal, building: b)
            .meters;

    test('direct riser == run + riser (7.70 − 2.00 = 5.70 m, never 7.70)', () {
      final n = build(0);
      expect(l(n, 'direct', two), closeTo(7.70 - 2.0, 1e-9));
      expect(l(n, 'run', two) + l(n, 'up', two), closeTo(1.70 + 4.00, 1e-9));
      expect(l(n, 'direct', two),
          closeTo(l(n, 'run', two) + l(n, 'up', two), 1e-9));
      // The inspector readout equals the riser-length datum.
      expect(displayedNodeElevation(n, n.nodeById('u')!, two).meters,
          closeTo(2.0, 1e-9));
      // The static datum the pressure solve uses is unchanged.
      expect(nodeElevation(n.nodeById('u')!, two).meters, 0);
    });

    test('an upper-floor AHU dropping to a lower main: 6.0 − 3.7 = 2.30 m', () {
      final n = build(1);
      expect(l(n, 'down', two), closeTo(6.0 - 3.70, 1e-9));
    });

    test('a 2.2 m storey caps the connection at the ceiling', () {
      // L1 2.2 m (ceiling 1.90 < 2.0 ⇒ connection 1.90), L2 4.0 m (ceiling
      // 2.2 + 4.0 − 0.3 = 5.90) ⇒ riser 5.90 − 1.90 = 4.00 m.
      const low =
          BuildingLevels([Floor('P', Length(2.2)), Floor('L2', Length(4))]);
      final n = build(0);
      expect(l(n, 'direct', low), closeTo(5.90 - 1.90, 1e-9));
    });

    test('property: every drawing of the same duct measures the same', () {
      // Seeded sweep over storey heights / ceiling drops: direct riser equals
      // the run-leg + riser decomposition for every air-unit kind.
      var seed = 35;
      double next() {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed / 0x7fffffff;
      }

      for (var i = 0; i < 200; i++) {
        final h0 = 2.0 + next() * 4.0;
        final h1 = 2.5 + next() * 4.0;
        final drop = 0.1 + next() * 0.6;
        final b = BuildingLevels([Floor('A', Length(h0)), Floor('B', Length(h1))]);
        final m = MountingHeights(ceilingDrop: Length(drop));
        for (final c in const [
          NodeComponent.ahu,
          NodeComponent.supplyFan,
          NodeComponent.exhaustFan,
        ]) {
          final n = Network(nodes: [
            NetNode(
                id: 'u',
                sheetId: 's0',
                x: 0,
                y: 0,
                floorIndex: 0,
                role: NodeRole.plant,
                component: c),
            const NetNode(id: 'm0', sheetId: 's0', x: 0, y: 0, floorIndex: 0),
            const NetNode(id: 'm1', sheetId: 's1', x: 0, y: 0, floorIndex: 1),
          ], edges: const [
            NetEdge(
                id: 'direct',
                fromId: 'u',
                toId: 'm1',
                service: ServiceType.duct,
                kind: EdgeKind.riser),
            NetEdge(
                id: 'run', fromId: 'u', toId: 'm0', service: ServiceType.duct),
            NetEdge(
                id: 'up',
                fromId: 'm0',
                toId: 'm1',
                service: ServiceType.duct,
                kind: EdgeKind.riser),
          ]);
          double ll(String id) => edgeLength(n.edgeById(id)!, n,
                  calibrationBySheet: cal, building: b, mounting: m)
              .meters;
          expect(ll('direct'), closeTo(ll('run') + ll('up'), 1e-9));
        }
      }
    });
  });
}
