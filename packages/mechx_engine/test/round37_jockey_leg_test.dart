// Round 37 (2026-10-18) — mech-sim-5-jockey-leg-mirrors-main-pump-bore.
//
// In a parallel fire-pump set (duty / standby / jockey, each behind a check
// valve onto one header) the JOCKEY leg is sized on the jockey's own duty
// flow — never mirrored onto the full set flow — and never ranks as the duty
// leg. Derivation: 0.47 L/s on the 25 mm fire-pipe minimum is
// v = 4Q / (pi D^2) = 4 x 0.47e-3 / (pi x 0.025^2) = 0.96 m/s, well inside the
// 6 m/s fire cap, so the jockey legs are DN25.
import 'dart:math' as math;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's',
        floorIndex: floor,
        x: x,
        y: y,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id,
        fromId: a,
        toId: b,
        service: ServiceType.fireHydrant,
        kind: k);

Network _set(List<String> pumps) {
  final nodes = <NetNode>[
    _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FH', 200, 0),
  ];
  final edges = <NetEdge>[];
  for (var i = 0; i < pumps.length; i++) {
    final p = pumps[i];
    nodes
      ..add(_n(p, 100, 40.0 * i, role: NodeRole.plant, c: NodeComponent.pump))
      ..add(_n('V$p', 150, 40.0 * i, c: NodeComponent.checkValve));
    edges
      ..add(_e('s$p', 'GT', p))
      ..add(_e('p$p', p, 'V$p'))
      ..add(_e('v$p', 'V$p', 'FH'));
  }
  for (var f = 0; f < 4; f++) {
    nodes
      ..add(_n('S$f', 300, 0, floor: f))
      ..add(_n('HB$f', 340, 0,
          floor: f, role: NodeRole.fixture, c: NodeComponent.hydrantBox));
    edges
      ..add(_e('hb$f', 'S$f', 'HB$f'))
      ..add(f == 0 ? _e('h0', 'FH', 'S0') : _e('r$f', 'S${f - 1}', 'S$f',
          k: EdgeKind.riser));
  }
  return Network(nodes: nodes, edges: edges);
}

const _jockey = FlowRate(0.00047);

void main() {
  test('the derivation: 0.47 L/s at DN25 is 0.96 m/s', () {
    expect(4 * 0.47e-3 / (math.pi * 0.025 * 0.025), closeTo(0.96, 0.005));
  });

  // The jockey's id sorts FIRST in one drawing ('AJP' < 'FP1') and last in
  // the other — it is never the duty leg either way.
  for (final pumps in const [
    ['FP1', 'FP2', 'JP'],
    ['AJP', 'FP1', 'FP2'],
  ]) {
    test('pumps $pumps: the jockey legs size on 0.47 L/s (DN25); the main '
        'pumps keep the full set flow; only the standby is mirrored', () {
      final jp = pumps.firstWhere((p) => p.contains('J'));
      final mains = pumps.where((p) => p != jp).toList()..sort();
      final par = <String>{};
      final s = autoSizeNetwork(
        _set(pumps),
        const SizingContext(),
        leafDemand: const {ServiceType.fireHydrant: FlowRate(0.0063)},
        hydrantDesignFlow: FlowRate.litersPerSecond(47.32),
        parallelLegEdgeIdsOut: par,
        jockeyLegFlows: {jp: _jockey},
      );
      final setQ = s['h0']!.flow.inLitersPerSecond;
      expect(setQ, greaterThan(1));
      for (final id in ['s$jp', 'p$jp', 'v$jp']) {
        expect(s[id]!.flow.inLitersPerSecond, closeTo(0.47, 1e-9), reason: id);
        expect(s[id]!.diameter.inMillimeters.round(), 25, reason: id);
      }
      for (final m in mains) {
        for (final id in ['s$m', 'p$m', 'v$m']) {
          expect(s[id]!.flow.inLitersPerSecond, closeTo(setQ, 1e-9),
              reason: id);
          expect(s[id]!.diameter.inMillimeters,
              greaterThan(s['p$jp']!.diameter.inMillimeters),
              reason: id);
        }
      }
      // The duty is the first MAIN pump; only the other main pump's leg is
      // a mirrored standby leg (the jockey leg is not).
      expect(par, {'s${mains[1]}', 'p${mains[1]}', 'v${mains[1]}'});
    });
  }

  test('no jockey designated: every leg is mirrored at the full set flow '
      '(byte-identical)', () {
    final par = <String>{};
    final s = autoSizeNetwork(
      _set(const ['FP1', 'FP2', 'JP']),
      const SizingContext(),
      leafDemand: const {ServiceType.fireHydrant: FlowRate(0.0063)},
      hydrantDesignFlow: FlowRate.litersPerSecond(47.32),
      parallelLegEdgeIdsOut: par,
    );
    expect(s['pJP']!.flow.inLitersPerSecond,
        closeTo(s['h0']!.flow.inLitersPerSecond, 1e-9));
    expect(par, containsAll(['sJP', 'pJP', 'vJP']));
  });
}
