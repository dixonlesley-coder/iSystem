// Round 69 (2026-10-18) — the downfeed tank walk, the PRV zone table and a
// duty / standby outlet booster set, pinned against the solve:
//
//   regression-downfeed-wall-gravity-tap-walls-whole-booster-riser
//       a gravity-only tap on L0 (ground-floor retail on its own drop off
//       the roof tank) never walls the outlet booster that serves L6..L18:
//       the booster set is a WALL only when every floor it alone serves is
//       a floor the tank also reaches without it (the literal floor test).
//   regression-duplex-booster-backwards-standby-collapses-duty
//       a duty / standby pair with the standby drawn riser -> booster ->
//       tank is the SAME set as the correctly drawn pair: same heads, same
//       datum, same zones, the standby leg on the whole set flow, and the
//       top lavatory at the target residual (never a false LOW). The
//       backwards member is named (judge-only).
//   plumbing-hvac-convergence-19-zone-table-top-zone-starts-at-booster-
//   wall-floor
//       the tank-fed top zone opens at the highest floor the tank actually
//       delivers to: a plant floor (no fixture on L24..L27) is no part of
//       the zone, and the zone's top residual is the tank head at that
//       floor's ceiling main.
//
// First principles: 20 storeys x 3.5 m, roof tank RT at the roof 70.0 m; the
// tank-fed zone admits floor f while datum(f) - fixture(f) <= the 392 kPa
// SNI 8153 static limit (39.96 m of head); the PRV zones below hold the
// setpoint at their top ceiling main and admit f while setpoint +
// rho g (ceiling(top) - fixture(f)) <= 392 kPa.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart'
    show headFromPressure, pressureFromHead;
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/zoning.dart' show defaultPrvSetpoint;
import 'package:mechx_engine/sizing/fire_index_friction.dart'
    show moversDrawnBackwards;
import 'package:mechx_engine/sizing/supply_design.dart';
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

NetNode _fix(
  String id,
  double x,
  double y,
  int floor, {
  PlumbingFixture f = PlumbingFixture.lavatory,
}) => _n(id, x, y, floor: floor, role: NodeRole.fixture, fixture: f);

/// RT (L19 roof) -> BP -> R19 .. R6, a lavatory per storey on L6..L19.
/// [tx] a lavatory TX on L19 straight off RT; [gap] a gravity drop
/// RT -> D19 =riser=> D0 -> G0 (a lavatory on L0); [duplex] a standby BQ in
/// parallel, drawn RT -> BQ -> R19, or riser-first R19 -> BQ -> RT when
/// [backwards].
(List<NetNode>, List<NetEdge>) _tower({
  bool tx = false,
  bool gap = false,
  bool duplex = false,
  bool backwards = false,
}) => (
  [
    _n('RT', 0, 0, floor: 19, role: NodeRole.plant, c: NodeComponent.roofTank),
    _n(
      'BP',
      50,
      0,
      floor: 19,
      role: NodeRole.plant,
      c: NodeComponent.boosterSet,
    ),
    if (duplex)
      _n(
        'BQ',
        50,
        40,
        floor: 19,
        role: NodeRole.plant,
        c: NodeComponent.boosterSet,
      ),
    if (tx) _fix('TX', 0, 100, 19),
    if (gap) ...[
      _n('D19', -100, 0, floor: 19),
      _n('D0', -100, 0, floor: 0),
      _fix('G0', -200, 0, 0),
    ],
    for (var f = 6; f <= 19; f++) ...[
      _n('R$f', 100, 0, floor: f),
      _fix('W$f', 200, 0, f),
    ],
  ],
  [
    _e('rt', 'RT', 'BP'),
    _e('bp', 'BP', 'R19'),
    if (duplex)
      if (backwards) ...[
        _e('bq', 'R19', 'BQ'),
        _e('rq', 'BQ', 'RT'),
      ] else ...[
        _e('rq', 'RT', 'BQ'),
        _e('bq', 'BQ', 'R19'),
      ],
    if (tx) _e('tx', 'RT', 'TX'),
    if (gap) ...[
      _e('d1', 'RT', 'D19'),
      _e('d2', 'D19', 'D0', k: EdgeKind.riser),
      _e('d3', 'D0', 'G0'),
    ],
    for (var f = 19; f > 6; f--)
      _e('r$f', 'R$f', 'R${f - 1}', k: EdgeKind.riser),
    for (var f = 6; f <= 19; f++) _e('w$f', 'R$f', 'W$f'),
  ],
);

