// Round 26 (2026-10-18) — hot-water recirculation:
//
//   ring-index-run-bfs   the index run is a SHORTEST-path (Dijkstra) walk —
//                        renaming edges never changes the return length
//   multi-loop           parallel drawn loops each carry their heat-loss share
//                        of the flow; the head is NOT the full flow pushed
//                        round one loop
//   separate-systems     two heaters are two recirculation systems (two ways)
//   house-gate           no return drawn + developed length <= 15 m ⇒ no
//                        recirculation is assumed (no pump, way, HWR leg)
//   mirrored-return-bom  the ASSUMED DN20 return is taken off, flagged
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/electrical/load_list.dart' show MepLoadSource;
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/hot_water.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';

NetNode _n(String id,
        {double x = 0,
        double y = 0,
        int floor = 0,
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

NetEdge _hw(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.hotWater, kind: k);

Map<String, EdgeSizing> _sizing(Network net, Diameter bore) => {
      for (final e in net.edges)
        e.id: EdgeSizing(
            edgeId: e.id,
            service: ServiceType.hotWater,
            flow: const FlowRate(0.0001),
            diameter: bore,
            velocity: const Velocity(0.2)),
    };

double _j(double qM3s, double lengthM, Diameter d) => headLossHazenWilliams(
        flow: FlowRate(qM3s),
        length: Length(lengthM),
        diameter: d,
        hazenWilliamsC: 150)
    .meters;

void main() {
  // ── ring index run: Dijkstra, never hop order ───────────────────────────
  group('a stub-fed ring: the index run is the shortest-path far node', () {
    // H —10→ F; ring F–P 10, P–O 10, O–Q 40, Q–F 40; a shower off P, O, Q.
    Network ring(List<String> ids) => Network(nodes: [
          _n('H', role: NodeRole.plant),
          _n('F'),
          _n('P'),
          _n('O'),
          _n('Q'),
          for (final j in ['P', 'O', 'Q'])
            _n('S$j', role: NodeRole.fixture, fixture: PlumbingFixture.shower),
        ], edges: [
          _hw('feed', 'H', 'F'),
          _hw(ids[0], 'F', 'P'),
          _hw(ids[1], 'P', 'O'),
          _hw(ids[2], 'O', 'Q'),
          _hw(ids[3], 'Q', 'F'),
          for (final j in ['P', 'O', 'Q']) _hw('x$j', j, 'S$j'),
        ]);
    double lenOf(Network net, NetEdge e) {
      if (e.id == 'feed') return 10;
      if (e.id.startsWith('x')) return 3;
      final ends = {e.fromId, e.toId};
      if (ends.containsAll(['F', 'P']) || ends.containsAll(['P', 'O'])) {
        return 10;
      }
      return 40;
    }

    test('the far node Q sits 50 m from the heater under any edge names', () {
      // Dijkstra: F 10, P 20, O 30, Q = min(10 + 40, 30 + 40) = 50 m.
      final rnd = math.Random(26);
      final base = ['a', 'b', 'c', 'd'];
      for (var t = 0; t < 24; t++) {
        final ids = [...base]..shuffle(rnd);
        final net = ring(ids);
        final loop = hotWaterRecircLoop(net, _sizing(net, const Diameter(0.025)),
            lengthOf: (e) => lenOf(net, e))!;
        expect(loop.drawnLoopLengthM, isNull);
        expect(loop.returnLengthM, closeTo(50, 1e-9), reason: 'ids $ids');
        expect(loop.circulatedLengthM, closeTo(110, 1e-9));
      }
    });
  });

  // ── parallel drawn loops ─────────────────────────────────────────────────
  test('four parallel loops each carry a quarter of the flow on their own '
      'legs; the shared trunk carries it all', () {
    // H —hm 10→ M —s_i 45→ T_i —r_i 45→ J —jh 10→ H, a shower off each T_i.
    final net = Network(nodes: [
      _n('H', role: NodeRole.plant),
      _n('M'),
      _n('J'),
      for (var i = 0; i < 4; i++) ...[
        _n('T$i'),
        _n('S$i', role: NodeRole.fixture, fixture: PlumbingFixture.shower),
      ],
    ], edges: [
      _hw('hm', 'H', 'M'),
      _hw('jh', 'J', 'H'),
      for (var i = 0; i < 4; i++) ...[
        _hw('s$i', 'M', 'T$i'),
        _hw('r$i', 'T$i', 'J'),
        _hw('b$i', 'T$i', 'S$i'),
      ],
    ]);
    double len(NetEdge e) => switch (e.id) {
          'hm' || 'jh' => 10,
          _ when e.id.startsWith('b') => 3,
          _ => 45,
        };
    const bore = Diameter(0.025);
    final loops =
        hotWaterRecircLoops(net, _sizing(net, bore), lengthOf: len);
    expect(loops, hasLength(1));
    final loop = loops.single;
    // Circulated = 20 + 4 × 90 = 380 m; each loop 110 m (drawn).
    expect(loop.circulatedLengthM, closeTo(380, 1e-9));
    expect(loop.drawnLoopLengthM, closeTo(110, 1e-9));
    final d = sizeHotWaterRecirculation(
      heatLoss: heatLossFromLength(loopLength: Length(loop.circulatedLengthM)),
      loopLength: const Length(0),
      returnDiameter: kDefaultRecircReturnDiameter,
      supplyPath: loop.indexPath,
      supplyPathFlowShares: loop.indexFlowShares,
    );
    // Q = 25 × 380 / (1000 × 4186 × 5) = 0.4539 L/s.
    final q = 25 * 380 / (1000 * waterSpecificHeat * 5);
    expect(d.recircFlow.cubicMetersPerSecond, closeTo(q, 1e-12));
    // Equal loops ⇒ equal shares: the 20 m trunk at Q, the 90 m own legs at
    // Q/4 — not J(Q) × 110 m.
    final expected = _j(q, 20, bore) + _j(q / 4, 90, bore);
    expect(d.loopHead.meters, closeTo(expected, 1e-9));
    expect(d.loopHead.meters, lessThan(_j(q, 110, bore) / 3));
  });

  // ── separate systems + the house gate (pure) ─────────────────────────────
  Network wing(String p, {double dx = 0}) => Network(nodes: [
        _n('${p}H', x: dx, role: NodeRole.plant),
        for (var i = 1; i <= 4; i++) ...[
          _n('${p}M$i', x: dx + 1000.0 * i),
          _n('${p}S$i',
              x: dx + 1000.0 * i,
              y: 300,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.shower),
        ],
      ], edges: [
        for (var i = 1; i <= 4; i++) ...[
          _hw('${p}m$i', i == 1 ? '${p}H' : '${p}M${i - 1}', '${p}M$i'),
          _hw('${p}b$i', '${p}M$i', '${p}S$i'),
        ],
      ]);
  Network merge(Network a, Network b) =>
      Network(nodes: [...a.nodes, ...b.nodes], edges: [...a.edges, ...b.edges]);
  double wingLen(NetEdge e) => e.id.contains('b') ? 3 : 10;

  test('two heaters are two systems, each with its own loop', () {
    final a = wing('A');
    final both = merge(a, wing('B', dx: 9000));
    const bore = Diameter(0.020);
    final alone = hotWaterRecircLoops(a, _sizing(a, bore), lengthOf: wingLen);
    final two =
        hotWaterRecircLoops(both, _sizing(both, bore), lengthOf: wingLen);
    expect(alone, hasLength(1));
    expect(two, hasLength(2));
    for (final l in two) {
      // Each wing: 40 m circulated main, the 40 m index run mirrored —
      // Q = 25 × 80 / 20 930 = 0.0956 L/s per wing, never one merged duty.
      expect(l.circulatedLengthM, alone.single.circulatedLengthM);
      expect(l.returnLengthM, alone.single.returnLengthM);
    }
    expect(two.map((l) => l.rootId).toSet(), {'AH', 'BH'});
  });

  test('house gate: developed length <= 15 m assumes no recirculation', () {
    // Heater → 3 m main → sink; the main's end rises 3 m → shower + lavatory
    // (2.7 m branches): farthest fixture = 3 + 3 + 2.7 = 8.7 m ≤ 15 m.
    final house = Network(nodes: [
      _n('H', role: NodeRole.plant),
      _n('M'),
      _n('U', floor: 1),
      _n('K', role: NodeRole.fixture, fixture: PlumbingFixture.kitchenSink),
      _n('SH', floor: 1, role: NodeRole.fixture, fixture: PlumbingFixture.shower),
      _n('LV', floor: 1, role: NodeRole.fixture, fixture: PlumbingFixture.lavatory),
    ], edges: [
      _hw('hm', 'H', 'M'),
      _hw('mk', 'M', 'K'),
      _hw('ru', 'M', 'U', k: EdgeKind.riser),
      _hw('us', 'U', 'SH'),
      _hw('ul', 'U', 'LV'),
    ]);
    double len(NetEdge e) => switch (e.id) {
          'hm' || 'ru' => 3,
          'mk' => 1,
          _ => 2.7,
        };
    final s = _sizing(house, const Diameter(0.015));
    expect(hotWaterRecircLoops(house, s, lengthOf: len), isEmpty);
    // Property: the same tree scaled up crosses the threshold exactly when
    // its developed length does (8.7 × k > 15 ⇔ k > 1.724).
    for (final k in [1.0, 1.5, 1.72, 1.73, 2.0, 5.0]) {
      final loops =
          hotWaterRecircLoops(house, s, lengthOf: (e) => len(e) * k);
      expect(loops.isNotEmpty, 8.7 * k > kRecircMinDevelopedLengthM,
          reason: 'k = $k');
    }
  });

  // ── provider level: ways + the assumed BOM line ──────────────────────────
  ProviderContainer container(Network net) {
    final c = ProviderContainer();
    c.read(projectControllerProvider.notifier)
      ..setFloors([Floor('L0', const Length(3.5)), Floor('L1', const Length(3.5))])
      ..setCalibration('s1', const ScaleCalibration(0.01));
    c.read(networkControllerProvider.notifier).loadNetwork(net);
    return c;
  }

  test('two wings: two recirc ways and two assumed DN20 return lines', () {
    final c = container(merge(wing('A'), wing('B', dx: 9000)));
    addTearDown(c.dispose);
    final systems = c.read(hotWaterRecircSystemsProvider);
    expect(systems, hasLength(2));
    final ways = [
      for (final l in c.read(mepEquipmentLoadsProvider))
        if (l.source == MepLoadSource.hotWaterRecircPump) l.id,
    ]..sort();
    expect(ways, ['hw-recirc-pump', 'hw-recirc-pump-2']);
    final assumed = [
      for (final b in c.read(bomProvider))
        if (b.assumed) b,
    ];
    expect(assumed, hasLength(2));
    for (final b in assumed) {
      expect(b.diameterMm, 20);
      expect(b.tag, 'HWR-ASSUMED');
      // Each wing's index run: 4 × 10 m of main (1000 px at 0.01 m/px) plus
      // the run's vertical leg from the floor-standing heater up to the
      // ceiling main (`runVerticalLeg`: ceiling 3.5 − 0.3 = 3.2 m) = 43.2 m —
      // exactly the return the calculation assumed.
      expect(b.totalLength.meters, closeTo(43.2, 1e-6));
      expect(systems.map((s) => s.assumedReturnLengthM),
          everyElement(closeTo(b.totalLength.meters, 1e-9)));
    }
    expect(c.read(hotWaterAssumedReturnProvider), isTrue);
    expect(
        c.read(componentTakeoffProvider).where((l) => l.assumed), hasLength(2));
  });

  test('a single short wing assumes nothing: no way, no BOM line, no HWR', () {
    // One 4 m main to one shower: 4 m + the 3.2 m rise to the ceiling main
    // + the 3 m branch and its drop to the shower ⇒ well under 15 m.
    final c = container(Network(nodes: [
      _n('H', role: NodeRole.plant),
      _n('M', x: 400),
      _n('S', x: 400, y: 300, role: NodeRole.fixture,
          fixture: PlumbingFixture.shower),
    ], edges: [
      _hw('hm', 'H', 'M'),
      _hw('ms', 'M', 'S'),
    ]));
    addTearDown(c.dispose);
    expect(c.read(hotWaterRecircSystemsProvider), isEmpty);
    expect(c.read(hotWaterRecircProvider), isNull);
    expect(
        c.read(mepEquipmentLoadsProvider)
            .where((l) => l.source == MepLoadSource.hotWaterRecircPump),
        isEmpty);
    expect(c.read(bomProvider).where((b) => b.assumed), isEmpty);
    expect(c.read(hotWaterAssumedReturnProvider), isFalse);
  });
}
