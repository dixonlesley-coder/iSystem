// Round 62 (2026-10-18) — app-side fixes.
//
//   fire-convergence-14-sprinkler-plus-yard-rated-as-phantom-class-i-
//   standpipe — sprinklers + yard (pillar) hydrants with NO hose outlet are
//     rated on max(sprinkler point, yard point); no phantom Class I standpipe
//     lifted to the building top (and so no false churn over-pressure).
//   regression-duty-pick-sizer-vs-basis-disagree — the fire basis duty pump
//     IS the panel feed's duty pump (one rule: bore, off the mirrored leg,
//     draw order), on any node / edge order (seeded).
//   regression-i0-fallback-consumes-peer-return — a return-less root AHU on
//     a shared supply never adopts a peer unit's return.
//   plumbing-hvac-convergence-12-inline-return-fan-gets-no-duty — an inline
//     return fan in an AHU-rooted return carries its own solved duty; the
//     AHU's inlet term is then its intake alone.
//   plumbing-hvac-convergence-12-per-riser-hw-circulators-classed-standby —
//     one circulator per return riser: three running duty machines, each at
//     its riser's share, none '(standby)'.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fan.dart' show sizeFan;
import 'package:mechx_engine/sizing/room_air.dart'
    show AirEquipmentKind, defaultInternalStatic;
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';

void _seed(ProviderContainer c, {int floors = 1, double h = 3.5}) {
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < floors; i++) Floor('L$i', Length(h))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
}

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c,
        FlowRate? airflow,
        PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c,
        airflow: airflow,
        fixture: fixture);

