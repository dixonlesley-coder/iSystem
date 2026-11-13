// Backlog G-1 (2026-11-13) — the Hunter demand-curve branch is chosen per
// PIPE: a cold-water pipe reads the flush-VALVE branch only when at least one
// flush-valve fixture is DOWNSTREAM of it (it serves one), otherwise the
// flush-TANK branch. Hand values: tank curve below 10 UBAP = 0.05 L/s per
// UBAP; valve curve 10 → 0.88333, 12 → 0.88333 + 2/15 x 0.63334 = 0.96778.
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const sni = SniProfile();
  double curve(double u, FlushSystem fs) =>
      sni.probableFlowForFixtureUnits(u, system: fs).inLitersPerSecond;

  NetNode n(String id, double x, double y,
          {NodeRole role = NodeRole.main, PlumbingFixture? fx}) =>
      NetNode(
          id: id,
          sheetId: 's1',
          x: x,
          y: y,
          floorIndex: 0,
          role: role,
          fixture: fx);
  NetEdge e(String id, String a, String b) =>
      NetEdge(id: id, fromId: a, toId: b, service: ServiceType.coldWater);

  // P (plant) → J; J → WC (flush valve, 10 UBAP); J → K; K → L1, L2 (1 each).
  Network build({String p = ''}) => Network(nodes: [
        n('${p}P', 0, 0, role: NodeRole.plant),
        n('${p}J', 100, 0),
        n('${p}WC', 200, 0,
            role: NodeRole.fixture, fx: PlumbingFixture.waterClosetFlushValve),
        n('${p}K', 100, 100),
        n('${p}L1', 200, 100,
            role: NodeRole.fixture, fx: PlumbingFixture.lavatory),
        n('${p}L2', 200, 200,
            role: NodeRole.fixture, fx: PlumbingFixture.lavatory),
      ], edges: [
        e('${p}pj', '${p}P', '${p}J'),
        e('${p}jw', '${p}J', '${p}WC'),
        e('${p}jk', '${p}J', '${p}K'),
        e('${p}k1', '${p}K', '${p}L1'),
        e('${p}k2', '${p}K', '${p}L2'),
      ]);

  Map<String, EdgeSizing> size(Network net, {String p = ''}) =>
      autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.coldWater: 1.0},
          nodeFixtureUnits: {'${p}WC': 10.0, '${p}L1': 1.0, '${p}L2': 1.0},
          flushSystem: FlushSystem.flushValve,
          flushValveNodeIds: {'${p}WC'});

  test('pipes serving the WC read the valve curve, the rest the tank curve',
      () {
    final s = size(build());
    // Trunk: 12 UBAP with the WC downstream ⇒ valve 0.96778 L/s.
    expect(s['pj']!.flow.inLitersPerSecond,
        closeTo(curve(12, FlushSystem.flushValve), 1e-12));
    expect(s['pj']!.flow.inLitersPerSecond, closeTo(0.96778, 5e-5));
    expect(s['jw']!.flow.inLitersPerSecond, closeTo(0.88333, 5e-5));
    // The lavatory sub-branch serves no flush valve: 2 x 0.05 = 0.1 L/s
    // (the valve curve would read 0.17667).
    expect(s['jk']!.flow.inLitersPerSecond, closeTo(0.1, 1e-12));
    expect(s['k1']!.flow.inLitersPerSecond, closeTo(0.05, 1e-12));
    expect(s['k2']!.flow.inLitersPerSecond, closeTo(0.05, 1e-12));
    expect(s['k1']!.diameter.inMillimeters, 15);
    expect(s['k1']!.velocity.metersPerSecond, closeTo(0.283, 5e-4));
  });

  test('order-independent: shuffled lists and renamed ids give equal sizes',
      () {
    final base = size(build());
    final rnd = math.Random(7);
    for (var t = 0; t < 12; t++) {
      final p = 'x$t-';
      final net = build(p: p);
      final shuffled = Network(
          nodes: [...net.nodes]..shuffle(rnd),
          edges: [...net.edges]..shuffle(rnd));
      final s = size(shuffled, p: p);
      for (final id in base.keys) {
        expect(s['$p$id']!.flow.inLitersPerSecond,
            closeTo(base[id]!.flow.inLitersPerSecond, 1e-12),
            reason: '$p$id');
        expect(s['$p$id']!.diameter.inMillimeters,
            base[id]!.diameter.inMillimeters);
      }
    }
  });

  test('no flush-valve node set ⇒ the single project curve (legacy)', () {
    final s = autoSizeNetwork(build(), const SizingContext(),
        leafDemand: const {ServiceType.coldWater: FlowRate(0)},
        leafFixtureUnits: const {ServiceType.coldWater: 1.0},
        nodeFixtureUnits: const {'WC': 10.0, 'L1': 1.0, 'L2': 1.0},
        flushSystem: FlushSystem.flushValve);
    expect(s['jk']!.flow.inLitersPerSecond,
        closeTo(curve(2, FlushSystem.flushValve), 1e-12));
  });
}
