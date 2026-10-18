/// Audit round 8 — MEP→electrical feed coupling (app side).
///
///   fire-hvac-1  an AC above 3 PK feeds its REAL per-unit input, not the
///                saturated 27 000 BTU/h nominal.
///   coupling-1   a pump drawn on a fire riser feeds as a life-safety FIRE
///                pump on the NFPA 20 motor (not a 1.5 kW supply pump).
///   coupling-2   a drawn plant node and its solved duty are ONE way.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/units.dart';

const _fireDuty = PumpDuty(
  flow: FlowRate(0.0347),
  head: Head(97),
  hydraulicPower: Power(33000),
  shaftPower: Power(47000),
  motorInputPower: Power(52000),
  selectedMotor: Power(55000),
);

const _supplyDuty = PumpDuty(
  flow: FlowRate(0.005),
  head: Head(30),
  hydraulicPower: Power(1500),
  shaftPower: Power(2100),
  motorInputPower: Power(2500),
  selectedMotor: Power(3000),
);

NetNode _n(String id, double x,
        {NodeComponent? c, NodeRole role = NodeRole.main}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 50,
        floorIndex: 0,
        role: role,
        component: c);

void main() {
  test('fire-hvac-1: a 100 m² room on ONE ducted AC feeds its real input', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.01));
    // 1000 px × 1000 px at 0.01 m/px = 10 m × 10 m = 100 m².
    const room = RoomArea(
        id: 'r0', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 1000, by: 1000);
    c.read(roomAreasProvider.notifier).set(const [room]);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
          _n('ac', 500,
              c: NodeComponent.acDucted, role: NodeRole.plant),
        ]));
    final load = room.coolingLoad(0.01)!;
    // The per-unit requirement is far above the 3 PK (27 000 BTU/h) top rung.
    expect(load.btuPerHr, greaterThan(27000));
    expect(selectAc(load.btuPerHr).exceedsRange, isTrue);
    final w = c.read(placedEquipmentLoadsProvider).single.mechanicalPower.watts;
    // input = Q_cool / (3.412 BTU/h per W) / COP 3 — on the REAL load.
    expect(w, closeTo(acInputPowerW(coolingBtuPerHr: load.btuPerHr), 1e-6));
    expect(w, greaterThan(acInputPowerW(coolingBtuPerHr: 27000) * 1.5));
  });

  test('fire-hvac-1 (seeded property): the fed input never drops below the '
      'room requirement split per unit', () {
    for (var side = 300; side <= 1500; side += 150) {
      final c = ProviderContainer();
      c
          .read(projectControllerProvider.notifier)
          .setCalibration('s1', const ScaleCalibration(0.01));
      final room = RoomArea(
          id: 'r', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0,
          bx: side.toDouble(), by: side.toDouble());
      c.read(roomAreasProvider.notifier).set([room]);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
            _n('a', 100, c: NodeComponent.acCassette, role: NodeRole.plant),
            _n('b', 200, c: NodeComponent.acCassette, role: NodeRole.plant),
          ]));
      final perUnit = room.coolingLoad(0.01)!.btuPerHr / 2;
      for (final l in c.read(placedEquipmentLoadsProvider)) {
        expect(l.mechanicalPower.watts,
            greaterThanOrEqualTo(acInputPowerW(coolingBtuPerHr: perUnit) - 1e-6),
            reason: 'side $side px');
      }
      c.dispose();
    }
  });

  ProviderContainer fireNet({bool dutyFeed = false}) {
    final c = ProviderContainer(overrides: [
      firePumpDutyProvider.overrideWith((ref) => _fireDuty),
      pumpDutyProvider.overrideWith((ref) => _supplyDuty),
    ]);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
          _n('FP', 0, c: NodeComponent.pump, role: NodeRole.plant),
          _n('H', 100, c: NodeComponent.hydrantBox, role: NodeRole.fixture),
          _n('P', 300, c: NodeComponent.pump, role: NodeRole.plant),
          _n('T', 400, role: NodeRole.fixture),
        ], edges: const [
          NetEdge(
              id: 'h', fromId: 'FP', toId: 'H', service: ServiceType.fireHydrant),
          NetEdge(
              id: 'w', fromId: 'P', toId: 'T', service: ServiceType.coldWater),
        ]));
    if (dutyFeed) c.read(mepDutyFeedEnabledProvider.notifier).enable();
    return c;
  }

  test('coupling-1: a pump on a hydrant riser is a life-safety fire pump on '
      'the NFPA 20 motor', () {
    final c = fireNet();
    addTearDown(c.dispose);
    final way = c
        .read(placedEquipmentCircuitsProvider)
        .firstWhere((w) => w.sourceEquipmentId == 'node-FP');
    expect(way.lifeSafety, isTrue);
    expect(way.cableType, 'FRC');
    expect(way.motorKw, closeTo(55, 1e-9));
    // input = 55 000 / η 0.90 = 61 111 W; Ib = 61 111 / (√3·400·0.85) = 103.8 A
    expect(way.loadW, closeTo(55000 / 0.90, 1e-6));
    expect(way.flaOverrideA!.amperes, closeTo(103.8, 0.1));
  });

  test('coupling-2: duty feed ON — each machine is ONE way, never two', () {
    final c = fireNet(dutyFeed: true);
    addTearDown(c.dispose);
    final ways = c.read(mepEquipmentCircuitsProvider);
    final ids = ways.map((w) => w.sourceEquipmentId).toList();
    // The drawn FP carries the fire duty; the drawn P carries the supply duty.
    expect(ids, isNot(contains('fire-pump')));
    expect(ids, isNot(contains('supply-pump')));
    expect(ids.where((i) => i == 'node-FP'), hasLength(1));
    expect(ids.where((i) => i == 'node-P'), hasLength(1));
    // P's way is the SUPPLY duty on its nameplate: 3 kW motor,
    // input = max(2500, 3000 / 0.90) = 3333.3 W — the schedule's kW.
    final p = ways.firstWhere((w) => w.sourceEquipmentId == 'node-P');
    expect(p.motorKw, closeTo(3.0, 1e-9));
    expect(p.loadW, closeTo(3000 / 0.90, 1e-6));
    expect(p.lifeSafety, isFalse);
  });

  test('coupling-2: duty feed OFF — the node still carries the solved duty', () {
    final c = fireNet();
    addTearDown(c.dispose);
    final p = c
        .read(placedEquipmentCircuitsProvider)
        .firstWhere((w) => w.sourceEquipmentId == 'node-P');
    expect(p.motorKw, closeTo(3.0, 1e-9)); // not the 1.5 kW component default
  });

  test('coupling-2: with NO drawn plant the duty way is still minted', () {
    final c = ProviderContainer(overrides: [
      firePumpDutyProvider.overrideWith((ref) => _fireDuty),
      pumpDutyProvider.overrideWith((ref) => _supplyDuty),
    ]);
    addTearDown(c.dispose);
    c.read(mepDutyFeedEnabledProvider.notifier).enable();
    final ids = c
        .read(mepEquipmentCircuitsProvider)
        .map((w) => w.sourceEquipmentId)
        .toSet();
    expect(ids, containsAll(['fire-pump', 'supply-pump']));
  });
}
