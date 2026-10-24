// Round 14 (2026-10-18) — mech-props-3 + regression root-choice findings,
// each pinned with a first-principles derivation and a seeded renaming /
// edge-order property (the round-7 determinism contract):
//   groundtank-rank-inline-tank   a terminus GWT beats an inline treated GWT;
//   recirc-pump-root              an inline recirc pump never roots the ring;
//   inline-booster-fan-phantom    an inline booster / fan is pass-through;
//   sump-ejector-outfall          an ejector pit is pass-through on drainage;
//   parallel-sources-by-id        a peer source's bridge mirrors the set flow;
//   dutystandby parallel legs     standby legs are recorded as non-delivery.
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart' as drain;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? component,
        FlowRate? airflow}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: y,
      floorIndex: floor,
      role: role,
      component: component,
      airflow: airflow,
    );

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

double _curve(double ubap) => const SniProfile()
    .probableFlowForFixtureUnits(ubap)
    .inLitersPerSecond;

/// A random renaming of [ids] — ids drawn so that string order differs from
/// the logical order (`n10` < `n9`), seeded.
Map<String, String> _rename(List<String> ids, int seed) {
  final rnd = math.Random(seed);
  final names = [
    for (var i = 0; i < ids.length; i++) 'n${rnd.nextInt(90) + 1}x$i',
  ]..shuffle(rnd);
  return {for (var i = 0; i < ids.length; i++) ids[i]: names[i]};
}

List<T> _shuffled<T>(List<T> xs, int seed) =>
    [...xs]..shuffle(math.Random(seed));

