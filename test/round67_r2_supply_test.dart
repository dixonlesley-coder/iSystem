// Round 67 r2 (2026-10-18) — reviewer follow-ups on the second-supply-network
// and phantom-PRV-zone fixes.
//
//   1. zonesProvider: a booster at the roof-tank OUTLET (RT -> BP -> riser,
//      the Round-56 datum case) is pipe to the served-floor walk — the whole
//      tank delivery passes it. A tank walk that finds no fixture never falls
//      to floor 0.
//   2. An extra supply component with NO drawn mover keeps its own solve
//      (the assumed pump, the primary convention) — a mains-fed podium reads
//      the same delivered field beside a tower as alone.
//   3. A source-less fragment (fixtures on a bare stub) is never solved: it
//      gets no fabricated zero-head field and never becomes the critical node.
//
// Drawing: 20 storeys of 3.5 m; tower = roof tank RT on L19 -> riser R19..R6,
// one lavatory W6..W19 per storey.
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

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
      id: id,
      fromId: a,
      toId: b,
      service: ServiceType.coldWater,
      kind: k,
    );

NetNode _fix(String id, double x, double y, int floor) => _n(
  id,
  x,
  y,
  floor: floor,
  role: NodeRole.fixture,
  fixture: PlumbingFixture.lavatory,
);

/// The tower; [outletBooster] puts a booster set BP between RT and R19.
(List<NetNode>, List<NetEdge>) _tower({bool outletBooster = false}) => (
  [
    _n('RT', 0, 0, floor: 19, role: NodeRole.plant, c: NodeComponent.roofTank),
    if (outletBooster)
      _n(
        'BP',
        50,
        0,
        floor: 19,
        role: NodeRole.plant,
        c: NodeComponent.boosterSet,
      ),
    for (var f = 6; f <= 19; f++) ...[
      _n('R$f', 100, 0, floor: f),
      _fix('W$f', 200, 0, f),
    ],
  ],
  [
    if (outletBooster) ...[
      _e('rt', 'RT', 'BP'),
      _e('bp', 'BP', 'R19'),
    ] else
      _e('rt', 'RT', 'R19'),
    for (var f = 19; f > 6; f--)
      _e('r$f', 'R$f', 'R${f - 1}', k: EdgeKind.riser),
    for (var f = 6; f <= 19; f++) _e('w$f', 'R$f', 'W$f'),
  ],
);

/// A mains-fed podium: water meter WM -> M0 .. M2, one lavatory per storey.
(List<NetNode>, List<NetEdge>) _podium() => (
  [
    _n('WM', 0, 400, c: NodeComponent.waterMeter),
    for (var f = 0; f <= 2; f++) ...[
      _n('M$f', 100, 400, floor: f),
      _fix('V$f', 200, 400, f),
    ],
  ],
  [
    _e('wm', 'WM', 'M0'),
    for (var f = 1; f <= 2; f++)
      _e('m$f', 'M${f - 1}', 'M$f', k: EdgeKind.riser),
    for (var f = 0; f <= 2; f++) _e('v$f', 'M$f', 'V$f'),
  ],
);

/// A source-less stub on L3: bare junction J with two fixtures.
(List<NetNode>, List<NetEdge>) _stub() => (
  [
    _n('J', 100, 800, floor: 3),
    _fix('U0', 200, 800, 3),
    _fix('U1', 200, 850, 3),
  ],
  [_e('u0', 'J', 'U0'), _e('u1', 'J', 'U1')],
);

ProviderContainer _solve(
  List<(List<NetNode>, List<NetEdge>)> parts,
  FeedStrategy feed,
) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([for (var i = 0; i < 20; i++) Floor('L$i', const Length(3.5))])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(feedStrategyProvider.notifier).set(feed);
  c
      .read(networkControllerProvider.notifier)
      .loadNetwork(
        Network(
          nodes: [for (final p in parts) ...p.$1],
          edges: [for (final p in parts) ...p.$2],
        ),
      );
  return c;
}

List<(int, int)> _spans(ProviderContainer c) => [
  for (final z in c.read(zonesProvider)) (z.topFloorIndex, z.bottomFloorIndex),
];

void main() {
  test('zones: a roof-tank OUTLET booster still serves L6 .. L19', () {
    final c = _solve([_tower(outletBooster: true)], FeedStrategy.downfeed);
    final spans = _spans(c);
    expect(spans, isNotEmpty);
    // The tank's whole delivery passes BP, so the walk reaches W6 .. W19:
    // the lowest served floor is L6, never the floor-0 fallback.
    expect(spans, [(19, 15), (14, 11), (10, 7), (6, 6)]);
    expect(spans.last.$2, 6, reason: '$spans');
    for (final s in spans) {
      expect(s.$2, greaterThanOrEqualTo(6), reason: '$spans');
    }
  });

  group('a mains-fed podium with no drawn mover keeps its own solve', () {
    for (final feed in [FeedStrategy.upfeed, FeedStrategy.downfeed]) {
      test('$feed beside the tower == the podium alone on upfeed', () {
        final aloneRes = _solve([
          _podium(),
        ], FeedStrategy.upfeed).read(residualByNodeProvider);
        expect(aloneRes['V2'], isNotNull);
        final mixed = _solve([_tower(), _podium()], feed);
        final res = mixed.read(residualByNodeProvider);
        for (var f = 0; f <= 2; f++) {
          final a = aloneRes['V$f']!.inKiloPascals;
          expect(a, greaterThan(0));
          expect(res['V$f']!.inKiloPascals, closeTo(a, 1e-6), reason: 'V$f');
        }
        if (feed == FeedStrategy.downfeed) {
          final tower = _solve([_tower()], feed);
          final d = mixed.read(downfeedDeliveredProvider)!;
          final t = tower.read(downfeedDeliveredProvider)!;
          // The podium (held at the target by its assumed pump) never
          // becomes the critical node of the tower's field.
          expect(d.criticalNodeId, t.criticalNodeId);
          expect(
            d.minResidual.inKiloPascals,
            closeTo(t.minResidual.inKiloPascals, 1e-6),
          );
        }
      });
    }
  });

  for (final feed in [FeedStrategy.upfeed, FeedStrategy.downfeed]) {
    test('$feed: a source-less stub is never solved', () {
      final tower = _solve([_tower()], feed);
      final mixed = _solve([_tower(), _stub()], feed);
      expect(mixed.read(extraSupplySourcesProvider), isEmpty);
      final res = mixed.read(residualByNodeProvider);
      expect(res.containsKey('U0'), isFalse);
      expect(res.containsKey('U1'), isFalse);
      if (feed == FeedStrategy.downfeed) {
        expect(
          mixed.read(downfeedDeliveredProvider)!.criticalNodeId,
          tower.read(downfeedDeliveredProvider)!.criticalNodeId,
        );
      }
    });
  }
}
