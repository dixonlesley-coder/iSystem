/// M1 + M9 — the two pressure-side honesty fixes.
///
/// **M1 (`network/zoning.dart`)** — `computeDownfeedZones` used to budget a zone
/// on the FLOOR-SURFACE delta `elevationOf(top) − elevationOf(bottom)`, while
/// `downfeedZoneStatics` measures the real thing: the ceiling main on the zone's
/// top floor down to the fixture connection on its bottom floor. The unbudgeted
/// difference is exactly
///     Δ = floorHeight(top) − ceilingDrop − fixtureHeight
///       = h_top − 0.3 − 1.1                       (default MountingHeights)
/// so any building with storeys tall enough to push a zone's true span past the
/// budget was handed zones the module's own checker rejected. The zoner now
/// budgets the SAME span the checker measures ⇒ compliant by construction.
///
/// **M9 (`network/pressure_solve.dart`)** — the upfeed solve DEFINES
/// `requiredPumpHead = max(friction + elevation + target)` and then reports
/// `residual = requiredPumpHead − friction − elevation`, so `residual ≥ target`
/// is an algebraic identity, not a check. The result now says so via
/// `PressureSolution.targetHeldByDesign` (true on upfeed); the gravity downfeed
/// solve, whose residuals really can fall short, carries false. Additive only —
/// every number is unchanged (pinned below).
///
/// Constants used throughout (all hand-derived, ρg = 1000 × 9.81 = 9810 Pa/m):
///   maxFixtureStatic = 392 266 Pa   (SNI zoning design max, ≈4 kgf/cm²)
///   prvSetpoint      = 225 000 Pa   (2.25 bar target residual held at zone top)
///   span budget      = 392 266 − 225 000 = 167 266 Pa
///                    = 167 266 / 9810 = 17.0506 m         ← maxZoneHeight
library;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/network/zoning.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

// ── Shared M1 fixtures ─────────────────────────────────────────────────────

/// SNI zoning design maximum at the lowest fixture (≈4 kgf/cm²).
const _maxFixtureStatic = Pressure(392266);

/// PRV setpoint held at each zone top (2.25 bar design target residual).
const _prv = Pressure(225000);

/// What the caller has left for the zone's own static drop.
const _budget = Pressure(392266 - 225000); // 167 266 Pa ⇒ 17.0506 m

BuildingLevels _uniform(int count, double height) => BuildingLevels(
      [for (var i = 0; i < count; i++) Floor('L$i', Length(height))],
    );

/// Every zone measured by the module's OWN checker, against the real limit.
List<DownfeedZoneStatic> _check(
  BuildingLevels b,
  List<PressureZone> zones, {
  MountingHeights mounting = const MountingHeights(),
}) =>
    downfeedZoneStatics(
      building: b,
      zones: zones,
      prvSetpoint: _prv,
      maxStatic: _maxFixtureStatic,
      mounting: mounting,
    );

