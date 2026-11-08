// Round 80 (2026-10-18) — fire pump stage heads reach every judge.
//
// (1) regression-outlet-overpressure-ignores-per-pump-stage-head — the
//     Round-79 tower (10 x 3.5 m; GA -> PA -> riser X0..X9 on L0, RT (L9) ->
//     PB -> X9) with hose reels. PB is rated on head − 35 m (its own roof
//     tank's rise); the NFPA 14 outlet judge must read THAT head: churn
//     1.4 x (head − 35). On it the L9 static is 31.5 (tank) + 1.4 x
//     (head − 35) − 32.7 (outlet) — e.g. head 93.6 m => 80.8 m = 792 kPa,
//     under 1207 kPa, and the residual at most 57.4 m < 690 kPa. The L0..L4
//     warnings on PA's path are genuine and unchanged.
//
// (2) fire-convergence-31-roof-standby-tank-collapses-series-stages — a
//     series tower (lower set on L0 serving L1..L(m-1), upper set on Lm
//     serving L(m+1)..top) reads the SAME stages (pump sets, stage heads)
//     with and without a roof gravity-standby tank tied to the riser top.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, double y, int floor, {NodeComponent? c}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: floor,
      role: c?.role ?? NodeRole.main,
      component: c,
    );

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.fireHydrant, kind: k);

Network _tower() {
  final nodes = <NetNode>[
    _n('GA', 0, 0, 0, c: NodeComponent.groundTank),
    _n('PA', 100, 0, 0, c: NodeComponent.pump),
    _n('RT', 0, 200, 9, c: NodeComponent.roofTank),
    _n('PB', 100, 200, 9, c: NodeComponent.pump),
  ];
  final edges = <NetEdge>[
    _e('ga', 'GA', 'PA'),
    _e('pa', 'PA', 'X0'),
    _e('rt', 'RT', 'PB'),
    _e('pb', 'PB', 'X9'),
  ];
  for (var f = 0; f < 10; f++) {
    nodes
      ..add(_n('X$f', 200, 0, f))
      ..add(_n('B$f', 300, 0, f, c: NodeComponent.hoseReel));
    edges.add(_e('b$f', 'X$f', 'B$f'));
    if (f > 0) edges.add(_e('x$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser));
  }
  return Network(nodes: nodes, edges: edges);
}

/// A series tower of [floors] storeys: the lower duplex set on L0 feeds the
/// riser AX0..AX[mid] (boxes L1..L[mid-1]); the upper duplex set on L[mid]
/// takes suction from AX[mid] and feeds ZX[mid]..ZX[top] (boxes above).
Network _series(int floors, int mid, {bool roofStandby = false}) {
  final top = floors - 1;
  final nodes = <NetNode>[
    _n('GT', 0, 0, 0, c: NodeComponent.groundTank),
    _n('ASH', 50, 0, 0),
    _n('APA', 100, 0, 0, c: NodeComponent.pump),
    _n('APB', 100, 40, 0, c: NodeComponent.pump),
    _n('ADH', 150, 0, 0),
    _n('ZSH', 250, 0, mid),
    _n('ZPA', 300, 0, mid, c: NodeComponent.pump),
    _n('ZPB', 300, 40, mid, c: NodeComponent.pump),
    _n('ZDH', 350, 0, mid),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'ASH'),
    _e('s1', 'ASH', 'APA'),
    _e('s2', 'ASH', 'APB'),
    _e('d1', 'APA', 'ADH'),
    _e('d2', 'APB', 'ADH'),
    _e('am', 'ADH', 'AX0'),
    _e('zs', 'AX$mid', 'ZSH'),
    _e('zs1', 'ZSH', 'ZPA'),
    _e('zs2', 'ZSH', 'ZPB'),
    _e('zd1', 'ZPA', 'ZDH'),
    _e('zd2', 'ZPB', 'ZDH'),
    _e('zm', 'ZDH', 'ZX$mid'),
  ];
  for (var f = 0; f <= mid; f++) {
    nodes.add(_n('AX$f', 200, 0, f));
    if (f > 0) {
      edges.add(_e('ax$f', 'AX${f - 1}', 'AX$f', k: EdgeKind.riser));
    }
    if (f > 0 && f < mid) {
      nodes.add(_n('AB$f', 220, 30, f, c: NodeComponent.hydrantBox));
      edges.add(_e('ab$f', 'AX$f', 'AB$f'));
    }
  }
  for (var f = mid; f <= top; f++) {
    nodes.add(_n('ZX$f', 400, 0, f));
    if (f > mid) {
      edges.add(_e('zx$f', 'ZX${f - 1}', 'ZX$f', k: EdgeKind.riser));
      nodes.add(_n('ZB$f', 420, 30, f, c: NodeComponent.hydrantBox));
      edges.add(_e('zb$f', 'ZX$f', 'ZB$f'));
    }
  }
  if (roofStandby) {
    nodes.add(_n('RT', 450, 0, top, c: NodeComponent.roofTank));
    edges.add(_e('rt', 'RT', 'ZX$top'));
  }
  return Network(nodes: nodes, edges: edges);
}

ProviderContainer _c(Network net, int floors) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors(
        [for (var i = 0; i < floors; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.05));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

FireSystemBasis _pumped(ProviderContainer c) => c
    .read(fireSystemBasesProvider)
    .where((x) => x.pumpIds.isNotEmpty)
    .single;

void main() {
  test('(1) the roof booster outlets are judged on its own churn', () {
    final c = _c(_tower(), 10);
    final b = _pumped(c);
    final pb = b.stageHeads['PB']!.meters;
    expect(pb, lessThan(b.head.meters));
    final hits = c.read(standpipeOutletOverPressureProvider);
    // Nothing on L9 — PB's own outlets — is over either NFPA 14 limit.
    for (final h in hits) {
      expect(h.highFloor, lessThan(9),
          reason: '${h.pumpId} ${h.residual} ${h.lowFloor}-${h.highFloor} '
              '${h.maxKpa}');
    }
    // The L9 static on PB's own churn: 31.5 + 1.4 x pb - 32.7 (in m) is
    // under 1207 kPa (123 m) by construction.
    expect((31.5 + 1.4 * pb - 32.7) * 9.80665, lessThan(1207));
  });

  test('(2) a roof standby tank never collapses the series stages', () {
    for (final (floors, mid) in [(32, 16), (20, 10), (24, 8)]) {
      final without = _pumped(_c(_series(floors, mid), floors));
      final withRt =
          _pumped(_c(_series(floors, mid, roofStandby: true), floors));
      expect(without.stages.length, 2, reason: '$floors/$mid');
      expect(withRt.stages.length, without.stages.length,
          reason: '$floors/$mid');
      for (var i = 0; i < without.stages.length; i++) {
        expect(withRt.stages[i].pumpIds, without.stages[i].pumpIds);
      }
      // The lower stage is rated on its own zone, never the whole system.
      final lower = without.stages.firstWhere((s) => s.upstream == null);
      expect(lower.head.meters, lessThan(without.head.meters - 1));
      for (final id in ['APA', 'APB', 'ZPA', 'ZPB']) {
        final a = without.stageHeads[id]!.meters;
        final b = withRt.stageHeads[id]!.meters;
        // A standby tank above the upper zone changes no stage's role; its
        // head may differ only by what it changes in the sized friction.
        expect((a - b).abs(), lessThan(math.max(2.0, 0.02 * a)),
            reason: '$floors/$mid $id $a vs $b');
      }
    }
  });
}
