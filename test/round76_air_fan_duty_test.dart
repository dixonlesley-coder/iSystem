// Round 76 (2026-10-18) — air fan duties on a two-fan system.
//
//   plumbing-hvac-convergence-25-exhaust-stub-duty-on-id-first-fan — the
//     inline movers are collected whatever rooted the system: a roof exhaust
//     fan with a bare discharge stub (the system roots at the louvre leaf)
//     keeps its duty, and the branch booster keeps its own — invariant to the
//     drawn stub and to renaming the two fans.
//   plumbing-hvac-convergence-25-exhaust-branch-fan-rated-on-main-fan-path —
//     a branch EXHAUST fan's static is its own grille-side sub-tree only; its
//     discharge path (toward the main fan) is the series side it reports.
//
// First principles (the probe, scale 0.01 m/px): exhaust grille g1 0.3 m3/s
// -e1 (10 m)-> booster BF -e2 (10 m)-> tee j <-e3 (5 m)- grille g2 10.0 m3/s;
// j -e4 (200 m)-> main fan EF [-e5 (3 m)-> louvre L]. Darcy air friction
// (`ductFrictionPaPerMetre`) x length x the 1.3 fitting factor, + the 30 Pa
// terminal drop at the index grille:
//   BF: 0.3 m3/s against e1 only = f(e1) x 10 x 1.3 + 30  (~37 Pa)
//   EF: 10.3 m3/s against max(e3, e2) + e4 (+ e5 when drawn) + 30.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/duct_sizing.dart'
    show ductFrictionPaPerMetre;
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/units.dart';

const _ex = ServiceType.exhaust, _duct = ServiceType.duct;

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

