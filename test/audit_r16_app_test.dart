// Round 16 (2026-10-18) — app-side regressions:
//   inline-fan-duty-by-role      an inline fresh-air fan's duty lands on the
//                                FAN under any node ids, never an FCU;
//   ducted-ac-load               ducting a ducted AC keeps its panel load on
//                                the room-PK input, scheduled once;
//   shared-main-second-ahu       a mirrored peer AHU carries the system duty;
//   report-fire-gate             no fire system drawn ⇒ no fire pump in the
//                                calc report;
//   hw-recirc-loop-head          the recirc head is the circulated index run
//                                at its own bores + the return leg;
//   root-pump-plus-booster       movers are sized IN SERIES;
//   transfer-pump-duty           GT -> TP -> RT gets its lift duty;
//   multi-booster                every zone booster gets its own duty;
//   recirc-pump-bound            a pump drawn on the HW loop is fed the
//                                recirc duty and scheduled.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/sizing/hot_water.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(
  String id,
  double x,
  double y, {
  int floor = 0,
  NodeRole role = NodeRole.main,
  NodeComponent? c,
  PlumbingFixture? fixture,
  FlowRate? airflow,
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: y,
  floorIndex: floor,
  role: role,
  component: c,
  fixture: fixture,
  airflow: airflow,
);

NetEdge _e(
  String id,
  String a,
  String b, {
  EdgeKind kind = EdgeKind.run,
  ServiceType service = ServiceType.coldWater,
}) => NetEdge(id: id, fromId: a, toId: b, service: service, kind: kind);

NetNode _wc(String id, double x, double y, int floor) => _n(
  id,
  x,
  y,
  floor: floor,
  role: NodeRole.fixture,
  fixture: PlumbingFixture.waterClosetFlushTank,
);

