// Round 52 (2026-10-18) — fire systems rated on what is actually drawn:
//
//   regression-transfer-pump-into-tank-rated-whole-building-standpipe
//   regression-pumpless-tank-fragment-becomes-governing-phantom-pump
//   regression-shared-suction-header-pump-rooms-still-combined-duty
//   regression-same-room-series-first-stage-rated-zero-head
//   regression-hydrant-ring-floored-at-other-systems-sprinkler-demand-
//     through-tank
//   fire-convergence-4-report-prints-phantom-class-i-pump-for-gravity-system
//   fire-convergence-4-series-stage-report-line-prints-system-pump-under-
//     booster-tag
//   fire-convergence-4-staged-sprinkler-system-false-over-pressure
import 'package:flutter/widgets.dart' hide Velocity;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/plan_symbols.dart' show equipmentNodeTags;
import 'package:mechx_engine/sizing/fire_index_friction.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart' show FireHazardClass;
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(
  String id,
  double x, {
  int floor = 0,
  double y = 0,
  NodeRole role = NodeRole.main,
  NodeComponent? c,
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: y,
  floorIndex: floor,
  role: role,
  component: c,
);

NetEdge _e(
  String id,
  String a,
  String b, {
  ServiceType s = ServiceType.fireHydrant,
  EdgeKind k = EdgeKind.run,
}) => NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

const _sp = ServiceType.fireSprinkler;

void _seed(
  ProviderContainer c,
  Network net,
  int floors, {
  double h = 3.5,
  bool calibrated = true,
}) {
  final p = c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < floors; i++) Floor('L$i', Length(h))]);
  if (calibrated) p.setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
}

ProviderContainer _container(
  Network net,
  int floors, {
  double h = 3.5,
  bool calibrated = true,
}) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  _seed(c, net, floors, h: h, calibrated: calibrated);
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

/// The r51 shared-tank fixture: GT -> FPH -> DH -> hydrant stack (a box per
/// floor) and GT -> FPS -> DS -> sprinkler riser ([heads] per floor).
Network _sharedTank({required int floors, int heads = 1}) => Network(
  nodes: [
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FPH', 100, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DH', 200),
    _n('FPS', 100, y: 300, role: NodeRole.plant, c: NodeComponent.pump),
    _n('DS', 200, y: 300),
    for (var f = 0; f < floors; f++) ...[
      _n('Q$f', 900, floor: f),
      _n(
        'HB$f',
        1000,
        floor: f,
        role: NodeRole.fixture,
        c: NodeComponent.hydrantBox,
      ),
      _n('R$f', 1500, y: 300, floor: f),
      for (var k = 1; k <= heads; k++)
        _n(
          'SH$f-$k',
          1500 + 300.0 * k,
          y: 300,
          floor: f,
          role: NodeRole.fixture,
          c: NodeComponent.sprinklerHead,
        ),
    ],
  ],
  edges: [
    _e('gh', 'GT', 'FPH'),
    _e('ph', 'FPH', 'DH'),
    _e('dq', 'DH', 'Q0'),
    _e('gs', 'GT', 'FPS', s: _sp),
    _e('ps', 'FPS', 'DS', s: _sp),
    _e('dr', 'DS', 'R0', s: _sp),
    for (var f = 0; f < floors; f++) ...[
      if (f > 0) _e('q$f', 'Q${f - 1}', 'Q$f', k: EdgeKind.riser),
      _e('hb$f', 'Q$f', 'HB$f'),
      if (f > 0) _e('r$f', 'R${f - 1}', 'R$f', s: _sp, k: EdgeKind.riser),
      for (var k = 1; k <= heads; k++)
        _e('sh$f-$k', k == 1 ? 'R$f' : 'SH$f-${k - 1}', 'SH$f-$k', s: _sp),
    ],
  ],
);

Network _plus(Network a, {List<NetNode> nodes = const [], List<NetEdge> edges = const []}) =>
    Network(nodes: [...a.nodes, ...nodes], edges: [...a.edges, ...edges]);