ProviderContainer _solve(
  List<NetNode> nodes,
  List<NetEdge> edges, {
  int floors = 20,
}) {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(projectControllerProvider.notifier)
    ..setFloors([
      for (var i = 0; i < floors; i++) Floor('L$i', const Length(3.5)),
    ])
    ..setCalibration('s1', const ScaleCalibration(0.01));
  c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
  c
      .read(networkControllerProvider.notifier)
      .loadNetwork(Network(nodes: nodes, edges: edges));
  return c;
}

ProviderContainer _solveTower((List<NetNode>, List<NetEdge>) t) =>
    _solve(t.$1, t.$2);

List<(int, int)> _spans(ProviderContainer c) => [
  for (final z in c.read(zonesProvider)) (z.topFloorIndex, z.bottomFloorIndex),
];

/// The zone table derived from first principles (no engine call): the
/// tank-fed zone from [top] while datum(f) - fixture(f) <= the limit head,
/// then PRV zones on the setpoint budget down to [low].
List<(int, int)> _derive(
  ProviderContainer c,
  double Function(int f) datum, {
  required int top,
  required int low,
}) {
  final b = c.read(projectControllerProvider).building;
  final m = c.read(projectControllerProvider).mounting;
  final limit = const SniProfile().maxFixtureStaticPressure.value;
  final limitHead = headFromPressure(limit).meters;
  final setpoint = defaultPrvSetpoint(
    targetResidual:
        SupplyDesignCriteria.recommended().targetFixtureResidualPressure,
    maxFixtureStatic: limit,
  );
  final prvHead = headFromPressure(
    Pressure(limit.pascals - setpoint.pascals),
  ).meters;
  final out = <(int, int)>[];
  var bottom = top;
  for (var f = top - 1; f >= low; f--) {
    if (datum(f) - b.fixtureElevationOf(f, m).meters > limitHead) break;
    bottom = f;
  }
  out.add((top, bottom));
  var zoneTop = bottom - 1;
  for (var f = zoneTop; f >= low; f--) {
    final span =
        b.ceilingElevationOf(zoneTop, m).meters -
        b.fixtureElevationOf(f, m).meters;
    if (span > prvHead && f < zoneTop) {
      out.add((zoneTop, f + 1));
      zoneTop = f;
    }
    if (f == low) out.add((zoneTop, low));
  }
  return out;
}

