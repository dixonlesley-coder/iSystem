/// Round 30 mechanical seed suite (2026-10-18):
///   * mech-sim-4-branch-dfu-table-shifted — the horizontal-branch DFU table
///     is IPC 710.1(2) with the RIGHT diameters.
///   * mech-sim-4-rainwater-top-junction-under-slab — a roof drain's leader
///     run to a bare top-storey junction carries its drop.
///   * mech-sim-4-phantom-basement-prv-zone — the downfeed zone walk stops at
///     the lowest SERVED floor.
///   * costing-2-2 / costing-2-4 — one elbow per run vertical leg; no
///     elbow / tee at plant nozzles.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/zoning.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart' as drain;
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? component}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: component?.role ?? role,
        component: component);

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

BuildingLevels _tower(int n, double h, {int groundIndex = 0}) =>
    BuildingLevels([for (var i = 0; i < n; i++) Floor('L$i', Length(h))],
        groundIndex: groundIndex);

void main() {
  group('branch DFU table = IPC 710.1(2)', () {
    test(
        'property: every load maps to the smallest IPC branch row covering '
        'it (1½ in 3 · 2 in 6 · 2½ in 12 · 3 in 20 · 4 in 160 …)', () {
      const ipc = [
        (3.0, 40.0),
        (6.0, 50.0),
        (12.0, 65.0),
        (20.0, 75.0),
        (160.0, 100.0),
        (360.0, 125.0),
        (620.0, 150.0),
        (1400.0, 200.0),
      ];
      final rnd = math.Random(30);
      for (var i = 0; i < 400; i++) {
        final dfu = 0.5 + rnd.nextDouble() * 1399;
        final want = ipc.firstWhere((r) => dfu <= r.$1).$2;
        expect(
            drain.drainDiameterForDfu(dfu, isStack: false).inMillimeters, want,
            reason: '$dfu');
      }
      // The tower's apartment branches: SH + LV = 4 DFU ⇒ DN50 (was DN65);
      // a kitchen-sink arm 2 DFU ⇒ DN40 (was DN50).
      expect(drain.drainDiameterForDfu(4, isStack: false).inMillimeters, 50);
      expect(drain.drainDiameterForDfu(2, isStack: false).inMillimeters, 40);
    });

    test(
        'r2: the stack 2½ in row is IPC 710.1(2) <=3-interval 20 DFU '
        '(was 24: a 21-24 DFU stack sized DN65 where IPC gives DN75)', () {
      // IPC 710.1(2), stacks <= 3 branch intervals: 2½ in 20 DFU, 3 in 48.
      // The 3 in row stays at 42 (conservative against 48, recorded).
      expect(drain.drainDiameterForDfu(20, isStack: true).inMillimeters, 65);
      for (final dfu in [20.5, 21.0, 24.0, 42.0]) {
        expect(drain.drainDiameterForDfu(dfu, isStack: true).inMillimeters, 75,
            reason: '$dfu');
      }
      expect(drain.drainDiameterForDfu(10, isStack: true).inMillimeters, 50);
      expect(drain.drainDiameterForDfu(43, isStack: true).inMillimeters, 100);
    });
  });

  group('roof-drain leader drop', () {
    // 10 storeys x 3.2 m: roof 32.0 m. A bare top-storey rainwater junction
    // sits under the top slab = ceiling of floor 8 = 9 x 3.2 - 0.3 = 28.5 m.
    final b = _tower(10, 3.2);
    const cal = ScaleCalibration(0.05);
    double total(Network net) {
      var sum = 0.0;
      for (final e in net.edges) {
        sum += edgeLength(e, net,
                calibrationBySheet: const {'s1': cal}, building: b)
            .meters;
      }
      return sum;
    }

    Network leader(bool asRun) => Network(nodes: [
          _n('RD', 0, 0, floor: 9, component: NodeComponent.roofDrain),
          _n('R9', asRun ? 20 : 0, 0, floor: asRun ? 9 : 8),
          _n('R0', asRun ? 20 : 0, 0, floor: 0),
        ], edges: [
          _e('rd', 'RD', 'R9', ServiceType.rainwater,
              kind: asRun ? EdgeKind.run : EdgeKind.riser),
          _e('dp', 'R9', 'R0', ServiceType.rainwater, kind: EdgeKind.riser),
        ]);

    test(
        'RD -run-> R(top) -riser-> foot carries the full roof-to-foot drop '
        '(32.0 - 0 = 32.0 m vertical, + 1.0 m horizontal)', () {
      // Run: 20 px x 0.05 = 1.0 m horizontal + (32.0 - 28.5) = 3.5 m drop;
      // riser R9 (28.5) -> R0 (0.0, lowest slab) = 28.5 m.
      final run = leader(true);
      expect(runVerticalLeg(run.edges.first, run, building: b).meters,
          closeTo(3.5, 1e-9));
      expect(total(run), closeTo(1.0 + 32.0, 1e-9));
      // The same downpipe drawn RD -riser-> R8 -> R0: 32.0 - 0 = 32.0 m.
      expect(total(leader(false)), closeTo(32.0, 1e-9));
    });

    test(
        'property: the leader idiom never changes the vertical total '
        '(seeded storeys / heights)', () {
      final rnd = math.Random(301);
      for (var i = 0; i < 40; i++) {
        final n = 2 + rnd.nextInt(10);
        final h = 2.8 + rnd.nextDouble() * 2;
        final bb = _tower(n, h);
        final top = n - 1;
        final asRun = Network(nodes: [
          _n('RD', 0, 0, floor: top, component: NodeComponent.roofDrain),
          _n('RT', 0, 0, floor: top),
          _n('R0', 0, 0, floor: 0),
        ], edges: [
          _e('rd', 'RD', 'RT', ServiceType.rainwater),
          _e('dp', 'RT', 'R0', ServiceType.rainwater, kind: EdgeKind.riser),
        ]);
        final asRiser = Network(nodes: [
          _n('RD', 0, 0, floor: top, component: NodeComponent.roofDrain),
          _n('R0', 0, 0, floor: 0),
        ], edges: [
          _e('dp', 'RD', 'R0', ServiceType.rainwater, kind: EdgeKind.riser),
        ]);
        double sum(Network net) => [
              for (final e in net.edges)
                edgeLength(e, net,
                        calibrationBySheet: const {'s1': cal}, building: bb)
                    .meters
            ].fold(0.0, (a, x) => a + x);
        expect(sum(asRun), closeTo(sum(asRiser), 1e-9), reason: '$n x $h');
      }
    });

    test('drainage keeps the datum-free run (no leg)', () {
      final net = Network(nodes: [
        _n('FD', 0, 0, floor: 9, component: NodeComponent.floorDrain),
        _n('J', 20, 0, floor: 9),
      ], edges: [
        _e('d', 'FD', 'J', ServiceType.drainage)
      ]);
      expect(runVerticalLeg(net.edges.first, net, building: b).meters, 0);
    });
  });

  group('downfeed zones stop at the lowest served floor', () {
    test(
        'tank-fed tower over two empty basements: one zone L1..L10, no '
        'phantom B2 PRV station', () {
      // 12 levels x 3.6 m, groundIndex 2 (B2, B1, L0..L9). Roof = 10 x 3.6
      // = 36.0 m; B2 fixture = -7.2 + 1.1 = -6.1 m ⇒ tank head 42.1 m.
      final bb = _tower(12, 3.6, groundIndex: 2);
      final all = computeDownfeedZones(
        building: bb,
        maxStaticPressure: const Pressure(250000),
        tankElevation: bb.roofElevation,
        maxFixtureStatic: const Pressure(400000),
      );
      // The legacy full-building walk opens a basement zone.
      expect(all.last.bottomFloorIndex, 0);
      expect(all.length, greaterThan(1));
      final served = computeDownfeedZones(
        building: bb,
        maxStaticPressure: const Pressure(250000),
        tankElevation: bb.roofElevation,
        maxFixtureStatic: const Pressure(400000),
        lowestServedFloor: 2,
      );
      expect(served.length, 1);
      expect(served.single.topFloorIndex, 11);
      expect(served.single.bottomFloorIndex, 2);
    });

    test(
        'property: zones tile exactly [lowestServed, top], top-down, and '
        'lowestServed 0 is the legacy walk (seeded)', () {
      final rnd = math.Random(302);
      for (var i = 0; i < 60; i++) {
        final n = 2 + rnd.nextInt(30);
        final bb = _tower(n, 3 + rnd.nextDouble() * 2);
        final low = rnd.nextInt(n);
        final tank = rnd.nextBool() ? bb.roofElevation : null;
        List<PressureZone> z(int l) => computeDownfeedZones(
              building: bb,
              maxStaticPressure: const Pressure(250000),
              tankElevation: tank,
              maxFixtureStatic: tank == null ? null : const Pressure(400000),
              lowestServedFloor: l,
            );
        final zs = z(low);
        expect(zs.first.topFloorIndex, n - 1);
        expect(zs.last.bottomFloorIndex, low);
        for (var k = 1; k < zs.length; k++) {
          expect(zs[k].topFloorIndex, zs[k - 1].bottomFloorIndex - 1);
        }
        expect(
            z(0).toString(),
            computeDownfeedZones(
              building: bb,
              maxStaticPressure: const Pressure(250000),
              tankElevation: tank,
              maxFixtureStatic: tank == null ? null : const Pressure(400000),
            ).toString());
      }
    });
  });

  group('fittings: drop elbows and plant nozzles', () {
    int count(List<FittingLine> l, FittingType t) =>
        l.where((x) => x.type == t).fold(0, (a, x) => a + x.count);

    test('a ceiling main dropping to a basin adds ONE elbow at the drop', () {
      // Main at ceiling 4.0 - 0.3 = 3.7 m, basin at 1.1 m ⇒ leg 2.6 m on the
      // 40 px (2.0 m) branch; the straight M0-M1-M2 main has no leg.
      final b1 = _tower(1, 4.0);
      final net = Network(nodes: [
        _n('M0', 0, 0),
        _n('M1', 100, 0),
        _n('M2', 200, 0),
        _n('B', 100, 40, role: NodeRole.fixture),
      ], edges: [
        _e('m1', 'M0', 'M1', ServiceType.coldWater),
        _e('m2', 'M1', 'M2', ServiceType.coldWater),
        _e('br', 'M1', 'B', ServiceType.coldWater),
      ]);
      expect(runVerticalLeg(net.edgeById('br')!, net, building: b1).meters,
          closeTo(2.6, 1e-9));
      final sizing = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0.1)});
      final legacy = buildFittings(net: net, sizing: sizing);
      final withDrops = buildFittings(net: net, sizing: sizing, building: b1);
      // Exactly the runs with a leg add one elbow each: 'br' only.
      expect(count(withDrops, FittingType.elbow),
          count(legacy, FittingType.elbow) + 1);
      expect(count(withDrops, FittingType.tee), count(legacy, FittingType.tee));
    });

    test('a zero-span drop (tee outlet turning straight down) adds none', () {
      final b1 = _tower(1, 4.0);
      final net = Network(nodes: [
        _n('M0', 0, 0),
        _n('B', 0, 0, role: NodeRole.fixture),
      ], edges: [
        _e('br', 'M0', 'B', ServiceType.coldWater)
      ]);
      final sizing = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0.1)});
      expect(
          count(buildFittings(net: net, sizing: sizing, building: b1),
              FittingType.elbow),
          0);
    });

    test(
        'a ground tank with three nozzles and a pump turning 90 deg count '
        'no tee / elbow', () {
      final net = Network(nodes: [
        _n('F', -100, 0),
        _n('GT', 0, 0, component: NodeComponent.groundTank),
        _n('O', 100, 0),
        _n('P', 0, 100, component: NodeComponent.pump),
        _n('X', 100, 100, role: NodeRole.fixture),
      ], edges: [
        _e('fill', 'F', 'GT', ServiceType.coldWater),
        _e('out', 'GT', 'O', ServiceType.coldWater),
        _e('suc', 'GT', 'P', ServiceType.coldWater),
        _e('dis', 'P', 'X', ServiceType.coldWater),
      ]);
      final sizing = <String, EdgeSizing>{
        for (final e in net.edges)
          e.id: EdgeSizing(
            edgeId: e.id,
            service: e.service,
            diameter: Diameter.mm(50),
            velocity: const Velocity(1),
            flow: const FlowRate(0.001),
          ),
      };
      final f = buildFittings(net: net, sizing: sizing);
      expect(count(f, FittingType.tee), 0);
      expect(count(f, FittingType.elbow), 0);
      expect(count(f, FittingType.reducer), 0);
    });
  });

  group('calc report: one fire-pump rating line per drawn system', () {
    CalcReportData data(List<FireSystemReportLine> systems) => CalcReportData(
          projectName: 'F',
          date: '2026-10-18',
          standardsName: 'SNI',
          standardsRevision: 'r',
          verifyItems: const [],
          building: _tower(8, 4),
          feedStrategy: 'Upfeed pump',
          targetResidual: const Pressure(225000),
          firePumpRating: systems.isEmpty ? null : systems.last.rating,
          fireSystems: systems,
        );
    // The round-28 fixture: a sprinkler pump 4.7 L/s @ 133.9 m beside a
    // standpipe pump 31.5 L/s @ 114.5 m.
    final sprinkler = checkFirePumpRating(
        ratedFlow: FlowRate.litersPerSecond(4.7), ratedHead: const Head(133.9));
    final standpipe = checkFirePumpRating(
        ratedFlow: FlowRate.litersPerSecond(31.5),
        ratedHead: const Head(114.5));

    test(
        'two systems: each pump is printed under its tag with its own head '
        'and motor', () {
      final md = buildCalcReportMarkdown(data([
        FireSystemReportLine(
            tag: 'P-01', sprinklerOnly: true, rating: sprinkler),
        FireSystemReportLine(
            tag: 'P-02', sprinklerOnly: false, rating: standpipe),
      ]));
      expect(md, contains('P-01 — sprinkler pump rating curve (NFPA 20):'));
      expect(md, contains('P-02 — standpipe pump rating curve (NFPA 20):'));
      // 133.9 m prints at 0 dp: '134 m'; the sprinkler motor is its own.
      expect(md, contains('@ 134 m'));
      expect(
          md, contains(sprinkler.selectedMotor.inKiloWatts.toStringAsFixed(1)));
    });

    test('one system: no extra line (byte-identical)', () {
      final one = buildCalcReportMarkdown(data([
        FireSystemReportLine(
            tag: 'P-01', sprinklerOnly: false, rating: standpipe),
      ]));
      final none = buildCalcReportMarkdown(CalcReportData(
        projectName: 'F',
        date: '2026-10-18',
        standardsName: 'SNI',
        standardsRevision: 'r',
        verifyItems: const [],
        building: _tower(8, 4),
        feedStrategy: 'Upfeed pump',
        targetResidual: const Pressure(225000),
        firePumpRating: standpipe,
      ));
      expect(one, none);
    });
  });
}
