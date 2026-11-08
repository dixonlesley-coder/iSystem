// Round 72 (plumbing-hvac-convergence-22-prv-on-break-tank-fill-shifts-tank-
// region) — a downfeed tower whose mid-height BREAK tank is filled through a
// PRV (the common float-valve protection):
//
//   RT (roof tank, L39) -> riser R39..R20, lavatories on L21..L39;
//   fill R20 -> [PRV] -> BT (roof-typed tank on L20 at 70 m);
//   BT -> riser L20..L1, a lavatory on every storey L1..L19.
//
// First principles: BT has a free water surface, so the head below it
// restarts from 70 m whatever happens on the fill pipe. The static head at a
// BT-fed lavatory is (70 - z) x rho g with z = 3.5 f + 1.1 m:
//   WB19 (70 - 67.6) = 2.4 m  -> 23.5 kPa,
//   WB10 (70 - 36.1) = 33.9 m -> 332.6 kPa,
//   WB1  (70 - 4.6)  = 65.4 m -> 641.6 kPa,
// identical with or without the fill PRV. Before the fix the fill PRV
// (inlet ~67 m of static head, setpoint 255 kPa ~ 26 m) subtracted its
// ~40.8 m excess from every BT-fed node (WB19 -376.8 kPa, booster 59.6 m).
library;

import 'dart:math';

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, int floor,
        {NodeRole role = NodeRole.main,
        NodeComponent? c,
        PlumbingFixture? fx}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: floor,
        role: role,
        component: c,
        fixture: fx);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.coldWater, kind: k);

final _b = BuildingLevels(
    [for (var i = 0; i < 40; i++) Floor('L$i', const Length(3.5))]);

/// [fillPrv]: the PRV on the fill pipe R20 -> PRV -> BT. [lowPrvFloor]: an
/// extra PRV drawn BELOW the break tank, inline on the BT riser at that
/// storey (null = none). [fillReversed] draws the fill pipes BT-first.
Network _tower(
    {bool fillPrv = true, int? lowPrvFloor, bool fillReversed = false}) {
  return Network(nodes: [
    _n('RT', 200, 39, role: NodeRole.plant, c: NodeComponent.roofTank),
    for (var f = 20; f <= 39; f++) _n('R$f', 220, f),
    for (var f = 21; f <= 39; f++)
      _n('WR$f', 240, f, role: NodeRole.fixture, fx: PlumbingFixture.lavatory),
    if (fillPrv) _n('PRV', 120, 20, c: NodeComponent.prv),
    _n('BT', 60, 20, role: NodeRole.plant, c: NodeComponent.roofTank),
    for (var f = 1; f <= 20; f++) _n('L$f', 140, f),
    if (lowPrvFloor != null) _n('PL', 145, lowPrvFloor, c: NodeComponent.prv),
    for (var f = 1; f <= 19; f++)
      _n('WB$f', 160, f, role: NodeRole.fixture, fx: PlumbingFixture.lavatory),
  ], edges: [
    _e('r39', 'RT', 'R39'),
    for (var f = 38; f >= 20; f--)
      _e('r$f', 'R${f + 1}', 'R$f', k: EdgeKind.riser),
    for (var f = 21; f <= 39; f++) _e('x$f', 'R$f', 'WR$f'),
    if (fillPrv) ...[
      fillReversed ? _e('f1', 'PRV', 'R20') : _e('f1', 'R20', 'PRV'),
      fillReversed ? _e('f2', 'BT', 'PRV') : _e('f2', 'PRV', 'BT'),
    ] else
      fillReversed ? _e('f1', 'BT', 'R20') : _e('f1', 'R20', 'BT'),
    _e('l20', 'BT', 'L20'),
    for (var f = 19; f >= 1; f--)
      if (lowPrvFloor == f) ...[
        _e('l${f}a', 'L${f + 1}', 'PL', k: EdgeKind.riser),
        _e('l${f}b', 'PL', 'L$f'),
      ] else
        _e('l$f', 'L${f + 1}', 'L$f', k: EdgeKind.riser),
    for (var f = 1; f <= 19; f++) _e('w$f', 'L$f', 'WB$f'),
  ]);
}

const _cal = {'s1': ScaleCalibration(0.01)};

