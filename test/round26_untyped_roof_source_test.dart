/// Round 26 (regression-untyped-roof-source-downfeed-silenced) — the drawn-
/// feed predicate [gravityDownfeedDrawnProvider] follows the ONE Round-23
/// gravity-source rule: a roof tank OR a PLANT above the top-storey fixture.
/// An untyped 'Source / tank' plant on the top storey sits at the roof
/// (Round 17), so a downfeed fed from it is judged exactly like a typed roof
/// tank — over-pressure, Review issues and the heatmap no longer go silent.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? c,
        PlumbingFixture? fixture}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c,
        fixture: fixture);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.coldWater, kind: k);

ProviderContainer _tower(NodeComponent? sourceComponent, int floors) {
  final c = ProviderContainer();
  c.read(projectControllerProvider.notifier)
    ..setFloors(
        [for (var i = 0; i < floors; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
  final top = floors - 1;
  c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
    _n('T', 0, 0, floor: top, role: NodeRole.plant, c: sourceComponent),
    for (var f = 0; f < floors; f++) ...[
      _n('R$f', 100, 0, floor: f),
      _n('W$f', 300, 0,
          floor: f,
          role: NodeRole.fixture,
          fixture: PlumbingFixture.waterClosetFlushTank),
    ],
  ], edges: [
    _e('t', 'T', 'R$top'),
    for (var f = 0; f < top; f++)
      _e('r$f', 'R$f', 'R${f + 1}', k: EdgeKind.riser),
    for (var f = 0; f < floors; f++) _e('w$f', 'R$f', 'W$f'),
  ]));
  c.read(electricalProjectProvider);
  return c;
}

void main() {
  test('an untyped top-storey plant is the same gravity source as a roof '
      'tank: identical tank datum, over-pressure set and Review issues', () {
    final typed = _tower(NodeComponent.roofTank, 20);
    final untyped = _tower(null, 20);
    addTearDown(typed.dispose);
    addTearDown(untyped.dispose);

    // Both sit at the roof: 20 storeys x 3.5 m = 70.0 m.
    expect(typed.read(downfeedTankElevationProvider)!.meters,
        closeTo(70.0, 1e-9));
    expect(untyped.read(downfeedTankElevationProvider)!.meters,
        closeTo(70.0, 1e-9));
    expect(untyped.read(gravityDownfeedDrawnProvider), isTrue);

    // The L0 WC sees ~70 m x 9.81 = 687 kPa of static — far over any SNI
    // fixture limit — so the untyped feed MUST be judged.
    final overTyped = {
      for (final o in typed.read(downfeedOverPressureProvider)) o.nodeId
    };
    final overUntyped = {
      for (final o in untyped.read(downfeedOverPressureProvider)) o.nodeId
    };
    expect(overTyped, contains('W0'));
    expect(overUntyped, overTyped);

    List<String> kinds(ProviderContainer c) => [
          for (final i in c.read(designIssuesProvider))
            if (i.kind.startsWith('downfeed')) i.kind
        ]..sort();
    expect(kinds(untyped), isNotEmpty);
    expect(kinds(untyped), kinds(typed));
    expect(untyped.read(residualByNodeProvider), isNotEmpty);
  });

  test('a bare top-storey main junction is still not a tank', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier)
      ..setFloors(
          [for (var i = 0; i < 3; i++) Floor('L$i', const Length(3.5))])
      ..setCalibration('s1', const ScaleCalibration(0.01));
    c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
      _n('M', 0, 0, floor: 2),
      _n('W2', 300, 0,
          floor: 2,
          role: NodeRole.fixture,
          fixture: PlumbingFixture.waterClosetFlushTank),
    ], edges: [
      _e('w', 'M', 'W2'),
    ]));
    expect(c.read(downfeedTankElevationProvider), isNull);
    expect(c.read(gravityDownfeedDrawnProvider), isFalse);
  });
}