void main() {
  group('groundtank-rank — a terminus GWT beats an INLINE treated GWT', () {
    // RAW (GWT, degree 1) → F (filter) → CLN (GWT, degree 2) → P (booster)
    // → H → 4 fixtures × 20 UBAP. The transfer main rf / fc carries the whole
    // building draw: curve(80 UBAP), flowing FROM the raw tank.
    const ids = ['RAW', 'F', 'CLN', 'P', 'H', 'f0', 'f1', 'f2', 'f3'];
    Network build(Map<String, String> r) {
      String m(String id) => r[id] ?? id;
      return Network(nodes: [
        _n(m('RAW'), 0, 0,
            role: NodeRole.plant, component: NodeComponent.groundTank),
        _n(m('F'), 40, 0, component: NodeComponent.strainer),
        _n(m('CLN'), 80, 0,
            role: NodeRole.plant, component: NodeComponent.groundTank),
        _n(m('P'), 120, 0, role: NodeRole.plant, component: NodeComponent.pump),
        _n(m('H'), 160, 0),
        for (var i = 0; i < 4; i++)
          _n(m('f$i'), 200, i * 30.0, role: NodeRole.fixture),
      ], edges: [
        _e('rf', m('RAW'), m('F'), ServiceType.coldWater),
        _e('fc', m('F'), m('CLN'), ServiceType.coldWater),
        _e('cp', m('CLN'), m('P'), ServiceType.coldWater),
        _e('ph', m('P'), m('H'), ServiceType.coldWater),
        for (var i = 0; i < 4; i++)
          _e('b$i', m('H'), m('f$i'), ServiceType.coldWater),
      ]);
    }

    Map<String, EdgeSizing> size(Network net) => autoSizeNetwork(net,
        const SizingContext(),
        leafDemand: const {ServiceType.coldWater: FlowRate(0)},
        leafFixtureUnits: const {ServiceType.coldWater: 20.0});

    test('rf / fc carry curve(80) from RAW under ANY node ids (seeded)', () {
      // curve(80) = 2.553 L/s (flush-tank branch of Gambar 1).
      final set = _curve(80);
      expect(set, closeTo(2.553, 5e-4));
      for (var seed = 0; seed < 30; seed++) {
        final r = seed == 0 ? {'CLN': 'n10', 'RAW': 'n9'} : _rename(ids, seed);
        final net = build(r);
        final s = size(
            Network(nodes: net.nodes, edges: _shuffled(net.edges, seed)));
        for (final id in ['rf', 'fc', 'cp', 'ph']) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(set, 1e-9),
              reason: 'seed $seed edge $id');
        }
        expect(s['rf']!.flowFromId, r['RAW'] ?? 'RAW', reason: 'seed $seed');
      }
    });
  });

  group('recirc-pump-root — the heater, never the recirc pump, roots', () {
    // H (component-less plant) → S0 → riser S1..S4, fixtures fx1..fx4 × 2
    // UBAP; S4 → R4 … R0 → RP (recirc pump) → CV → H. The CV passes toward
    // H (a return valve) ⇒ the return is a zero-draw-off branch and the supply
    // main hs carries the full curve(8 UBAP).
    const ids = ['H', 'S0', 'S1', 'S2', 'S3', 'S4', 'R0', 'R1', 'R2', 'R3',
        'R4', 'RP', 'CV', 'fx1', 'fx2', 'fx3', 'fx4'];
    Network build(Map<String, String> r) {
      String m(String id) => r[id] ?? id;
      return Network(nodes: [
        _n(m('H'), 0, 0, role: NodeRole.plant),
        for (var f = 0; f <= 4; f++) _n(m('S$f'), 100, 0, floor: f),
        for (var f = 1; f <= 4; f++)
          _n(m('fx$f'), 200, 0, floor: f, role: NodeRole.fixture),
        for (var f = 0; f <= 4; f++) _n(m('R$f'), 50, 40, floor: f),
        _n(m('RP'), 30, 40, role: NodeRole.plant, component: NodeComponent.pump),
        _n(m('CV'), 10, 40, component: NodeComponent.checkValve),
      ], edges: [
        _e('hs', m('H'), m('S0'), ServiceType.hotWater),
        for (var f = 1; f <= 4; f++) ...[
          _e('s$f', m('S${f - 1}'), m('S$f'), ServiceType.hotWater,
              kind: EdgeKind.riser),
          _e('b$f', m('S$f'), m('fx$f'), ServiceType.hotWater),
        ],
        _e('top', m('S4'), m('R4'), ServiceType.hotWater),
        for (var f = 4; f >= 1; f--)
          _e('r$f', m('R$f'), m('R${f - 1}'), ServiceType.hotWater,
              kind: EdgeKind.riser),
        _e('rp', m('R0'), m('RP'), ServiceType.hotWater),
        _e('pc', m('RP'), m('CV'), ServiceType.hotWater),
        _e('ch', m('CV'), m('H'), ServiceType.hotWater),
      ]);
    }

    Map<String, EdgeSizing> size(Network net) => autoSizeNetwork(net,
        const SizingContext(),
        leafDemand: const {ServiceType.hotWater: FlowRate(0)},
        leafFixtureUnits: const {ServiceType.hotWater: 2.0});

    test('hs = curve(8) and the return carries no draw-off, any ids', () {
      final full = _curve(8);
      for (var seed = 0; seed < 30; seed++) {
        final r = seed == 0 ? {'H': 'WH', 'RP': 'P'} : _rename(ids, seed);
        final s = size(build(r));
        expect(s['hs']!.flow.inLitersPerSecond, closeTo(full, 1e-9),
            reason: 'seed $seed (was 0.176 L/s DN15 when the pump rooted)');
        expect(s['hs']!.flowFromId, r['H'] ?? 'H', reason: 'seed $seed');
        expect(s['top']?.flow.inLitersPerSecond ?? 0, 0.0,
            reason: 'seed $seed');
      }
    });
  });

  group('inline-booster-fan-phantom — an inline mover is pass-through', () {
    test('PDAM → WM → booster → HDR: suction carries curve(20) toward B', () {
      final net = Network(nodes: [
        _n('PDAM', 0, 0),
        _n('WM', 40, 0, component: NodeComponent.waterMeter),
        _n('B', 80, 0,
            role: NodeRole.plant, component: NodeComponent.boosterSet),
        _n('HDR', 120, 0),
        for (var i = 0; i < 10; i++)
          _n('f$i', 200, i * 20.0, role: NodeRole.fixture),
      ], edges: [
        _e('in', 'PDAM', 'WM', ServiceType.coldWater),
        _e('wb', 'WM', 'B', ServiceType.coldWater),
        _e('bh', 'B', 'HDR', ServiceType.coldWater),
        for (var i = 0; i < 10; i++)
          _e('b$i', 'HDR', 'f$i', ServiceType.coldWater),
      ]);
      final s = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.coldWater: 2.0});
      // 10 × 2 UBAP = 20 UBAP → curve(20) on every edge between the PDAM
      // connection and the header (was in/wb = 2 UBAP phantom, reversed).
      final q = _curve(20);
      for (final id in ['in', 'wb', 'bh']) {
        expect(s[id]!.flow.inLitersPerSecond, closeTo(q, 1e-9), reason: id);
      }
      expect(s['in']!.flowFromId, 'PDAM');
      expect(s['wb']!.flowFromId, 'WM');
      expect(s['in']!.diameter.inMillimeters, s['bh']!.diameter.inMillimeters);
    });

    test('4 grilles → J → inline exhaust fan → louvre: discharge carries 0.4',
        () {
      const q = FlowRate(0.1);
      final net = Network(nodes: [
        for (var i = 0; i < 4; i++)
          _n('g$i', 0, i * 30.0,
              role: NodeRole.fixture,
              component: NodeComponent.exhaustGrille,
              airflow: q),
        _n('J', 60, 45),
        _n('F', 120, 45,
            role: NodeRole.plant, component: NodeComponent.exhaustFan),
        _n('L', 180, 45),
      ], edges: [
        for (var i = 0; i < 4; i++) _e('g$i', 'g$i', 'J', ServiceType.exhaust),
        _e('jf', 'J', 'F', ServiceType.exhaust),
        _e('fl', 'F', 'L', ServiceType.exhaust),
      ]);
      final s = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.exhaust: FlowRate(0.03)},
          nodeFlowDemand: {for (var i = 0; i < 4; i++) 'g$i': q});
      // Σ 4 × 0.1 = 0.4 m³/s through the fan AND out of its discharge (was
      // 0.03 m³/s — the louvre leaf's phantom grille default — on fl).
      expect(s['jf']!.flow.cubicMetersPerSecond, closeTo(0.4, 1e-12));
      expect(s['fl']!.flow.cubicMetersPerSecond, closeTo(0.4, 1e-12));
      expect(serviceComponentRoots(net, ServiceType.exhaust,
          demandNodeIds: {'g0', 'g1', 'g2', 'g3'})['F'], 'L');
    });
  });

  group('sump-ejector-outfall — the ejector pit is pass-through', () {
    // Basement (floor 0): 4 WC × 4 DFU → BJ → SUMP (GWT) → EJ (pump) —riser
    // rm→ GJ (floor 1) + 3 lavatories × 1 DFU → OUT.
    const ids = ['w0', 'w1', 'w2', 'w3', 'BJ', 'SUMP', 'EJ', 'GJ', 'l0', 'l1',
        'l2', 'OUT'];
    Network build(Map<String, String> r) {
      String m(String id) => r[id] ?? id;
      return Network(nodes: [
        for (var i = 0; i < 4; i++)
          _n(m('w$i'), 0, i * 30.0, role: NodeRole.fixture),
        _n(m('BJ'), 60, 45),
        _n(m('SUMP'), 120, 45,
            role: NodeRole.plant, component: NodeComponent.groundTank),
        _n(m('EJ'), 160, 45,
            role: NodeRole.plant, component: NodeComponent.pump),
        _n(m('GJ'), 160, 45, floor: 1),
        for (var i = 0; i < 3; i++)
          _n(m('l$i'), 220, i * 30.0, floor: 1, role: NodeRole.fixture),
        _n(m('OUT'), 300, 45, floor: 1),
      ], edges: [
        for (var i = 0; i < 4; i++)
          _e('w$i', m('w$i'), m('BJ'), ServiceType.drainage),
        _e('bs', m('BJ'), m('SUMP'), ServiceType.drainage),
        _e('se', m('SUMP'), m('EJ'), ServiceType.drainage),
        _e('rm', m('EJ'), m('GJ'), ServiceType.drainage, kind: EdgeKind.riser),
        for (var i = 0; i < 3; i++)
          _e('l$i', m('l$i'), m('GJ'), ServiceType.drainage),
        _e('go', m('GJ'), m('OUT'), ServiceType.drainage),
      ]);
    }

    test('go carries 16 + 3 = 19 DFU toward OUT; nothing drains down', () {
      for (var seed = 0; seed < 20; seed++) {
        final r = seed == 0 ? const <String, String>{} : _rename(ids, seed);
        String m(String id) => r[id] ?? id;
        final dfu = {
          for (var i = 0; i < 4; i++) m('w$i'): 4.0,
          for (var i = 0; i < 3; i++) m('l$i'): 1.0,
        };
        final out = <String, double>{};
        final s = autoSizeNetwork(build(r), const SizingContext(),
            leafDemand: const {}, nodeDrainageUnits: dfu, fixtureUnitsOut: out);
        expect(out['bs'], closeTo(16, 1e-12), reason: 'seed $seed');
        expect(out['se'], closeTo(16, 1e-12), reason: 'seed $seed');
        expect(out['rm'], closeTo(16, 1e-12), reason: 'seed $seed');
        // Was: 2 DFU phantom (DN50) flowing FROM OUT inward.
        expect(out['go'], closeTo(19, 1e-12), reason: 'seed $seed');
        expect(s['go']!.flowFromId, m('GJ'), reason: 'seed $seed');
        expect(s['bs']!.flowFromId, m('BJ'), reason: 'seed $seed');
        expect(s['rm']!.flowFromId, m('EJ'), reason: 'seed $seed');
        // The outfall carries WCs ⇒ at least the branch-table size for 19 DFU
        // and the DN75 WC floor.
        final table = drain.drainDiameterForDfu(19, isStack: false).inMillimeters;
        expect(s['go']!.diameter.inMillimeters,
            greaterThanOrEqualTo(math.max(table, drain.kMinWcDrainMm)),
            reason: 'seed $seed');
      }
    });
  });

  group('parallel-sources-by-id — a peer source mirrors the set flow', () {
    test('two GWT compartments: both suction legs carry curve(12), any ids',
        () {
      const ids = ['TA', 'TB', 'J', 'P', 'H', 'f0', 'f1', 'f2', 'f3', 'f4',
          'f5'];
      for (var seed = 0; seed < 30; seed++) {
        final r = seed == 0
            ? const <String, String>{}
            : seed == 1
                ? {'TA': 'TB', 'TB': 'TA'}
                : _rename(ids, seed);
        String m(String id) => r[id] ?? id;
        final net = Network(nodes: [
          _n(m('TA'), 0, -20,
              role: NodeRole.plant, component: NodeComponent.groundTank),
          _n(m('TB'), 0, 20,
              role: NodeRole.plant, component: NodeComponent.groundTank),
          _n(m('J'), 40, 0),
          _n(m('P'), 80, 0, role: NodeRole.plant, component: NodeComponent.pump),
          _n(m('H'), 120, 0),
          for (var i = 0; i < 6; i++)
            _n(m('f$i'), 200, i * 20.0, role: NodeRole.fixture),
        ], edges: [
          _e('leg1', m('TA'), m('J'), ServiceType.coldWater),
          _e('leg2', m('TB'), m('J'), ServiceType.coldWater),
          _e('jp', m('J'), m('P'), ServiceType.coldWater),
          _e('ph', m('P'), m('H'), ServiceType.coldWater),
          for (var i = 0; i < 6; i++)
            _e('b$i', m('H'), m('f$i'), ServiceType.coldWater),
        ]);
        final legs = <String>{};
        final s = autoSizeNetwork(net, const SizingContext(),
            leafDemand: const {ServiceType.coldWater: FlowRate(0)},
            leafFixtureUnits: const {ServiceType.coldWater: 2.0},
            parallelLegEdgeIdsOut: legs);
        // 6 × 2 = 12 UBAP → curve(12) on BOTH compartment legs.
        for (final id in ['leg1', 'leg2', 'jp']) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(_curve(12), 1e-9),
              reason: 'seed $seed $id');
        }
        expect(s['leg1']!.diameter.inMillimeters,
            s['leg2']!.diameter.inMillimeters,
            reason: 'seed $seed');
        // Each leg flows FROM its own tank; exactly one is a mirrored leg.
        expect(s['leg1']!.flowFromId, m('TA'), reason: 'seed $seed');
        expect(s['leg2']!.flowFromId, m('TB'), reason: 'seed $seed');
        expect(legs.length, 1, reason: 'seed $seed');
        expect(legs.single, anyOf('leg1', 'leg2'));
      }
    });

    test('two AHUs at opposite ends of one supply duct: both legs 0.6 m3/s',
        () {
      const q = FlowRate(0.2);
      for (final swap in [false, true]) {
        final a = swap ? 'AHU2' : 'AHU1', b = swap ? 'AHU1' : 'AHU2';
        final net = Network(nodes: [
          _n(a, 0, 0, role: NodeRole.plant, component: NodeComponent.ahu),
          _n(b, 300, 0, role: NodeRole.plant, component: NodeComponent.ahu),
          _n('J', 150, 0),
          for (var i = 0; i < 3; i++)
            _n('d$i', 150, 40.0 + i * 30,
                role: NodeRole.fixture,
                component: NodeComponent.supplyDiffuser,
                airflow: q),
        ], edges: [
          _e('east', a, 'J', ServiceType.duct),
          _e('west', b, 'J', ServiceType.duct),
          for (var i = 0; i < 3; i++) _e('d$i', 'J', 'd$i', ServiceType.duct),
        ]);
        final s = autoSizeNetwork(net, const SizingContext(),
            leafDemand: const {ServiceType.duct: FlowRate(0.03)},
            nodeFlowDemand: {for (var i = 0; i < 3; i++) 'd$i': q});
        // Σ 3 × 0.2 = 0.6 m³/s on BOTH AHU legs (was 0.6 / unsized by id).
        expect(s['east']!.flow.cubicMetersPerSecond, closeTo(0.6, 1e-12),
            reason: 'swap $swap');
        expect(s['west']!.flow.cubicMetersPerSecond, closeTo(0.6, 1e-12),
            reason: 'swap $swap');
        expect(s['east']!.diameter.inMillimeters,
            s['west']!.diameter.inMillimeters);
      }
    });
  });

  group('duty/standby — the standby legs are recorded as non-delivery', () {
    test('T → P1/P2 → CV1/CV2 → HDR: t2/p2/c2 are the parallel legs', () {
      final net = Network(nodes: [
        _n('T', 0, 0, role: NodeRole.plant, component: NodeComponent.groundTank),
        _n('P1', 40, -20, role: NodeRole.plant, component: NodeComponent.pump),
        _n('P2', 40, 20, role: NodeRole.plant, component: NodeComponent.pump),
        _n('CV1', 80, -20, component: NodeComponent.checkValve),
        _n('CV2', 80, 20, component: NodeComponent.checkValve),
        _n('HDR', 120, 0),
        for (var i = 0; i < 4; i++)
          _n('fx$i', 200, i * 30.0, role: NodeRole.fixture),
      ], edges: [
        _e('t1', 'T', 'P1', ServiceType.coldWater),
        _e('t2', 'T', 'P2', ServiceType.coldWater),
        _e('p1', 'P1', 'CV1', ServiceType.coldWater),
        _e('p2', 'P2', 'CV2', ServiceType.coldWater),
        _e('c1', 'CV1', 'HDR', ServiceType.coldWater),
        _e('c2', 'CV2', 'HDR', ServiceType.coldWater),
        for (var i = 0; i < 4; i++)
          _e('b$i', 'HDR', 'fx$i', ServiceType.coldWater),
      ]);
      final legs = <String>{};
      final units = <String, double>{};
      final s = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.coldWater: 20.0},
          fixtureUnitsOut: units,
          parallelLegEdgeIdsOut: legs);
      expect(legs, {'t2', 'p2', 'c2'});
      // The duty suction t1 alone is the delivery: curve(80) = 2.553 L/s,
      // never curve(80 + 80) = 4.053 L/s.
      expect(units['t1'], closeTo(80, 1e-12));
      expect(s['t1']!.flow.inLitersPerSecond, closeTo(_curve(80), 1e-9));
      expect(_curve(160), closeTo(4.053, 5e-4));
    });
  });
}