void main() {
  // ══ M1 ═══════════════════════════════════════════════════════════════════

  group('M1 — generated zones are compliant by construction (sweep)', () {
    // Floor heights spanning the realistic Indonesian range, at several stack
    // depths. For EVERY combination the zoner's output must satisfy the
    // checker's own withinLimit — the property the datum mismatch broke.
    const heights = [2.5, 3.0, 3.2, 3.5, 4.0, 4.5, 5.0];
    const counts = [1, 2, 3, 5, 8, 12, 20];

    for (final h in heights) {
      for (final n in counts) {
        test('uniform ${n}x${h}m: every zone passes downfeedZoneStatics', () {
          final b = _uniform(n, h);
          final zones =
              computeDownfeedZones(building: b, maxStaticPressure: _budget);
          final statics = _check(b, zones);

          expect(statics, hasLength(zones.length));
          for (final s in statics) {
            // A single storey is indivisible, so the only zone the zoner may
            // legitimately emit over-limit is one whose OWN floor already
            // exceeds the budget (h − 1.4 > 17.05 m, i.e. h > 18.45 m — far
            // outside this sweep). Nothing here may fail.
            expect(
              s.withinLimit,
              isTrue,
              reason: '${n}x${h}m zone ${s.zone} bottom static '
                  '${s.bottomStatic.pascals} Pa exceeds '
                  '${_maxFixtureStatic.pascals} Pa',
            );
          }

          // …and the zones must still partition the stack exactly once.
          final covered = zones.expand((z) => z.floors).toList()..sort();
          expect(covered, List.generate(n, (i) => i));
        });
      }
    }

    test('mixed floor heights: every zone passes', () {
      // A realistic irregular stack: tall ground/plant floors, ordinary typicals
      // and one very tall hall — 16 levels, cycling 5.0 / 3.0 / 3.6 / 4.5 m.
      const cycle = [5.0, 3.0, 3.6, 4.5];
      final b = BuildingLevels(
        [for (var i = 0; i < 16; i++) Floor('L$i', Length(cycle[i % 4]))],
      );
      final zones =
          computeDownfeedZones(building: b, maxStaticPressure: _budget);
      for (final s in _check(b, zones)) {
        expect(s.withinLimit, isTrue, reason: 'mixed-height zone ${s.zone}');
      }
      final covered = zones.expand((z) => z.floors).toList()..sort();
      expect(covered, List.generate(16, (i) => i));
    });

    test('with basements (negative datum): every zone passes', () {
      // groundIndex 2 ⇒ two basements read negative. Elevation DELTAS (and so
      // every zone span) are datum-independent, but the sweep pins that.
      final b = BuildingLevels(
        [for (var i = 0; i < 12; i++) const Floor('L', Length(4.0))],
        groundIndex: 2,
      );
      final zones =
          computeDownfeedZones(building: b, maxStaticPressure: _budget);
      for (final s in _check(b, zones)) {
        expect(s.withinLimit, isTrue, reason: 'basement stack zone ${s.zone}');
      }
    });

    test('a custom MountingHeights is honoured on both sides', () {
      // ceilingDrop 0.5, fixtureHeight 0.9 ⇒ Δ = h − 1.4 is unchanged in this
      // case, so also try an asymmetric pair that genuinely moves the span.
      const mounting =
          MountingHeights(ceilingDrop: Length(0.8), fixtureHeight: Length(0.4));
      final b = _uniform(14, 4.0);
      final zones = computeDownfeedZones(
        building: b,
        maxStaticPressure: _budget,
        mounting: mounting,
      );
      for (final s in _check(b, zones, mounting: mounting)) {
        expect(s.withinLimit, isTrue, reason: 'custom-mounting zone ${s.zone}');
      }
    });
  });

  group('M1 — hand-derived 12 x 4.0 m case (the audit probe)', () {
    final b = _uniform(12, 4.0);
    // Budget = 17.0506 m. Span measured for a candidate zone [top … f]:
    //   ceiling(top) − fixture(f) = (4·top + 4 − 0.3) − (4·f + 1.1).
    //
    // Zone A, top = 11 (ceiling 47.7 m):
    //   f = 8 : 47.7 − 33.1 = 14.6 m ≤ 17.05  ✓ included
    //   f = 7 : 47.7 − 29.1 = 18.6 m > 17.05  ✗ → close A = [11 … 8]
    // Zone B, top = 7 (ceiling 31.7 m):
    //   f = 4 : 31.7 − 17.1 = 14.6 m ✓ ; f = 3 : 18.6 m ✗ → B = [7 … 4]
    // Zone C, top = 3 (ceiling 15.7 m):
    //   f = 0 : 15.7 −  1.1 = 14.6 m ✓ → C = [3 … 0]
    late List<PressureZone> zones;

    setUp(() {
      zones = computeDownfeedZones(building: b, maxStaticPressure: _budget);
    });

    test('boundaries are [11-8], [7-4], [3-0]', () {
      expect(zones, const [
        PressureZone(11, 8),
        PressureZone(7, 4),
        PressureZone(3, 0),
      ]);
    });

    test('every zone bottom static = 225 000 + 9810 x 14.6 = 368 226 Pa', () {
      for (final s in _check(b, zones)) {
        expect(s.bottomStatic.pascals, closeTo(368226, 1e-6));
        expect(s.withinLimit, isTrue);
      }
    });

    test('the OLD floor-surface boundaries were the ones the checker rejected',
        () {
      // What the pre-fix zoner produced (budgeting 4·(top − f) ≤ 17.05 ⇒ at
      // most 4 storeys of surface delta): [11-7], [6-2], [1-0].
      // Measured properly those top two span 18.6 m ⇒ 225 000 + 9810 × 18.6
      // = 407 466 Pa > 392 266 Pa — the audit's "2 of 3 zones at 407.5 kPa".
      const old = [PressureZone(11, 7), PressureZone(6, 2), PressureZone(1, 0)];
      final statics = _check(b, old);
      expect(statics[0].bottomStatic.pascals, closeTo(407466, 1e-6));
      expect(statics[0].withinLimit, isFalse);
      expect(statics[1].bottomStatic.pascals, closeTo(407466, 1e-6));
      expect(statics[1].withinLimit, isFalse);
      // Only the bottom zone (span 6.6 m) was compliant.
      expect(statics[2].bottomStatic.pascals, closeTo(289746, 1e-6));
      expect(statics[2].withinLimit, isTrue);
      // …and the fix does NOT simply add zones: still 3, just placed honestly.
      expect(zones, hasLength(old.length));
    });
  });

  group('M1 — identity: a building that already passed is unchanged', () {
    test('12 x 3.0 m keeps the pre-fix boundaries [11-6], [5-0]', () {
      // PRE-FIX output (floor-surface budget, 3·(top − f) ≤ 17.0506 ⇒ at most 5
      // storeys of delta): top = 11 breaks at f = 5 (18.0 m) ⇒ [11 … 6]; then
      // top = 5 reaches f = 0 (15.0 m ≤ 17.05) ⇒ [5 … 0].
      // Those zones ALREADY passed the checker — span 35.7 − 19.1 = 16.6 m and
      // 17.7 − 1.1 = 16.6 m, i.e. 225 000 + 9810 × 16.6 = 387 846 Pa ≤ 392 266 —
      // so the stricter budget must reproduce them exactly.
      final b = _uniform(12, 3.0);
      final zones =
          computeDownfeedZones(building: b, maxStaticPressure: _budget);
      expect(zones, const [PressureZone(11, 6), PressureZone(5, 0)]);
      for (final s in _check(b, zones)) {
        expect(s.bottomStatic.pascals, closeTo(387846, 1e-6));
        expect(s.withinLimit, isTrue);
      }
    });

    test('10 x 3.5 m at the 196 133 Pa budget keeps [9-4], [3-0]', () {
      // The long-standing zoning_test fixture. Pre-fix: 3.5·(9 − f) ≤ 19.993 ⇒
      // breaks at f = 3 (21.0 m) ⇒ [9 … 4], then [3 … 0].
      // Post-fix: ceiling(9) = 34.7; f = 4 ⇒ 34.7 − 15.1 = 19.6 ≤ 19.993 ✓,
      // f = 3 ⇒ 23.1 ✗ — the same boundary.
      final b = _uniform(10, 3.5);
      final zones = computeDownfeedZones(
        building: b,
        maxStaticPressure: const Pressure(196133),
      );
      expect(zones, const [PressureZone(9, 4), PressureZone(3, 0)]);
    });

    test('a single floor is never split, whatever the budget', () {
      // Guard on the greedy: the walk must always admit f == zoneTop, or a
      // tiny budget would emit a zone whose bottom is above its own top.
      const single = BuildingLevels([Floor('G', Length(3.5))]);
      final zones = computeDownfeedZones(
        building: single,
        maxStaticPressure: const Pressure(1),
      );
      expect(zones, const [PressureZone(0, 0)]);

      // On a tall stack a near-zero budget still yields exactly one zone per
      // floor (never an inverted or empty zone).
      final tall = _uniform(6, 4.0);
      final perFloor =
          computeDownfeedZones(building: tall, maxStaticPressure: const Pressure(1));
      expect(perFloor, hasLength(6));
      for (final z in perFloor) {
        expect(z.topFloorIndex, z.bottomFloorIndex);
      }
    });

    test('an indivisible over-tall storey is emitted and honestly flagged', () {
      // h − 1.4 = 18.6 m > 17.05 m budget: no partition can fix this, so the
      // zone is emitted (one floor) and the checker reports it over-limit.
      const hall = BuildingLevels([Floor('HALL', Length(20.0))]);
      final zones =
          computeDownfeedZones(building: hall, maxStaticPressure: _budget);
      expect(zones, const [PressureZone(0, 0)]);
      expect(_check(hall, zones).single.withinLimit, isFalse);
    });
  });

  // ══ M9 ═══════════════════════════════════════════════════════════════════

  group('M9 — targetHeldByDesign', () {
    // Building: 4.0 / 3.0 / 3.0 m ⇒ surfaces 0, 4, 7 m;
    //   ceiling(0) = 0 + 4 − 0.3 = 3.7 m, ceiling(2) = 7 + 3 − 0.3 = 9.7 m,
    //   roof (tank datum) = 7 + 3 = 10.0 m.
    const building = BuildingLevels([
      Floor('G', Length(4.0)),
      Floor('L1', Length(3.0)),
      Floor('L2', Length(3.0)),
    ]);
    const calibration = <String, ScaleCalibration>{'s1': ScaleCalibration(0.1)};

    // Min faucet residual 0.5 kgf/cm² = 49 033.25 Pa = 4.998292558 m head.
    const targetResidual = Pressure(49033.25);
    final targetHead = headFromPressure(targetResidual).meters;

    // s (floor 0 main, 3.7 m) --run--> n1 (floor 0) --riser--> n2 (floor 2).
    const net = Network(
      nodes: [
        NetNode(id: 's', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'n1', sheetId: 's1', x: 500, y: 0, floorIndex: 0),
        NetNode(id: 'n2', sheetId: 's1', x: 500, y: 0, floorIndex: 2),
      ],
      edges: [
        NetEdge(
            id: 'e1', fromId: 's', toId: 'n1', service: ServiceType.coldWater),
        NetEdge(
          id: 'r1',
          fromId: 'n1',
          toId: 'n2',
          service: ServiceType.coldWater,
          kind: EdgeKind.riser,
        ),
      ],
    );

    PressureSolution upfeed({Map<String, EdgeSizing> sizing = const {}}) =>
        solvePressurized(
          net: net,
          service: ServiceType.coldWater,
          sourceId: 's',
          edgeFlows: const {'e1': FlowRate(0.005), 'r1': FlowRate(0.005)},
          sizing: sizing,
          calibrationBySheet: calibration,
          building: building,
          targetResidual: targetResidual,
        );

    test('the upfeed solve carries targetHeldByDesign = true', () {
      expect(upfeed().targetHeldByDesign, isTrue);
    });

    test('upfeed numerics are unchanged by the added field', () {
      // Frictionless (no sizing ⇒ every edge skipped), so the whole solve is
      // static lift + target:
      //   elevation gain @ n2 = ceiling(2) − ceiling(0) = 9.7 − 3.7 = 6.0 m
      //   requiredPumpHead     = 0 + 6.0 + 4.998292558 = 10.998292558 m
      //   residual(s)  = residual(n1) = ρg·(6.0 + h_target)
      //                = 58 860 + 49 033.25 = 107 893.25 Pa
      //   residual(n2) = 49 033.25 Pa  (exactly the target — the critical node)
      final sol = upfeed();
      expect(sol.requiredPumpHead.meters, closeTo(6.0 + targetHead, 1e-9));
      expect(sol.criticalNodeId, 'n2');
      expect(sol.residualPressure['s']!.pascals, closeTo(107893.25, 1e-6));
      expect(sol.residualPressure['n1']!.pascals, closeTo(107893.25, 1e-6));
      expect(sol.residualPressure['n2']!.pascals, closeTo(49033.25, 1e-6));
    });

    test('why it is not a verdict: crippling the pipe cannot make it fail', () {
      // DN20 (0.020 m) carrying 5 L/s over the same 50 m run + 6 m riser is a
      // grossly undersized, ~16 m/s design. The residual at the critical node is
      // STILL exactly the target — only the pump head moves. That is the M9
      // unfalsifiability, pinned.
      const tiny = Diameter(0.020);
      final sizing = <String, EdgeSizing>{
        'e1': const EdgeSizing(
          edgeId: 'e1',
          service: ServiceType.coldWater,
          flow: FlowRate(0.005),
          diameter: tiny,
          velocity: Velocity(15.9),
        ),
        'r1': const EdgeSizing(
          edgeId: 'r1',
          service: ServiceType.coldWater,
          flow: FlowRate(0.005),
          diameter: tiny,
          velocity: Velocity(15.9),
        ),
      };
      final lossy = upfeed(sizing: sizing);
      expect(lossy.targetHeldByDesign, isTrue);
      expect(lossy.residualPressure['n2']!.pascals, closeTo(49033.25, 1e-6));
      // Every node is at or above target, by construction, for both solves.
      for (final p in lossy.residualPressure.values) {
        expect(p.pascals, greaterThanOrEqualTo(49033.25 - 1e-6));
      }
      // The pump head is what actually absorbed the friction.
      expect(lossy.requiredPumpHead.meters,
          greaterThan(upfeed().requiredPumpHead.meters + 1.0));
    });

    test('the downfeed solve carries targetHeldByDesign = false and CAN fail',
        () {
      // tank (plant, roof 10 m) --riser--> m2 (floor 2 ceiling, 9.7 m)
      //                          --riser--> m0 (floor 0 ceiling, 3.7 m).
      // Frictionless gravity: residual(m2) = 0.3 m, residual(m0) = 6.3 m; the
      // worst-served node m2 is 0.3 m against a 4.998 m target ⇒ a real
      // shortfall the solve reports instead of engineering away.
      const tank = NetNode(
          id: 'tank',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 2,
          role: NodeRole.plant);
      const m2 = NetNode(id: 'm2', sheetId: 's1', x: 0, y: 0, floorIndex: 2);
      const m0 = NetNode(id: 'm0', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
      const downNet = Network(
        nodes: [tank, m2, m0],
        edges: [
          NetEdge(
              id: 'dt',
              fromId: 'tank',
              toId: 'm2',
              service: ServiceType.coldWater,
              kind: EdgeKind.riser),
          NetEdge(
              id: 'dr',
              fromId: 'm2',
              toId: 'm0',
              service: ServiceType.coldWater,
              kind: EdgeKind.riser),
        ],
      );

      final sol = solveDownfeed(
        net: downNet,
        service: ServiceType.coldWater,
        tankId: 'tank',
        edgeFlows: const {},
        sizing: const {},
        calibrationBySheet: calibration,
        building: building,
        targetResidual: targetResidual,
      );

      expect(sol.targetHeldByDesign, isFalse);
      // Numerics pinned unchanged.
      expect(sol.residualPressure['m2']!.pascals,
          closeTo(pressureFromHead(const Head(0.3)).pascals, 1e-6));
      expect(sol.residualPressure['m0']!.pascals,
          closeTo(pressureFromHead(const Head(6.3)).pascals, 1e-6));
      expect(sol.criticalNodeId, 'm2');
      // Falsifiable: this design genuinely misses the target.
      expect(sol.minResidual.pascals, lessThan(targetResidual.pascals));
      expect(sol.boosterHeadRequired.meters, closeTo(targetHead - 0.3, 1e-6));
      expect(sol.gravitySufficient, isFalse);
    });
  });
}
