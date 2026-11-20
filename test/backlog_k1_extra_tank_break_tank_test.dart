// Backlog K-1 (2026-11-20, shophouse backlog (g)) — the intermediate break
// tank of an EXTRA roof-tank component is zoned exactly like the main
// tank's (Round 70): its floors leave the component's roof-tank group and
// hang from the break tank's own datum.
//
// Building: 12 storeys of 3.5 m (L0..L11), default mounting (fixture
// height 1.1 m), downfeed.
//  * Component A (the main solve, roof tank 'RA' wins the id tie): RA on
//    L11 -> a down-riser with one lavatory on every floor L1..L11.
//  * Component B (the extra roof-tank component 'RB'): GB (ground tank,
//    L0) -> PB1 -> riser -> BB (ground tank on L6, the BREAK tank) -> PB2 ->
//    riser -> RB (roof tank, L11). BB feeds a down-riser with a lavatory on
//    L1..L6; RB one on L7..L11 — the Round-70 tower shape, at 12 storeys.
//
// Hand arithmetic:
//  * BB is a plant ground tank: its datum is its floor slab, 6 x 3.5 =
//    21.0 m.
//  * A fixture on floor f sits at 3.5 f + 1.1 m. WB_B1 (L1) static from BB
//    = 21.0 - 4.6 = 16.4 m -> 16.4 x 9.80665 = 160.83 kPa (from the break
//    tank, never RB's datum).
//  * The SNI 8153 limit (392 kPa) is 392 / 9.80665 = 39.97 m of head: BB's
//    deepest floor is 16.4 m below it, so BB's tank-fed zone spans L6..L1
//    in ONE zone, datum 21.0 m.
//  * RB's group keeps only the floors RB itself feeds: L7..L11 (top 11,
//    bottom 7). Before K-1 RB's group spanned L11..L1 and BB had no group.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(
  String id,
  double x,
  int floor, {
  NodeRole role = NodeRole.main,
  NodeComponent? c,
  PlumbingFixture? fx,
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: 0,
  floorIndex: floor,
  role: role,
  component: c,
  fixture: fx,
);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: ServiceType.coldWater, kind: k);

const _lav = PlumbingFixture.lavatory;

Network _twoComponents({bool withB = true}) => Network(
  nodes: [
    // Component A.
    _n('RA', 0, 11, role: NodeRole.plant, c: NodeComponent.roofTank),
    for (var f = 1; f <= 11; f++) ...[
      _n('A$f', 20, f),
      _n('WA$f', 40, f, role: NodeRole.fixture, fx: _lav),
    ],
    if (withB) ...[
      // Component B.
      _n('GB', 500, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('PB1', 520, 0, role: NodeRole.plant, c: NodeComponent.pump),
      for (var f = 0; f <= 6; f++) _n('U$f', 540, f),
      _n('BB', 560, 6, role: NodeRole.plant, c: NodeComponent.groundTank),
      _n('PB2', 580, 6, role: NodeRole.plant, c: NodeComponent.pump),
      for (var f = 6; f <= 11; f++) _n('V$f', 600, f),
      for (var f = 1; f <= 6; f++) ...[
        _n('L$f', 640, f),
        _n('WB$f', 660, f, role: NodeRole.fixture, fx: _lav),
      ],
      _n('RB', 700, 11, role: NodeRole.plant, c: NodeComponent.roofTank),
      for (var f = 7; f <= 11; f++) ...[
        _n('R$f', 720, f),
        _n('WR$f', 740, f, role: NodeRole.fixture, fx: _lav),
      ],
    ],
  ],
  edges: [
    _e('a11', 'RA', 'A11'),
    for (var f = 10; f >= 1; f--)
      _e('a$f', 'A${f + 1}', 'A$f', k: EdgeKind.riser),
    for (var f = 1; f <= 11; f++) _e('wa$f', 'A$f', 'WA$f'),
    if (withB) ...[
      _e('g', 'GB', 'PB1'),
      _e('t0', 'PB1', 'U0'),
      for (var f = 1; f <= 6; f++)
        _e('u$f', 'U${f - 1}', 'U$f', k: EdgeKind.riser),
      _e('ub', 'U6', 'BB'),
      _e('b2', 'BB', 'PB2'),
      _e('v0', 'PB2', 'V6'),
      for (var f = 7; f <= 11; f++)
        _e('v$f', 'V${f - 1}', 'V$f', k: EdgeKind.riser),
      _e('vr', 'V11', 'RB'),
      _e('l6', 'BB', 'L6'),
      for (var f = 5; f >= 1; f--)
        _e('l$f', 'L${f + 1}', 'L$f', k: EdgeKind.riser),
      for (var f = 1; f <= 6; f++) _e('wb$f', 'L$f', 'WB$f'),
      _e('r11', 'RB', 'R11'),
      for (var f = 10; f >= 7; f--)
        _e('r$f', 'R${f + 1}', 'R$f', k: EdgeKind.riser),
      for (var f = 7; f <= 11; f++) _e('wr$f', 'R$f', 'WR$f'),
    ],
  ],
);

ProviderContainer _c({bool withB = true}) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 12; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
  c
      .read(networkControllerProvider.notifier)
      .loadNetwork(_twoComponents(withB: withB));
  return c;
}

