// Round 80 (2026-10-18) — fire-convergence-31-peer-duplex-rooms-on-one-tank-
// standby-made-jockey.
//
// A petrol depot, one storey: ONE ground tank GT feeds two independent duplex
// rooms (GT -> S1 -> P1a / P1b -> D1 -> Y2 and GT -> S2 -> P2a / P2b -> D2 ->
// Y0) into a DN150 yard ring Y0..Y3 with 4 pillar hydrants.
//
// First principles: every main pump develops the yard point (38 L/s) — one
// duty and three full-size standbys. No smaller leg is drawn, so there is no
// jockey; an ASSUMED jockey needs three or more pumps of ONE room (one pair
// of headers). Every pump leg carries the 38 L/s set flow on DN150, whichever
// way the pipes are drawn and with or without a sprinkler grid off the ring.
// A genuine three-pump room on one pair of headers keeps its assumed jockey.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, double y, {NodeComponent? c}) => NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: 0,
      role: c?.role ?? NodeRole.main,
      component: c,
    );

Network _depot({bool grid = false, bool reversed = false}) {
  final nodes = <NetNode>[
    _n('GT', 0, 0, c: NodeComponent.groundTank),
  ];
  final edges = <NetEdge>[];
  void e(String id, String a, String b, {bool spr = false}) => edges.add(
        NetEdge(
          id: id,
          fromId: reversed ? b : a,
          toId: reversed ? a : b,
          service: spr ? ServiceType.fireSprinkler : ServiceType.fireHydrant,
          kind: EdgeKind.run,
        ),
      );
  const ring = [(400.0, 0.0), (400.0, 400.0), (800.0, 400.0), (800.0, 0.0)];
  for (var i = 0; i < 4; i++) {
    nodes
      ..add(_n('Y$i', ring[i].$1, ring[i].$2))
      ..add(_n('PH$i', ring[i].$1 + 50, ring[i].$2 + 50,
          c: NodeComponent.pillarHydrant));
    e('y$i', 'Y$i', 'Y${(i + 1) % 4}');
    e('ph$i', 'Y$i', 'PH$i');
  }
  for (final (r, y, yard) in [('1', 300.0, 'Y2'), ('2', -300.0, 'Y0')]) {
    nodes
      ..add(_n('S$r', 100, y))
      ..add(_n('P${r}a', 200, y, c: NodeComponent.pump))
      ..add(_n('P${r}b', 200, y + 40, c: NodeComponent.pump))
      ..add(_n('D$r', 300, y));
    e('g$r', 'GT', 'S$r');
    for (final k in ['a', 'b']) {
      e('s$r$k', 'S$r', 'P$r$k');
      e('d$r$k', 'P$r$k', 'D$r');
    }
    e('h$r', 'D$r', yard);
  }
  if (grid) {
    nodes.add(_n('ZS', 600, 500));
    e('zs', 'Y1', 'ZS', spr: true);
    for (var k = 0; k < 12; k++) {
      nodes.add(_n('SP$k', 500.0 + 20 * k, 550, c: NodeComponent.sprinklerHead));
      e('sp$k', k == 0 ? 'ZS' : 'SP${k - 1}', 'SP$k', spr: true);
    }
  }
  return Network(nodes: nodes, edges: edges);
}

ProviderContainer _c(Network net) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([Floor('L0', const Length(6))])
    ..setCalibration('s1', const ScaleCalibration(0.05));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  for (final grid in [false, true]) {
    for (final reversed in [false, true]) {
      test('two duplex rooms on one tank (grid $grid, reversed $reversed): '
          'one duty, three standbys, no jockey', () {
        final c = _c(_depot(grid: grid, reversed: reversed));
        final bind = c.read(mepDutyBindingProvider);
        expect(bind.fireJockeyPumpNodeIds, isEmpty);
        expect(bind.fireAssumedJockeyPumpNodeIds, isEmpty);
        expect(bind.fireStandbyPumpNodeIds, hasLength(3));
        final duties = c.read(equipmentNodeDutiesProvider);
        final kw = {
          for (final p in ['P1a', 'P1b', 'P2a', 'P2b'])
            p: duties[p]!.motor.watts,
        };
        expect(kw.values.toSet(), hasLength(1), reason: '$kw');
        final sz = c.read(sizingProvider);
        for (final id in ['s1a', 's1b', 's2a', 's2b', 'd1a', 'd1b', 'd2a',
            'd2b']) {
          expect(sz[id]!.diameter.inMillimeters, greaterThanOrEqualTo(150),
              reason: id);
          expect(sz[id]!.flow.inLitersPerSecond, greaterThanOrEqualTo(38 - 1e-6),
              reason: id);
        }
      });
    }
  }

  test('a genuine three-pump room on one pair of headers keeps its assumed '
      'jockey', () {
    final nodes = <NetNode>[
      _n('GT', 0, 0, c: NodeComponent.groundTank),
      _n('S', 100, 0),
      _n('D', 300, 0),
      for (var k = 0; k < 3; k++)
        _n('P$k', 200, 40.0 * k, c: NodeComponent.pump),
      _n('Y', 400, 0),
      _n('PH', 450, 0, c: NodeComponent.pillarHydrant),
    ];
    NetEdge e(String id, String a, String b) => NetEdge(
        id: id,
        fromId: a,
        toId: b,
        service: ServiceType.fireHydrant,
        kind: EdgeKind.run);
    final edges = [
      e('g', 'GT', 'S'),
      for (var k = 0; k < 3; k++) ...[
        e('s$k', 'S', 'P$k'),
        e('d$k', 'P$k', 'D'),
      ],
      e('m', 'D', 'Y'),
      e('ph', 'Y', 'PH'),
    ];
    final c = _c(Network(nodes: nodes, edges: edges));
    final bind = c.read(mepDutyBindingProvider);
    expect(bind.fireAssumedJockeyPumpNodeIds, hasLength(1));
    expect(bind.fireStandbyPumpNodeIds, hasLength(1));
  });
}
