// Round 63 — every drawn air mover carries a solved duty.
//
//  * plumbing-hvac-convergence-13-return-fan-on-peer-ahu-leg-gets-component-
//    default: two AHUs on ONE shared return, each with its own return fan;
//    the sizer roots the return at one AHU and mirrors the other AHU's leg
//    (duty / standby). The mirrored leg's return fan is the inline fan's
//    twin: the same airflow (the whole 9.0 m3/s return trunk) at the same
//    return index static, the same motor — never the 0.75 kW default.
//  * plumbing-hvac-convergence-13-exhaust-inline-fan-no-duty: an inline
//    exhaust fan in series with the root exhaust fan moves the exhaust
//    system's airflow (2 x 1.5 = 3.0 m3/s) against its exhaust index static
//    (the Round-62 conservative full-index convention), fed on that duty.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fan.dart' show sizeFan;
import 'package:mechx_engine/units.dart';

NetNode _n(
  String id,
  double x,
  double y, {
  NodeRole role = NodeRole.main,
  NodeComponent? c,
  FlowRate? airflow,
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: y,
  floorIndex: 0,
  role: role,
  component: c,
  airflow: airflow,
);

NetNode _term(String id, double x, double y, NodeComponent c, double q) =>
    _n(id, x, y, role: NodeRole.fixture, c: c, airflow: FlowRate(q));

NetEdge _air(String id, String a, String b, ServiceType s) =>
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

void main() {
  test('return fan on a peer AHU leg is the inline fan\'s twin', () {
    const ret = ServiceType.returnAir;
    final c = _container(
      Network(
        nodes: [
          _n('ahuA', 0, 0, role: NodeRole.plant, c: NodeComponent.ahu),
          _n('ahuB', 0, 2000, role: NodeRole.plant, c: NodeComponent.ahu),
          _term('da', 1500, 0, NodeComponent.supplyDiffuser, 5.0),
          _term('db', 1500, 2000, NodeComponent.supplyDiffuser, 5.0),
          _n(
            'rfA',
            300,
            800,
            role: NodeRole.plant,
            c: NodeComponent.exhaustFan,
          ),
          _n(
            'rfB',
            300,
            1200,
            role: NodeRole.plant,
            c: NodeComponent.exhaustFan,
          ),
          _n('j', 800, 1000),
          _n('rj', 1400, 1000),
          _term('rg1', 2000, 900, NodeComponent.returnGrille, 4.5),
          _term('rg2', 2000, 1100, NodeComponent.returnGrille, 4.5),
        ],
        edges: [
          _air('sa', 'ahuA', 'da', ServiceType.duct),
          _air('sb', 'ahuB', 'db', ServiceType.duct),
          _air('g1', 'rg1', 'rj', ret),
          _air('g2', 'rg2', 'rj', ret),
          _air('rjj', 'rj', 'j', ret),
          _air('ja', 'j', 'rfA', ret),
          _air('fa', 'rfA', 'ahuA', ret),
          _air('jb', 'j', 'rfB', ret),
          _air('fb', 'rfB', 'ahuB', ret),
        ],
      ),
    );
    final rets = c.read(airSystemsProvider(ret));
    expect(rets, hasLength(1));
    final r = rets.single;
    // 4.5 + 4.5 = 9.0 m3/s on the return trunk.
    expect(r.trunk.cubicMetersPerSecond, closeTo(9.0, 1e-9));
    expect(r.inlineFanIds, hasLength(1));
    final inline = r.inlineFanIds.single;
    final twin = inline == 'rfA' ? 'rfB' : 'rfA';
    final duties = c.read(supplyFanDutiesByRootProvider);
    final expected = sizeFan(airflow: r.trunk, totalStaticPressure: r.stat);
    for (final id in ['rfA', 'rfB']) {
      expect(duties[id], isNotNull, reason: id);
      expect(
        duties[id]!.airflow.cubicMetersPerSecond,
        closeTo(9.0, 1e-9),
        reason: id,
      );
      expect(
        duties[id]!.totalStaticPressure.pascals,
        closeTo(expected.totalStaticPressure.pascals, 1e-9),
        reason: id,
      );
      expect(duties[id]!.selectedMotor.watts, expected.selectedMotor.watts);
    }
    expect(duties[twin]!.selectedMotor.watts, greaterThan(750));
    final fed = c.read(nodeFedLoadsProvider);
    expect(fed['rfA']!.source, NodeLoadSource.solvedDuty);
    expect(fed['rfB']!.source, NodeLoadSource.solvedDuty);
  });

  test('an inline exhaust fan carries the exhaust system duty', () {
    const ex = ServiceType.exhaust;
    final c = _container(
      Network(
        nodes: [
          _term('e1', 0, -200, NodeComponent.exhaustGrille, 1.5),
          _term('e2', 0, 200, NodeComponent.exhaustGrille, 1.5),
          _n('j', 600, 0),
          _n('efI', 1200, 0, role: NodeRole.plant, c: NodeComponent.exhaustFan),
          _n('efR', 2000, 0, role: NodeRole.plant, c: NodeComponent.exhaustFan),
        ],
        edges: [
          _air('x1', 'e1', 'j', ex),
          _air('x2', 'e2', 'j', ex),
          _air('x3', 'j', 'efI', ex),
          _air('x4', 'efI', 'efR', ex),
        ],
      ),
    );
    final s = c.read(airSystemsProvider(ex)).single;
    expect(s.fanNodeId, 'efR');
    expect(s.inlineFanIds, ['efI']);
    // 1.5 + 1.5 = 3.0 m3/s.
    expect(s.trunk.cubicMetersPerSecond, closeTo(3.0, 1e-9));
    final duties = c.read(exhaustFanDutiesByRootProvider);
    final expected = sizeFan(airflow: s.trunk, totalStaticPressure: s.stat);
    for (final id in ['efR', 'efI']) {
      expect(
        duties[id]!.totalStaticPressure.pascals,
        closeTo(expected.totalStaticPressure.pascals, 1e-9),
        reason: id,
      );
      expect(duties[id]!.airflow.cubicMetersPerSecond, closeTo(3.0, 1e-9));
    }
    final fed = c.read(nodeFedLoadsProvider);
    expect(fed['efI']!.source, NodeLoadSource.solvedDuty);
    expect(fed['efR']!.source, NodeLoadSource.solvedDuty);
  });
}
