// Round 23 (2026-10-18) — the engine half of the round-23 audit:
//
//   regression-upfeed-prv-held-by-design-lie
//                            a reducing PRV breaks the 'held by design'
//                            identity: the upfeed solve re-judges
import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
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
  group('regression-upfeed-prv-held-by-design-lie', () {
    const cal = {'s1': ScaleCalibration(0.01)};

    // P -> V(prv) -> R0 -> riser -> R1..R{n-1}, each Rf -> Wf (flush-tank WC);
    // optionally the PRV sits on the riser below floor [prvAt] instead.
    Network net(int storeys, {int prvAt = 0}) => Network(nodes: [
          _n('P', 0, 0, role: NodeRole.plant, c: NodeComponent.pump),
          for (var f = 0; f < storeys; f++) ...[
            _n('R$f', 100, f),
            _n('W$f', 300, f,
                role: NodeRole.fixture,
                fixture: PlumbingFixture.waterClosetFlushTank),
          ],
          _n('V', 50, prvAt, c: NodeComponent.prv),
        ], edges: [
          if (prvAt == 0) ...[
            _e('pv', 'P', 'V'),
            _e('v0', 'V', 'R0'),
          ] else
            _e('p', 'P', 'R0'),
          for (var f = 0; f < storeys - 1; f++)
            if (prvAt != 0 && f == prvAt - 1) ...[
              _e('rv', 'R$f', 'V', k: EdgeKind.riser),
              _e('vr', 'V', 'R${f + 1}'),
            ] else
              _e('r$f', 'R$f', 'R${f + 1}', k: EdgeKind.riser),
          for (var f = 0; f < storeys; f++) _e('w$f', 'R$f', 'W$f'),
        ]);

    PressureSolution solve(Network network, BuildingLevels b,
        {required Pressure target, required Pressure setpoint}) {
      final sizing = autoSizeNetwork(network, const SizingContext(),
          leafDemand: const {},
          leafFixtureUnits: const {ServiceType.coldWater: 3});
      final flows = {for (final e in sizing.entries) e.key: e.value.flow};
      return solvePressurized(
        net: network,
        service: ServiceType.coldWater,
        sourceId: 'P',
        edgeFlows: flows,
        sizing: sizing,
        calibrationBySheet: cal,
        building: b,
        targetResidual: target,
        prvSetpoint: setpoint,
      );
    }

    test('a PRV at the pump discharge starves the top floors: LOW, not held',
        () {
      final b = _uniform(6, 3.5);
      final network = net(6);
      const target = Pressure(50000);
      const setpoint = Pressure(80000);
      final s = solve(network, b, target: target, setpoint: setpoint);
      expect(s.targetHeldByDesign, isFalse);
      // The critical fixture is the least-residual delivery node: the top WC.
      expect(s.criticalNodeId, 'W5');
      final w5 = s.residualPressure['W5']!.pascals;
      expect(w5, lessThan(target.pascals));
      // First principles: the PRV outlet holds 80 kPa, so W5 sees at most
      // 80 kPa − rho·g·(elev W5 − elev V) (friction only lowers it further).
      final lift = nodeElevation(network.nodeById('W5')!, b).meters -
          nodeElevation(network.nodeById('V')!, b).meters;
      // V is a ceiling main on L0, W5 a fixture on L5:
      // (5 × 3.5 + fixture height) − L0 ceiling elevation.
      const m = MountingHeights();
      expect(
          lift,
          closeTo(
              5 * 3.5 +
                  m.fixtureHeight.meters -
                  b.ceilingElevationOf(0, m).meters,
              1e-9));
      expect(w5, lessThanOrEqualTo(setpoint.pascals - _rhoG * lift + 1e-6));
      // 80 − 9.81 × 15.4 = −71 kPa: the top fixture is genuinely dry.
      expect(w5, lessThan(0));
    });

    test('a PRV that leaves every fixture above target keeps the identity', () {
      // 8 storeys, a PRV feeding only the ground fixture at a 255 kPa
      // setpoint (the Round-22 fixture): W0 still sees >= the 225 kPa target.
      final b = _uniform(8, 3.5);
      final network = Network(nodes: [
        _n('P', 0, 0, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 0; f < 8; f++) ...[
          _n('R$f', 100, f),
          _n('W$f', 300, f,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.waterClosetFlushTank),
        ],
        _n('V0', 200, 0, c: NodeComponent.prv),
      ], edges: [
        _e('p', 'P', 'R0'),
        for (var f = 0; f < 7; f++)
          _e('r$f', 'R$f', 'R${f + 1}', k: EdgeKind.riser),
        _e('v0', 'R0', 'V0'),
        _e('w0', 'V0', 'W0'),
        for (var f = 1; f < 8; f++) _e('w$f', 'R$f', 'W$f'),
      ]);
      final s = solve(network, b,
          target: const Pressure(225000), setpoint: const Pressure(255000));
      expect(s.targetHeldByDesign, isTrue);
      expect(s.residualPressure['W0']!.pascals,
          greaterThanOrEqualTo(225000 - 1e-6));
    });

    // Seeded property: for any storey count, PRV position and setpoint, the
    // verdict is exactly 'every delivery residual >= target', and the critical
    // node is the least-residual delivery node whenever that fails.
    test('property: heldByDesign == (min delivery residual >= target)', () {
      final rnd = math.Random(23);
      for (var i = 0; i < 60; i++) {
        final storeys = 2 + rnd.nextInt(8);
        final prvAt = rnd.nextInt(storeys);
        final target = Pressure(30000 + rnd.nextDouble() * 200000);
        final setpoint = Pressure(30000 + rnd.nextDouble() * 400000);
        final b = _uniform(storeys, 3 + rnd.nextDouble());
        final network = net(storeys, prvAt: prvAt);
        final s = solve(network, b, target: target, setpoint: setpoint);
        final residuals = {
          for (final id in s.deliveryNodeIds)
            id: s.residualPressure[id]!.pascals,
        };
        final minRes = residuals.values.reduce(math.min);
        final holds = minRes >= target.pascals - 1e-3;
        expect(s.targetHeldByDesign, holds,
            reason: 'case $i: storeys $storeys prv@$prvAt');
        if (!holds) {
          expect(residuals[s.criticalNodeId], closeTo(minRes, 1e-6),
              reason: 'case $i');
        }
      }
    });
  });

  // keep the import used when trimming
  test('headFromPressure round trip', () {
    expect(headFromPressure(const Pressure(9810)).meters, closeTo(1, 1e-3));
  });
}
