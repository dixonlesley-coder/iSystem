// Round 49 — fire systems rated on their OWN zone, stage and class:
//   fire-convergence-zone-lift-is-whole-building
//   fire-convergence-series-booster-fire-pump-standby
//   fire-convergence-hose-reel-rated-as-class-i-standpipe
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart' show headFromPressure;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.fireSprinkler,
        EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

/// One sprinkler ZONE: tank [p]T -> pump [p]P on floor [lo], a riser
/// [p]Q[lo]..[p]Q[hi] with 6 heads per storey (3 m apart at 0.01 m/px).
(List<NetNode>, List<NetEdge>) _sprinklerZone(String p, int lo, int hi,
    {double x0 = 0}) {
  final nodes = <NetNode>[
    _n('${p}T', x0, floor: lo, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('${p}P', x0 + 50, floor: lo, role: NodeRole.plant, c: NodeComponent.pump),
  ];
  final edges = <NetEdge>[
    _e('${p}g', '${p}T', '${p}P'),
    _e('${p}p', '${p}P', '${p}Q$lo'),
  ];
  for (var f = lo; f <= hi; f++) {
    nodes.add(_n('${p}Q$f', x0 + 150, floor: f));
    if (f > lo) {
      edges.add(_e('${p}q$f', '${p}Q${f - 1}', '${p}Q$f', k: EdgeKind.riser));
    }
    for (var h = 1; h <= 6; h++) {
      nodes.add(_n('${p}H$f-$h', x0 + 150 + 300.0 * h,
          floor: f, role: NodeRole.fixture, c: NodeComponent.sprinklerHead));
      edges.add(_e('${p}b$f-$h', h == 1 ? '${p}Q$f' : '${p}H$f-${h - 1}',
          '${p}H$f-$h'));
    }
  }
  return (nodes, edges);
}

ProviderContainer _container(Network net, int floors) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([
      for (var i = 0; i < floors; i++) Floor('L$i', const Length(3)),
    ])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

void main() {
  group('fire-convergence-zone-lift-is-whole-building', () {
    test('two unconnected zones of a 20-storey tower each rate at their own '
        '10-storey head and raise no over-pressure', () {
      final lo = _sprinklerZone('L', 0, 9);
      final hi = _sprinklerZone('U', 10, 19, x0: 5000);
      final c = _container(
          Network(nodes: [...lo.$1, ...hi.$1], edges: [...lo.$2, ...hi.$2]),
          20);
      final bases = c.read(fireSystemBasesProvider);
      expect(bases, hasLength(2));
      // Each zone lifts from its pump floor to its top floor's ceiling
      // (`ceilingElevationOf`: the floor's top less the 0.3 m default
      // ceilingDrop): low 0 -> L9 ceiling = 10 x 3 - 0.3 = 29.7 m; high
      // L10 (30 m) -> L19 ceiling (59.7 m) = 29.7 m — never the whole
      // 59.7 m building.
      for (final b in bases) {
        expect(b.staticLiftM, closeTo(29.7, 1e-9));
      }
      // The reference: the low zone alone in a 10-storey building.
      final alone = _container(Network(nodes: lo.$1, edges: lo.$2), 10);
      final ref = alone.read(fireSystemBasesProvider).single;
      expect(ref.staticLiftM, closeTo(29.7, 1e-9));
      for (final b in bases) {
        expect(b.head.meters, closeTo(ref.head.meters, 1e-6));
        expect(b.duty!.selectedMotor.watts, ref.duty!.selectedMotor.watts);
      }
      // Churn 1.4 x head x 9.81 stays under the 1210 kPa (175 psi) limit, so
      // the zoning designers use to clear the warning does clear it.
      expect(c.read(fireOverPressureProvider), isEmpty);
      expect(
          c
              .read(designIssuesProvider)
              .any((i) => i.kind.startsWith('fire-system-over-pressure')),
          isFalse);
    });

    test('a single whole-height system keeps the whole-building lift', () {
      final z = _sprinklerZone('L', 0, 19);
      final c = _container(Network(nodes: z.$1, edges: z.$2), 20);
      // Floor 0 surface -> L19 ceiling = 20 x 3 - 0.3 = 59.7 m (the legacy
      // whole-building figure).
      expect(c.read(fireSystemBasesProvider).single.staticLiftM,
          closeTo(59.7, 1e-9));
    });
  });

  group('fire-convergence-series-booster-fire-pump-standby', () {
    // GT -> FP1 (L0) -> hydrant stack L0..L9 (a hose box per storey),
    // Q9 -> T10 -> FP2 (L10, in SERIES) -> stack L10..L19 (boxes).
    Network series() {
      const h = ServiceType.fireHydrant;
      return Network(nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('FP1', 50, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 0; f < 10; f++) ...[
          _n('Q$f', 150, floor: f),
          _n('HB$f', 250,
              floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        ],
        _n('T10', 150, floor: 10),
        _n('FP2', 200, floor: 10, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 10; f < 20; f++) ...[
          _n('R$f', 300, floor: f),
          _n('HB$f', 400,
              floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        ],
      ], edges: [
        _e('g', 'GT', 'FP1', s: h),
        _e('p1', 'FP1', 'Q0', s: h),
        for (var f = 0; f < 10; f++) ...[
          if (f > 0) _e('q$f', 'Q${f - 1}', 'Q$f', s: h, k: EdgeKind.riser),
          _e('hb$f', 'Q$f', 'HB$f', s: h),
        ],
        _e('qt', 'Q9', 'T10', s: h, k: EdgeKind.riser),
        _e('t2', 'T10', 'FP2', s: h),
        _e('p2', 'FP2', 'R10', s: h),
        for (var f = 10; f < 20; f++) ...[
          if (f > 10) _e('r$f', 'R${f - 1}', 'R$f', s: h, k: EdgeKind.riser),
          _e('hb$f', 'R$f', 'HB$f', s: h),
        ],
      ]);
    }

    test('the upper booster is a duty unit (never a df-0 standby)', () {
      final c = _container(series(), 20);
      final bind = c.read(mepDutyBindingProvider);
      expect(bind.firePumpNodeIds, {'FP1', 'FP2'});
      expect(bind.fireStandbyPumpNodeIds, isEmpty);
      expect(bind.fireJockeyPumpNodeIds, isEmpty);
      final fp2 = c
          .read(placedEquipmentLoadsProvider)
          .where((l) => l.id.contains('FP2'))
          .toList();
      expect(fp2, isNotEmpty);
      expect(fp2.first.demandFactor ?? 1.0, 1.0);
    });

    test('each series stage carries only its own head; the stages sum to the '
        'system head', () {
      final c = _container(series(), 20);
      final b = c.read(fireSystemBasesProvider).single;
      final h1 = b.stageHeads['FP1']!.meters;
      final h2 = b.stageHeads['FP2']!.meters;
      expect(h1 + h2, closeTo(b.head.meters, 1e-6));
      // Stage 1 serves its own zone to the L9 outlet: lift 9 x 3 + 1.2 =
      // 28.2 m + friction F + the Class I 690 kPa residual; the system needs
      // the L19 outlet: 19 x 3 + 1.2 = 58.2 m + F + residual. So the upper
      // stage adds exactly the 30 m of storeys between the two zone tops.
      final residual =
          headFromPressure(Pressure.kiloPascals(kResidualPressureClassIKpa))
              .meters;
      expect(h2, closeTo(30.0, 1e-6));
      expect(h1, closeTo(b.head.meters - 30.0, 1e-6));
      expect(b.head.meters - 58.2 - residual, greaterThanOrEqualTo(15 - 1e-9));
      expect(b.dutyFor('FP2')!.head.meters, closeTo(30.0, 1e-6));
      expect(b.dutyFor('FP1')!.head.meters, closeTo(h1, 1e-6));
    });

    test('a duty + standby set drawn between one tank and one header stays '
        'duty / standby', () {
      const h = ServiceType.fireHydrant;
      final net = Network(nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('FPa', 50, role: NodeRole.plant, c: NodeComponent.pump),
        _n('FPb', 60, role: NodeRole.plant, c: NodeComponent.pump),
        _n('HD', 100),
        for (var f = 0; f < 3; f++) ...[
          _n('Q$f', 150, floor: f),
          _n('HB$f', 250,
              floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        ],
      ], edges: [
        _e('ga', 'GT', 'FPa', s: h),
        _e('gb', 'GT', 'FPb', s: h),
        _e('pa', 'FPa', 'HD', s: h),
        _e('pb', 'FPb', 'HD', s: h),
        _e('hq', 'HD', 'Q0', s: h),
        for (var f = 0; f < 3; f++) ...[
          if (f > 0) _e('q$f', 'Q${f - 1}', 'Q$f', s: h, k: EdgeKind.riser),
          _e('hb$f', 'Q$f', 'HB$f', s: h),
        ],
      ]);
      final c = _container(net, 3);
      final bind = c.read(mepDutyBindingProvider);
      expect(bind.fireStandbyPumpNodeIds.length, 1);
      expect(c.read(fireSystemBasesProvider).single.stageHeads, isEmpty);
    });
  });

  group('fire-convergence-hose-reel-rated-as-class-i-standpipe', () {
    Network shophouse(NodeComponent outlet) {
      const h = ServiceType.fireHydrant;
      return Network(nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('FP', 50, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 0; f < 3; f++) ...[
          _n('Q$f', 150, floor: f),
          _n('HR$f', 250, floor: f, role: NodeRole.fixture, c: outlet),
        ],
      ], edges: [
        _e('g', 'GT', 'FP', s: h),
        _e('p', 'FP', 'Q0', s: h),
        for (var f = 0; f < 3; f++) ...[
          if (f > 0) _e('q$f', 'Q${f - 1}', 'Q$f', s: h, k: EdgeKind.riser),
          _e('hr$f', 'Q$f', 'HR$f', s: h),
        ],
      ]);
    }

    test('a hose-reel-only shophouse is a Class II system: 100 gpm, 450 kPa, '
        'a 7.5 kW motor and no DN100 trunk', () {
      final c = _container(shophouse(NodeComponent.hoseReel), 3);
      final b = c.read(fireSystemBasesProvider).single;
      expect(b.standpipeClass, StandpipeClass.classII);
      // NFPA 14 Class II: 100 gpm = 100 x 3.785411784 / 60 = 6.309 L/s.
      expect(b.flow.inLitersPerSecond, closeTo(6.309, 1e-3));
      // Head = lift (2 x 3 + 1.2 = 7.2 m) + F (the 15 m allowance floor) +
      // 450 kPa / (1000 x 9.81) = 45.87 m ⇒ >= 68.07 m.
      final residual = 450000 / (1000 * 9.81);
      expect(b.head.meters, greaterThanOrEqualTo(7.2 + 15 + residual - 1e-6));
      expect(b.head.meters, lessThan(80));
      // NFPA 20 overload: 150 % flow (9.46 L/s) at 65 % head (44.2 m) =
      // 9810 x 0.009464 x 44.25 / (0.70 x 0.85) = 6.9 kW ⇒ the 7.5 kW frame
      // (Class I rated it at 31.5 L/s, 55 kW).
      expect(b.duty!.selectedMotor.inKiloWatts, 7.5);
      final sz = c.read(sizingProvider);
      for (final e in c.read(networkControllerProvider).network.edges) {
        final d = sz[e.id]?.diameter.inMillimeters;
        if (d == null) continue;
        expect(d, lessThan(100), reason: 'edge ${e.id} sized DN$d');
        expect(sz[e.id]!.flow.inLitersPerSecond, lessThanOrEqualTo(6.31));
      }
    });

    test('any hydrant box keeps the Class I basis (byte-identical)', () {
      final c = _container(shophouse(NodeComponent.hydrantBox), 3);
      final b = c.read(fireSystemBasesProvider).single;
      expect(b.standpipeClass, StandpipeClass.classI);
      expect(b.flow.inLitersPerSecond,
          closeTo(standpipeFlow(1).inLitersPerSecond, 1e-9));
      final sz = c.read(sizingProvider);
      expect(sz['q1']!.diameter.inMillimeters, greaterThanOrEqualTo(100));
    });
  });
}
