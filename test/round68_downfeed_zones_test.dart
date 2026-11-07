// Round 68 (2026-10-18) — the downfeed PRV zone table vs the drawn
// tank-outlet booster:
//
//   regression-1  duty / standby boosters BP + BQ in parallel at the roof
//                 tank outlet are ONE set: the tank never "bypasses" BP
//                 through BQ, the datum lifts ONCE (max head, never the
//                 sum), and the served-floor walk never falls to a podium
//                 fixture of another supply network.
//   regression-2  a lavatory TX fed straight off the tank beside the outlet
//                 booster neither walls the booster (its served floors
//                 extend below the tank-only set) nor drops the lift.
//   regression-3  a heater WH off the tank serving a hot shower HX on L19:
//                 the datum walk and the zone walk read ONE cold + hot graph.
//
// First principles (20 storeys x 3.5 m, roof tank RT on L19 at the roof,
// 70.0 m; a booster head H at the outlet): the tank-fed top zone admits
// floor f while rho g (datum - fixture(f)) <= the SNI 8153 392 kPa static
// limit = 39.96 m of head. With the booster datum 70 + H every boosted
// floor is judged on it, so every drawing that runs BP over L6..L19 gets the
// plain single-booster table [(19,15),(14,11),(10,7),(6,6)].
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart' show headFromPressure;
import 'package:mechx_engine/network/network.dart';
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
}) => NetNode(
  id: id,
  sheetId: 's1',
  x: x,
  y: y,
  floorIndex: floor,
  role: role,
  component: c,
  fixture: fixture,
);

NetEdge _e(
  String id,
  String a,
  String b, {
  EdgeKind k = EdgeKind.run,
  ServiceType s = ServiceType.coldWater,
}) => NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

NetNode _fix(String id, double x, double y, int floor,
        {PlumbingFixture f = PlumbingFixture.lavatory}) =>
    _n(id, x, y, floor: floor, role: NodeRole.fixture, fixture: f);

/// The tower: RT -> BP -> R19 .. R6, a lavatory per storey. [duplex] adds a
/// parallel standby BQ (RT -> BQ -> R19); [tx] a lavatory TX on L19 piped
/// straight from RT; [heater] a heater WH fed RT -> WH (cold) serving a hot
/// shower HX on L19.
(List<NetNode>, List<NetEdge>) _tower({
  bool duplex = false,
  bool tx = false,
  bool heater = false,
}) => (
  [
    _n('RT', 0, 0, floor: 19, role: NodeRole.plant, c: NodeComponent.roofTank),
    _n('BP', 50, 0,
        floor: 19, role: NodeRole.plant, c: NodeComponent.boosterSet),
    if (duplex)
      _n('BQ', 50, 40,
          floor: 19, role: NodeRole.plant, c: NodeComponent.boosterSet),
    if (tx) _fix('TX', 0, 100, 19),
    if (heater) ...[
      _n('WH', -50, 0, floor: 19, role: NodeRole.plant),
      _fix('HX', -100, 0, 19, f: PlumbingFixture.shower),
    ],
    for (var f = 6; f <= 19; f++) ...[
      _n('R$f', 100, 0, floor: f),
      _fix('W$f', 200, 0, f),
    ],
  ],
  [
    _e('rt', 'RT', 'BP'),
    _e('bp', 'BP', 'R19'),
    if (duplex) ...[_e('rq', 'RT', 'BQ'), _e('bq', 'BQ', 'R19')],
    if (tx) _e('tx', 'RT', 'TX'),
    if (heater) ...[
      _e('wh', 'RT', 'WH'),
      _e('hx', 'WH', 'HX', s: ServiceType.hotWater),
    ],
    for (var f = 19; f > 6; f--)
      _e('r$f', 'R$f', 'R${f - 1}', k: EdgeKind.riser),
    for (var f = 6; f <= 19; f++) _e('w$f', 'R$f', 'W$f'),
  ],
);

/// A mains-fed podium on L0..L5 (water meter -> riser, a lavatory each).
(List<NetNode>, List<NetEdge>) _podium() => (
  [
    _n('WM', 0, 400, c: NodeComponent.waterMeter),
    for (var f = 0; f <= 5; f++) ...[
      _n('M$f', 100, 400, floor: f),
      _fix('V$f', 200, 400, f),
    ],
  ],
  [
    _e('wm', 'WM', 'M0'),
    for (var f = 1; f <= 5; f++)
      _e('m$f', 'M${f - 1}', 'M$f', k: EdgeKind.riser),
    for (var f = 0; f <= 5; f++) _e('v$f', 'M$f', 'V$f'),
  ],
);

