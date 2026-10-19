/// Round 25 review follow-ups (orchestrator):
///   * upfeed-below-target — a drawn REDUCING PRV after the pump leaves upper
///     fixtures below the target (the solve's `targetHeldByDesign` is false):
///     Review raises `upfeed-below-target` and the compliance 'Supply
///     pressure' row FAILS — it used to print a vacuous PASS.
///   * no-tank-heatmap — a downfeed SETTING with no roof tank drawn has no
///     gravity source, so the heatmap residual field and the downfeed
///     over-pressure judge are empty (no phantom-tank field).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/compliance_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c,
        PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c,
        fixture: fixture);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.coldWater, kind: k);

void _seed(ProviderContainer c, int floors) {
  c.read(projectControllerProvider.notifier)
    ..setFloors(
        [for (var i = 0; i < floors; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
}

void main() {
  test('upfeed: a reducing PRV after the pump is a finding and fails the '
      'Supply pressure row', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    _seed(c, 6);
    c.read(feedStrategyProvider.notifier).set(FeedStrategy.upfeed);
    // P -> V(prv) -> R0 -> riser R1..R5, a flush-tank WC on every floor.
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('P', 0, 0, role: NodeRole.plant, c: NodeComponent.pump),
      _n('V', 50, 0, c: NodeComponent.prv),
      for (var f = 0; f < 6; f++) ...[
        _n('R$f', 100, 0, floor: f),
        _n('W$f', 300, 0,
            floor: f,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushTank),
      ],
    ], edges: [
      _e('pv', 'P', 'V'),
      _e('v0', 'V', 'R0'),
      for (var f = 0; f < 5; f++)
        _e('r$f', 'R$f', 'R${f + 1}', k: EdgeKind.riser),
      for (var f = 0; f < 6; f++) _e('w$f', 'R$f', 'W$f'),
    ]));
    // Build the electrical controller (and its MEP sync) up front.
    c.read(electricalProjectProvider);
    final s = c.read(solveProvider)!;
    final target = c.read(targetResidualProvider);
    // Precondition: the PRV (setpoint target + 30 kPa) cannot lift 5 storeys
    // (5 x 3.5 m x 9.81 kPa/m ≈ 172 kPa of static alone).
    expect(s.targetHeldByDesign, isFalse);
    expect(s.residualPressure[s.criticalNodeId]!.inKiloPascals,
        lessThan(target.inKiloPascals));

    final issues = c
        .read(designIssuesProvider)
        .where((i) => i.kind == 'upfeed-below-target')
        .toList();
    expect(issues, hasLength(1));
    expect(issues.single.locate?.nodeId, s.criticalNodeId);

    final row = c.read(complianceSummaryProvider).items.firstWhere(
        (i) => i.category == 'Supply pressure');
    expect(row.pass, isFalse);
  });

  test('downfeed with no roof tank drawn paints no phantom field', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    _seed(c, 3);
    c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('M', 0, 0, floor: 2),
      _n('R1', 100, 0, floor: 1),
      _n('W1', 300, 0,
          floor: 1,
          role: NodeRole.fixture,
          fixture: PlumbingFixture.waterClosetFlushTank),
    ], edges: [
      _e('m', 'M', 'R1', k: EdgeKind.riser),
      _e('w', 'R1', 'W1'),
    ]));
    expect(c.read(gravityDownfeedDrawnProvider), isFalse);
    expect(c.read(residualByNodeProvider), isEmpty);
    expect(c.read(downfeedOverPressureProvider), isEmpty);
  });
}