void main() {
  test('the extra component is RB; the field judges BB-fed floors from BB', () {
    final c = _c();
    expect(c.read(extraDownfeedTanksProvider).map((t) => t.tank), ['RB']);
    final sol = c.read(downfeedDeliveredProvider)!;
    // (21.0 - 4.6) x 9.80665 = 160.83 kPa.
    expect(
      sol.noFlowStaticPressure['WB1']!.inKiloPascals,
      closeTo(16.4 * 9.80665, 0.5),
    );
  });

  test('BB zones its own floors from its 21.0 m datum', () {
    final c = _c();
    final groups = c.read(downfeedZoneGroupsProvider);
    expect(groups.map((g) => g.tankId), ['RA', 'RB', 'BB']);
    final bb = groups.firstWhere((g) => g.tankId == 'BB');
    // 6 x 3.5 = 21.0 m (the break tank's floor slab).
    expect(bb.tankElevation!.meters, closeTo(21.0, 1e-9));
    expect(bb.tankElevationByFloor, isNull);
    // 21.0 - 4.6 = 16.4 m <= 39.97 m: one tank-fed zone L6..L1.
    expect(bb.zones, hasLength(1));
    expect(bb.zones.single.topFloorIndex, 6);
    expect(bb.zones.single.bottomFloorIndex, 1);
    // RB's group keeps only the floors RB feeds itself: L11..L7.
    final rb = groups.firstWhere((g) => g.tankId == 'RB');
    expect(rb.zones.first.topFloorIndex, 11);
    expect(rb.zones.last.bottomFloorIndex, 7);
    // The zone statics carry BB's first zone from its own datum.
    final statics = c.read(zoneStaticsProvider);
    expect(statics, hasLength(groups.fold<int>(0, (a, g) => a + g.zones.length)));
  });

  test('the main component alone is unchanged by K-1 (one group)', () {
    final c = _c(withB: false);
    final groups = c.read(downfeedZoneGroupsProvider);
    expect(groups.map((g) => g.tankId), ['RA']);
    expect(groups.single.zones.first.topFloorIndex, 11);
    expect(groups.single.zones.last.bottomFloorIndex, 1);
  });

  test('the same break tank on the MAIN component zones identically', () {
    // Component B drawn alone: RB is the main tank, BB its Round-70 break
    // tank. The BB group must equal the one K-1 gives the extra component.
    final alone = ProviderContainer();
    addTearDown(alone.dispose);
    alone.read(projectControllerProvider.notifier)
      ..setFloors([for (var i = 0; i < 12; i++) Floor('L$i', const Length(3.5))])
      ..setCalibration('s1', const ScaleCalibration(0.01));
    alone.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
    final full = _twoComponents();
    final bOnly = Network(
      nodes: [
        for (final n in full.nodes)
          if (n.x >= 500) n,
      ],
      edges: [
        for (final e in full.edges)
          if (!e.id.startsWith('a') && !e.id.startsWith('wa')) e,
      ],
    );
    alone.read(networkControllerProvider.notifier).loadNetwork(bOnly);
    final mainGroups = alone.read(downfeedZoneGroupsProvider);
    final extraGroups = _c().read(downfeedZoneGroupsProvider);
    String sig(DownfeedZoneGroup g) =>
        '${g.tankId} ${g.tankElevation?.meters.toStringAsFixed(6)} '
        '${[for (final z in g.zones) '${z.topFloorIndex}-${z.bottomFloorIndex}']}';
    expect(
      mainGroups.where((g) => g.tankId == 'BB').map(sig),
      extraGroups.where((g) => g.tankId == 'BB').map(sig),
    );
    expect(
      mainGroups.where((g) => g.tankId == 'RB').map(sig),
      extraGroups.where((g) => g.tankId == 'RB').map(sig),
    );
  });
}
