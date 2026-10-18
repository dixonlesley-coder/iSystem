// Round 12 (2026-10-18) — mech-props-2 network-sizing findings, each pinned
// with a first-principles derivation and, where it fits, a seeded property:
//   gravity-pump-root       a sump/ejector pump never roots a drainage tree;
//   gravity-loop-unsized    every edge of a gravity loop is sized, order-free;
//   recirc-checkvalve       a check-valved HW return is not a supply path;
//   rain-downpipe-shrinks   a downpipe never necks below its collector;
//   cleanout-leaf-phantom   a cleanout / air vent LEAF carries no load.
// (vent-stack-reverse-taper is re-derived in audit_r7_mech_sizing_test.dart.)
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart' as drain;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/storm_sizing.dart' as storm;
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? component,
        PlumbingFixture? fixture}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: floor,
      role: role,
      component: component,
      fixture: fixture,
    );

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

List<T> _shuffled<T>(List<T> xs, int seed) =>
    [...xs]..shuffle(math.Random(seed));

NetEdge _flip(NetEdge e) => NetEdge(
    id: e.id, fromId: e.toId, toId: e.fromId, service: e.service, kind: e.kind);

void main() {
  group('gravity-pump-root — a sump pump is pass-through, not the outfall', () {
    // Basement fixture bf (6 DFU) → B (floor 0) —riser→ G (floor 1) —bd→ out.
    // A 4-floor stack (4 × 30 DFU) joins at G.
    Network build({required bool pumpAtB}) {
      final nodes = <NetNode>[
        _n('bf', 0, 0, role: NodeRole.fixture),
        pumpAtB
            ? _n('B', 50, 0, role: NodeRole.plant, component: NodeComponent.pump)
            : _n('B', 50, 0),
        _n('G', 50, 0, floor: 1),
        _n('out', 400, 0, floor: 1),
      ];
      final edges = <NetEdge>[
        _e('b0', 'bf', 'B', ServiceType.drainage),
        _e('rB', 'B', 'G', ServiceType.drainage, kind: EdgeKind.riser),
        _e('bd', 'G', 'out', ServiceType.drainage),
      ];
      var below = 'G';
      for (var f = 2; f <= 5; f++) {
        nodes
          ..add(_n('S$f', 50, 0, floor: f))
          ..add(_n('fx$f', 100, 0, floor: f, role: NodeRole.fixture));
        edges
          ..add(_e('s$f', below, 'S$f', ServiceType.drainage,
              kind: EdgeKind.riser))
          ..add(_e('fb$f', 'S$f', 'fx$f', ServiceType.drainage));
        below = 'S$f';
      }
      return Network(nodes: nodes, edges: edges);
    }

    final dfu = {'bf': 6.0, for (var f = 2; f <= 5; f++) 'fx$f': 30.0};
    Map<String, EdgeSizing> size(Network net) => autoSizeNetwork(net,
        const SizingContext(),
        leafDemand: const {}, nodeDrainageUnits: dfu);

    test('the building drain carries 6 + 4×30 = 126 DFU → DN100 either way',
        () {
      // Branch table row (21, 160] → DN100.
      expect(drain.drainDiameterForDfu(126, isStack: false).inMillimeters, 100);
      for (final pump in [false, true]) {
        final s = size(build(pumpAtB: pump));
        expect(s['bd']!.flow, isNotNull);
        expect(s['bd']!.diameter.inMillimeters, 100, reason: 'pump=$pump');
        // Drainage flows FROM G toward the outfall (never reversed).
        expect(s['bd']!.flowFromId, 'G', reason: 'pump=$pump');
        // The pump's discharge riser carries only the basement 6 DFU.
        expect(s['rB']!.flowFromId, 'B', reason: 'pump=$pump');
      }
    });

    test('property: any edge order roots at the outfall (seeded)', () {
      final net = build(pumpAtB: true);
      final ref = size(net);
      for (var seed = 0; seed < 25; seed++) {
        final r = math.Random(seed);
        final edges = [
          for (final e in _shuffled(net.edges, seed))
            r.nextBool() ? _flip(e) : e,
        ];
        final s = size(Network(nodes: net.nodes, edges: edges));
        for (final id in ref.keys) {
          expect(s[id]!.diameter.inMillimeters,
              ref[id]!.diameter.inMillimeters,
              reason: 'seed $seed edge $id');
        }
      }
    });
  });

  group('gravity-loop-unsized — a two-downpipe gutter is fully sized', () {
    // Roof drains on C0..C3 (floor 3, 1.5 L/s each), downpipes dpA (C0→G0)
    // and dpB (C3→G3), ground run gg (G3→G0) → go (G0→out).
    Network build() => Network(
          nodes: [
            for (var i = 0; i < 4; i++)
              _n('C$i', 100.0 * i, 0,
                  floor: 3,
                  role: NodeRole.fixture,
                  component: NodeComponent.roofDrain),
            _n('G0', 0, 0),
            _n('G3', 300, 0),
            _n('out', -200, 0),
          ],
          edges: [
            _e('c1', 'C0', 'C1', ServiceType.rainwater),
            _e('c2', 'C1', 'C2', ServiceType.rainwater),
            _e('c3', 'C2', 'C3', ServiceType.rainwater),
            _e('dpA', 'C0', 'G0', ServiceType.rainwater, kind: EdgeKind.riser),
            _e('dpB', 'C3', 'G3', ServiceType.rainwater, kind: EdgeKind.riser),
            _e('gg', 'G3', 'G0', ServiceType.rainwater),
            _e('go', 'G0', 'out', ServiceType.rainwater),
          ],
        );
    Map<String, EdgeSizing> size(Network net) => autoSizeNetwork(
        net, const SizingContext(),
        leafDemand: const {ServiceType.rainwater: FlowRate(0.0015)});

    test('every drawn edge is sized and the outfall carries all 6.0 L/s', () {
      final s = size(build());
      for (final e in build().edges) {
        expect(s.containsKey(e.id), isTrue, reason: '${e.id} unsized');
      }
      // Continuity at the outfall: 4 × 1.5 = 6.0 L/s.
      expect(s['go']!.flow.inLitersPerSecond, closeTo(6.0, 1e-9));
      // Nearest-outlet split (fewest hops to `out`, ties to the lower edge
      // id): C0,C1,C2 drain via dpA (4.5 L/s), C3 via dpB (1.5 L/s); the
      // closing gutter edge c3 carries the larger adjacent load (1.5 L/s)
      // and is flagged provisional. Both downpipes carry flow.
      expect(s['dpA']!.flow.inLitersPerSecond, closeTo(4.5, 1e-9));
      expect(s['dpB']!.flow.inLitersPerSecond, closeTo(1.5, 1e-9));
      expect(
          s['dpA']!.flow.inLitersPerSecond + s['dpB']!.flow.inLitersPerSecond,
          closeTo(6.0, 1e-9));
      expect(s['c3']!.loopUnbalanced, isTrue);
      expect(s['c3']!.flow.inLitersPerSecond, closeTo(1.5, 1e-9));
      expect(s['dpA']!.loopUnbalanced, isFalse);
    });

    test('property: identical sizes under any edge order / direction', () {
      final net = build();
      final ref = size(net);
      for (var seed = 0; seed < 40; seed++) {
        final r = math.Random(seed);
        final edges = [
          for (final e in _shuffled(net.edges, seed))
            r.nextBool() ? _flip(e) : e,
        ];
        final s = size(Network(nodes: net.nodes, edges: edges));
        expect(s.keys.toSet(), ref.keys.toSet(), reason: 'seed $seed');
        for (final id in ref.keys) {
          expect(s[id]!.flow.inLitersPerSecond,
              closeTo(ref[id]!.flow.inLitersPerSecond, 1e-12),
              reason: 'seed $seed edge $id');
          expect(s[id]!.diameter.inMillimeters,
              ref[id]!.diameter.inMillimeters,
              reason: 'seed $seed edge $id');
        }
      }
    });
  });

  group('recirc-checkvalve — the HW return is not a parallel supply path', () {
    // Heater/pump H → S0..S4 supply riser with a 2-UBAP fixture at S1..S4 →
    // top link S4–R4 → return riser R4..R0 → check valve CV → H.
    Network build({required bool withReturn}) {
      final nodes = <NetNode>[
        _n('H', 0, 0, role: NodeRole.plant, component: NodeComponent.pump),
        for (var f = 0; f <= 4; f++) _n('S$f', 100, 0, floor: f),
        for (var f = 1; f <= 4; f++)
          _n('fx$f', 200, 0, floor: f, role: NodeRole.fixture),
        if (withReturn) ...[
          for (var f = 0; f <= 4; f++) _n('R$f', 50, 0, floor: f),
          _n('CV', 20, 0, component: NodeComponent.checkValve),
        ],
      ];
      final edges = <NetEdge>[
        _e('hs', 'H', 'S0', ServiceType.hotWater),
        for (var f = 1; f <= 4; f++) ...[
          _e('s$f', 'S${f - 1}', 'S$f', ServiceType.hotWater,
              kind: EdgeKind.riser),
          _e('b$f', 'S$f', 'fx$f', ServiceType.hotWater),
        ],
        if (withReturn) ...[
          _e('top', 'S4', 'R4', ServiceType.hotWater),
          for (var f = 4; f >= 1; f--)
            _e('r$f', 'R$f', 'R${f - 1}', ServiceType.hotWater,
                kind: EdgeKind.riser),
          _e('rc', 'R0', 'CV', ServiceType.hotWater),
          _e('ch', 'CV', 'H', ServiceType.hotWater),
        ],
      ];
      return Network(nodes: nodes, edges: edges);
    }

    Map<String, EdgeSizing> size(Network net) => autoSizeNetwork(
          net,
          const SizingContext(),
          leafDemand: const {ServiceType.hotWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.hotWater: 2.0},
        );

    test('the supply main carries curve(8 UBAP) = 0.400 L/s with the return',
        () {
      // Flush-tank Gambar 1 segment 0→10 UBAP: 8/10 × 0.5 = 0.400 L/s.
      final expected = const SniProfile()
          .probableFlowForFixtureUnits(8)
          .inLitersPerSecond;
      expect(expected, closeTo(0.400, 1e-9));
      final open = size(build(withReturn: false));
      final closed = size(build(withReturn: true));
      expect(open['hs']!.flow.inLitersPerSecond, closeTo(expected, 1e-9));
      expect(closed['hs']!.flow.inLitersPerSecond, closeTo(expected, 1e-9));
      expect(closed['hs']!.diameter.inMillimeters,
          open['hs']!.diameter.inMillimeters);
      // s2 carries the 3 fixtures above it: curve(6) = 6/10 × 0.5 = 0.300.
      expect(closed['s2']!.flow.inLitersPerSecond, closeTo(0.300, 1e-9));
      // No draw-off is routed through the check valve (both its edges 0).
      expect(closed['ch']!.flow.inLitersPerSecond, closeTo(0, 1e-12));
      expect(closed['rc']!.flow.inLitersPerSecond, closeTo(0, 1e-12));
      expect(closed['hs']!.loopUnbalanced, isFalse);
    });

    test('property: any edge order keeps the full supply flow (seeded)', () {
      final net = build(withReturn: true);
      for (var seed = 0; seed < 20; seed++) {
        final s = size(Network(nodes: net.nodes, edges: _shuffled(net.edges, seed)));
        expect(s['hs']!.flow.inLitersPerSecond, closeTo(0.400, 1e-9),
            reason: 'seed $seed');
      }
    });
  });

  test('rain-downpipe-shrinks — a downpipe is never smaller than its collector',
      () {
    // 4 roof drains × 0.8 L/s on a roof collector → one downpipe → ground run.
    final net = Network(
      nodes: [
        for (var i = 0; i < 4; i++)
          _n('rd$i', 100.0 * i, 0,
              floor: 3,
              role: NodeRole.fixture,
              component: NodeComponent.roofDrain),
        _n('top', 400, 0, floor: 3),
        _n('base', 400, 0),
        _n('out', 800, 0),
      ],
      edges: [
        for (var i = 0; i < 3; i++)
          _e('c$i', 'rd$i', 'rd${i + 1}', ServiceType.rainwater),
        _e('c3', 'rd3', 'top', ServiceType.rainwater),
        _e('dp', 'top', 'base', ServiceType.rainwater, kind: EdgeKind.riser),
        _e('go', 'base', 'out', ServiceType.rainwater),
      ],
    );
    final s = autoSizeNetwork(net, const SizingContext(),
        leafDemand: const {ServiceType.rainwater: FlowRate(0.0008)});
    // The downpipe's own table pick at 3.2 L/s is DN65 (row 3.4 L/s) …
    expect(
        storm.sizeRainwaterDownpipe(const FlowRate(0.0032))
            .diameter
            .inMillimeters,
        65);
    // … but the collector c3 (3.2 L/s, Manning) discharges into it.
    final collector = s['c3']!.diameter.inMillimeters;
    expect(collector, greaterThan(65));
    expect(s['dp']!.diameter.inMillimeters, greaterThanOrEqualTo(collector));
    expect(s['dp']!.stackRaisedForBranch, isTrue);
    // Property: the diameter never decreases in the direction of flow.
    expect(s['go']!.diameter.inMillimeters,
        greaterThanOrEqualTo(s['dp']!.diameter.inMillimeters - 1e-9));
  });

  group('cleanout-leaf-phantom — a non-demand LEAF carries no load', () {
    test('a cleanout at the head of a drain adds 0 DFU', () {
      Network build({required bool cleanout}) => Network(
            nodes: [
              _n('lav', 0, 0, role: NodeRole.fixture),
              _n('J', 100, 0),
              _n('out', 300, 0),
              if (cleanout)
                _n('co', 100, 50,
                    role: NodeRole.fixture, component: NodeComponent.cleanout),
            ],
            edges: [
              _e('a', 'lav', 'J', ServiceType.drainage),
              _e('b', 'J', 'out', ServiceType.drainage),
              if (cleanout) _e('c', 'J', 'co', ServiceType.drainage),
            ],
          );
      final out = <String, double>{};
      autoSizeNetwork(build(cleanout: true), const SizingContext(),
          leafDemand: const {},
          nodeDrainageUnits: const {'lav': 1.0},
          fixtureUnitsOut: out);
      // The main carries only the lavatory: 1 DFU → DN40 (not 3 DFU → DN50).
      expect(out['b'], closeTo(1.0, 1e-12));
      expect(out['c'], closeTo(0.0, 1e-12));
    });

    test('an air vent at a cold-water riser top adds 0 UBAP', () {
      final net = Network(
        nodes: [
          _n('P', 0, 0, role: NodeRole.plant, component: NodeComponent.pump),
          _n('J', 0, 0, floor: 1),
          _n('fx', 100, 0, floor: 1, role: NodeRole.fixture),
          _n('av', 0, 0,
              floor: 2, role: NodeRole.fixture, component: NodeComponent.airVent),
        ],
        edges: [
          _e('r1', 'P', 'J', ServiceType.coldWater, kind: EdgeKind.riser),
          _e('b', 'J', 'fx', ServiceType.coldWater),
          _e('r2', 'J', 'av', ServiceType.coldWater, kind: EdgeKind.riser),
        ],
      );
      final out = <String, double>{};
      autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.coldWater: 2.0},
          fixtureUnitsOut: out);
      // r1 carries the one fixture's 2 UBAP, not 2 + a phantom 2.
      expect(out['r1'], closeTo(2.0, 1e-12));
    });
  });
}