Network _exhaust({
  required bool stub,
  String bf = 'BF',
  String ef = 'EF',
}) {
  final nodes = <NetNode>[
    _n('g1', 0, 0, role: NodeRole.fixture, c: NodeComponent.exhaustGrille,
        q: 0.3),
    _n(bf, 1000, 0, role: NodeRole.plant, c: NodeComponent.exhaustFan),
    _n('j', 2000, 0),
    _n('g2', 2000, 500,
        role: NodeRole.fixture, c: NodeComponent.exhaustGrille, q: 10.0),
    _n(ef, 22000, 0, role: NodeRole.plant, c: NodeComponent.exhaustFan),
    if (stub) _n('L', 22300, 0),
  ];
  final edges = <NetEdge>[
    _e('e1', 'g1', bf, _ex),
    _e('e2', bf, 'j', _ex),
    _e('e3', 'g2', 'j', _ex),
    _e('e4', 'j', ef, _ex),
    if (stub) _e('e5', ef, 'L', _ex),
  ];
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

/// f(edge) x L x 1.3 — the duct-static edge cost from first principles. L is
/// the drawn span ([spanM], 0.01 m/px) plus the run's vertical leg (a ceiling
/// grille / diffuser to a datum-less fan's 2.0 m casing connection on a 5 m
/// storey = 3 m), the same `edgeLength` the solve buys.
double _edgePa(ProviderContainer c, String edgeId, double spanM) {
  final net = c.read(sizingNetworkProvider);
  final s = c.read(sizingProvider)[edgeId]!;
  final e = net.edges.firstWhere((x) => x.id == edgeId);
  final project = c.read(projectControllerProvider);
  final lengthM = edgeLength(e, net,
          calibrationBySheet: project.calibrations,
          building: project.building,
          mounting: project.mounting)
      .meters;
  expect(lengthM, greaterThanOrEqualTo(spanM - 1e-9));
  return ductFrictionPaPerMetre(
        s.flow,
        s.diameter,
        roughness: ductRoughnessFor(effectiveDuctProductFor(e)),
      ) *
      lengthM *
      1.3;
}

void main() {
  for (final stub in [false, true]) {
    test('stub=$stub: the branch booster is rated on its own grille side', () {
      final c = _container(_exhaust(stub: stub));
      final sys = c.read(airSystemsProvider(_ex)).single;
      expect(sys.fanNodeId, 'EF');
      expect(sys.inlineFanIds, ['BF']);
      expect(sys.trunk.cubicMetersPerSecond, closeTo(10.3, 1e-9));
      final duties = c.read(exhaustFanDutiesByRootProvider);
      final bf = duties['BF']!;
      expect(bf.airflow.cubicMetersPerSecond, closeTo(0.3, 1e-9));
      // e1 only + the 30 Pa grille: never the main fan's 200 m path.
      expect(bf.totalStaticPressure.pascals,
          closeTo(_edgePa(c, 'e1', 10) + 30, 1e-6));
      final ef = duties['EF']!;
      expect(ef.airflow.cubicMetersPerSecond, closeTo(10.3, 1e-9));
      final idx = (_edgePa(c, 'e3', 5) > _edgePa(c, 'e2', 10)
              ? _edgePa(c, 'e3', 5)
              : _edgePa(c, 'e2', 10)) +
          _edgePa(c, 'e4', 200) +
          (stub ? _edgePa(c, 'e5', 3) : 0) +
          30;
      expect(ef.totalStaticPressure.pascals, closeTo(idx, 1e-6));
      expect(ef.selectedMotor.watts, greaterThan(bf.selectedMotor.watts));
    });
  }

  test('the duties are invariant to renaming the two fans', () {
    for (final stub in [false, true]) {
      final a = _container(_exhaust(stub: stub));
      final b = _container(_exhaust(stub: stub, bf: 'zBF', ef: 'aEF'));
      final da = a.read(exhaustFanDutiesByRootProvider);
      final db = b.read(exhaustFanDutiesByRootProvider);
      expect(db['zBF']!.totalStaticPressure.pascals,
          closeTo(da['BF']!.totalStaticPressure.pascals, 1e-9));
      expect(db['zBF']!.selectedMotor.watts, da['BF']!.selectedMotor.watts);
      expect(db['aEF']!.totalStaticPressure.pascals,
          closeTo(da['EF']!.totalStaticPressure.pascals, 1e-9));
      expect(db['aEF']!.selectedMotor.watts, da['EF']!.selectedMotor.watts);
    }
  });

  test('a supply fan rooted at its bare intake leaf keeps its branch booster',
      () {
    // L (intake leaf) -i (3 m)-> SF -> m1 -> d1 (2.0 m3/s); m1 -> BB -> d2
    // (0.4 m3/s): the fan carries 2.4 m3/s, the booster its own 0.4.
    final net = Network(nodes: [
      _n('L', 0, 0),
      _n('SF', 300, 0, role: NodeRole.plant, c: NodeComponent.supplyFan),
      _n('m1', 1300, 0),
      _n('d1', 2300, 0,
          role: NodeRole.fixture, c: NodeComponent.supplyDiffuser, q: 2.0),
      _n('BB', 1300, 1000, role: NodeRole.plant, c: NodeComponent.supplyFan),
      _n('d2', 1300, 2000,
          role: NodeRole.fixture, c: NodeComponent.supplyDiffuser, q: 0.4),
    ], edges: [
      _e('i', 'L', 'SF', _duct),
      _e('s1', 'SF', 'm1', _duct),
      _e('s2', 'm1', 'd1', _duct),
      _e('b1', 'm1', 'BB', _duct),
      _e('b2', 'BB', 'd2', _duct),
    ]);
    final c = _container(net);
    final sys = c.read(airSystemsProvider(_duct)).single;
    expect(sys.fanNodeId, 'SF');
    expect(sys.inlineFanIds, ['BB']);
    expect(sys.inlineFanFlow['BB']!.cubicMetersPerSecond, closeTo(0.4, 1e-9));
    final bb = c.read(supplyFanDutiesByRootProvider)['BB']!;
    expect(bb.airflow.cubicMetersPerSecond, closeTo(0.4, 1e-9));
    expect(bb.totalStaticPressure.pascals,
        closeTo(_edgePa(c, 'b2', 10) + 30, 1e-6));
  });
}
