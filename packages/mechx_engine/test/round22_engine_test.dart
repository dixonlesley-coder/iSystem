// Round 22 (2026-10-18) — the engine half of the round-22 audit:
//
//   regression-standpipe-every-riser-carries-total-flow
//                            a riser / single-stack trunk carries ONE
//                            standpipe's 500 gpm; only the common supply
//                            carries the multi-riser total
//   regression-jogged-standpipe-counted-twice
//                            stacks in SERIES (a jogged standpipe) count once
//   regression-vent-stack-top-under-top-slab
//                            a vent stack runs to the roof (VTR)
//   regression-riser-page-break-drops-tags
//                            every riser tag prints on exactly one page; a
//                            pass-through riser is drawn on the middle page
//   basement-datum-ffl-label-plus-minus
//                            FFL -3.20, never FFL +-3.20
//   pressurized-3-1          the top zone is fed by the tank head, not a PRV
//   pressurized-3-2          the upfeed solve holds a drawn PRV's setpoint
//   pressurized-3-3          solveDownfeed adds a sized booster's head
//   pressurized-3-4          hot water never takes the flush-valve curve
import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/network/zoning.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/riser_pagination.dart';
import 'package:mechx_engine/report/riser_tags.dart' show fflLabel;
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/supply_design.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _rhoG = 1000 * 9.81;

