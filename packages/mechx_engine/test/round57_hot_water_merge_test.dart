// Round 57 (2026-10-18) — plumbing-hvac-convergence-7-dual-fixture-cold-
// pressure-masked-by-hot.
//
// A dual-fed fixture (a shower on a cold AND a hot edge) is ONE node id in
// the cold and the hot pressure fields. The merge used to spread hot over
// cold, so a PRV drawn on the HOT branch only (a realistic slip: zone the hot
// side, forget the cold shower branch) replaced the shower's 503 kPa cold
// static by the ~275 kPa hot one and the over-pressure judge passed.
//
// First principles: the SNI 8153 fixture maximum is 4 kgf/cm2 = 392.3 kPa and
// the mandatory relief threshold 5 kgf/cm2 = 490.3 kPa. A shower whose cold
// side sees 503 kPa no-flow static is over BOTH, whatever its hot side sees;
// the merged field therefore keeps, per node, the WORST (largest) no-flow
// static and the LEAST residual of the two services.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/hot_water_pressure.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _target = Pressure(225000);

NetNode _at(String id, double z,
        {NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: 0,
        y: 0,
        floorIndex: 0,
        role: role,
        component: c,
        elevation: Length(z));

EdgeSizing _z(String id, String from) => EdgeSizing(
    edgeId: id,
    service: ServiceType.hotWater,
    flow: const FlowRate(0),
    diameter: const Diameter(0.025),
    velocity: const Velocity(0),
    flowFromId: from);

void main() {
  group('merge helpers', () {
    test('min residual / max static per shared key; single keys pass', () {
      const cold = {'S': Pressure(503000), 'C': Pressure(510000)};
      const hot = {'S': Pressure(275000), 'T': Pressure(260000)};
      final r = mergeLeastResidual(cold, hot);
      final s = mergeWorstStatic(cold, hot);
      expect(r, {
        'S': const Pressure(275000),
        'C': const Pressure(510000),
        'T': const Pressure(260000),
      });
      expect(s, {
        'S': const Pressure(503000),
        'C': const Pressure(510000),
        'T': const Pressure(260000),
      });
      // A cold-only field is returned unchanged (byte-identical).
      expect(mergeLeastResidual(cold, const {}), cold);
      expect(mergeWorstStatic(cold, const {}), cold);
    });

    test('seeded property: symmetric, idempotent, bounded by both inputs', () {
      final rnd = math.Random(5704);
      for (var t = 0; t < 200; t++) {
        Map<String, Pressure> m() => {
              for (var k = 0; k < 6; k++)
                if (rnd.nextBool()) 'n$k': Pressure(rnd.nextDouble() * 6e5),
            };
        final a = m();
        final b = m();
        final lo = mergeLeastResidual(a, b);
        final hi = mergeWorstStatic(a, b);
        expect(lo, mergeLeastResidual(b, a));
        expect(hi, mergeWorstStatic(b, a));
        expect(lo.keys.toSet(), {...a.keys, ...b.keys});
        for (final id in lo.keys) {
          final xs = [a[id], b[id]].whereType<Pressure>().map((p) => p.pascals);
          expect(lo[id]!.pascals, xs.reduce(math.min));
          expect(hi[id]!.pascals, xs.reduce(math.max));
        }
      }
    });
  });

  group('dual-fed shower: a hot-side PRV never masks the cold verdict', () {
    // Cold C -> S (shower) and C -> H (heater, plant on both services);
    // hot H -> V (PRV) -> S. Everything at z = 0, zero flow: the hot field
    // is pure static, held at the PRV setpoint downstream of V.
    final net = Network(nodes: [
      _at('C', 0),
      _at('H', 0, role: NodeRole.plant),
      _at('V', 0, c: NodeComponent.prv),
      _at('S', 0, role: NodeRole.fixture),
    ], edges: const [
      NetEdge(id: 'cs', fromId: 'C', toId: 'S', service: ServiceType.coldWater),
      NetEdge(id: 'ch', fromId: 'C', toId: 'H', service: ServiceType.coldWater),
      NetEdge(id: 'hv', fromId: 'H', toId: 'V', service: ServiceType.hotWater),
      NetEdge(id: 'vs', fromId: 'V', toId: 'S', service: ServiceType.hotWater),
    ]);
    const building = BuildingLevels([Floor('L0', Length(3.5))]);
    const cold = PressureSolution(
      residualPressure: {
        'C': Pressure(503000),
        'H': Pressure(503000),
        'S': Pressure(503000),
      },
      requiredPumpHead: Head(52.35),
      criticalNodeId: 'S',
      targetHeldByDesign: true,
      noFlowStaticPressure: {
        'C': Pressure(503000),
        'H': Pressure(503000),
        'S': Pressure(503000),
      },
      deliveryNodeIds: {'S'},
    );
    HotWaterField hot() => solveHotWaterFromHeaters(
          net: net,
          coldResidual: cold.residualPressure,
          coldNoFlow: cold.noFlowStaticPressure,
          sizing: {'hv': _z('hv', 'H'), 'vs': _z('vs', 'V')},
          calibrationBySheet: const {},
          building: building,
          targetResidual: _target,
          prvSetpoint: const Pressure(275000),
        );

    test('upfeed: the cold 503 kPa shower is still over the relief trigger',
        () {
      final h = hot();
      // The hot side is held below the cold one by the PRV.
      expect(h.noFlowStatic['S']!.pascals, lessThan(503000));
      final merged = mergeHotWaterField(cold, h, targetResidual: _target);
      expect(merged.noFlowStaticPressure['S']!.pascals, 503000);
      final over = upfeedOverPressure(merged);
      expect(over.map((o) => o.nodeId), ['S']);
      expect(over.single.overRelief, isTrue);
      // The residual verdict takes the least-served side (the hot one).
      expect(merged.residualPressure['S']!.pascals, h.residual['S']!.pascals);
    });

    test('downfeed: the same merge keeps the cold over-pressure', () {
      final h = hot();
      const dcold = DownfeedSolution(
        residualPressure: {'S': Pressure(503000)},
        criticalNodeId: 'S',
        minResidual: Pressure(503000),
        boosterHeadRequired: Head(0),
        noFlowStaticPressure: {'S': Pressure(503000)},
        deliveryNodeIds: {'S'},
      );
      final merged = mergeHotWaterDownfeed(dcold, h, targetResidual: _target);
      expect(merged.noFlowStaticPressure['S']!.pascals, 503000);
      expect(downfeedOverPressure(merged).map((o) => o.nodeId), ['S']);
    });

    test('the reverse: a hot side above the cold one is still judged', () {
      // Cold PRV-held at 275 kPa, hot unprotected at 503 kPa.
      const c2 = PressureSolution(
        residualPressure: {'S': Pressure(275000)},
        requiredPumpHead: Head(30),
        criticalNodeId: 'S',
        noFlowStaticPressure: {'S': Pressure(275000)},
        deliveryNodeIds: {'S'},
      );
      const h2 = HotWaterField(
        residual: {'S': Pressure(503000)},
        noFlowStatic: {'S': Pressure(503000)},
        deliveryNodeIds: {'S'},
        criticalNodeId: 'S',
      );
      final merged = mergeHotWaterField(c2, h2, targetResidual: _target);
      expect(upfeedOverPressure(merged).map((o) => o.nodeId), ['S']);
      // The low judge reads the cold 275 kPa.
      expect(merged.residualPressure['S']!.pascals, 275000);
    });
  });
}
