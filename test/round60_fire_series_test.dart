// Round 60 (2026-10-18) — fire-convergence-12-series-lower-stage-rated-with-
// whole-system-friction.
//
// In a series fire-pump chain the LOWER stage develops what its OWN zone
// needs from the system datum: its zone's index-path friction (the sized
// Hazen–Williams path from the root pump to the lower zone's terminals, at
// least the 15 m allowance), never the whole system's friction to the TOP
// terminal. The top stage takes the rest of the system head, so the stage
// heads still sum to it.
//
// First principles (6 x 3.5 m, calibrated 0.01 m/px): GT -> P1 -> D1 -> low
// riser (boxes L0-L2); D1 -> P2 -> 300 m discharge main -> D2 -> upper riser
// (boxes L3-L5). One stack, Class I: 500 gpm = 31.545 L/s. The main is P2's
// DISCHARGE, so (Round 61) NFPA 20 Table 4.28(a) floors it at 5 in (DN125):
// J = 10.67 Q^1.852 / (C^1.852 D^4.87) at C 120 ~ 0.18 x (100/125)^4.87 =
// 0.061 m/m, so 300 m adds ~18 m to the TOP terminal's friction (> the 15 m
// allowance; the 150 m of the Round-60 drawing gave only ~9 m on DN125),
// while the low zone's short path stays under the allowance (15 m governs).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(
  String id,
  double x, {
  int floor = 0,
  NodeRole role = NodeRole.main,
  NodeComponent? c,
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: 0,
  floorIndex: floor,
  role: role,
  component: c,
);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
      id: id,
      fromId: a,
      toId: b,
      service: ServiceType.fireHydrant,
      kind: k,
    );

Network _tower() => Network(
  nodes: [
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('P1', 100, role: NodeRole.plant, c: NodeComponent.pump),
    _n('D1', 200),
    _n('P2', 300, role: NodeRole.plant, c: NodeComponent.pump),
    _n('D2', 30300),
    for (var f = 0; f < 6; f++) ...[
      _n('L$f', f < 3 ? 900 : 30300, floor: f),
      _n(
        'HB$f',
        f < 3 ? 1000 : 30400,
        floor: f,
        role: NodeRole.fixture,
        c: NodeComponent.hydrantBox,
      ),
    ],
  ],
  edges: [
    _e('g1', 'GT', 'P1'),
    _e('p1', 'P1', 'D1'),
    _e('dl', 'D1', 'L0'),
    _e('d1p2', 'D1', 'P2'),
    _e('p2', 'P2', 'D2'),
    _e('du', 'D2', 'L3', k: EdgeKind.riser),
    for (var f = 0; f < 6; f++) ...[
      if (f > 0 && f != 3) _e('q$f', 'L${f - 1}', 'L$f', k: EdgeKind.riser),
      _e('hb$f', 'L$f', 'HB$f'),
    ],
  ],
);

// designStandpipe's default frictionAllowance (the NFPA-practice 15 m).
const allowance = 15.0;

void main() {
  test('the lower series stage is rated on its OWN zone friction; the '
      'stages still sum to the system head', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier)
      ..setFloors([for (var i = 0; i < 6; i++) Floor('L$i', const Length(3.5))])
      ..setCalibration('s1', const ScaleCalibration(0.01));
    c.read(networkControllerProvider.notifier).loadNetwork(_tower());
    final b = c.read(fireSystemBasesProvider).single;
    expect(b.stageHeads.keys, unorderedEquals(['P1', 'P2']));
    final net = _tower();
    final project = c.read(projectControllerProvider);
    double lengthOf(NetEdge e) => edgeLength(
      e,
      net,
      calibrationBySheet: project.calibrations,
      building: project.building,
      mounting: project.mounting,
    ).meters;
    final sys = fireRatingSystems(net).single;
    final sizing = c.read(sizingProvider);
    final lowFriction = fireIndexPathFrictionM(
      net: net,
      system: sys,
      pumpId: 'P1',
      sizing: sizing,
      lengthOf: lengthOf,
      terminals: FireTerminalKind.hydrant,
      targetIds: const {'HB0', 'HB1', 'HB2'},
    )!;
    // The system friction (to the TOP box, past the 300 m main) is above the
    // 15 m allowance; the low zone's own path is below it.
    expect(b.indexFrictionM!, greaterThan(allowance));
    expect(lowFriction, lessThan(allowance));
    // P1: the standpipe point of its own zone (the L2 outlet, 7 + 1.2 m) at
    // the ZONE's friction term (here the 15 m allowance).
    const lowLift = Length(2 * 3.5 + kHoseOutletHeightM);
    final low = designStandpipe(
      risers: b.standpipeRisers,
      buildingHeight: lowLift,
      indexPathFriction: Head(lowFriction),
    );
    expect(b.stageHeads['P1']!.meters, closeTo(low.pumpHead.meters, 1e-9));
    // ... never the whole system's friction (the Round 59 figure).
    final whole = designStandpipe(
      risers: b.standpipeRisers,
      buildingHeight: lowLift,
      indexPathFriction: Head(b.indexFrictionM!),
    );
    expect(
      whole.pumpHead.meters - b.stageHeads['P1']!.meters,
      closeTo(b.indexFrictionM! - allowance, 1e-6),
    );
    // P2 takes the rest: the stages sum to the system head.
    expect(
      b.stageHeads['P1']!.meters + b.stageHeads['P2']!.meters,
      closeTo(b.head.meters, 1e-9),
    );
  });
}
