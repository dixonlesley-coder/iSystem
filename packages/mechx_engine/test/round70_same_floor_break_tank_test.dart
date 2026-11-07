// Round 70 (regression-same-floor-break-tank-transfer-zeroed) — a transfer
// pump filling a BREAK tank on its own floor (pump room and break tank in
// one plant room) is a transfer system with that tank as its destination,
// whatever fire service each pump-room pipe is drawn on and whichever way
// each pipe is drawn.
//
// Drawing: GT(L0) -g1- J1 -g2- SH -s- TP -d- DS -tr- BT (ground tank, L0)
// -s2a- SH2 -s2- FP -d2- DH -> riser with a hydrant box on L1..L7.
//
// First principles: the zone is one Class I stack = 500 gpm = 31.545 L/s,
// and the transfer pump must refill BT at that flow (fireTransferFedFlow);
// NFPA 20 Table 4.28(a) 500 gpm ⇒ DN125 suction and discharge. So every
// pipe g1..d2 carries 31.545 L/s on DN125, flowing GT -> BT -> FP — the
// all-hydrant drawing's reading, which the structural destination test
// (BT is the one tank of the transfer system another system draws on)
// recovers without reading a drawn direction or a pipe's fire service.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: floor * 10.0,
        floorIndex: floor,
        role: role,
        component: c);

const _train = ['g1', 'g2', 's', 'd', 'tr', 's2a', 's2', 'd2'];

Network _net({Set<String> sprinkler = const {}, Set<String> flip = const {}}) {
  NetEdge e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) {
    final f = flip.contains(id);
    return NetEdge(
        id: id,
        fromId: f ? b : a,
        toId: f ? a : b,
        service: sprinkler.contains(id)
            ? ServiceType.fireSprinkler
            : ServiceType.fireHydrant,
        kind: k);
  }

  return Network(nodes: [
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('J1', 50),
    _n('SH', 100),
    _n('TP', 150, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DS', 200),
    _n('BT', 250, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH2', 300),
    _n('FP', 350, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DH', 400),
    for (var f = 1; f <= 7; f++) ...[
      _n('X$f', 400, floor: f),
      _n('B$f', 500,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
    ],
  ], edges: [
    e('g1', 'GT', 'J1'),
    e('g2', 'J1', 'SH'),
    e('s', 'SH', 'TP'),
    e('d', 'TP', 'DS'),
    e('tr', 'DS', 'BT'),
    e('s2a', 'BT', 'SH2'),
    e('s2', 'SH2', 'FP'),
    e('d2', 'FP', 'DH'),
    e('r1', 'DH', 'X1', k: EdgeKind.riser),
    for (var f = 2; f <= 7; f++) e('r$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
    for (var f = 1; f <= 7; f++) e('b$f', 'X$f', 'B$f'),
  ]);
}

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {
        ServiceType.fireHydrant: FlowRate(0.005),
        ServiceType.fireSprinkler: FlowRate(0.001),
      },
      hydrantDesignFlow: standpipeFlow(1),
      building: BuildingLevels(
          [for (var i = 0; i < 8; i++) Floor('L$i', const Length(3.5))]),
      calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
    );

void _expectTrain(Map<String, EdgeSizing> r, Map<String, EdgeSizing> base,
    String why) {
  for (final id in _train) {
    expect(r[id]?.diameter.inMillimeters, base[id]!.diameter.inMillimeters,
        reason: '$why $id DN');
    expect(r[id]!.flow.cubicMetersPerSecond,
        closeTo(base[id]!.flow.cubicMetersPerSecond, 1e-9),
        reason: '$why $id flow');
    expect(r[id]!.flowFromId, base[id]!.flowFromId, reason: '$why $id dir');
  }
}

void main() {
  final base = _size(_net());

  test('all hydrant: the transfer train carries the zone flow on DN125', () {
    final q = standpipeFlow(1).cubicMetersPerSecond;
    for (final id in _train) {
      expect(base[id]!.diameter.inMillimeters, 125, reason: id);
      expect(base[id]!.flow.cubicMetersPerSecond, closeTo(q, 1e-9),
          reason: id);
    }
    expect(base['tr']!.flowFromId, 'DS'); // into the break tank
    expect(base['s2a']!.flowFromId, 'BT'); // out of it
  });

  test('one pump-room pipe on the sprinkler service: == all hydrant', () {
    for (final id in _train) {
      _expectTrain(_size(_net(sprinkler: {id})), base, 'sprinkler $id');
    }
  });

  test('every pipe flipped: == all hydrant', () {
    _expectTrain(_size(_net(flip: {..._train})), base, 'all flipped');
  });

  test('seeded: services x flips == all hydrant', () {
    final rnd = math.Random(70);
    for (var t = 0; t < 40; t++) {
      final spr = {
        for (final id in _train)
          if (rnd.nextInt(4) == 0) id
      };
      final flip = {
        for (final id in _train)
          if (rnd.nextBool()) id
      };
      _expectTrain(_size(_net(sprinkler: spr, flip: flip)), base,
          'trial $t spr=$spr flip=$flip');
    }
  });
}
