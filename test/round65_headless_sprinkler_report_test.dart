// Round 65 (regression-3) — a sprinkler-labelled pipe with no sprinkler HEAD
// is no sprinkler system on the issued calc report either.
//
// GT -g(sp)- SH -sa(sp)- P -d- a 4-storey Class I hydrant riser, one box a
// floor, NO head. Round 64 rates the pump on the hydrant basis
// (500 gpm = 31.545 L/s) and the sprinkler-vs-pump judge is null; the report
// used to print a sprinkler design + a 6.0 L/s remote-area check beside it.
// With one head drawn on a sprinkler branch the sprinkler sections return.
import 'package:flutter/widgets.dart' hide Velocity;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/inspector/project_panel.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
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
        {EdgeKind k = EdgeKind.run, ServiceType s = ServiceType.fireHydrant}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

Network _headless({bool withHead = false}) {
  const sp = ServiceType.fireSprinkler;
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('SH', 100),
    _n('P', 200, role: NodeRole.plant, c: NodeComponent.pump),
    _n('X0', 300),
    if (withHead)
      _n('HD', 300, floor: 4, role: NodeRole.fixture,
          c: NodeComponent.sprinklerHead),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'SH', s: sp),
    _e('sa', 'SH', 'P', s: sp),
    _e('d', 'P', 'X0'),
    if (withHead) _e('hd', 'X4', 'HD', s: sp),
  ];
  for (var f = 1; f <= 4; f++) {
    nodes
      ..add(_n('X$f', 300, floor: f))
      ..add(_n('B$f', 400,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges
      ..add(_e('r$f', 'X${f - 1}', 'X$f', k: EdgeKind.riser))
      ..add(_e('b$f', 'X$f', 'B$f'));
  }
  return Network(nodes: nodes, edges: edges);
}

Future<(WidgetRef, ProviderContainer)> _harness(WidgetTester tester) async {
  late WidgetRef capturedRef;
  await tester.pumpWidget(
    ProviderScope(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Consumer(builder: (context, ref, _) {
          capturedRef = ref;
          return const SizedBox.shrink();
        }),
      ),
    ),
  );
  await tester.pump();
  final container = ProviderScope.containerOf(
      tester.element(find.byType(Consumer)),
      listen: false);
  return (capturedRef, container);
}

void main() {
  testWidgets('no head: no sprinkler design on the report', (tester) async {
    final (ref, c) = await _harness(tester);
    c.read(projectControllerProvider.notifier)
      ..setFloors([for (var i = 0; i < 5; i++) Floor('L$i', const Length(3.5))])
      ..setCalibration('s1', const ScaleCalibration(0.01));
    c.read(networkControllerProvider.notifier).loadNetwork(_headless());
    await tester.pump();
    expect(c.read(sprinklerHeadDrawnProvider), isFalse);
    expect(c.read(sprinklerPumpCheckProvider), isNull);
    final data = buildMechanicalReportData(ref);
    expect(data.sprinkler, isNull);
    expect(data.sprinklerRemoteArea, isNull);
    // The hydrant standpipe the pump is rated on still prints.
    expect(data.standpipe, isNotNull);
  });

  testWidgets('one head drawn: the sprinkler design returns', (tester) async {
    final (ref, c) = await _harness(tester);
    c.read(projectControllerProvider.notifier)
      ..setFloors([for (var i = 0; i < 5; i++) Floor('L$i', const Length(3.5))])
      ..setCalibration('s1', const ScaleCalibration(0.01));
    c.read(networkControllerProvider.notifier)
        .loadNetwork(_headless(withHead: true));
    await tester.pump();
    expect(c.read(sprinklerHeadDrawnProvider), isTrue);
    final data = buildMechanicalReportData(ref);
    expect(data.sprinkler, isNotNull);
    expect(data.sprinklerRemoteArea, isNotNull);
  });
}
