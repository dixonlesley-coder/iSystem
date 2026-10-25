// Round 64 (plumbing-hvac-convergence-14-branch-inline-fan-rated-on-whole-
// system) — an inline air fan on ONE BRANCH moves only the flow through it
// against its own sub-tree's static, and a branch return fan never removes
// the unit's return static over the paths it does not boost.
//
// First principles (continuity + the fan law the engine's own primitives
// encode): a booster 'bf' feeding one 0.5 m3/s diffuser carries 0.5 m3/s
// (the flow on its own ducts), never the AHU's 9 x 1.0 + 0.5 = 9.5 m3/s
// trunk; its static is the index run of ITS sub-tree (`solveDuctStatic`
// rooted at the booster, less the upstream walk it reports as 'intake').
// The AHU sees (supply index - intake) + max(intake, return index over the
// paths no return fan boosts) + its 250 Pa internal static.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/duct_static.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fan.dart' show sizeFan;
import 'package:mechx_engine/units.dart';

const _duct = ServiceType.duct, _ret = ServiceType.returnAir;
const _ex = ServiceType.exhaust;

NetNode _n(
  String id,
  double x,
  double y, {
  NodeRole role = NodeRole.main,
  NodeComponent? c,
  double? q,
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: y,
  floorIndex: 0,
  role: role,
  component: c,
  airflow: q == null ? null : FlowRate(q),
);

NetEdge _e(String id, String a, String b, ServiceType s) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: EdgeKind.run);

/// AHU -> 9 supply diffusers (1.0 m3/s) on a 9-node main, a branch booster
/// 'bf' -> one 0.5 m3/s diffuser; 9 return grilles (0.9 m3/s) on a 9-node
/// return main straight to the AHU, plus [returnFan] one 0.2 m3/s grille
/// through an inline return fan 'rb'.
Network _ahu({bool returnFan = true}) {
  final nodes = <NetNode>[
    _n('ahu', 0, 0, role: NodeRole.plant, c: NodeComponent.ahu),
  ];
  final edges = <NetEdge>[];
  var prevS = 'ahu', prevR = 'ahu';
  for (var k = 1; k <= 9; k++) {
    nodes
      ..add(_n('m$k', 500.0 * k, 0))
      ..add(
        _n(
          'd$k',
          500.0 * k,
          200,
          role: NodeRole.fixture,
          c: NodeComponent.supplyDiffuser,
          q: 1.0,
        ),
      )
      ..add(_n('r$k', 500.0 * k, 1000))
      ..add(
        _n(
          'g$k',
          500.0 * k,
          1200,
          role: NodeRole.fixture,
          c: NodeComponent.returnGrille,
          q: 0.9,
        ),
      );
    edges
      ..add(_e('s$k', prevS, 'm$k', _duct))
      ..add(_e('t$k', 'm$k', 'd$k', _duct))
      ..add(_e('u$k', 'g$k', 'r$k', _ret))
      ..add(_e('v$k', 'r$k', prevR, _ret));
    prevS = 'm$k';
    prevR = 'r$k';
  }
  nodes
    ..add(_n('bf', 500, -300, role: NodeRole.plant, c: NodeComponent.supplyFan))
    ..add(
      _n(
        'db',
        500,
        -600,
        role: NodeRole.fixture,
        c: NodeComponent.supplyDiffuser,
        q: 0.5,
      ),
    );
  edges
    ..add(_e('b1', 'm1', 'bf', _duct))
    ..add(_e('b2', 'bf', 'db', _duct));
  if (returnFan) {
    nodes
      ..add(
        _n('rb', 500, 1500, role: NodeRole.plant, c: NodeComponent.supplyFan),
      )
      ..add(
        _n(
          'gb',
          500,
          1800,
          role: NodeRole.fixture,
          c: NodeComponent.returnGrille,
          q: 0.2,
        ),
      );
    edges
      ..add(_e('c1', 'gb', 'rb', _ret))
      ..add(_e('c2', 'rb', 'r1', _ret));
  }
  return Network(nodes: nodes, edges: edges);
}