void main() {
  group('finding 1: a gravity tap on L0 never walls the outlet booster', () {
    for (final tx in [false, true]) {
      test('gap tap (TX $tx): L6..L19 on 70 + h, L0..L5 on the bare 70 m', () {
        final c = _solveTower(_tower(gap: true, tx: tx));
        final h = c.read(downfeedMoverHeadsProvider)['BP']!.meters;
        expect(h, greaterThan(15));
        final byFloor = c.read(downfeedDatumByFloorProvider);
        expect(byFloor, isNotNull, reason: 'BP is pipe, never a wall');
        // Floors BP alone serves carry its head; L0..L5 (G0's gravity drop,
        // and the storeys the riser only passes) the bare tank datum.
        for (var f = 0; f < 20; f++) {
          expect(
            byFloor![f]!.meters,
            closeTo(f >= 6 ? 70.0 + h : 70.0, 1e-9),
            reason: 'L$f',
          );
        }
        expect(
          c.read(effectiveDownfeedDatumProvider)!.meters,
          closeTo(70.0 + h, 1e-9),
        );
        final expected = _derive(
          c,
          (f) => f >= 6 ? 70.0 + h : 70.0,
          top: 19,
          low: 0,
        );
        expect(expected, const [(19, 15), (14, 11), (10, 7), (6, 3), (2, 0)]);
        expect(_spans(c), expected);
        // The tank-fed top zone's residual is the BOOSTED datum's head.
        final statics = c.read(zoneStaticsProvider);
        expect(statics.first.viaPrv, isFalse);
        expect(statics.first.topResidual.pascals, greaterThan(150000));
        for (final z in statics) {
          expect(z.withinLimit, isTrue, reason: '${z.zone}');
        }
      });
    }

    test('a booster whose floors the tank also reaches stays a wall', () {
      // A side-branch booster BS off RT serving only L19 (where TX is fed
      // straight off the tank): its served floor set {19} is tank-reached,
      // so it is a wall and lifts nothing.
      final c = _solve(
        [
          _n(
            'RT',
            0,
            0,
            floor: 19,
            role: NodeRole.plant,
            c: NodeComponent.roofTank,
          ),
          _n(
            'BS',
            0,
            50,
            floor: 19,
            role: NodeRole.plant,
            c: NodeComponent.boosterSet,
          ),
          _fix('S19', 0, 100, 19, f: PlumbingFixture.shower),
          _fix('TX', 50, 0, 19),
          for (var f = 6; f <= 19; f++) ...[
            _n('G$f', 100, 0, floor: f),
            _fix('W$f', 200, 0, f),
          ],
        ],
        [
          _e('bs1', 'RT', 'BS'),
          _e('bs2', 'BS', 'S19'),
          _e('tx', 'RT', 'TX'),
          _e('g', 'RT', 'G19'),
          for (var f = 19; f > 6; f--)
            _e('g$f', 'G$f', 'G${f - 1}', k: EdgeKind.riser),
          for (var f = 6; f <= 19; f++) _e('w$f', 'G$f', 'W$f'),
        ],
      );
      expect(c.read(downfeedDatumByFloorProvider), isNull);
      expect(
        c.read(effectiveDownfeedDatumProvider)!.meters,
        closeTo(70.0, 1e-9),
      );
    });
  });

  group('finding 2: a backwards-drawn standby is the same duplex set', () {
    late ProviderContainer ok;
    setUp(() => ok = _solveTower(_tower(duplex: true)));

    test('backwards standby == the correctly drawn duplex', () {
      final c = _solveTower(_tower(duplex: true, backwards: true));
      final okHeads = ok.read(downfeedMoverHeadsProvider);
      final heads = c.read(downfeedMoverHeadsProvider);
      double setHead(Map<String, Head> m) =>
          [m['BP']?.meters ?? 0.0, m['BQ']?.meters ?? 0.0].reduce(math.max);
      expect(setHead(okHeads), greaterThan(15));
      expect(setHead(heads), closeTo(setHead(okHeads), 1e-6));
      expect(c.read(transferPumpNodeIdsProvider), isEmpty);
      expect(
        c.read(effectiveDownfeedDatumProvider)!.meters,
        closeTo(70.0 + setHead(okHeads), 1e-6),
      );
      expect(_spans(c), _spans(ok));
      expect(_spans(c), const [(19, 15), (14, 11), (10, 7), (6, 6)]);
      // The standby leg carries the whole set flow (the duty unit isolated),
      // in the pump direction RT -> BQ -> R19, on the duty leg's bore.
      final sz = c.read(sizingProvider);
      final okSz = ok.read(sizingProvider);
      for (final id in ['rt', 'bp', 'rq', 'bq']) {
        expect(sz[id], isNotNull, reason: id);
        expect(
          sz[id]!.flow.inLitersPerSecond,
          closeTo(okSz[id]!.flow.inLitersPerSecond, 1e-9),
          reason: id,
        );
        expect(
          sz[id]!.diameter.inMillimeters,
          okSz[id]!.diameter.inMillimeters,
          reason: id,
        );
      }
      expect(sz['rq']!.flowFromId, 'RT');
      expect(sz['bq']!.flowFromId, 'BQ');
      expect(
        sz['rq']!.flow.inLitersPerSecond,
        closeTo(sz['rt']!.flow.inLitersPerSecond, 1e-9),
      );
      // The top lavatory sees the target, never a false LOW.
      final w19 = c.read(residualByNodeProvider)['W19']!.pascals;
      expect(w19, closeTo(ok.read(residualByNodeProvider)['W19']!.pascals, 1));
      expect(w19, greaterThan(pressureFromHead(const Head(5)).pascals));
      // Judge-only: the backwards member is named, the correct drawing is
      // silent.
      bool named(ProviderContainer x, String id) => x
          .read(designIssuesProvider)
          .any((i) => i.kind == 'parallel-pump-drawn-backwards:$id');
      expect(named(c, 'BQ'), isTrue);
      expect(named(c, 'BP'), isFalse);
      expect(named(ok, 'BQ'), isFalse);
    });

    test(
      'seeded property: flipping any parallel member never moves the set',
      () {
        final base = _spans(ok);
        final baseHead = ok
            .read(downfeedMoverHeadsProvider)
            .values
            .map((h) => h.meters)
            .reduce(math.max);
        final rnd = math.Random(69);
        for (var trial = 0; trial < 12; trial++) {
          final t = _tower(duplex: true);
          // Flip the drawn direction of each pump leg (both its pipes) at
          // random, then shuffle the lists.
          final flipBp = rnd.nextBool(), flipBq = rnd.nextBool();
          NetEdge flip(NetEdge e) => NetEdge(
            id: e.id,
            fromId: e.toId,
            toId: e.fromId,
            service: e.service,
            kind: e.kind,
          );
          final edges = [
            for (final e in t.$2)
              if ((flipBp && (e.id == 'rt' || e.id == 'bp')) ||
                  (flipBq && (e.id == 'rq' || e.id == 'bq')))
                flip(e)
              else
                e,
          ]..shuffle(rnd);
          final nodes = [...t.$1]..shuffle(rnd);
          final c = _solve(nodes, edges);
          final hs = c
              .read(downfeedMoverHeadsProvider)
              .values
              .map((h) => h.meters)
              .toList();
          final both = flipBp && flipBq;
          if (both) {
            // The whole set drawn backwards is a coherent reading (a pump
            // pumping into the tank) — out of scope of this property.
            continue;
          }
          expect(hs, isNotEmpty, reason: 'trial $trial');
          expect(
            hs.reduce(math.max),
            closeTo(baseHead, 1e-6),
            reason: 'trial $trial bp=$flipBp bq=$flipBq',
          );
          expect(_spans(c), base, reason: 'trial $trial');
        }
      },
    );
  });

  group('r2: only a disagreeing set member is named backwards', () {
    // GT -> P -> J -> two lavatories (L0), on a TREE. Drawn forwards or
    // with the pump pipes drawn riser-first (J -> P, P -> GT): a tree
    // ignores drawn direction (Round 15), so both size identically, and a
    // lone pump is no set member — never `parallel-pump-drawn-backwards`.
    (List<NetNode>, List<NetEdge>) lone({required bool backwards}) => (
      [
        _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
        _n('P', 50, 0, role: NodeRole.plant, c: NodeComponent.pump),
        _n('J', 100, 0),
        _fix('L1', 150, 0, 0),
        _fix('L2', 150, 50, 0),
      ],
      [
        if (backwards) ...[
          _e('a', 'P', 'GT'),
          _e('b', 'J', 'P'),
        ] else ...[
          _e('a', 'GT', 'P'),
          _e('b', 'P', 'J'),
        ],
        _e('c', 'J', 'L1'),
        _e('d', 'J', 'L2'),
      ],
    );

    test('a lone backwards pump on a tree is not named', () {
      final f = lone(backwards: false), b = lone(backwards: true);
      final cf = _solve(f.$1, f.$2, floors: 2);
      final cb = _solve(b.$1, b.$2, floors: 2);
      final sf = cf.read(sizingProvider), sb = cb.read(sizingProvider);
      for (final id in ['a', 'b', 'c', 'd']) {
        expect(
          sb[id]!.flow.inLitersPerSecond,
          closeTo(sf[id]!.flow.inLitersPerSecond, 1e-12),
          reason: id,
        );
        expect(sb[id]!.diameter.inMillimeters, sf[id]!.diameter.inMillimeters);
        expect(sb[id]!.flowFromId, sf[id]!.flowFromId, reason: id);
      }
      // Non-vacuous: the drawing-vs-solved judge does list P (the drawn
      // pipes run against the solved flow); only the set filter drops it.
      expect(
        moversDrawnBackwards(
          Network(nodes: b.$1, edges: b.$2),
          sb,
          (s) => s == ServiceType.coldWater,
        ),
        ['P'],
      );
      expect(cb.read(disagreeingSetMoversProvider), isEmpty);
      for (final x in [cf, cb]) {
        expect(
          x
              .read(designIssuesProvider)
              .where((i) => i.kind.startsWith('parallel-pump-drawn-backwards')),
          isEmpty,
        );
      }
    });

    // A single-junction hot-water recirculation loop: heater H -> P -> J,
    // J -> lavatory, and a valveless circulator drawn J -> Pr -> H. On hot
    // water a supply pump and a return circulator between the SAME two
    // junctions read as a disagreeing pair topologically, so the rule is
    // gated off there: the circulator leg stays the drawn return (flow
    // J -> Pr -> H), never a second feed, and Pr is never named.
    test('hot water keeps a single-junction circulator as the return', () {
      NetEdge hw(String id, String a, String b) => NetEdge(
        id: id,
        fromId: a,
        toId: b,
        service: ServiceType.hotWater,
        kind: EdgeKind.run,
      );
      final c = _solve(
        [
          _n('H', 0, 0, role: NodeRole.plant),
          _n('P', 50, 0, role: NodeRole.plant, c: NodeComponent.pump),
          _n('J', 100, 0),
          _fix('L', 150, 0, 0),
          _n('Pr', 50, 50, role: NodeRole.plant, c: NodeComponent.pump),
        ],
        [
          hw('h', 'H', 'P'),
          hw('p', 'P', 'J'),
          hw('l', 'J', 'L'),
          hw('r1', 'J', 'Pr'),
          hw('r2', 'Pr', 'H'),
        ],
        floors: 2,
      );
      final s = c.read(sizingProvider);
      expect(s['r1']!.flowFromId, 'J');
      expect(s['r2']!.flowFromId, 'Pr');
      expect(s['p']!.flowFromId, 'P');
      // The pre-r69 reading: the circulator leg on the r8 balance-against-
      // pump envelope, named on the pump.
      expect(c.read(moverAgainstBalanceProvider), {'Pr'});
      expect(c.read(disagreeingSetMoversProvider), isEmpty);
      expect(
        c
            .read(designIssuesProvider)
            .where((i) => i.kind.startsWith('parallel-pump-drawn-backwards')),
        isEmpty,
      );
    });

    test('the backwards duplex standby is a disagreeing set member', () {
      final c = _solveTower(_tower(duplex: true, backwards: true));
      expect(c.read(disagreeingSetMoversProvider), {'BP', 'BQ'});
    });
  });

  group('finding 4: the tank-fed zone opens at the highest served floor', () {
    test('a plant floor (no fixture on L24..L27) is no part of the zone', () {
      // 28 storeys x 3.5 m, RT at the roof 98.0 m, one gravity riser with a
      // shower on L0..L23.
      final c = _solve(
        [
          _n(
            'RT',
            0,
            0,
            floor: 27,
            role: NodeRole.plant,
            c: NodeComponent.roofTank,
          ),
          for (var f = 0; f <= 27; f++) _n('G$f', 100, 0, floor: f),
          for (var f = 0; f <= 23; f++)
            _fix('X$f', 200, 0, f, f: PlumbingFixture.shower),
        ],
        [
          _e('g', 'RT', 'G27'),
          for (var f = 27; f > 0; f--)
            _e('g$f', 'G$f', 'G${f - 1}', k: EdgeKind.riser),
          for (var f = 0; f <= 23; f++) _e('x$f', 'G$f', 'X$f'),
        ],
        floors: 28,
      );
      final b = c.read(projectControllerProvider).building;
      final m = c.read(projectControllerProvider).mounting;
      expect(
        c.read(effectiveDownfeedDatumProvider)!.meters,
        closeTo(98.0, 1e-9),
      );
      final zones = c.read(zonesProvider);
      expect(zones.first.topFloorIndex, 23);
      expect(_spans(c), _derive(c, (_) => 98.0, top: 23, low: 0));
      final top = c.read(zoneStaticsProvider).first;
      expect(top.viaPrv, isFalse);
      // rho g (98.0 - ceiling(L23)): ~14 m of head, never the ~3 kPa the
      // roof storey's ceiling gave.
      final expectedTop = pressureFromHead(
        Head(98.0 - b.ceilingElevationOf(23, m).meters),
      );
      expect(top.topResidual.pascals, closeTo(expectedTop.pascals, 1e-6));
      expect(top.topResidual.pascals, greaterThan(100000));
    });
  });

  group('fire-convergence-21: a pump room above its suction tank', () {
    // 32 storeys x 3.2 m; a break tank BT on L16; a duty / standby pair on
    // [pumpFloor]; hydrant boxes on L17..L31.
    (List<NetNode>, List<NetEdge>) upper(int pumpFloor) => (
      [
        _n(
          'BT',
          0,
          0,
          floor: 16,
          role: NodeRole.plant,
          c: NodeComponent.groundTank,
        ),
        _n('SH', 50, 0, floor: pumpFloor),
        _n(
          'P3',
          100,
          0,
          floor: pumpFloor,
          role: NodeRole.plant,
          c: NodeComponent.pump,
        ),
        _n(
          'P4',
          100,
          40,
          floor: pumpFloor,
          role: NodeRole.plant,
          c: NodeComponent.pump,
        ),
        _n('DH', 150, 0, floor: pumpFloor),
        for (var f = 17; f <= 31; f++) ...[
          _n('X$f', 200, 0, floor: f),
          _n(
            'B$f',
            260,
            0,
            floor: f,
            role: NodeRole.fixture,
            c: NodeComponent.hydrantBox,
          ),
        ],
      ],
      [
        _e(
          'bt',
          'BT',
          'SH',
          s: ServiceType.fireHydrant,
          k: pumpFloor == 16 ? EdgeKind.run : EdgeKind.riser,
        ),
        _e('s3', 'SH', 'P3', s: ServiceType.fireHydrant),
        _e('s4', 'SH', 'P4', s: ServiceType.fireHydrant),
        _e('d3', 'P3', 'DH', s: ServiceType.fireHydrant),
        _e('d4', 'P4', 'DH', s: ServiceType.fireHydrant),
        _e(
          'dx',
          'DH',
          'X17',
          s: ServiceType.fireHydrant,
          k: pumpFloor == 17 ? EdgeKind.run : EdgeKind.riser,
        ),
        for (var f = 18; f <= 31; f++)
          _e(
            'x$f',
            'X${f - 1}',
            'X$f',
            s: ServiceType.fireHydrant,
            k: EdgeKind.riser,
          ),
        for (var f = 17; f <= 31; f++)
          _e('b$f', 'X$f', 'B$f', s: ServiceType.fireHydrant),
      ],
    );
    ProviderContainer solve(int pumpFloor) {
      final t = upper(pumpFloor);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(projectControllerProvider.notifier)
        ..setFloors([
          for (var i = 0; i < 32; i++) Floor('L$i', const Length(3.2)),
        ])
        ..setCalibration('s1', const ScaleCalibration(0.01));
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(Network(nodes: t.$1, edges: t.$2));
      return c;
    }

    test('the lift is taken from the tank floor; the arrangement is named', () {
      final above = solve(17), beside = solve(16);
      final a = above.read(fireSystemBasesProvider).single;
      final b = beside.read(fireSystemBasesProvider).single;
      // 31 x 3.2 + 1.2 - 16 x 3.2 = 49.2 m from the L16 tank surface.
      expect(b.staticLiftM, closeTo(49.2, 1e-9));
      expect(a.staticLiftM, closeTo(b.staticLiftM, 1e-9));
      bool named(ProviderContainer c) => c
          .read(designIssuesProvider)
          .any((i) => i.kind.startsWith('fire-pump-suction-lift:'));
      expect(named(above), isTrue);
      expect(named(beside), isFalse);
    });
  });
}
