// Round 70 (plumbing-hvac-convergence-20-downfeed-break-tank-ignored) — a
// downfeed tower with a mid-height BREAK tank: GT (L0) -> TP1 -> riser -> BT
// (ground tank on L20, 70 m) -> TP2 -> riser -> RT (roof tank on L39).
// BT feeds a riser with a lavatory on L1..L20, RT one on L21..L39.
//
// First principles: a storage tank has a FREE water surface, so the
// pressure below it restarts from its own elevation. The static head at a
// lavatory BT feeds is (70 m - fixture elevation) x rho g, never the roof
// tank's 140 m datum. On 40 x 3.5 m storeys with the default 1.1 m fixture
// height: WB10 sits at 35 + 1.1 = 36.1 m => (70 - 36.1) x 9.80665 =
// 332.4 kPa (under the 392 kPa SNI limit); WB1 at 4.6 m => 641.4 kPa. The
// RT-fed floors keep the 140 m datum.
library;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, int floor,
        {NodeRole role = NodeRole.main,
        NodeComponent? c,
        PlumbingFixture? fx}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: floor,
        role: role,
        component: c,
        fixture: fx);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.coldWater, kind: k);

final _b = BuildingLevels(
    [for (var i = 0; i < 40; i++) Floor('L$i', const Length(3.5))]);

Network _tower({bool breakTank = true}) => Network(nodes: [
      if (breakTank) ...[
        _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('TP1', 20, 0, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 0; f <= 20; f++) _n('U$f', 40, f),
        _n('BT', 60, 20, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('TP2', 80, 20, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 20; f <= 39; f++) _n('V$f', 100, f),
        for (var f = 1; f <= 20; f++) ...[
          _n('L$f', 140, f),
          _n('WB$f', 160, f,
              role: NodeRole.fixture, fx: PlumbingFixture.lavatory),
        ],
      ],
      _n('RT', 200, 39, role: NodeRole.plant, c: NodeComponent.roofTank),
      for (var f = 21; f <= 39; f++) ...[
        _n('R$f', 220, f),
        _n('WR$f', 240, f,
            role: NodeRole.fixture, fx: PlumbingFixture.lavatory),
      ],
    ], edges: [
      if (breakTank) ...[
        _e('g', 'GT', 'TP1'),
        _e('t0', 'TP1', 'U0'),
        for (var f = 1; f <= 20; f++)
          _e('u$f', 'U${f - 1}', 'U$f', k: EdgeKind.riser),
        _e('ub', 'U20', 'BT'),
        _e('b2', 'BT', 'TP2'),
        _e('v0', 'TP2', 'V20'),
        for (var f = 21; f <= 39; f++)
          _e('v$f', 'V${f - 1}', 'V$f', k: EdgeKind.riser),
        _e('vr', 'V39', 'RT'),
        // BT's own riser down to L1.
        _e('l20', 'BT', 'L20'),
        for (var f = 19; f >= 1; f--)
          _e('l$f', 'L${f + 1}', 'L$f', k: EdgeKind.riser),
        for (var f = 1; f <= 20; f++) _e('w$f', 'L$f', 'WB$f'),
      ],
      _e('r39', 'RT', 'R39'),
      for (var f = 38; f >= 21; f--)
        _e('r$f', 'R${f + 1}', 'R$f', k: EdgeKind.riser),
      for (var f = 21; f <= 39; f++) _e('x$f', 'R$f', 'WR$f'),
    ]);

DownfeedSolution _solve(Network net, {bool friction = true}) {
  final sizing = autoSizeNetwork(net, const SizingContext(),
      leafDemand: const {ServiceType.coldWater: FlowRate(0.0002)},
      building: _b, calibrationBySheet: const {'s1': ScaleCalibration(0.01)});
  return solveDownfeed(
    net: net,
    service: ServiceType.coldWater,
    tankId: 'RT',
    edgeFlows: friction
        ? {for (final e in sizing.entries) e.key: e.value.flow}
        : const {},
    sizing: sizing,
    calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
    building: _b,
    targetResidual: Pressure.kiloPascals(225),
  );
}

double _kpa(double head) => pressureFromHead(Head(head)).inKiloPascals;

void main() {
  test('the BT-fed floors are judged from the break tank (no friction)', () {
    final sol = _solve(_tower(), friction: false);
    // WB10: fixture at 10 x 3.5 + 1.1 = 36.1 m, BT at 70 m.
    expect(sol.noFlowStaticPressure['WB10']!.inKiloPascals,
        closeTo(_kpa(70 - 36.1), 0.05));
    expect(sol.noFlowStaticPressure['WB10']!.inKiloPascals, lessThan(392));
    expect(sol.noFlowStaticPressure['WB1']!.inKiloPascals,
        closeTo(_kpa(70 - 4.6), 0.05));
    expect(sol.noFlowStaticPressure['WB19']!.inKiloPascals,
        closeTo(_kpa(70 - (19 * 3.5 + 1.1)), 0.05));
    // The RT-fed floors keep the roof datum (RT on L39 at 140 m).
    final rt = nodeElevation(
            _tower().nodeById('RT')!, _b, const MountingHeights())
        .meters;
    expect(sol.noFlowStaticPressure['WR25']!.inKiloPascals,
        closeTo(_kpa(rt - (25 * 3.5 + 1.1)), 0.05));
  });

  test('a single-tank downfeed is unchanged by the break-tank rule', () {
    final net = _tower(breakTank: false);
    final sizing = autoSizeNetwork(net, const SizingContext(),
        leafDemand: const {ServiceType.coldWater: FlowRate(0.0002)},
        building: _b,
        calibrationBySheet: const {'s1': ScaleCalibration(0.01)});
    expect(
        downfeedTankRegions(
            net: net,
            service: ServiceType.coldWater,
            sourceTankId: 'RT',
            sizing: sizing),
        isEmpty);
  });

  test('with friction the BT regions still read from BT (residual <= static)',
      () {
    final sol = _solve(_tower());
    for (final f in [1, 10, 19]) {
      final st = sol.noFlowStaticPressure['WB$f']!.inKiloPascals;
      expect(st, closeTo(_kpa(70 - (f * 3.5 + 1.1)), 0.05));
      expect(sol.residualPressure['WB$f']!.inKiloPascals,
          lessThanOrEqualTo(st + 1e-6));
    }
  });
}