ProviderContainer _container(Network net) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([const Floor('L0', Length(5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

double _branchStatic(ProviderContainer c, ServiceType service, String fan) {
  final net = c.read(sizingNetworkProvider);
  final sizing = c.read(sizingProvider);
  final project = c.read(projectControllerProvider);
  final r = solveDuctStatic(
    net: net,
    service: service,
    fanNodeId: fan,
    edgeFlows: {for (final e in sizing.entries) e.key: e.value.flow},
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
    mounting: project.mounting,
  );
  return r.totalStaticPressure.pascals - r.intakeStaticPressure.pascals;
}

void main() {
  test('a branch supply booster carries the flow through it', () {
    final c = _container(_ahu());
    final sup = c.read(airSystemsProvider(_duct)).single;
    expect(sup.fanNodeId, 'ahu');
    // 9 x 1.0 + 0.5 = 9.5 m3/s on the trunk.
    expect(sup.trunk.cubicMetersPerSecond, closeTo(9.5, 1e-9));
    expect(sup.inlineFanIds, ['bf']);
    expect(sup.inlineFanFlow['bf']!.cubicMetersPerSecond, closeTo(0.5, 1e-9));
    final bf = c.read(supplyFanDutiesByRootProvider)['bf']!;
    expect(bf.airflow.cubicMetersPerSecond, closeTo(0.5, 1e-9));
    final branch = _branchStatic(c, _duct, 'bf');
    expect(bf.totalStaticPressure.pascals, closeTo(branch, 1e-9));
    final expected = sizeFan(
      airflow: const FlowRate(0.5),
      totalStaticPressure: Pressure(branch),
    );
    expect(bf.selectedMotor.watts, expected.selectedMotor.watts);
    // Never the whole-system rating.
    final whole = sizeFan(
      airflow: sup.trunk,
      totalStaticPressure: Pressure(sup.stat.pascals - sup.intake.pascals),
    );
    expect(bf.selectedMotor.watts, lessThan(whole.selectedMotor.watts));
  });

  test('a branch return fan never drops the AHU return static', () {
    final c = _container(_ahu());
    final sup = c.read(airSystemsProvider(_duct)).single;
    final ret = c.read(airSystemsProvider(_ret)).single;
    expect(ret.fanNodeId, 'ahu');
    expect(ret.inlineFanIds, ['rb']);
    expect(inlineFanOnTrunk(ret, 'rb'), isFalse);
    expect(ret.inlineFanFlow['rb']!.cubicMetersPerSecond, closeTo(0.2, 1e-9));
    // The unboosted main return still costs the AHU its index static.
    expect(ret.statPastBranchFans.pascals, greaterThan(sup.intake.pascals));
    final ahu = c.read(supplyFanDutiesByRootProvider)['ahu']!;
    // 250 Pa AHU internal allowance (`defaultInternalStatic`).
    final expectedPa =
        sup.stat.pascals -
        sup.intake.pascals +
        ret.statPastBranchFans.pascals +
        airUnitInternalStatic(
          c.read(sizingNetworkProvider).nodeById('ahu'),
        ).pascals;
    expect(ahu.totalStaticPressure.pascals, closeTo(expectedPa, 1e-9));
    // The return fan itself: its own 0.2 m3/s against its own branch.
    final rb = c.read(supplyFanDutiesByRootProvider)['rb']!;
    expect(rb.airflow.cubicMetersPerSecond, closeTo(0.2, 1e-9));
    expect(
      rb.totalStaticPressure.pascals,
      closeTo(_branchStatic(c, _ret, 'rb'), 1e-9),
    );
  });

  test('a branch inline exhaust fan carries its own branch', () {
    final nodes = <NetNode>[
      _n('ef', 0, 0, role: NodeRole.plant, c: NodeComponent.exhaustFan),
    ];
    final edges = <NetEdge>[];
    var prev = 'ef';
    for (var k = 1; k <= 4; k++) {
      nodes
        ..add(_n('x$k', 500.0 * k, 0))
        ..add(
          _n(
            'e$k',
            500.0 * k,
            200,
            role: NodeRole.fixture,
            c: NodeComponent.exhaustGrille,
            q: 0.5,
          ),
        );
      edges
        ..add(_e('p$k', 'x$k', prev, _ex))
        ..add(_e('q$k', 'e$k', 'x$k', _ex));
      prev = 'x$k';
    }
    nodes
      ..add(
        _n('ib', 500, -300, role: NodeRole.plant, c: NodeComponent.exhaustFan),
      )
      ..add(
        _n(
          'eb',
          500,
          -600,
          role: NodeRole.fixture,
          c: NodeComponent.exhaustGrille,
          q: 0.1,
        ),
      );
    edges
      ..add(_e('i1', 'eb', 'ib', _ex))
      ..add(_e('i2', 'ib', 'x1', _ex));
    final c = _container(Network(nodes: nodes, edges: edges));
    final s = c.read(airSystemsProvider(_ex)).single;
    expect(s.fanNodeId, 'ef');
    expect(s.trunk.cubicMetersPerSecond, closeTo(2.1, 1e-9));
    final ib = c.read(exhaustFanDutiesByRootProvider)['ib']!;
    expect(ib.airflow.cubicMetersPerSecond, closeTo(0.1, 1e-9));
    expect(
      ib.totalStaticPressure.pascals,
      closeTo(_branchStatic(c, _ex, 'ib'), 1e-9),
    );
  });
}