NetEdge _e(String id, String a, String b,
        {EdgeKind k = EdgeKind.run, ServiceType s = ServiceType.fireHydrant}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

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

/// A 6-storey car park: GT -> P -> J; a sprinkler riser off J with four
/// heads per floor; a 4-pillar yard main off J; [hoseBoxes] adds a hydrant
/// riser with a box on every floor.
Network _carPark({bool hoseBoxes = false}) {
  const sp = ServiceType.fireSprinkler;
  final nodes = <NetNode>[
    _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('P', 100, 0, role: NodeRole.plant, c: NodeComponent.pump),
    _n('J', 200, 0),
    for (var f = 0; f < 6; f++) ...[
      _n('S$f', 300, 0, floor: f),
      for (var k = 0; k < 4; k++)
        _n('H$f$k', 400.0 + 300 * k, 0,
            floor: f, role: NodeRole.fixture, c: NodeComponent.sprinklerHead),
    ],
    for (var k = 0; k < 4; k++) ...[
      _n('Y$k', 200.0 + 3000 * k, 2000),
      _n('PH$k', 200.0 + 3000 * k, 2100,
          role: NodeRole.fixture, c: NodeComponent.pillarHydrant),
    ],
    if (hoseBoxes)
      for (var f = 0; f < 6; f++) ...[
        _n('X$f', 200, 600, floor: f),
        _n('B$f', 300, 600,
            floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ],
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'P'),
    _e('d', 'P', 'J'),
    _e('js', 'J', 'S0', s: sp),
    for (var f = 1; f < 6; f++)
      _e('sr$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser, s: sp),
    for (var f = 0; f < 6; f++) ...[
      _e('b${f}0', 'S$f', 'H${f}0', s: sp),
      for (var k = 1; k < 4; k++)
        _e('b$f$k', 'H$f${k - 1}', 'H$f$k', s: sp),
    ],
    _e('y0', 'J', 'Y0'),
    for (var k = 1; k < 4; k++) _e('y$k', 'Y${k - 1}', 'Y$k'),
    for (var k = 0; k < 4; k++) _e('l$k', 'Y$k', 'PH$k'),
    if (hoseBoxes) ...[
      _e('jx', 'J', 'X0'),
      for (var f = 1; f < 6; f++)
        _e('xr$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser),
      for (var f = 0; f < 6; f++) _e('xb$f', 'X$f', 'B$f'),
    ],
  ];
  return Network(nodes: nodes, edges: edges);
}

void main() {
  group('sprinklers + yard pillars: no phantom Class I standpipe', () {
    test('rated on the yard / sprinkler points, no over-pressure', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seed(c, floors: 6, h: 3.0);
      c.read(networkControllerProvider.notifier).loadNetwork(_carPark());
      final b = c.read(fireSystemBasesProvider).single;
      // The yard flow (38 L/s, SNI 03-1735) governs the flow.
      expect(b.flow.inLitersPerSecond, closeTo(38.0, 1e-9));
      expect(b.standpipe, isNull);
      expect(c.read(reportStandpipeDesignProvider), isNull);
      // Never the Class I head: lift to the top + 690 kPa (70.34 m) + 15 m
      // (16.2 + 70.34 + 15 = 101.5 m at the least).
      const classI = 5 * 3.0 + 1.2 + 690000 / 9810 + 15;
      expect(b.head.meters, lessThan(classI - 10));
      // The yard point: the 350 kPa outlet residual + >= 15 m friction.
      expect(b.head.meters, greaterThanOrEqualTo(350000 / 9810 + 15 - 1e-6));
      // 1.4 x head (churn) stays under 1210 kPa (123.3 m): no false warning.
      expect(
          c.read(designIssuesProvider).where(
              (i) => i.kind.startsWith('fire-system-over-pressure')),
          isEmpty);
    });

    test('add hose boxes: the Class I standpipe returns', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seed(c, floors: 6, h: 3.0);
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(_carPark(hoseBoxes: true));
      final b = c.read(fireSystemBasesProvider).single;
      expect(b.standpipe, isNotNull);
      expect(b.head.meters,
          greaterThanOrEqualTo(5 * 3.0 + 1.2 + 690000 / 9810 + 15 - 1e-6));
    });
  });

  // Seeded property: identical mirrored fire-pump legs (n9 / n10, valves
  // n20 / n100 whose String order disagrees with the pumps'), every node /
  // edge order: the basis duty pump IS the feed's duty pump (the one the
  // MDP / schedule do not call '(standby)').
  test('property: basis duty pump == feed duty pump (seeded)', () {
    final rnd = math.Random(62);
    for (var t = 0; t < 12; t++) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seed(c, floors: 2);
      final nodes = <NetNode>[
        _n('n1', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('n2', 100, 0),
        _n('n9', 200, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n('n10', 200, 100, role: NodeRole.plant, c: NodeComponent.pump),
        _n('n20', 300, 0, c: NodeComponent.checkValve),
        _n('n100', 300, 100, c: NodeComponent.checkValve),
        _n('n3', 400, 0),
        _n('n4', 400, 0, floor: 1),
        _n('n5', 500, 0,
            floor: 1, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
      ]..shuffle(rnd);
      final edges = <NetEdge>[
        _e('e1', 'n1', 'n2'),
        _e('e2', 'n2', 'n9'),
        _e('e3', 'n9', 'n20'),
        _e('e4', 'n20', 'n3'),
        _e('e5', 'n2', 'n10'),
        _e('e6', 'n10', 'n100'),
        _e('e7', 'n100', 'n3'),
        _e('e8', 'n3', 'n4', k: EdgeKind.riser),
        _e('e9', 'n4', 'n5'),
      ]..shuffle(rnd);
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(Network(nodes: nodes, edges: edges));
      final bind = c.read(mepDutyBindingProvider);
      final bases = c.read(fireSystemBasesProvider);
      expect(bases, hasLength(1), reason: 'trial $t');
      final duty = bases.single.dutyPumpId;
      expect(bind.fireStandbyPumpNodeIds, isNot(contains(duty)),
          reason: 'trial $t: the basis names the feed standby $duty');
      // The first-drawn pump is the duty everywhere.
      expect(duty, 'n9', reason: 'trial $t');
      expect(bind.fireStandbyPumpNodeIds, {'n10'}, reason: 'trial $t');
    }
  });

  group('air units', () {
    NetEdge air(String id, String a, String b, ServiceType s) =>
        NetEdge(id: id, fromId: a, toId: b, service: s, kind: EdgeKind.run);
    NetNode term(String id, double x, double y, NodeComponent c, double q) =>
        _n(id, x, y, role: NodeRole.fixture, c: c, airflow: FlowRate(q));
    final internal = defaultInternalStatic(AirEquipmentKind.ahu).pascals;

    test('a return-less root AHU never adopts a peer unit\'s return', () {
      // ahuA and ahuB both feed the shared supply main J; only ahuB has a
      // return (two grilles).
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seed(c);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
        _n('ahuA', 0, 0, role: NodeRole.plant, c: NodeComponent.ahu),
        _n('ahuB', 0, 1000, role: NodeRole.plant, c: NodeComponent.ahu),
        _n('J', 400, 500),
        term('sa1', 1200, 300, NodeComponent.supplyDiffuser, 1.0),
        term('sa2', 1200, 700, NodeComponent.supplyDiffuser, 1.0),
        _n('rj', 600, 1500),
        term('rg1', 1500, 1400, NodeComponent.returnGrille, 0.9),
        term('rg2', 1500, 1600, NodeComponent.returnGrille, 0.9),
      ], edges: [
        air('a', 'ahuA', 'J', ServiceType.duct),
        air('b', 'ahuB', 'J', ServiceType.duct),
        air('j1', 'J', 'sa1', ServiceType.duct),
        air('j2', 'J', 'sa2', ServiceType.duct),
        air('g1', 'rg1', 'rj', ServiceType.returnAir),
        air('g2', 'rg2', 'rj', ServiceType.returnAir),
        air('rb', 'rj', 'ahuB', ServiceType.returnAir),
      ]));
      final supplies = c.read(airSystemsProvider(ServiceType.duct));
      final rets = c.read(airSystemsProvider(ServiceType.returnAir));
      expect(supplies, hasLength(1));
      expect(rets.single.fanNodeId, 'ahuB');
      final s = supplies.single;
      final root = s.fanNodeId;
      final peer = root == 'ahuA' ? 'ahuB' : 'ahuA';
      final duties = c.read(supplyFanDutiesByRootProvider);
      final rb = rets.single.stat.pascals;
      final supplyIndex = s.stat.pascals - s.intake.pascals;
      double withReturn() =>
          supplyIndex + math.max(s.intake.pascals, rb) + internal;
      double without() => supplyIndex + s.intake.pascals + internal;
      expect(duties['ahuA']!.totalStaticPressure.pascals,
          closeTo(root == 'ahuA' ? without() : withReturn(), 1e-6),
          reason: 'root $root');
      expect(duties['ahuB']!.totalStaticPressure.pascals,
          closeTo(withReturn(), 1e-6));
      expect(rb, greaterThan(s.intake.pascals));
      expect(peer, isNotEmpty);
    });

    test('an inline return fan carries its own solved duty', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      _seed(c);
      c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
        _n('ahu', 0, 0, role: NodeRole.plant, c: NodeComponent.ahu),
        _n('sj', 500, 0),
        term('sd1', 1500, -300, NodeComponent.supplyDiffuser, 5.0),
        term('sd2', 1500, 300, NodeComponent.supplyDiffuser, 5.0),
        _n('rf', 0, 1000, role: NodeRole.plant, c: NodeComponent.exhaustFan),
        _n('rj', 800, 1000),
        term('rg1', 1600, 800, NodeComponent.returnGrille, 4.5),
        term('rg2', 1600, 1200, NodeComponent.returnGrille, 4.5),
      ], edges: [
        air('s0', 'ahu', 'sj', ServiceType.duct),
        air('s1', 'sj', 'sd1', ServiceType.duct),
        air('s2', 'sj', 'sd2', ServiceType.duct),
        air('g1', 'rg1', 'rj', ServiceType.returnAir),
        air('g2', 'rg2', 'rj', ServiceType.returnAir),
        air('rr', 'rj', 'rf', ServiceType.returnAir),
        air('ra', 'rf', 'ahu', ServiceType.returnAir),
      ]));
      final ret = c.read(airSystemsProvider(ServiceType.returnAir)).single;
      expect(ret.fanNodeId, 'ahu');
      expect(ret.inlineFanIds, ['rf']);
      expect(ret.trunk.cubicMetersPerSecond, closeTo(9.0, 1e-9));
      final duties = c.read(supplyFanDutiesByRootProvider);
      final expected = sizeFan(airflow: ret.trunk, totalStaticPressure: ret.stat);
      expect(duties['rf']!.totalStaticPressure.pascals,
          closeTo(expected.totalStaticPressure.pascals, 1e-9));
      expect(duties['rf']!.selectedMotor.watts,
          expected.selectedMotor.watts);
      // The AHU no longer carries the return static (the return fan does).
      final s = c.read(airSystemsProvider(ServiceType.duct)).single;
      expect(duties['ahu']!.totalStaticPressure.pascals,
          closeTo(s.stat.pascals + internal, 1e-6));
      // The panel way is fed on the solved duty, never the component default.
      final fed = c.read(nodeFedLoadsProvider)['rf'];
      expect(fed, isNotNull);
      expect(fed!.source, NodeLoadSource.solvedDuty);
    });
  });

  // A heater H feeding three supply risers (showers on L1..L3); each riser
  // top returns down its OWN return riser through its own circulator Pk and
  // check valve CVk into the common header RJ -> H.
  testWidgets('one circulator per return riser: three running duties',
      (tester) async {
    final (ref, c) = await _harness(tester);
    _seed(c, floors: 4, h: 3.2);
    const hw = ServiceType.hotWater;
    final nodes = <NetNode>[
      _n('H', 0, 0, role: NodeRole.plant),
      _n('M', 100, 0),
      _n('RJ', 100, 400),
      for (var k = 0; k < 3; k++) ...[
        _n('S${k}0', 300.0 + 400 * k, 0),
        _n('R${k}0', 300.0 + 400 * k, 300),
        _n('P$k', 200.0 + 400 * k, 350,
            role: NodeRole.plant, c: NodeComponent.pump),
        _n('CV$k', 150.0 + 400 * k, 380, c: NodeComponent.checkValve),
        for (var f = 1; f < 4; f++) ...[
          _n('S$k$f', 300.0 + 400 * k, 0, floor: f),
          _n('R$k$f', 300.0 + 400 * k, 300, floor: f),
          _n('W$k$f', 350.0 + 400 * k, 100,
              floor: f,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.shower),
        ],
      ],
    ];
    final edges = <NetEdge>[
      _e('hm', 'H', 'M', s: hw),
      for (var k = 0; k < 3; k++) ...[
        _e('m$k', k == 0 ? 'M' : 'S${k - 1}0', 'S${k}0', s: hw),
        for (var f = 1; f < 4; f++) ...[
          _e('s$k$f', 'S$k${f - 1}', 'S$k$f', s: hw, k: EdgeKind.riser),
          _e('w$k$f', 'S$k$f', 'W$k$f', s: hw),
          _e('r$k$f', 'R$k$f', 'R$k${f - 1}', s: hw, k: EdgeKind.riser),
        ],
        _e('t$k', 'S${k}3', 'R${k}3', s: hw),
        _e('p$k', 'R${k}0', 'P$k', s: hw),
        _e('v$k', 'P$k', 'CV$k', s: hw),
        _e('j$k', 'CV$k', 'RJ', s: hw),
      ],
      _e('rh', 'RJ', 'H', s: hw),
    ];
    c
        .read(networkControllerProvider.notifier)
        .loadNetwork(Network(nodes: nodes, edges: edges));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    final bind = c.read(mepDutyBindingProvider);
    expect(bind.hwRecircPumpNodeIds, {'P0', 'P1', 'P2'});
    expect(bind.hwStandbyPumpNodeIds, isEmpty);
    final sys = c.read(hotWaterRecircSystemsProvider).single;
    final duties = c.read(hwCirculatorDutiesProvider);
    var sum = 0.0;
    for (final id in ['P0', 'P1', 'P2']) {
      final q = duties[id]!.flow.cubicMetersPerSecond;
      expect(q, lessThan(sys.design.recircFlow.cubicMetersPerSecond),
          reason: id);
      expect(q, greaterThan(0), reason: id);
      expect(duties[id]!.head.meters,
          closeTo(sys.design.loopHead.meters, 1e-9));
      sum += q;
    }
    // The three loops' shares add up to the system recirculation flow.
    expect(sum, closeTo(sys.design.recircFlow.cubicMetersPerSecond, 1e-9));
    final rows = gatherEquipmentScheduleData(ref)
        .pumps
        .where((p) => p.service.startsWith('Hot-water recirculation'))
        .toList();
    expect(rows, hasLength(3));
    expect(rows.where((r) => r.service.contains('standby')), isEmpty);
    for (final r in rows) {
      expect(r.duty.flow.cubicMetersPerSecond,
          lessThan(sys.design.recircFlow.cubicMetersPerSecond));
    }
    await tester.pump(const Duration(seconds: 10));
  });
}