DownfeedSolution _solve(Network net) {
  final sizing = autoSizeNetwork(net, const SizingContext(),
      leafDemand: const {ServiceType.coldWater: FlowRate(0.0002)},
      building: _b,
      calibrationBySheet: _cal);
  return solveDownfeed(
    net: net,
    service: ServiceType.coldWater,
    tankId: 'RT',
    edgeFlows: {for (final e in sizing.entries) e.key: e.value.flow},
    sizing: sizing,
    calibrationBySheet: _cal,
    building: _b,
    targetResidual: Pressure.kiloPascals(225),
    prvSetpoint: Pressure.kiloPascals(255),
  );
}

double _kpa(double head) => pressureFromHead(Head(head)).inKiloPascals;

void main() {
  for (final rev in [false, true]) {
    test('fill-line PRV never shifts the break-tank region (reversed: $rev)',
        () {
      final base = _solve(_tower(fillPrv: false, fillReversed: rev));
      final prv = _solve(_tower(fillReversed: rev));
      for (final f in [1, 10, 19]) {
        final z = f * 3.5 + 1.1;
        expect(prv.noFlowStaticPressure['WB$f']!.inKiloPascals,
            closeTo(_kpa(70 - z), 0.05),
            reason: 'WB$f static from the 70 m water surface');
        expect(prv.residualPressure['WB$f']!.inKiloPascals,
            closeTo(base.residualPressure['WB$f']!.inKiloPascals, 1e-6));
      }
      // RT-fed floors unchanged too.
      for (final f in [21, 39]) {
        expect(prv.noFlowStaticPressure['WR$f']!.inKiloPascals,
            closeTo(base.noFlowStaticPressure['WR$f']!.inKiloPascals, 1e-6));
      }
      expect(prv.criticalNodeId, 'WB19');
      expect(prv.criticalNodeId, base.criticalNodeId);
      expect(prv.boosterHeadRequired.meters,
          closeTo(base.boosterHeadRequired.meters, 1e-6));
      // The booster tops WB19 (2.4 m of static less its friction) up to the
      // 225 kPa target: deficit >= target head - 2.4 m (~ 20.5 m), and far
      // from the pre-fix ~59.6 m.
      expect(
          prv.boosterHeadRequired.meters,
          greaterThanOrEqualTo(
              headFromPressure(Pressure.kiloPascals(225)).meters - 2.4 - 1e-6));
      expect(prv.boosterHeadRequired.meters, lessThan(30));
    });
  }

  test('prvHeldNodes holds no node past the break tank', () {
    final held =
        prvHeldNodes(_tower(), service: ServiceType.coldWater, sourceId: 'RT');
    expect(held.heldBy['PRV'], 'PRV');
    expect(held.heldBy['BT'], 'PRV', reason: 'the float valve is protected');
    for (var f = 1; f <= 20; f++) {
      expect(held.heldBy.containsKey('L$f'), isFalse);
    }
    for (var f = 1; f <= 19; f++) {
      expect(held.heldBy.containsKey('WB$f'), isFalse);
    }
  });

  test('a PRV BELOW the break tank still reduces the floors it serves', () {
    final sol = _solve(_tower(lowPrvFloor: 10));
    // PL sits on the BT riser between L11 and L10; its inlet static from the
    // 70 m surface exceeds the 26 m (255 kPa) setpoint, so WB1..WB10 drop
    // below their gravity value while WB11..WB19 keep the 70 m datum.
    for (final f in [1, 5, 10]) {
      expect(sol.noFlowStaticPressure['WB$f']!.inKiloPascals,
          lessThan(_kpa(70 - (f * 3.5 + 1.1)) - 1));
    }
    for (final f in [11, 19]) {
      expect(sol.noFlowStaticPressure['WB$f']!.inKiloPascals,
          closeTo(_kpa(70 - (f * 3.5 + 1.1)), 0.05));
    }
    final held = prvHeldNodes(_tower(lowPrvFloor: 10),
        service: ServiceType.coldWater, sourceId: 'RT');
    expect(held.heldBy['WB5'], 'PL');
  });

  test(
      'seeded: the fill-line PRV and its drawn direction never move a '
      'BT-fed pressure', () {
    final rng = Random(72);
    final base = _solve(_tower(fillPrv: false));
    for (var trial = 0; trial < 6; trial++) {
      final sol =
          _solve(_tower(fillPrv: rng.nextBool(), fillReversed: rng.nextBool()));
      for (var f = 1; f <= 19; f++) {
        expect(sol.noFlowStaticPressure['WB$f']!.inKiloPascals,
            closeTo(base.noFlowStaticPressure['WB$f']!.inKiloPascals, 1e-6));
        expect(sol.residualPressure['WB$f']!.inKiloPascals,
            closeTo(base.residualPressure['WB$f']!.inKiloPascals, 1e-6));
      }
    }
  });
}