void main() {
  // ── regression-transfer-pump-into-tank ──────────────────────────────────
  group('a fire transfer pump filling a break tank', () {
    // 20 x 3 m: GT -> TP (L0) -> riser -> TT (break tank, L10); FP2 on L10
    // serves a hydrant stack L10-L19.
    Network tower() => Network(
      nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('TP', 100, role: NodeRole.plant, c: NodeComponent.pump),
        _n('A0', 200),
        _n('A10', 200, floor: 10),
        _n('TT', 300, floor: 10, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('FP2', 400, floor: 10, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 10; f < 20; f++) ...[
          _n('B$f', 500, floor: f),
          _n(
            'HB$f',
            600,
            floor: f,
            role: NodeRole.fixture,
            c: NodeComponent.hydrantBox,
          ),
        ],
      ],
      edges: [
        _e('g', 'GT', 'TP'),
        _e('t', 'TP', 'A0'),
        _e('r', 'A0', 'A10', k: EdgeKind.riser),
        _e('a', 'A10', 'TT'),
        _e('s2', 'TT', 'FP2'),
        _e('d2', 'FP2', 'B10'),
        for (var f = 10; f < 20; f++) ...[
          if (f > 10) _e('q$f', 'B${f - 1}', 'B$f', k: EdgeKind.riser),
          _e('hb$f', 'B$f', 'HB$f'),
        ],
      ],
    );

    for (final calibrated in [false, true]) {
      test('rated on the lift to the tank + friction, no residual; FP2 '
          'governs (calibrated: $calibrated)', () {
        final c = _container(tower(), 20, h: 3, calibrated: calibrated);
        final bases = c.read(fireSystemBasesProvider);
        final tp = bases.singleWhere((b) => b.pumpIds.contains('TP'));
        final fp2 = bases.singleWhere((b) => b.pumpIds.contains('FP2'));
        expect(tp.transfer, isTrue);
        expect(tp.transferTankId, 'TT');
        expect(tp.standpipe, isNull);
        expect(tp.jockey, isNull);
        // Lift: TT on the L10 floor surface (10 x 3 = 30 m) above TP (0 m).
        expect(tp.staticLiftM, closeTo(30.0, 1e-9));
        final f = tp.indexFrictionM;
        if (calibrated) {
          expect(f, isNotNull);
        } else {
          expect(f, isNull);
        }
        expect(tp.head.meters, closeTo(30.0 + (f ?? 0.0), 1e-9));
        // Never the whole-building Class I head (143.5 m / 75 kW).
        expect(tp.head.meters, lessThan(40));
        final duties = c.read(equipmentNodeDutiesProvider);
        // The NFPA 20 frame of exactly that point (uncalibrated 30 m ⇒
        // 18.5 kW, the pre-r51 duty; calibrated the sized riser adds its own
        // ~6.9 m friction ⇒ the next frame) — never the 75 kW standpipe one.
        final expectDuty = firePumpDuty(
          ratedFlow: tp.flow,
          ratedHead: tp.head,
          rating: checkFirePumpRating(ratedFlow: tp.flow, ratedHead: tp.head),
        );
        expect(duties['TP']!.motor.watts, expectDuty.selectedMotor.watts);
        expect(duties['TP']!.motor.watts, tp.duty!.selectedMotor.watts);
        expect(duties['TP']!.motor.watts,
            lessThanOrEqualTo(calibrated ? 22000 : 18500));
        // FP2 is the fire pump the project is rated on.
        final gov = c.read(governingFireBasisProvider)!;
        expect(gov.pumpIds, ['FP2']);
        expect(identical(gov, fp2), isTrue);
        expect(c.read(fireRatedPointProvider).head.meters,
            closeTo(fp2.head.meters, 1e-9));
        // FP2: its own zone — lift L10 -> the L19 outlet = 9 x 3 + 1.2 m.
        expect(fp2.staticLiftM, closeTo(9 * 3 + kHoseOutletHeightM, 1e-9));
        expect(c.read(fireOverPressureProvider)
            .where((o) => o.basis.transfer), isEmpty);
      });
    }

    testWidgets('the schedule labels it a fire tank transfer pump',
        (tester) async {
      final (ref, c) = await _harness(tester);
      _seed(c, tower(), 20, h: 3);
      await tester.pump();
      final data = gatherEquipmentScheduleData(ref);
      final tags = equipmentNodeTags(c.read(networkControllerProvider).network);
      final tp = data.pumps.singleWhere((p) => p.tag == tags['TP']);
      expect(tp.service, 'Fire tank transfer pump');
      final basis = c.read(firePumpBasisByNodeProvider)['TP']!;
      expect(tp.duty.selectedMotor.watts, basis.duty!.selectedMotor.watts);
      expect(tp.duty.head.meters, lessThan(40));
    });
  });

  // ── regression-pumpless-tank-fragment ───────────────────────────────────
  group('a pump-less, terminal-less fragment behind a tank', () {
    test('FDC -> GT: exactly two bases, FPH governs', () {
      final net = _plus(
        _sharedTank(floors: 6),
        nodes: [
          _n('FDC', -100,
              role: NodeRole.fixture, c: NodeComponent.fireDeptConnection),
        ],
        edges: [_e('fdc', 'FDC', 'GT')],
      );
      final c = _container(net, 8, h: 4);
      final bases = c.read(fireSystemBasesProvider);
      expect(bases, hasLength(2));
      expect(bases.every((b) => b.pumpIds.isNotEmpty), isTrue);
      expect(c.read(governingFireBasisProvider)!.pumpIds, ['FPH']);
      final fph = bases.singleWhere((b) => b.pumpIds.contains('FPH'));
      expect(c.read(firePumpDutyProvider)!.selectedMotor.watts,
          fph.duty!.selectedMotor.watts);
    });

    test('GT2 - GT sprinkler equalising pipe: no phantom basis', () {
      final net = _plus(
        _sharedTank(floors: 6, heads: 4),
        nodes: [
          _n('GT2', -100, role: NodeRole.plant, c: NodeComponent.groundTank),
        ],
        edges: [_e('eq', 'GT2', 'GT', s: _sp)],
      );
      final c = _container(net, 6, h: 4);
      c.read(fireHazardProvider.notifier).set(FireHazardClass.ordinaryHazard2);
      final bases = c.read(fireSystemBasesProvider);
      expect(bases, hasLength(2));
      expect(bases.any((b) => b.pumpIds.isEmpty), isFalse);
    });
  });

  // ── regression-shared-suction-header ────────────────────────────────────
  test('GT -> SH header -> FPH (hydrant) + FPS (sprinkler): each pump room '
      'on its own point, no false over-pressure', () {
    final net = Network(
      nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('SH', 50),
        _n('FPH', 100, role: NodeRole.plant, c: NodeComponent.pump),
        _n('DH', 200),
        _n('FPS', 100, y: 300, role: NodeRole.plant, c: NodeComponent.pump),
        _n('DS', 200, y: 300),
        for (var f = 0; f < 6; f++) ...[
          _n('Q$f', 900, floor: f),
          _n('HB$f', 1000,
              floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
          _n('R$f', 1500, y: 300, floor: f),
          for (var k = 1; k <= 4; k++)
            _n('SH$f-$k', 1500 + 300.0 * k,
                y: 300,
                floor: f,
                role: NodeRole.fixture,
                c: NodeComponent.sprinklerHead),
        ],
      ],
      edges: [
        _e('gs', 'GT', 'SH'),
        _e('sh', 'SH', 'FPH'),
        _e('ss', 'SH', 'FPS'),
        _e('ph', 'FPH', 'DH'),
        _e('dq', 'DH', 'Q0'),
        _e('ps', 'FPS', 'DS', s: _sp),
        _e('dr', 'DS', 'R0', s: _sp),
        for (var f = 0; f < 6; f++) ...[
          if (f > 0) _e('q$f', 'Q${f - 1}', 'Q$f', k: EdgeKind.riser),
          _e('hb$f', 'Q$f', 'HB$f'),
          if (f > 0) _e('r$f', 'R${f - 1}', 'R$f', s: _sp, k: EdgeKind.riser),
          for (var k = 1; k <= 4; k++)
            _e('sh$f-$k', k == 1 ? 'R$f' : 'SH$f-${k - 1}', 'SH$f-$k', s: _sp),
        ],
      ],
    );
    final c = _container(net, 6, h: 4);
    c.read(fireHazardProvider.notifier).set(FireHazardClass.ordinaryHazard2);
    final bases = c.read(fireSystemBasesProvider);
    expect(bases, hasLength(2));
    final hyd = bases.singleWhere((b) => b.pumpIds.contains('FPH'));
    final spr = bases.singleWhere((b) => b.pumpIds.contains('FPS'));
    expect(hyd.pumpIds, ['FPH']);
    expect(spr.pumpIds, ['FPS']);
    expect(spr.sprinklerOnly, isTrue);
    expect(hyd.stageHeads, isEmpty);
    expect(spr.stageHeads, isEmpty);
    final remote = c.read(sprinklerRemoteAreaProvider);
    expect(spr.flow.inLitersPerSecond,
        closeTo(remote.remoteAreaDemand.inLitersPerSecond, 1e-9));
    expect(hyd.flow.inLitersPerSecond,
        closeTo(standpipeFlow(1).inLitersPerSecond, 1e-9));
    final duties = c.read(equipmentNodeDutiesProvider);
    // The sprinkler pump on ITS OWN remote-area point (≈ 12 L/s), never the
    // 55 kW / 31.5 L/s standpipe frame.
    expect(duties['FPS']!.motor.watts, spr.duty!.selectedMotor.watts);
    expect(duties['FPS']!.motor.watts, lessThan(15000));
    expect(duties['FPH']!.motor.watts, hyd.duty!.selectedMotor.watts);
    expect(c.read(fireOverPressureProvider), isEmpty);
  });

  // ── regression-same-room-series-first-stage-rated-zero-head ─────────────
  test('two series pumps in one room, a drain tee between: the system head '
      'is split, never a 0 m stage', () {
    final net = Network(
      nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('P1', 100, role: NodeRole.plant, c: NodeComponent.pump),
        _n('M', 200),
        _n('TL', 200, y: 100),
        _n('P2', 300, role: NodeRole.plant, c: NodeComponent.pump),
        _n('D', 400),
        for (var f = 0; f < 6; f++) ...[
          _n('L$f', 900, floor: f),
          _n('HB$f', 1000,
              floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
        ],
      ],
      edges: [
        _e('g', 'GT', 'P1'),
        _e('p1', 'P1', 'M'),
        _e('tl', 'M', 'TL'),
        _e('m2', 'M', 'P2'),
        _e('p2', 'P2', 'D'),
        _e('dl', 'D', 'L0'),
        for (var f = 0; f < 6; f++) ...[
          if (f > 0) _e('q$f', 'L${f - 1}', 'L$f', k: EdgeKind.riser),
          _e('hb$f', 'L$f', 'HB$f'),
        ],
      ],
    );
    final c = _container(net, 6, h: 4);
    final b = c.read(fireSystemBasesProvider).single;
    expect(b.stages, hasLength(2));
    final h1 = b.stageHeads['P1']!.meters;
    final h2 = b.stageHeads['P2']!.meters;
    // No interstage terminal, no floor lift: the system head split equally.
    expect(h1, closeTo(b.head.meters / 2, 1e-9));
    expect(h2, closeTo(b.head.meters / 2, 1e-9));
    expect(h1 + h2, closeTo(b.head.meters, 1e-9));
    expect(h1, greaterThanOrEqualTo(kMinFireStageHeadM));
    final duties = c.read(equipmentNodeDutiesProvider);
    expect(duties['P1']!.motor.watts, b.stageDuties['P1']!.selectedMotor.watts);
    expect(duties['P1']!.motor.watts, greaterThan(370));
  });

  // ── regression-hydrant-ring-floored-at-other-systems-sprinkler-demand ───
  test('a hydrant ring beside a separate extra-hazard sprinkler system on the '
      'same tank carries the hydrant flow, not the sprinkler demand', () {
    for (final shared in [true, false]) {
      final base = _sharedTank(floors: 6, heads: 4);
      final net = Network(
        nodes: [
          ...base.nodes,
          _n('Y', 500, y: 100),
          if (!shared)
            _n('GT2', 0,
                y: 300, role: NodeRole.plant, c: NodeComponent.groundTank),
        ],
        edges: [
          for (final e in base.edges)
            if (!shared && e.id == 'gs')
              _e('gs', 'GT2', 'FPS', s: _sp)
            else
              e,
          _e('dy', 'DH', 'Y'),
          _e('yq', 'Y', 'Q0'),
        ],
      );
      final c = _container(net, 6, h: 4);
      c.read(fireHazardProvider.notifier).set(FireHazardClass.extraHazard);
      final demand =
          c.read(sprinklerRemoteAreaProvider).remoteAreaDemand.inLitersPerSecond;
      expect(demand, greaterThan(standpipeFlow(1).inLitersPerSecond));
      final sz = c.read(sizingProvider);
      for (final id in ['dq', 'dy', 'yq']) {
        expect(sz[id]!.flow.inLitersPerSecond,
            lessThanOrEqualTo(standpipeFlow(1).inLitersPerSecond + 1e-9),
            reason: '$id shared=$shared');
      }
    }
  });

  // ── fire-convergence-4-report-prints-phantom-class-i-pump ───────────────
  testWidgets('a gravity hose-reel system prints its gravity verdict, never '
      'a Class I pump', (tester) async {
    final (ref, c) = await _harness(tester);
    _seed(
      c,
      Network(
        nodes: [
          _n('RT', 0, floor: 1, role: NodeRole.plant, c: NodeComponent.roofTank),
          _n('Q1', 100, floor: 1),
          _n('Q0', 100),
          _n('HR1', 200,
              floor: 1, role: NodeRole.fixture, c: NodeComponent.hoseReel),
          _n('HR0a', 200, role: NodeRole.fixture, c: NodeComponent.hoseReel),
          _n('HR0b', 200,
              y: 100, role: NodeRole.fixture, c: NodeComponent.hoseReel),
        ],
        edges: [
          _e('rt', 'RT', 'Q1'),
          _e('rq', 'Q1', 'Q0', k: EdgeKind.riser),
          _e('h1', 'Q1', 'HR1'),
          _e('h0a', 'Q0', 'HR0a'),
          _e('h0b', 'Q0', 'HR0b'),
        ],
      ),
      2,
      h: 4,
    );
    await tester.pump();
    final b = c.read(fireSystemBasesProvider).single;
    expect(b.gravityFed, isTrue);
    expect(b.standpipeClass, StandpipeClass.classII);
    expect(c.read(reportStandpipeDesignProvider), isNull);
    final d = buildMechanicalReportData(ref);
    expect(d.standpipe, isNull);
    expect(d.firePumpRating, isNull);
    expect(d.fireSystems, isEmpty);
    expect(d.fireGravity, hasLength(1));
    final g = d.fireGravity.single;
    expect(g.flowLps, closeTo(b.flow.inLitersPerSecond, 1e-9));
    expect(g.availableM, closeTo(b.gravityAvailableHeadM!, 1e-9));
    expect(g.requiredM, closeTo(b.gravityRequiredHeadM!, 1e-9));
    expect(g.short, isTrue);
    final md = buildCalcReportMarkdown(d);
    expect(md, isNot(contains('Standpipe:')));
    expect(md, contains('Gravity fire supply (standpipe, no pump):'));
    expect(md, contains('SHORT - add a fire pump'));
    // No Class I 690 kPa residual verify line for a design that prints none.
    expect(
        d.verifyItems.any((v) =>
            standpipeVerifyChecklist.any((x) => identical(x, v))),
        isFalse);
  });

  // ── fire-convergence-4-series-stage-report-line ─────────────────────────
  // 10 x 3 m: GT -> FPH -> hydrant riser L0-L4 -> booster BH on L5 -> L5-L9;
  // the sprinkler side the same shape (FPS, BS).
  Network zoned({bool sprinklerSide = true, int floors = 10, int boost = 5,
          int heads = 1}) =>
      Network(
        nodes: [
          _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
          _n('FPH', 100, role: NodeRole.plant, c: NodeComponent.pump),
          _n('BH', 800, floor: boost, role: NodeRole.plant, c: NodeComponent.pump),
          if (sprinklerSide) ...[
            _n('FPS', 100,
                y: 300, role: NodeRole.plant, c: NodeComponent.pump),
            _n('BS', 800,
                y: 300,
                floor: boost,
                role: NodeRole.plant,
                c: NodeComponent.pump),
          ],
          for (var f = 0; f < floors; f++) ...[
            _n('Q$f', 900, floor: f),
            _n('HB$f', 1000,
                floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox),
            if (sprinklerSide) ...[
              _n('R$f', 1500, y: 300, floor: f),
              for (var k = 1; k <= heads; k++)
                _n('SH$f-$k', 1500 + 300.0 * k,
                    y: 300,
                    floor: f,
                    role: NodeRole.fixture,
                    c: NodeComponent.sprinklerHead),
            ],
          ],
        ],
        edges: [
          _e('gh', 'GT', 'FPH'),
          _e('ph', 'FPH', 'Q0'),
          _e('bh1', 'Q${boost - 1}', 'BH', k: EdgeKind.riser),
          _e('bh2', 'BH', 'Q$boost'),
          if (sprinklerSide) ...[
            _e('gs', 'GT', 'FPS', s: _sp),
            _e('ps', 'FPS', 'R0', s: _sp),
            _e('bs1', 'R${boost - 1}', 'BS', s: _sp, k: EdgeKind.riser),
            _e('bs2', 'BS', 'R$boost', s: _sp),
          ],
          for (var f = 0; f < floors; f++) ...[
            if (f > 0 && f != boost)
              _e('q$f', 'Q${f - 1}', 'Q$f', k: EdgeKind.riser),
            _e('hb$f', 'Q$f', 'HB$f'),
            if (sprinklerSide) ...[
              if (f > 0 && f != boost)
                _e('r$f', 'R${f - 1}', 'R$f', s: _sp, k: EdgeKind.riser),
              for (var k = 1; k <= heads; k++)
                _e('sh$f-$k', k == 1 ? 'R$f' : 'SH$f-${k - 1}', 'SH$f-$k',
                    s: _sp),
            ],
          ],
        ],
      );

  testWidgets('a staged system reports one line per stage under its own duty '
      'pump, on the schedule\'s figures', (tester) async {
    final (ref, c) = await _harness(tester);
    _seed(c, zoned(), 10, h: 3);
    await tester.pump();
    final bases = c.read(fireSystemBasesProvider);
    final hyd = bases.singleWhere((b) => b.pumpIds.contains('FPH'));
    expect(hyd.stages, hasLength(2));
    expect(hyd.dutyPumpId, isNotNull);
    final d = buildMechanicalReportData(ref);
    final tags = equipmentNodeTags(c.read(networkControllerProvider).network);
    final duties = c.read(equipmentNodeDutiesProvider);
    // Every printed line names a drawn machine whose schedule motor it
    // prints: no line carries the summed-head frame of no machine.
    final byTag = {for (final e in tags.entries) e.value: e.key};
    for (final l in d.fireSystems) {
      final id = byTag[l.tag]!;
      expect(l.rating.selectedMotor.watts, duties[id]!.motor.watts,
          reason: l.tag);
    }
    final lineTags = d.fireSystems.map((l) => l.tag).toSet();
    for (final id in ['FPH', 'BH', 'FPS', 'BS']) {
      expect(lineTags, contains(tags[id]), reason: id);
    }
    // The governing system is staged: no single summed-head rating block,
    // its jockey point still printed.
    expect(d.firePumpRating, isNull);
    expect(d.fireJockeyRating, isNotNull);
    final summed = checkFirePumpRating(ratedFlow: hyd.flow, ratedHead: hyd.head);
    final md = buildCalcReportMarkdown(d);
    expect(
        md,
        isNot(contains(
            'motor ${summed.selectedMotor.inKiloWatts.toStringAsFixed(1)} kW')));
    expect(md, contains('Jockey pump:'));
  });

  // ── fire-convergence-4-staged-sprinkler-system-false-over-pressure ──────
  group('zoned sprinkler tower over-pressure', () {
    // 20 x 3 m sprinkler side only: GT -> FPS -> riser L0-L9 -> BS on L10 ->
    // L10-L19, OH1, 4 heads per floor, calibrated.
    Network sprTower({required bool booster}) => Network(
      nodes: [
        _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('FPS', 100, role: NodeRole.plant, c: NodeComponent.pump),
        if (booster)
          _n('BS', 800, floor: 10, role: NodeRole.plant, c: NodeComponent.pump),
        for (var f = 0; f < 20; f++) ...[
          _n('R$f', 1500, floor: f),
          for (var k = 1; k <= 4; k++)
            _n('SH$f-$k', 1500 + 300.0 * k,
                floor: f,
                role: NodeRole.fixture,
                c: NodeComponent.sprinklerHead),
        ],
      ],
      edges: [
        _e('gs', 'GT', 'FPS', s: _sp),
        _e('ps', 'FPS', 'R0', s: _sp),
        if (booster) ...[
          _e('b1', 'R9', 'BS', s: _sp, k: EdgeKind.riser),
          _e('b2', 'BS', 'R10', s: _sp),
        ],
        for (var f = 0; f < 20; f++) ...[
          if (f > 0 && (!booster || f != 10))
            _e('r$f', 'R${f - 1}', 'R$f', s: _sp, k: EdgeKind.riser),
          for (var k = 1; k <= 4; k++)
            _e('sh$f-$k', k == 1 ? 'R$f' : 'SH$f-${k - 1}', 'SH$f-$k',
                s: _sp),
        ],
      ],
    );

    test('with the L10 booster: judged at each stage discharge, no warning',
        () {
      final c = _container(sprTower(booster: true), 20, h: 3);
      c.read(fireHazardProvider.notifier).set(FireHazardClass.ordinaryHazard1);
      final b = c.read(fireSystemBasesProvider).single;
      expect(b.stages, hasLength(2));
      final s0 = b.stages[0], s1 = b.stages[1];
      expect(s0.pumpIds, ['FPS']);
      expect(s1.pumpIds, ['BS']);
      expect(s1.upstream, 0);
      expect(s1.suctionLiftM, closeTo(30.0, 1e-9));
      // First principles: the booster discharge sees 1.4·H1 − 30 + 1.4·H2.
      const rhoG = 1000 * 9.81;
      final atBooster = s0.rating.churn.head.meters -
          30 +
          s1.rating.churn.head.meters;
      final atMain = s0.rating.churn.head.meters;
      final worstKpa =
          rhoG * (atBooster > atMain ? atBooster : atMain) / 1000;
      expect(worstKpa, lessThan(kFireComponentMaxPressureKpa));
      expect(c.read(fireOverPressureProvider), isEmpty);
      // The old single-point judge at 1.4 x the summed head would warn — the
      // pin is meaningful only if it does.
      expect(fireOverPressureCheck(rating: b.rating).over, isTrue,
          reason: 'probe must exercise the false-warning band');
    });

    test('the same tower with ONE pump still warns', () {
      final c = _container(sprTower(booster: false), 20, h: 3);
      c.read(fireHazardProvider.notifier).set(FireHazardClass.ordinaryHazard1);
      final b = c.read(fireSystemBasesProvider).single;
      expect(b.stages, isEmpty);
      final o = c.read(fireOverPressureProvider);
      expect(o, hasLength(1));
      expect(o.single.pumpId, 'FPS');
    });
  });

  test('rating systems: a series chain is one system (sanity)', () {
    final net = zoned(sprinklerSide: false);
    expect(fireRatingSystems(net), hasLength(1));
  });
}
