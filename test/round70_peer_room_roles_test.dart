// Round 70 (fire-convergence-22-peer-duplex-room-pump-wired-as-assumed-
// jockey) — two duplex pump rooms on a yard ring (8 pillar hydrants, a
// 24-head sprinkler zone): room A (GA -> SA -> A1 / A2, each through a check
// valve -> HA -> Y4) and its mirror room B into Y0.
//
// First principles: one fire event runs ONE room; each room carries the
// whole set flow while the other is isolated (the Round-14 peer source), so
// the governing room's first pump is the DUTY machine (demand factor 1) and
// every other main pump — the governing room's standby and BOTH peer-room
// pumps — is a STANDBY unit of the same rating (demand factor 0). Nothing
// drawn is a smaller leg, so there is NO jockey (an ASSUMED jockey needs
// three or more pumps of one room). The roles never depend on which fire
// service the room-B pipes are drawn on, nor on the check valves.
import 'dart:math' as math;

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

NetNode _n(String id, double x, double y, {NodeComponent? c, int floor = 0}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: floor,
      role: c?.role ?? NodeRole.main,
      component: c,
    );

Network _yard({bool roomBSprinkler = false, bool checkValves = true}) {
  final nodes = <NetNode>[];
  final edges = <NetEdge>[];
  NetEdge e(String id, String a, String b, {bool spr = false}) => NetEdge(
    id: id,
    fromId: a,
    toId: b,
    service: spr ? ServiceType.fireSprinkler : ServiceType.fireHydrant,
    kind: EdgeKind.run,
  );
  for (var i = 0; i < 8; i++) {
    final a = i * math.pi / 4;
    nodes
      ..add(_n('Y$i', 400 * math.cos(a), 400 * math.sin(a)))
      ..add(
        _n(
          'PH$i',
          500 * math.cos(a),
          500 * math.sin(a),
          c: NodeComponent.pillarHydrant,
        ),
      );
    edges
      ..add(e('y$i', 'Y$i', 'Y${(i + 1) % 8}'))
      ..add(e('ph$i', 'Y$i', 'PH$i'));
  }
  // A 24-head sprinkler zone off Y2: one branch, heads in a row.
  nodes.add(_n('ZS', 0, 300));
  edges.add(e('zs', 'Y2', 'ZS', spr: true));
  for (var k = 0; k < 24; k++) {
    nodes.add(
      _n('SP$k', 50.0 * k - 600, 250, c: NodeComponent.sprinklerHead),
    );
    edges.add(e('sp$k', k == 0 ? 'ZS' : 'SP${k - 1}', 'SP$k', spr: true));
  }
  for (final (r, x, yard) in [('A', -900.0, 'Y4'), ('B', 900.0, 'Y0')]) {
    final s = x.sign;
    final spr = r == 'B' && roomBSprinkler;
    nodes
      ..add(_n('G$r', x + s * 300, 0, c: NodeComponent.groundTank))
      ..add(_n('S$r', x + s * 200, 0))
      ..add(_n('H$r', x, 0));
    edges.add(e('g$r', 'G$r', 'S$r', spr: spr));
    for (var k = 1; k <= 2; k++) {
      final p = '$r$k';
      nodes.add(_n(p, x + s * 150, 60.0 * (k - 1), c: NodeComponent.pump));
      edges.add(e('s$p', 'S$r', p, spr: spr));
      if (checkValves) {
        nodes.add(
          _n('C$p', x + s * 75, 60.0 * (k - 1), c: NodeComponent.checkValve),
        );
        edges
          ..add(e('d$p', p, 'C$p', spr: spr))
          ..add(e('c$p', 'C$p', 'H$r', spr: spr));
      } else {
        edges.add(e('d$p', p, 'H$r', spr: spr));
      }
    }
    edges.add(e('h$r', 'H$r', yard, spr: spr));
  }
  return Network(nodes: nodes, edges: edges);
}

ProviderContainer _c(Network net) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 3; i++) Floor('L$i', const Length(6))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  for (final spr in [false, true]) {
    for (final cv in [true, false]) {
      test('room B ${spr ? 'sprinkler' : 'hydrant'}, '
          '${cv ? 'check valves' : 'no check valves'}: one duty, three '
          'standbys, no jockey', () {
        final c = _c(_yard(roomBSprinkler: spr, checkValves: cv));
        final bind = c.read(mepDutyBindingProvider);
        expect(bind.fireJockeyPumpNodeIds, isEmpty);
        expect(bind.fireAssumedJockeyPumpNodeIds, isEmpty);
        expect(bind.fireStandbyPumpNodeIds, hasLength(3));
        final duty = {
          'A1',
          'A2',
          'B1',
          'B2',
        }.difference(bind.fireStandbyPumpNodeIds);
        expect(duty, hasLength(1));
        // Every pump is the same full-size machine.
        final duties = c.read(equipmentNodeDutiesProvider);
        final kw = {
          for (final p in ['A1', 'A2', 'B1', 'B2'])
            p: duties[p]!.motor.watts,
        };
        expect(kw.values.toSet(), hasLength(1), reason: '$kw');
        expect(kw.values.first, greaterThan(10000));
        // Room B's main pipes carry the set flow on the same bore as A's.
        final sz = c.read(sizingProvider);
        for (final k in ['1', '2']) {
          expect(
            sz['sB$k']!.diameter.inMillimeters,
            sz['sA$k']!.diameter.inMillimeters,
          );
          expect(
            sz['sB$k']!.flow.cubicMetersPerSecond,
            closeTo(sz['sA$k']!.flow.cubicMetersPerSecond, 1e-6),
          );
        }
      });
    }
  }
}
