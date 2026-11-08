// Round 52 r2 (2026-10-18) — a fire TRANSFER pump filling a roof tank that
// gravity-feeds the only fire terminals: no fire pump to rate.
//
//   r52-review-transfer-exclusion-leaks-phantom-pump-into-report
import 'package:flutter/widgets.dart' hide Velocity;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/plan_symbols.dart' show equipmentNodeTags;
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

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.fireHydrant, kind: k);

/// 6 x 3.5 m: GT -> TP (L0) -> riser -> RT roof tank (L5) -> riser down ->
/// a hose reel on every floor.
Network _transferThenGravity() => Network(
  nodes: [
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('TP', 100, role: NodeRole.plant, c: NodeComponent.pump),
    _n('A0', 200),
    _n('A5', 200, floor: 5),
    _n('RT', 300, floor: 5, role: NodeRole.plant, c: NodeComponent.roofTank),
    for (var f = 0; f < 6; f++) ...[
      _n('Q$f', 400, floor: f),
      _n('HR$f', 500,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hoseReel),
    ],
  ],
  edges: [
    _e('g', 'GT', 'TP'),
    _e('t', 'TP', 'A0'),
    _e('r', 'A0', 'A5', k: EdgeKind.riser),
    _e('a', 'A5', 'RT'),
    _e('rt', 'RT', 'Q5'),
    for (var f = 0; f < 6; f++) ...[
      if (f < 5) _e('q$f', 'Q${f + 1}', 'Q$f', k: EdgeKind.riser),
      _e('h$f', 'Q$f', 'HR$f'),
    ],
  ],
);

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

void main() {
  testWidgets('transfer pump -> roof tank -> gravity hose reels: no phantom '
      'fire pump, the report names the transfer pump and the gravity verdict',
      (tester) async {
    final (ref, c) = await _harness(tester);
    c.read(projectControllerProvider.notifier)
      ..setFloors([for (var i = 0; i < 6; i++) Floor('L$i', Length(3.5))])
      ..setCalibration('s1', const ScaleCalibration(0.01));
    c.read(networkControllerProvider.notifier).loadNetwork(
        _transferThenGravity());
    await tester.pump();

    final bases = c.read(fireSystemBasesProvider);
    expect(bases.where((b) => b.transfer), hasLength(1));
    expect(bases.where((b) => b.gravityFed), hasLength(1));
    expect(c.read(governingFireBasisProvider), isNull);
    expect(c.read(fireAllGravityFedProvider), isTrue);
    expect(c.read(firePumpDutyProvider), isNull);
    expect(c.read(fireJockeyDutyProvider), isNull);
    // The rated point is a DRAWN system's, never the advisory standpipe's
    // 31.5 L/s.
    final transfer = bases.singleWhere((b) => b.transfer);
    expect(c.read(fireRatedPointProvider).flow.inLitersPerSecond,
        closeTo(transfer.flow.inLitersPerSecond, 1e-9));

    final d = buildMechanicalReportData(ref);
    expect(d.firePumpRating, isNull);
    expect(d.fireJockeyRating, isNull);
    final tags = equipmentNodeTags(c.read(networkControllerProvider).network);
    expect(d.fireSystems, hasLength(1));
    final line = d.fireSystems.single;
    expect(line.transfer, isTrue);
    expect(line.tag, tags['TP']);
    expect(line.rating.selectedMotor.watts,
        transfer.rating.selectedMotor.watts);
    expect(d.fireGravity, hasLength(1));
    expect(d.fireGravity.single.short, isTrue);

    final md = buildCalcReportMarkdown(d);
    expect(md, contains(tags['TP']!));
    expect(md, contains('SHORT - add a fire pump'));
    expect(md, isNot(contains('Jockey pump')));
    expect(md, isNot(contains('duty pump)')));
    expect(md, contains('tank transfer pump rating curve'));
    // Never the advisory whole-building standpipe head (6 x 3.5 m Class I,
    // ~104 m) of a pump no drawn machine carries.
    expect(md, isNot(contains('@ 104 m')));
    expect(transfer.head.meters, lessThan(40));

    // The schedule keeps the transfer pump as its only fire row.
    final sched = gatherEquipmentScheduleData(ref);
    final fire = sched.pumps
        .where((p) => p.service.toLowerCase().contains('fire'))
        .toList();
    expect(fire, hasLength(1));
    expect(fire.single.tag, tags['TP']);
    expect(fire.single.service, 'Fire tank transfer pump');
    expect(fire.single.duty.selectedMotor.watts,
        transfer.duty!.selectedMotor.watts);
    // The MDP way is the same machine.
    expect(c.read(equipmentNodeDutiesProvider)['TP']!.motor.watts,
        transfer.duty!.selectedMotor.watts);
  });
}