ProviderContainer _container(
  Network net, {
  FeedStrategy feed = FeedStrategy.upfeed,
  int floors = 3,
}) {
  final c = ProviderContainer();
  c.read(projectControllerProvider.notifier)
    ..setFloors([
      for (var i = 0; i < floors; i++) Floor('L$i', const Length(3.5)),
    ])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(feedStrategyProvider.notifier).set(feed);
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

Future<(WidgetRef, ProviderContainer)> _harness(WidgetTester tester) async {
  late WidgetRef capturedRef;
  await tester.pumpWidget(
    ProviderScope(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Consumer(
          builder: (context, ref, _) {
            capturedRef = ref;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(Consumer)),
    listen: false,
  );
  return (capturedRef, container);
}

/// A seeded renaming of [ids] whose string order differs from the logical one.
Map<String, String> _rename(List<String> ids, int seed) {
  final rnd = math.Random(seed);
  final names = [
    for (var i = 0; i < ids.length; i++) 'n${rnd.nextInt(90) + 1}x$i',
  ]..shuffle(rnd);
  return {for (var i = 0; i < ids.length; i++) ids[i]: names[i]};
}

void main() {
  group('inline-fan-duty-by-role', () {
    // L (bare intake) → FAN (inline supply fan) → J; J → FA → D1 and
    // J → FB → D2 (FCUs inline, 0.1 m³/s diffusers each).
    const ids = ['L', 'FAN', 'J', 'FA', 'FB', 'D1', 'D2'];
    Network build(Map<String, String> r) {
      String m(String id) => r[id] ?? id;
      const q = FlowRate(0.1);
      return Network(
        nodes: [
          _n(m('L'), 0, 0),
          _n(
            m('FAN'),
            100,
            0,
            role: NodeRole.plant,
            c: NodeComponent.supplyFan,
          ),
          _n(m('J'), 200, 0),
          _n(m('FA'), 300, -100, role: NodeRole.plant, c: NodeComponent.fcu),
          _n(m('FB'), 300, 100, role: NodeRole.plant, c: NodeComponent.fcu),
          _n(
            m('D1'),
            400,
            -100,
            role: NodeRole.fixture,
            c: NodeComponent.supplyDiffuser,
            airflow: q,
          ),
          _n(
            m('D2'),
            400,
            100,
            role: NodeRole.fixture,
            c: NodeComponent.supplyDiffuser,
            airflow: q,
          ),
        ],
        edges: [
          _e('lf', m('L'), m('FAN'), service: ServiceType.duct),
          _e('fj', m('FAN'), m('J'), service: ServiceType.duct),
          _e('ja', m('J'), m('FA'), service: ServiceType.duct),
          _e('jb', m('J'), m('FB'), service: ServiceType.duct),
          _e('a1', m('FA'), m('D1'), service: ServiceType.duct),
          _e('b2', m('FB'), m('D2'), service: ServiceType.duct),
        ],
      );
    }

    test('the FAN carries the 0.2 m³/s duty under ANY node ids', () {
      for (var seed = 0; seed < 20; seed++) {
        final r = seed == 0 ? const <String, String>{} : _rename(ids, seed);
        String m(String id) => r[id] ?? id;
        final c = _container(build(r));
        addTearDown(c.dispose);
        expect(
          c.read(airSystemRootNodesProvider).supply,
          m('FAN'),
          reason: 'seed $seed',
        );
        final duties = c.read(equipmentNodeDutiesProvider);
        expect(duties.containsKey(m('FAN')), isTrue, reason: 'seed $seed');
        expect(duties.containsKey(m('FA')), isFalse, reason: 'seed $seed');
        expect(duties.containsKey(m('FB')), isFalse, reason: 'seed $seed');
        // 0.1 + 0.1 = 0.2 m³/s through the fan.
        expect(
          c.read(ductFanProvider)!.airflow.cubicMetersPerSecond,
          closeTo(0.2, 1e-9),
        );
      }
    });
  });

  group('ducted-ac-load', () {
    // 1000 × 1000 px at 0.01 m/px = 100 m², one ducted AC.
    const room = RoomArea(
      id: 'r0',
      sheetId: 's1',
      floorIndex: 0,
      ax: 0,
      ay: 0,
      bx: 1000,
      by: 1000,
    );
    Network net({required bool ducted}) => Network(
      nodes: [
        _n('ac', 500, 500, role: NodeRole.plant, c: NodeComponent.acDucted),
        if (ducted) ...[
          _n('j', 600, 500),
          _n(
            'd1',
            700,
            400,
            role: NodeRole.fixture,
            c: NodeComponent.supplyDiffuser,
            airflow: const FlowRate(0.15),
          ),
          _n(
            'd2',
            700,
            600,
            role: NodeRole.fixture,
            c: NodeComponent.supplyDiffuser,
            airflow: const FlowRate(0.15),
          ),
        ],
      ],
      edges: [
        if (ducted) ...[
          _e('aj', 'ac', 'j', service: ServiceType.duct),
          _e('j1', 'j', 'd1', service: ServiceType.duct),
          _e('j2', 'j', 'd2', service: ServiceType.duct),
        ],
      ],
    );

    testWidgets('ducting keeps the room-PK input; scheduled once', (
      tester,
    ) async {
      final (ref, c) = await _harness(tester);
      c
          .read(projectControllerProvider.notifier)
          .setCalibration('s1', const ScaleCalibration(0.01));
      c.read(roomAreasProvider.notifier).set(const [room]);
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(net(ducted: false));
      final bare = c.read(nodeFedLoadsProvider)['ac']!;
      expect(bare.source, NodeLoadSource.roomPk);
      // input = Q_cool / 3.412 / COP 3 on the real (> 3 PK) room load.
      expect(
        bare.watts,
        closeTo(
          acInputPowerW(coolingBtuPerHr: room.coolingLoad(0.01)!.btuPerHr),
          1e-6,
        ),
      );
      c.read(networkControllerProvider.notifier).loadNetwork(net(ducted: true));
      // The AC now roots its own supply system (a fan duty exists) ...
      expect(c.read(supplyFanDutiesByRootProvider).containsKey('ac'), isTrue);
      // ... but its panel way stays on the compressor input.
      final fed = c.read(nodeFedLoadsProvider)['ac']!;
      expect(fed.source, NodeLoadSource.roomPk);
      expect(fed.watts, closeTo(bare.watts, 1e-9));
      final data = gatherEquipmentScheduleData(ref);
      expect(data.acUnits, hasLength(1));
      expect(data.fans, isEmpty, reason: 'no duplicate fan row for the AC');
    });
  });

  group('shared-main-second-ahu', () {
    test('a mirrored peer AHU carries the same system duty', () {
      const q = FlowRate(0.5);
      final c = _container(
        Network(
          nodes: [
            _n('ahu1', 0, 0, role: NodeRole.plant, c: NodeComponent.ahu),
            _n('ahu2', 4000, 0, role: NodeRole.plant, c: NodeComponent.ahu),
            _n('j', 2000, 0),
            _n(
              'd1',
              2000,
              -500,
              role: NodeRole.fixture,
              c: NodeComponent.supplyDiffuser,
              airflow: q,
            ),
            _n(
              'd2',
              2000,
              500,
              role: NodeRole.fixture,
              c: NodeComponent.supplyDiffuser,
              airflow: q,
            ),
          ],
          edges: [
            _e('e1', 'ahu1', 'j', service: ServiceType.duct),
            _e('e3', 'ahu2', 'j', service: ServiceType.duct),
            _e('j1', 'j', 'd1', service: ServiceType.duct),
            _e('j2', 'j', 'd2', service: ServiceType.duct),
          ],
        ),
      );
      addTearDown(c.dispose);
      final duties = c.read(supplyFanDutiesByRootProvider);
      expect(duties.keys.toSet(), {'ahu1', 'ahu2'});
      // 0.5 + 0.5 = 1.0 m³/s on each (one runs at a time, like a standby).
      expect(duties['ahu1']!.airflow.cubicMetersPerSecond, closeTo(1.0, 1e-9));
      expect(identical(duties['ahu2'], duties['ahu1']), isTrue);
      final fed = c.read(nodeFedLoadsProvider);
      expect(fed['ahu2']!.source, NodeLoadSource.solvedDuty);
      expect(fed['ahu2']!.watts, closeTo(fed['ahu1']!.watts, 1e-9));
    });
  });

  group('report-fire-gate', () {
    testWidgets('no fire edge ⇒ no fire pump / standpipe in the calc report', (
      tester,
    ) async {
      final (ref, c) = await _harness(tester);
      c
          .read(projectControllerProvider.notifier)
          .setCalibration('s1', const ScaleCalibration(0.01));
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(
            Network(
              nodes: [_n('a', 0, 0), _wc('w', 500, 0, 0)],
              edges: [_e('cw', 'a', 'w')],
            ),
          );
      final data = buildMechanicalReportData(ref);
      expect(data.firePumpRating, isNull);
      expect(data.standpipe, isNull);
      expect(data.sprinkler, isNull);
      final md = buildCalcReportMarkdown(data);
      expect(md, isNot(contains('Fire-pump rating curve')));
      expect(md, isNot(contains('Jockey pump')));
      // The schedule agrees: no FP-01.
      expect(gatherEquipmentScheduleData(ref).pumps, isEmpty);
      // With a hydrant drawn the fire design returns.
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(
            Network(
              nodes: [
                _n('a', 0, 0),
                _n(
                  'h',
                  500,
                  0,
                  role: NodeRole.fixture,
                  c: NodeComponent.hydrantBox,
                ),
              ],
              edges: [_e('fh', 'a', 'h', service: ServiceType.fireHydrant)],
            ),
          );
      final withFire = buildMechanicalReportData(ref);
      expect(withFire.firePumpRating, isNotNull);
      expect(withFire.standpipe, isNotNull);
    });
  });

  group('hw-recirc-loop-head', () {
    // Heater (plant, L0) → H0, a HW riser H0..H19 (3.5 m per storey), and 4
    // shower branches per floor (dead legs the recirc never reaches).
    Network build({bool pump = false}) => Network(
      nodes: [
        _n('HTR', 0, 0, role: NodeRole.plant),
        if (pump)
          _n('HWP', 100, 0, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 0; f < 20; f++) _n('H$f', 200, 0, floor: f),
        for (var f = 0; f < 20; f++)
          for (var i = 0; i < 4; i++)
            _n(
              'S${f}_$i',
              400,
              i * 100.0,
              floor: f,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.shower,
            ),
      ],
      edges: [
        if (pump) ...[
          _e('hp', 'HTR', 'HWP', service: ServiceType.hotWater),
          _e('ph', 'HWP', 'H0', service: ServiceType.hotWater),
        ] else
          _e('hh', 'HTR', 'H0', service: ServiceType.hotWater),
        for (var f = 1; f < 20; f++)
          _e(
            'r$f',
            'H${f - 1}',
            'H$f',
            kind: EdgeKind.riser,
            service: ServiceType.hotWater,
          ),
        for (var f = 0; f < 20; f++)
          for (var i = 0; i < 4; i++)
            _e('s${f}_$i', 'H$f', 'S${f}_$i', service: ServiceType.hotWater),
      ],
    );

    test('the head is Σ index-run losses at each bore + the DN20 return', () {
      final c = _container(build(), floors: 20);
      addTearDown(c.dispose);
      final net = c.read(sizingNetworkProvider);
      final sizing = c.read(sizingProvider);
      final project = c.read(projectControllerProvider);
      double len(NetEdge e) => edgeLength(
        e,
        net,
        calibrationBySheet: project.calibrations,
        building: project.building,
        mounting: project.mounting,
      ).meters;
      // Circulated = the heater main + the 19 riser edges (no shower branch).
      final circ = [
        for (final e in net.edges)
          if (e.id == 'hh' || e.id.startsWith('r')) e,
      ];
      final lc = circ.fold<double>(0, (a, e) => a + len(e));
      // The index run IS that whole chain; the return mirrors its length.
      final lr = lc;
      // Q = 25 W/m · (Lc + Lr) / (ρ · c · ΔT) = 25·2·Lc / (1000·4186·5).
      final q = 25 * (lc + lr) / (1000 * waterSpecificHeat * 5);
      var head = headLossHazenWilliams(
        flow: FlowRate(q),
        length: Length(lr),
        diameter: kDefaultRecircReturnDiameter,
        hazenWilliamsC: 150,
      ).meters;
      for (final e in circ) {
        head += headLossHazenWilliams(
          flow: FlowRate(q),
          length: Length(len(e)),
          diameter: sizing[e.id]!.diameter,
          hazenWilliamsC: 150,
        ).meters;
      }
      final r = c.read(hotWaterRecircProvider)!;
      expect(r.recircFlow.cubicMetersPerSecond, closeTo(q, 1e-12));
      expect(r.loopHead.meters, closeTo(head, 1e-9));
      expect(r.loopLength.meters, closeTo(lr, 1e-9));
      // A fractional-kW circulator on a few metres — never 1711 m / 30 kW.
      expect(r.loopHead.meters, lessThan(10));
      expect(r.pump.selectedMotor.inKiloWatts, lessThan(1.0));
    });

    testWidgets('a pump drawn on the HW loop is fed + scheduled on the duty', (
      tester,
    ) async {
      final (ref, c) = await _harness(tester);
      c.read(projectControllerProvider.notifier)
        ..setFloors([
          for (var i = 0; i < 20; i++) Floor('L$i', const Length(3.5)),
        ])
        ..setCalibration('s1', const ScaleCalibration(0.01));
      c.read(networkControllerProvider.notifier).loadNetwork(build(pump: true));
      // Let the electrical project's MEP auto-sync settle (a microtask).
      await tester.pump();
      c.read(electricalResultProvider);
      await tester.pump();
      final recirc = c.read(hotWaterRecircProvider)!;
      final duty = c.read(equipmentNodeDutiesProvider)['HWP'];
      expect(duty, isNotNull);
      expect(duty!.motor.watts, recirc.pump.selectedMotor.watts);
      expect(
        c.read(nodeFedLoadsProvider)['HWP']!.source,
        NodeLoadSource.solvedDuty,
      );
      final rows = gatherEquipmentScheduleData(ref).pumps;
      expect(rows.where((p) => identical(p.duty, recirc.pump)), hasLength(1));
    });
  });

  group('root-pump-plus-booster', () {
    // Root pump P (L0) → riser H0..H5 (6 floors); 2 WCs on L0..L4 off H_f;
    // L5's 2 WCs sit behind booster BS (H5 → BS → K).
    Network build() => Network(
      nodes: [
        _n('P', -500, 0, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 0; f < 6; f++) _n('H$f', 0, 0, floor: f),
        _n(
          'BS',
          200,
          0,
          floor: 5,
          role: NodeRole.plant,
          c: NodeComponent.boosterSet,
        ),
        _n('K', 300, 0, floor: 5),
        for (var f = 0; f < 5; f++)
          for (var i = 0; i < 2; i++) _wc('W${f}_$i', 300, i * 100.0, f),
        for (var i = 0; i < 2; i++) _wc('W5_$i', 400, i * 100.0, 5),
      ],
      edges: [
        _e('ph', 'P', 'H0'),
        for (var f = 1; f < 6; f++)
          _e('r$f', 'H${f - 1}', 'H$f', kind: EdgeKind.riser),
        for (var f = 0; f < 5; f++)
          for (var i = 0; i < 2; i++) _e('w${f}_$i', 'H$f', 'W${f}_$i'),
        _e('hb', 'H5', 'BS'),
        _e('bk', 'BS', 'K'),
        for (var i = 0; i < 2; i++) _e('w5_$i', 'K', 'W5_$i'),
      ],
    );

    test('P carries the floors it feeds; BS only its shortfall', () {
      final c = _container(build(), floors: 6);
      addTearDown(c.dispose);
      final sol = c.read(solveProvider)!;
      final target = c.read(targetResidualProvider).pascals;
      final pH = pressureFromHead(sol.requiredPumpHead).pascals;
      double r0(String id) => sol.residualPressure[id]!.pascals - pH;
      var hp = double.negativeInfinity;
      for (var f = 0; f < 5; f++) {
        for (var i = 0; i < 2; i++) {
          hp = math.max(hp, target - r0('W${f}_$i'));
        }
      }
      var hb = double.negativeInfinity;
      for (var i = 0; i < 2; i++) {
        hb = math.max(hb, target - (r0('W5_$i') + hp));
      }
      final duties = c.read(supplyMoverDutiesProvider);
      expect(duties.keys.toSet(), {'P', 'BS'});
      expect(
        duties['P']!.head.meters,
        closeTo(headFromPressure(Pressure(hp)).meters, 1e-9),
      );
      expect(
        duties['BS']!.head.meters,
        closeTo(headFromPressure(Pressure(hb)).meters, 1e-9),
      );
      // In series they deliver the system head at the critical L5 fixture.
      expect(
        duties['P']!.head.meters + duties['BS']!.head.meters,
        closeTo(sol.requiredPumpHead.meters, 1e-9),
      );
      // P moves the trunk flow, BS its own 2 WCs.
      final sizing = c.read(sizingProvider);
      expect(
        duties['P']!.flow.cubicMetersPerSecond,
        closeTo(sizing['ph']!.flow.cubicMetersPerSecond, 1e-12),
      );
      expect(
        duties['BS']!.flow.cubicMetersPerSecond,
        closeTo(sizing['hb']!.flow.cubicMetersPerSecond, 1e-12),
      );
      // The primary duty is P's; both machines are fed their own duty.
      expect(identical(c.read(pumpDutyProvider), duties['P']), isTrue);
      final fed = c.read(nodeFedLoadsProvider);
      expect(fed['P']!.source, NodeLoadSource.solvedDuty);
      expect(fed['BS']!.source, NodeLoadSource.solvedDuty);
      expect(fed['P']!.watts, duties['P']!.selectedMotor.watts);
      expect(fed['BS']!.watts, duties['BS']!.selectedMotor.watts);
    });
  });

  group('transfer-pump-duty', () {
    // GT → TP → (riser) RT (L2) → gravity riser, 2 flush-tank WCs per floor.
    Network build() => Network(
      nodes: [
        _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('TP', 100, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n(
          'RT',
          100,
          0,
          floor: 2,
          role: NodeRole.plant,
          c: NodeComponent.roofTank,
        ),
        for (var f = 0; f < 3; f++) _n('H$f', 200, 0, floor: f),
        for (var f = 0; f < 3; f++)
          for (var i = 0; i < 2; i++) _wc('W${f}_$i', 400, i * 200.0, f),
      ],
      edges: [
        _e('gt', 'GT', 'TP'),
        _e('tr', 'TP', 'RT', kind: EdgeKind.riser),
        _e('rh', 'RT', 'H2'),
        _e('r1', 'H2', 'H1', kind: EdgeKind.riser),
        _e('r0', 'H1', 'H0', kind: EdgeKind.riser),
        for (var f = 0; f < 3; f++)
          for (var i = 0; i < 2; i++) _e('w${f}_$i', 'H$f', 'W${f}_$i'),
      ],
    );

    testWidgets('the lift GT -> RT + friction at the discharge flow', (
      tester,
    ) async {
      final (ref, c) = await _harness(tester);
      c.read(projectControllerProvider.notifier)
        ..setFloors([
          for (var i = 0; i < 3; i++) Floor('L$i', const Length(3.5)),
        ])
        ..setCalibration('s1', const ScaleCalibration(0.01));
      c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
      c.read(networkControllerProvider.notifier).loadNetwork(build());
      await tester.pump();
      c.read(electricalResultProvider);
      await tester.pump();
      final net = c.read(sizingNetworkProvider);
      final sizing = c.read(sizingProvider);
      final project = c.read(projectControllerProvider);
      final q = sizing['tr']!.flow;
      // Lift: RT at the roof (3 × 3.5 = 10.5 m) − GT on the L0 surface (0).
      final lift =
          nodeElevation(
            net.nodeById('RT')!,
            project.building,
            project.mounting,
          ).meters -
          nodeElevation(
            net.nodeById('GT')!,
            project.building,
            project.mounting,
          ).meters;
      expect(lift, closeTo(10.5, 1e-9));
      final c150 = const SniProfile().hazenWilliamsC(PipeMaterial.pvc);
      var friction = 0.0;
      for (final id in ['gt', 'tr']) {
        final e = net.edgeById(id)!;
        friction += headLossHazenWilliams(
          flow: q,
          length: edgeLength(
            e,
            net,
            calibrationBySheet: project.calibrations,
            building: project.building,
            mounting: project.mounting,
          ),
          diameter: sizing[id]!.diameter,
          hazenWilliamsC: c150,
        ).meters;
      }
      final duty = c.read(supplyMoverDutiesProvider)['TP'];
      expect(duty, isNotNull);
      expect(duty!.head.meters, closeTo(lift + friction, 1e-9));
      expect(
        duty.flow.cubicMetersPerSecond,
        closeTo(q.cubicMetersPerSecond, 1e-12),
      );
      expect(c.read(transferPumpNodeIdsProvider), {'TP'});
      // Still no BOOSTER duty (Round 15 r2 kept) ...
      expect(c.read(pumpDutyProvider), isNull);
      // ... but the transfer pump is fed + scheduled on its own lift.
      expect(
        c.read(nodeFedLoadsProvider)['TP']!.source,
        NodeLoadSource.solvedDuty,
      );
      final rows = gatherEquipmentScheduleData(ref).pumps;
      expect(rows.where((p) => identical(p.duty, duty)), hasLength(1));
      expect(rows.single.service, contains('Transfer'));
    });
  });

  group('multi-booster', () {
    // Downfeed: RT (L2) → T; T → B1 → K1 → 2 WCs and T → B2 → K2 → 1 WC on
    // L2; a gravity riser T → D1 → D0 with 2 WCs per lower floor.
    Network build() => Network(
      nodes: [
        _n(
          'RT',
          0,
          0,
          floor: 2,
          role: NodeRole.plant,
          c: NodeComponent.roofTank,
        ),
        _n('T', 100, 0, floor: 2),
        _n(
          'B1',
          200,
          -100,
          floor: 2,
          role: NodeRole.plant,
          c: NodeComponent.boosterSet,
        ),
        _n(
          'B2',
          200,
          100,
          floor: 2,
          role: NodeRole.plant,
          c: NodeComponent.boosterSet,
        ),
        _n('K1', 300, -100, floor: 2),
        _n('K2', 300, 100, floor: 2),
        _wc('U0', 400, -150, 2),
        _wc('U1', 400, -50, 2),
        _wc('U2', 400, 100, 2),
        _n('D1', 100, 0, floor: 1),
        _n('D0', 100, 0),
        for (var f = 0; f < 2; f++)
          for (var i = 0; i < 2; i++) _wc('L${f}_$i', 300, i * 200.0, f),
      ],
      edges: [
        _e('rt', 'RT', 'T'),
        _e('tb1', 'T', 'B1'),
        _e('b1', 'B1', 'K1'),
        _e('u0', 'K1', 'U0'),
        _e('u1', 'K1', 'U1'),
        _e('tb2', 'T', 'B2'),
        _e('b2', 'B2', 'K2'),
        _e('u2', 'K2', 'U2'),
        _e('d1', 'T', 'D1', kind: EdgeKind.riser),
        _e('d0', 'D1', 'D0', kind: EdgeKind.riser),
        _e('l1a', 'D1', 'L1_0'),
        _e('l1b', 'D1', 'L1_1'),
        _e('l0a', 'D0', 'L0_0'),
        _e('l0b', 'D0', 'L0_1'),
      ],
    );

    test('each booster gets its OWN shortfall duty on its own flow', () {
      final c = _container(build(), feed: FeedStrategy.downfeed);
      addTearDown(c.dispose);
      final down = c.read(downfeedProvider)!;
      final target = c.read(targetResidualProvider).pascals;
      final sizing = c.read(sizingProvider);
      PumpDuty expected(List<String> served, String inEdge) {
        var worst = double.negativeInfinity;
        for (final id in served) {
          worst = math.max(worst, target - down.residualPressure[id]!.pascals);
        }
        return sizePump(
          flow: sizing[inEdge]!.flow,
          head: headFromPressure(Pressure(worst)),
        );
      }

      final duties = c.read(supplyMoverDutiesProvider);
      expect(duties.keys.toSet(), {'B1', 'B2'});
      final e1 = expected(['U0', 'U1'], 'tb1');
      final e2 = expected(['U2'], 'tb2');
      expect(duties['B1']!.head.meters, closeTo(e1.head.meters, 1e-9));
      expect(duties['B2']!.head.meters, closeTo(e2.head.meters, 1e-9));
      expect(
        duties['B2']!.flow.cubicMetersPerSecond,
        closeTo(e2.flow.cubicMetersPerSecond, 1e-12),
      );
      final fed = c.read(nodeFedLoadsProvider);
      expect(fed['B1']!.source, NodeLoadSource.solvedDuty);
      expect(fed['B2']!.source, NodeLoadSource.solvedDuty);
      expect(fed['B2']!.watts, duties['B2']!.selectedMotor.watts);
    });
  });
}