ProviderContainer _solve(List<(List<NetNode>, List<NetEdge>)> parts) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 20; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
  c.read(networkControllerProvider.notifier).loadNetwork(Network(
        nodes: [for (final p in parts) ...p.$1],
        edges: [for (final p in parts) ...p.$2],
      ));
  return c;
}

List<(int, int)> _spans(ProviderContainer c) => [
  for (final z in c.read(zonesProvider)) (z.topFloorIndex, z.bottomFloorIndex),
];

const _expected = [(19, 15), (14, 11), (10, 7), (6, 6)];

void main() {
  late ProviderContainer single;
  late double singleDatum, singleHead;
  setUp(() {
    single = _solve([_tower()]);
    singleDatum = single.read(effectiveDownfeedDatumProvider)!.meters;
    singleHead = single.read(downfeedMoverHeadsProvider)['BP']!.meters;
  });

  test('the plain outlet booster: datum = tank + head, four zones', () {
    // RT sits at the roof: 20 x 3.5 = 70.0 m.
    expect(singleHead, greaterThan(15));
    expect(singleDatum, closeTo(70.0 + singleHead, 1e-9));
    expect(_spans(single), _expected);
    // Hand check of the top-zone break: floor 15's fixture is admitted and
    // floor 14's is not on the 39.96 m (392 kPa) tank-fed span.
    final b = single.read(projectControllerProvider).building;
    final m = single.read(projectControllerProvider).mounting;
    final span =
        headFromPressure(const SniProfile().maxFixtureStaticPressure.value)
            .meters;
    expect(singleDatum - b.fixtureElevationOf(15, m).meters,
        lessThanOrEqualTo(span));
    expect(singleDatum - b.fixtureElevationOf(14, m).meters,
        greaterThan(span));
  });

  for (final podium in [false, true]) {
    test('regression-1: duplex outlet boosters == single (podium $podium)',
        () {
      final c = _solve([_tower(duplex: true), if (podium) _podium()]);
      final heads = c.read(downfeedMoverHeadsProvider);
      // The set lifts ONCE: its largest member head, never the sum.
      final setHead = [heads['BP']?.meters ?? 0.0, heads['BQ']?.meters ?? 0.0]
          .reduce((a, b) => a > b ? a : b);
      expect(setHead, greaterThan(15));
      expect(c.read(effectiveDownfeedDatumProvider)!.meters,
          closeTo(70.0 + setHead, 1e-9));
      expect(setHead, closeTo(singleHead, 0.5));
      expect(_spans(c), _expected, reason: 'never the podium L0..L5');
    });
  }

  test('regression-2: a fixture fed straight off the tank never walls BP',
      () {
    final c = _solve([_tower(tx: true)]);
    final h = c.read(downfeedMoverHeadsProvider)['BP']!.meters;
    expect(c.read(effectiveDownfeedDatumProvider)!.meters,
        closeTo(70.0 + h, 1e-9));
    expect(_spans(c), _expected);
    // The datum per floor: every floor BP serves is lifted; nothing reads
    // the bare tank datum below L19.
    final byFloor = c.read(downfeedDatumByFloorProvider)!;
    for (var f = 6; f <= 19; f++) {
      expect(byFloor[f]!.meters, closeTo(70.0 + h, 1e-9), reason: 'L$f');
    }
  });

  test('regression-3: a hot top fixture off a tank-fed heater == plain', () {
    final c = _solve([_tower(heater: true)]);
    final h = c.read(downfeedMoverHeadsProvider)['BP']!.meters;
    expect(c.read(effectiveDownfeedDatumProvider)!.meters,
        closeTo(70.0 + h, 1e-9));
    expect(_spans(c), _expected);
  });

  test('a gravity-only drawing keeps the bare tank datum', () {
    // No mover: no floor is lifted (byte-identical single datum).
    final c = _solve([
      (
        [
          _n('RT', 0, 0,
              floor: 19, role: NodeRole.plant, c: NodeComponent.roofTank),
          for (var f = 6; f <= 19; f++) ...[
            _n('R$f', 100, 0, floor: f),
            _fix('W$f', 200, 0, f),
          ],
        ],
        [
          _e('rt', 'RT', 'R19'),
          for (var f = 19; f > 6; f--)
            _e('r$f', 'R$f', 'R${f - 1}', k: EdgeKind.riser),
          for (var f = 6; f <= 19; f++) _e('w$f', 'R$f', 'W$f'),
        ],
      ),
    ]);
    expect(c.read(downfeedDatumByFloorProvider), isNull);
    expect(c.read(effectiveDownfeedDatumProvider)!.meters, closeTo(70.0, 1e-9));
  });
}