NetNode _n(String id, double x, int floor,
        {NodeRole role = NodeRole.main,
        NodeComponent? c,
        PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: floor,
        role: role,
        component: c,
        fixture: fixture);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.coldWater, EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

BuildingLevels _uniform(int n, double h) =>
    BuildingLevels([for (var i = 0; i < n; i++) Floor('L$i', Length(h))]);

void main() {
  // ── standpipe: per-riser flow ─────────────────────────────────────────────
  group('regression-standpipe-every-riser-carries-total-flow', () {
    // Pump P -> header H, feeding two 6-storey hydrant stacks A and B with a
    // hydrant box on every floor.
    Network twoStacks() => Network(nodes: [
          _n('P', 0, 0, role: NodeRole.plant, c: NodeComponent.pump),
          _n('H', 50, 0),
          for (final s in ['A', 'B'])
            for (var f = 0; f < 6; f++) ...[
              _n('$s$f', s == 'A' ? 100 : 300, f),
              _n('${s}x$f', s == 'A' ? 150 : 350, f,
                  role: NodeRole.fixture, c: NodeComponent.hydrantBox),
            ],
        ], edges: [
          _e('p', 'P', 'H', s: ServiceType.fireHydrant),
          for (final s in ['A', 'B']) ...[
            _e('h$s', 'H', '${s}0', s: ServiceType.fireHydrant),
            for (var f = 0; f < 5; f++)
              _e('$s$f', '$s$f', '$s${f + 1}',
                  s: ServiceType.fireHydrant, k: EdgeKind.riser),
            for (var f = 0; f < 6; f++)
              _e('${s}b$f', '$s$f', '${s}x$f', s: ServiceType.fireHydrant),
          ],
        ]);

    test('risers carry 500 gpm (DN100); the common header 750 gpm', () {
      final net = twoStacks();
      final n = drawnStandpipeRiserCount(net);
      expect(n, 2);
      final total = standpipeFlow(n);
      final one = standpipeFlow(1);
      // 500 gpm × 3.785411784 / 60 = 31.545 L/s; 750 gpm = 47.318 L/s.
      expect(one.inLitersPerSecond, closeTo(500 * 3.785411784 / 60, 1e-9));
      expect(total.inLitersPerSecond, closeTo(750 * 3.785411784 / 60, 1e-9));
      final sized = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {ServiceType.fireHydrant: FlowRate(0.005)},
        hydrantDesignFlow: total,
      );
      // The header upstream of the split carries the system total.
      expect(sized['p']!.flow.cubicMetersPerSecond,
          closeTo(total.cubicMetersPerSecond, 1e-12));
      // Every riser and each per-stack branch carries ONE standpipe's flow:
      // d = √(4 × 0.031545 / (π × 6)) = 0.0818 m ⇒ DN100 (v = 4.02 m/s);
      // at 47.3 L/s it would be 0.1002 m ⇒ DN125.
      for (final s in ['A', 'B']) {
        for (final id in ['h$s', for (var f = 0; f < 5; f++) '$s$f']) {
          expect(sized[id]!.flow.cubicMetersPerSecond,
              closeTo(one.cubicMetersPerSecond, 1e-12),
              reason: id);
          expect(sized[id]!.diameter.inMillimeters, closeTo(100, 1e-9),
              reason: id);
        }
        // A single-box branch keeps its 5 L/s.
        expect(sized['${s}b0']!.flow.cubicMetersPerSecond,
            closeTo(0.005, 1e-15));
      }
    });
  });

  // ── standpipe: series vs parallel count ───────────────────────────────────
  group('regression-jogged-standpipe-counted-twice', () {
    test('a stack jogging at a transfer floor counts once', () {
      final net = Network(nodes: [
        for (var f = 0; f < 4; f++) _n('a$f', 100, f),
        for (var f = 3; f < 8; f++) _n('b$f', 300, f),
      ], edges: [
        for (var f = 0; f < 3; f++)
          _e('ra$f', 'a$f', 'a${f + 1}',
              s: ServiceType.fireHydrant, k: EdgeKind.riser),
        _e('jog', 'a3', 'b3', s: ServiceType.fireHydrant),
        for (var f = 3; f < 7; f++)
          _e('rb$f', 'b$f', 'b${f + 1}',
              s: ServiceType.fireHydrant, k: EdgeKind.riser),
      ]);
      expect(drawnStandpipeRiserCount(net), 1);
      // 500 gpm, not 750 gpm.
      expect(standpipeFlow(drawnStandpipeRiserCount(net)).inLitersPerMinute,
          closeTo(500 * 3.785411784, 1e-6));
    });

    // Property: m standpipes, each a chain of 1..4 riser segments covering
    // floors [0, N] with a horizontal jog between segments, drawn in random
    // order — every storey interval is covered by exactly m stacks, so the
    // count is m whatever the jogs (seeded).
    test('m jogged parallel stacks count m (seeded property)', () {
      final rnd = math.Random(22);
      for (var trial = 0; trial < 200; trial++) {
        final storeys = 3 + rnd.nextInt(10);
        final m = 1 + rnd.nextInt(4);
        // Round 28 — independent fire networks are separate SYSTEMS (each
        // counts only its own stacks), so the m stacks are drawn off ONE
        // common pump header HDR: a single system with m parallel stacks.
        final nodes = <NetNode>[_n('HDR', -500, 0)];
        final edges = <NetEdge>[];
        for (var k = 0; k < m; k++) {
          edges.add(
              _e('h$k', 'HDR', 's$k-0-0', s: ServiceType.fireHydrant));
          // Random cut floors (strictly inside) split the stack into series
          // segments.
          final cuts = <int>{
            for (var i = 0; i < rnd.nextInt(4); i++) 1 + rnd.nextInt(storeys - 2),
          }.toList()
            ..sort();
          final bounds = [0, ...cuts, storeys - 1];
          for (var seg = 0; seg + 1 < bounds.length; seg++) {
            final x = 1000.0 * k + 50.0 * seg;
            for (var f = bounds[seg]; f <= bounds[seg + 1]; f++) {
              nodes.add(_n('s$k-$seg-$f', x, f));
              // Round 58 — a stack carries hose outlets of its own: a
              // hydrant box on every node of the segment.
              nodes.add(_n('b$k-$seg-$f', x + 5, f,
                  role: NodeRole.fixture, c: NodeComponent.hydrantBox));
              edges.add(_e('bx$k-$seg-$f', 's$k-$seg-$f', 'b$k-$seg-$f',
                  s: ServiceType.fireHydrant));
            }
            for (var f = bounds[seg]; f < bounds[seg + 1]; f++) {
              edges.add(_e('r$k-$seg-$f', 's$k-$seg-$f', 's$k-$seg-${f + 1}',
                  s: ServiceType.fireHydrant, k: EdgeKind.riser));
            }
            if (seg > 0) {
              final f = bounds[seg];
              edges.add(_e('j$k-$seg', 's$k-${seg - 1}-$f', 's$k-$seg-$f',
                  s: ServiceType.fireHydrant));
            }
          }
        }
        edges.shuffle(rnd);
        nodes.shuffle(rnd);
        expect(drawnStandpipeRiserCount(Network(nodes: nodes, edges: edges)),
            m,
            reason: 'trial $trial: $m stacks over $storeys storeys');
      }
    });
  });

  // ── vent stack to the roof ────────────────────────────────────────────────
  group('regression-vent-stack-top-under-top-slab', () {
    Network stack(ServiceType s) => Network(nodes: [
          for (var f = 0; f < 8; f++) _n('v$f', 100, f),
        ], edges: [
          for (var f = 0; f < 7; f++)
            _e('e$f', 'v$f', 'v${f + 1}', s: s, k: EdgeKind.riser),
        ]);
    final b = _uniform(8, 3.6);
    double total(Network net) => [
          for (final e in net.edges)
            edgeLength(e, net, calibrationBySheet: const {}, building: b)
                .meters,
        ].fold(0.0, (a, x) => a + x);

    test('the vent stack is roof − foot = 28.8 m (VTR at the roof)', () {
      // Foot on the lowest slab (0.0), top through the roof at 8 × 3.6.
      expect(b.roofElevation.meters, closeTo(28.8, 1e-9));
      expect(total(stack(ServiceType.vent)), closeTo(28.8, 1e-9));
      final net = stack(ServiceType.vent);
      expect(
          displayedNodeElevation(net, net.nodeById('v7')!, b).meters,
          closeTo(28.8, 1e-9));
    });

    test('a drainage stack keeps the under-slab top datum', () {
      // Top junction under L7's slab = ceiling of L6 = 7 × 3.6 − 0.3.
      final net = stack(ServiceType.drainage);
      expect(total(net), closeTo(b.ceilingElevationOf(6).meters, 1e-9));
    });
  });

  // ── riser pagination keeps every tag ──────────────────────────────────────
  group('regression-riser-page-break-drops-tags', () {
    Network riser(int storeys) => Network(nodes: [
          _n('RT', 100, storeys - 1,
              role: NodeRole.plant, c: NodeComponent.roofTank),
          for (var f = 0; f < storeys; f++) ...[
            _n('R$f', 200, f),
            _n('W$f', 400, f, role: NodeRole.fixture),
            _n('L$f', 420, f, role: NodeRole.fixture),
          ],
        ], edges: [
          _e('t', 'RT', 'R${storeys - 1}'),
          for (var f = 0; f < storeys - 1; f++)
            _e('r$f', 'R$f', 'R${f + 1}', k: EdgeKind.riser),
          for (var f = 0; f < storeys; f++) ...[
            _e('w$f', 'R$f', 'W$f'),
            _e('l$f', 'R$f', 'L$f'),
          ],
        ]);
    BuildingLevels building(int n) => BuildingLevels(
        [for (var i = 0; i < n; i++) Floor('Lantai ${i + 1}', const Length(3.5))]);
    bool isRiserId(SldLabel l) => RegExp(r'^CW-R\d+$').hasMatch(l.text);

    test('Σ riser-id labels over the pages == the single sheet', () {
      final net = riser(12);
      final b = building(12);
      SldSheet build(({int lo, int hi})? r) => buildMechanicalRiserSld(
          network: net, building: b, focus: ServiceType.coldWater,
          floorRange: r);
      final whole = build(null).prims.whereType<SldLabel>().where(isRiserId);
      final pages = paginatedRiserSheets(build: build, levelCount: 12);
      expect(pages.length, greaterThan(1));
      final paged = [
        for (final p in pages)
          ...p.prims.whereType<SldLabel>().where(isRiserId).map((l) => l.text),
      ];
      expect(paged.length, whole.length);
      expect(paged..sort(), [...whole.map((l) => l.text)]..sort());
    });

    test('a riser spanning a whole page is drawn on it (pass-through)', () {
      // One riser A (Lantai 1) -> B (Lantai 12); 4 floors per page.
      final net = Network(nodes: [
        _n('A', 200, 0),
        _n('B', 200, 11),
        _n('WA', 400, 0, role: NodeRole.fixture),
        _n('WB', 400, 11, role: NodeRole.fixture),
      ], edges: [
        _e('r', 'A', 'B', k: EdgeKind.riser),
        _e('wa', 'A', 'WA'),
        _e('wb', 'B', 'WB'),
      ]);
      final b = building(12);
      final chunks = riserFloorChunks(12, 4);
      expect(chunks[1], (lo: 4, hi: 7));
      final middle = buildMechanicalRiserSld(
          network: net, building: b, focus: ServiceType.coldWater,
          floorRange: chunks[1]);
      final verticals = middle.prims.whereType<SldLine>().where((l) =>
          (l.x1 - l.x2).abs() < 1e-9 &&
          (l.y1 - l.y2).abs() > 100 &&
          l.layer == 'CW');
      expect(verticals, isNotEmpty);
      final lanjut = middle.prims
          .whereType<SldLabel>()
          .where((l) => l.text.startsWith('LANJUT KE '))
          .map((l) => l.text)
          .toSet();
      expect(lanjut, {'LANJUT KE Lantai 12', 'LANJUT KE Lantai 1'});
    });
  });

  // ── FFL notation ──────────────────────────────────────────────────────────
  group('basement-datum-ffl-label-plus-minus', () {
    test('signed FFL labels', () {
      expect(fflLabel(-3.2), 'FFL -3.20');
      expect(fflLabel(-6.2), 'FFL -6.20');
      expect(fflLabel(4), 'FFL +4.00');
      expect(fflLabel(0), 'FFL +0.00');
      // Anything rounding to zero prints +0.00, never -0.00.
      expect(fflLabel(-0.004), 'FFL +0.00');
    });

    test('the riser gutter of a basement building carries no "+-"', () {
      const b = BuildingLevels([
        Floor('B2', Length(3.0)),
        Floor('B1', Length(3.2)),
        Floor('Ground', Length(4.0)),
        Floor('L1', Length(3.5)),
        Floor('L2', Length(3.5)),
      ], groundIndex: 2);
      final net = Network(nodes: [
        for (var f = 0; f < 5; f++) _n('R$f', 200, f),
        for (var f = 0; f < 5; f++) _n('W$f', 400, f, role: NodeRole.fixture),
      ], edges: [
        for (var f = 0; f < 4; f++)
          _e('r$f', 'R$f', 'R${f + 1}', k: EdgeKind.riser),
        for (var f = 0; f < 5; f++) _e('w$f', 'R$f', 'W$f'),
      ]);
      final s = buildMechanicalRiserSld(network: net, building: b);
      final ffl = [
        for (final l in s.prims.whereType<SldLabel>())
          if (l.text.startsWith('FFL ')) l.text,
      ];
      expect(ffl, containsAll(['FFL -6.20', 'FFL -3.20', 'FFL +0.00']));
      expect(ffl.any((t) => t.contains('+-')), isFalse);
    });
  });

  // ── tank-fed top zone ─────────────────────────────────────────────────────
  group('pressurized-3-1 tank-fed top zone', () {
    final maxFix = const SniProfile().maxFixtureStaticPressure.value;
    final setpoint = defaultPrvSetpoint(
        targetResidual: SupplyDesignCriteria.recommended()
            .targetFixtureResidualPressure,
        maxFixtureStatic: maxFix);
    final budget = Pressure(maxFix.pascals - setpoint.pascals);

    test('6 × 3.5 m, tank at 21 m: one tank-fed zone, no PRV', () {
      final b = _uniform(6, 3.5);
      const tank = Length(21);
      final zones = computeDownfeedZones(
          building: b,
          maxStaticPressure: budget,
          tankElevation: tank,
          maxFixtureStatic: maxFix);
      expect(zones, [const PressureZone(5, 0)]);
      final statics = downfeedZoneStatics(
          building: b,
          zones: zones,
          prvSetpoint: setpoint,
          maxStatic: maxFix,
          tankElevation: tank);
      expect(statics.single.viaPrv, isFalse);
      // Ground fixture: ρg × (21 − 1.1) = 195.2 kPa; top ceiling main at
      // 6 × 3.5 − 0.3 = 20.7 m ⇒ ρg × 0.3 = 2.94 kPa.
      expect(statics.single.bottomStatic.pascals,
          closeTo(_rhoG * (21 - 1.1), 1e-6));
      expect(statics.single.topResidual.pascals,
          closeTo(_rhoG * (21 - b.ceilingElevationOf(5).meters), 1e-6));
      expect(statics.single.withinLimit, isTrue);
    });

    test('10 × 4.5 m, tank at 45 m: only L0 needs a PRV station', () {
      final b = _uniform(10, 4.5);
      const tank = Length(45);
      // L1 fixture: ρg(45 − 4.5 − 1.1) = 386.5 kPa ≤ 392; L0: 430.7 > 392.
      expect(_rhoG * (45 - 4.5 - 1.1), lessThan(maxFix.pascals));
      expect(_rhoG * (45 - 1.1), greaterThan(maxFix.pascals));
      final zones = computeDownfeedZones(
          building: b,
          maxStaticPressure: budget,
          tankElevation: tank,
          maxFixtureStatic: maxFix);
      expect(zones, [const PressureZone(9, 1), const PressureZone(0, 0)]);
      final statics = downfeedZoneStatics(
          building: b,
          zones: zones,
          prvSetpoint: setpoint,
          maxStatic: maxFix,
          tankElevation: tank);
      expect([for (final z in statics) z.viaPrv], [false, true]);
      expect(statics[1].topResidual, setpoint);
      expect(statics.every((z) => z.withinLimit), isTrue);
    });

    // Property: for random buildings and tank heights, every zone passes and
    // the tank-fed zone holds exactly the floors whose tank head is within the
    // limit (seeded).
    test('tank zone = floors within the tank head (seeded property)', () {
      final rnd = math.Random(2210);
      for (var t = 0; t < 200; t++) {
        final n = 2 + rnd.nextInt(25);
        final b = BuildingLevels([
          for (var i = 0; i < n; i++)
            Floor('L$i', Length(3.0 + rnd.nextDouble() * 2))
        ]);
        final tank = Length(b.roofElevation.meters + rnd.nextDouble() * 6);
        final zones = computeDownfeedZones(
            building: b,
            maxStaticPressure: budget,
            tankElevation: tank,
            maxFixtureStatic: maxFix);
        final top = zones.first;
        for (var f = top.bottomFloorIndex; f < n - 1; f++) {
          expect(_rhoG * (tank.meters - b.fixtureElevationOf(f).meters),
              lessThanOrEqualTo(maxFix.pascals + 1e-6));
        }
        if (top.bottomFloorIndex > 0) {
          expect(
              _rhoG *
                  (tank.meters -
                      b.fixtureElevationOf(top.bottomFloorIndex - 1).meters),
              greaterThan(maxFix.pascals));
        }
        final statics = downfeedZoneStatics(
            building: b,
            zones: zones,
            prvSetpoint: setpoint,
            maxStatic: maxFix,
            tankElevation: tank);
        expect(statics.every((z) => z.withinLimit), isTrue,
            reason: 'trial $t');
        // Floors partition exactly, top → bottom.
        expect(zones.last.bottomFloorIndex, 0);
        for (var i = 0; i + 1 < zones.length; i++) {
          expect(zones[i + 1].topFloorIndex, zones[i].bottomFloorIndex - 1);
        }
      }
    });
  });

  // ── upfeed PRV ────────────────────────────────────────────────────────────
  group('pressurized-3-2 upfeed PRV', () {
    const storeys = 8;
    final b = _uniform(storeys, 3.5);
    const cal = {'s1': ScaleCalibration(0.01)};
    Network net() => Network(nodes: [
          _n('P', 0, 0, role: NodeRole.plant, c: NodeComponent.pump),
          for (var f = 0; f < storeys; f++) ...[
            _n('R$f', 100, f),
            _n('W$f', 300, f,
                role: NodeRole.fixture,
                fixture: PlumbingFixture.waterClosetFlushTank),
          ],
          _n('V0', 200, 0, c: NodeComponent.prv),
        ], edges: [
          _e('p', 'P', 'R0'),
          for (var f = 0; f < storeys - 1; f++)
            _e('r$f', 'R$f', 'R${f + 1}', k: EdgeKind.riser),
          _e('v0', 'R0', 'V0'),
          _e('w0', 'V0', 'W0'),
          for (var f = 1; f < storeys; f++) _e('w$f', 'R$f', 'W$f'),
        ]);

    test('the PRV outlet holds its setpoint; the pump head is unchanged', () {
      final network = net();
      final sizing = autoSizeNetwork(network, const SizingContext(),
          leafDemand: const {}, leafFixtureUnits: const {
            ServiceType.coldWater: 3,
          });
      final flows = {for (final e in sizing.entries) e.key: e.value.flow};
      const target = Pressure(225000);
      const setpoint = Pressure(255000);
      PressureSolution solve(Pressure sp) => solvePressurized(
            net: network,
            service: ServiceType.coldWater,
            sourceId: 'P',
            edgeFlows: flows,
            sizing: sizing,
            calibrationBySheet: cal,
            building: b,
            targetResidual: target,
            prvSetpoint: sp,
          );
      // A setpoint no inlet reaches ⇒ the PRV never reduces (the old field).
      final open = solve(const Pressure(1e9));
      final held = solve(setpoint);
      expect(held.requiredPumpHead.meters,
          closeTo(open.requiredPumpHead.meters, 1e-12));
      expect(open.residualPressure['V0']!.pascals,
          greaterThan(setpoint.pascals));
      // Outlet = setpoint (flowing and no-flow).
      expect(held.residualPressure['V0']!.pascals,
          closeTo(setpoint.pascals, 1e-6));
      expect(held.noFlowStaticPressure['V0']!.pascals,
          closeTo(setpoint.pascals, 1e-6));
      // Below it the field drops by exactly the excess the PRV removed.
      final dFlow = open.residualPressure['V0']!.pascals - setpoint.pascals;
      expect(held.residualPressure['W0']!.pascals,
          closeTo(open.residualPressure['W0']!.pascals - dFlow, 1e-6));
      // No-flow at W0 = setpoint + ρg(elev V0 − elev W0).
      final drop = nodeElevation(network.nodeById('V0')!, b).meters -
          nodeElevation(network.nodeById('W0')!, b).meters;
      expect(held.noFlowStaticPressure['W0']!.pascals,
          closeTo(setpoint.pascals + _rhoG * drop, 1e-6));
      // Upstream of the PRV nothing moves.
      for (final id in ['R0', 'R3', 'W5']) {
        expect(held.residualPressure[id]!.pascals,
            closeTo(open.residualPressure[id]!.pascals, 1e-9));
      }
    });
  });

  // ── downfeed booster head ─────────────────────────────────────────────────
  group('pressurized-3-3 downfeed delivered field', () {
    test('a sized booster adds its head to what it serves', () {
      final b = _uniform(4, 3.5);
      const cal = {'s1': ScaleCalibration(0.01)};
      final network = Network(nodes: [
        _n('RT', 0, 3, role: NodeRole.plant, c: NodeComponent.roofTank),
        for (var f = 0; f < 4; f++) ...[
          _n('R$f', 100, f),
          _n('W$f', 300, f, role: NodeRole.fixture),
        ],
        _n('BS', 200, 3, c: NodeComponent.boosterSet),
      ], edges: [
        _e('t', 'RT', 'R3'),
        for (var f = 0; f < 3; f++)
          _e('r$f', 'R$f', 'R${f + 1}', k: EdgeKind.riser),
        _e('b', 'R3', 'BS'),
        _e('w3', 'BS', 'W3'),
        for (var f = 0; f < 3; f++) _e('w$f', 'R$f', 'W$f'),
      ]);
      final sizing = autoSizeNetwork(network, const SizingContext(),
          leafDemand: const {},
          leafFixtureUnits: const {ServiceType.coldWater: 3});
      final flows = {for (final e in sizing.entries) e.key: e.value.flow};
      DownfeedSolution solve(Map<String, Head> heads) => solveDownfeed(
            net: network,
            service: ServiceType.coldWater,
            tankId: 'RT',
            edgeFlows: flows,
            sizing: sizing,
            calibrationBySheet: cal,
            building: b,
            targetResidual: const Pressure(225000),
            prvSetpoint: const Pressure(1e9),
            moverHeads: heads,
          );
      final base = solve(const {});
      final boosted = solve(const {'BS': Head(20)});
      // W3 is served by BS: +ρg × 20 m flowing and no-flow.
      expect(boosted.residualPressure['W3']!.pascals,
          closeTo(base.residualPressure['W3']!.pascals + _rhoG * 20, 1e-6));
      expect(boosted.noFlowStaticPressure['W3']!.pascals,
          closeTo(base.noFlowStaticPressure['W3']!.pascals + _rhoG * 20,
              1e-6));
      // Nodes not served by BS are untouched.
      for (final id in ['R3', 'W2', 'W0']) {
        expect(boosted.residualPressure[id]!.pascals,
            closeTo(base.residualPressure[id]!.pascals, 1e-9));
      }
    });
  });

  // ── hot water off the flush-valve curve ───────────────────────────────────
  group('pressurized-3-4 hot water flush tank', () {
    test('a flush-valve project sizes HW on the tank curve, CW on valve', () {
      // Two 6-fixture trees (3 UBAP each ⇒ 18 UBAP trunk), one per service.
      Network tree(ServiceType s, String p) => Network(nodes: [
            _n('${p}S', 0, 0, role: NodeRole.plant),
            _n('${p}J', 100, 0),
            for (var i = 0; i < 6; i++)
              _n('$p$i', 200.0 + 20 * i, 0, role: NodeRole.fixture),
          ], edges: [
            _e('${p}t', '${p}S', '${p}J', s: s),
            for (var i = 0; i < 6; i++) _e('$p$i', '${p}J', '$p$i', s: s),
          ]);
      final cw = tree(ServiceType.coldWater, 'c');
      final hw = tree(ServiceType.hotWater, 'h');
      final net = Network(
          nodes: [...cw.nodes, ...hw.nodes], edges: [...cw.edges, ...hw.edges]);
      final sized = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {},
          leafFixtureUnits: const {
            ServiceType.coldWater: 3,
            ServiceType.hotWater: 3,
          },
          flushSystem: FlushSystem.flushValve);
      const sni = SniProfile();
      expect(
          sized['ht']!.flow.cubicMetersPerSecond,
          closeTo(
              sni
                  .probableFlowForFixtureUnits(18, system: FlushSystem.flushTank)
                  .cubicMetersPerSecond,
              1e-12));
      expect(
          sized['ct']!.flow.cubicMetersPerSecond,
          closeTo(
              sni
                  .probableFlowForFixtureUnits(18,
                      system: FlushSystem.flushValve)
                  .cubicMetersPerSecond,
              1e-12));
      // The valve branch is genuinely larger at 18 UBAP.
      expect(sized['ct']!.flow.cubicMetersPerSecond,
          greaterThan(sized['ht']!.flow.cubicMetersPerSecond));
    });
  });

  // Keep hydraulics imported for pressureFromHead use in derivations.
  test('ρg constant matches the engine', () {
    expect(pressureFromHead(const Head(1)).pascals, closeTo(_rhoG, 1e-9));
  });
}
