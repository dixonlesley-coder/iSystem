// Round 65 — the series split between an air unit and a drawn BRANCH inline
// fan, and a return system rooted at its own return fan.
//
//  * regression-2: an AHU (or a root exhaust fan) moves its air only up to a
//    branch booster's inlet; the boosted branch beyond is the booster's own
//    static (`inlineFanBranchStat`). The unit is rated on
//    `statPastBranchFans` (the index with the walk stopped at every branch
//    fan = max(unboosted index, path to each booster's inlet)), never on the
//    full index through the boosted branch — that counted the branch twice
//    across the series pair. With the booster's diffuser 300 m out the
//    branch governs the full index, so the full rating is strictly larger.
//    Identity: full index (excl. intake) = path to bf's inlet + bf's branch
//    static <= statPastBranchFans (excl. intake) + bf's branch static.
//  * plumbing-hvac-convergence-15: a return system rooted at a drawn return
//    fan 'rf' (not connected to the AHU) is rf's: rf is rated on its own
//    3.6 m3/s (4 x 0.9) against its own return static + internal, and the
//    AHU on (supply index - intake) + intake + 250 Pa — never on rf's
//    return static.
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

/// A root [unit] on [service] with 4 terminals (1.0 m3/s, or 0.5 exhaust)
/// on a 500 px main, and a branch inline fan 'bf' off the first main node
/// feeding / drawing one 0.5 m3/s terminal 300 m (30000 px) out.
Network _boosted(ServiceType service) {
  final supply = service == _duct;
  final unitC = supply ? NodeComponent.ahu : NodeComponent.exhaustFan;
  final fanC = supply ? NodeComponent.supplyFan : NodeComponent.exhaustFan;
  final termC = supply
      ? NodeComponent.supplyDiffuser
      : NodeComponent.exhaustGrille;
  final nodes = <NetNode>[_n('u', 0, 0, role: NodeRole.plant, c: unitC)];
  final edges = <NetEdge>[];
  // Supply flows unit -> terminals; extract terminals -> unit (drawn so).
  NetEdge link(String id, String up, String down) =>
      supply ? _e(id, up, down, service) : _e(id, down, up, service);
  var prev = 'u';
  for (var k = 1; k <= 4; k++) {
    nodes
      ..add(_n('m$k', 500.0 * k, 0))
      ..add(
        _n(
          't$k',
          500.0 * k,
          200,
          role: NodeRole.fixture,
          c: termC,
          q: supply ? 1.0 : 0.5,
        ),
      );
    edges
      ..add(link('s$k', prev, 'm$k'))
      ..add(link('d$k', 'm$k', 't$k'));
    prev = 'm$k';
  }
  nodes
    ..add(_n('bf', 500, -300, role: NodeRole.plant, c: fanC))
    ..add(
      _n('tb', 500, -30300, role: NodeRole.fixture, c: termC, q: 0.5),
    );
  edges
    ..add(link('b1', 'm1', 'bf'))
    ..add(link('b2', 'bf', 'tb'));
  return Network(nodes: nodes, edges: edges);
}

void main() {
  test('the AHU is rated past the branch booster, not through it', () {
    final c = _container(_boosted(_duct));
    final s = c.read(airSystemsProvider(_duct)).single;
    expect(s.fanNodeId, 'u');
    expect(s.inlineFanIds, ['bf']);
    expect(inlineFanOnTrunk(s, 'bf'), isFalse);
    final branch = _branchStatic(c, _duct, 'bf');
    // The boosted branch governs the full index ...
    expect(s.statPastBranchFans.pascals, lessThan(s.stat.pascals));
    // ... and the full index is the path to bf's inlet plus its branch,
    // the inlet path being no more than what the unit is rated on.
    expect(
      s.stat.pascals - s.intake.pascals - branch,
      lessThanOrEqualTo(s.statPastBranchFans.pascals - s.intake.pascals + 1e-9),
    );
    final duties = c.read(supplyFanDutiesByRootProvider);
    final internal = airUnitInternalStatic(
      c.read(sizingNetworkProvider).nodeById('u'),
    ).pascals;
    // No return: inlet = intake. (statPastBranchFans - intake) + intake +
    // internal.
    expect(
      duties['u']!.totalStaticPressure.pascals,
      closeTo(s.statPastBranchFans.pascals + internal, 1e-9),
    );
    expect(duties['bf']!.totalStaticPressure.pascals, closeTo(branch, 1e-9));
    // Never the double-counted full-index rating.
    final full = sizeFan(
      airflow: s.trunk,
      totalStaticPressure: Pressure(s.stat.pascals + internal),
    );
    expect(
      duties['u']!.totalStaticPressure.pascals,
      lessThan(full.totalStaticPressure.pascals),
    );
  });

  test('the root exhaust fan is rated past the branch inline fan', () {
    final c = _container(_boosted(_ex));
    final s = c.read(airSystemsProvider(_ex)).single;
    expect(s.fanNodeId, 'u');
    expect(s.inlineFanIds, ['bf']);
    expect(s.statPastBranchFans.pascals, lessThan(s.stat.pascals));
    final duties = c.read(exhaustFanDutiesByRootProvider);
    expect(
      duties['u']!.totalStaticPressure.pascals,
      closeTo(s.statPastBranchFans.pascals, 1e-9),
    );
    expect(
      duties['bf']!.totalStaticPressure.pascals,
      closeTo(_branchStatic(c, _ex, 'bf'), 1e-9),
    );
  });

  test('a return rooted at its own return fan is that fan\'s duty', () {
    // Sports hall: AHU -> 4 diffusers at 1.0 m3/s; a SEPARATE return of 4
    // grilles at 0.9 m3/s ending at a drawn return fan rf.
    final nodes = <NetNode>[
      _n('ahu', 0, 0, role: NodeRole.plant, c: NodeComponent.ahu),
      _n('rf', 0, 1000, role: NodeRole.plant, c: NodeComponent.supplyFan),
    ];
    final edges = <NetEdge>[];
    var prevS = 'ahu', prevR = 'rf';
    for (var k = 1; k <= 4; k++) {
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
    final c = _container(Network(nodes: nodes, edges: edges));
    final sup = c.read(airSystemsProvider(_duct)).single;
    final ret = c.read(airSystemsProvider(_ret)).single;
    expect(ret.fanNodeId, 'rf');
    expect(ret.trunk.cubicMetersPerSecond, closeTo(3.6, 1e-9));
    final duties = c.read(supplyFanDutiesByRootProvider);
    expect(duties.keys.toSet(), {'ahu', 'rf'});
    final net = c.read(sizingNetworkProvider);
    final rf = duties['rf']!;
    expect(rf.airflow.cubicMetersPerSecond, closeTo(3.6, 1e-9));
    expect(
      rf.totalStaticPressure.pascals,
      closeTo(
        ret.stat.pascals + airUnitInternalStatic(net.nodeById('rf')).pascals,
        1e-9,
      ),
    );
    // The AHU: (supply - intake) + intake + internal, no return static.
    expect(
      duties['ahu']!.totalStaticPressure.pascals,
      closeTo(
        sup.stat.pascals + airUnitInternalStatic(net.nodeById('ahu')).pascals,
        1e-9,
      ),
    );
  });
}
