// Round 37 (2026-10-18) — regression-duty-standby-leg-with-two-check-valves-
// splits.
//
// A duty/standby pump set whose legs carry TWO check valves (a suction / foot
// valve and the discharge check: GT -> V_i -> P_i -> C_i -> HDR) is the same
// Round-13 parallel set as with one valve per leg: every leg carries the full
// set flow, the standby legs are mirrored — never a Hardy–Cross split.
//
// Derivation: HDR feeds a 4-floor riser with a 4-UBAP fixture per floor, so
// the set flow is curve(16) = 0.6533 L/s; at DN20 v = 4Q/(pi D^2) =
// 2.08 m/s > the 2.0 m/s cap, at DN25 1.33 m/s ⇒ DN25 on every leg edge.
import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.coldWater, kind: k);

const _sni = SniProfile();
double _curve(double ubap) =>
    _sni.probableFlowForFixtureUnits(ubap).inLitersPerSecond;

/// [valves][i] = number of check valves on leg i+1 (0, 1 = discharge check,
/// 2 = suction valve + discharge check).
Network _set(List<int> valves) {
  final nodes = <NetNode>[
    _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('HDR', 100, 0),
  ];
  final edges = <NetEdge>[];
  for (var k = 0; k < valves.length; k++) {
    final i = k + 1;
    final y = 20.0 * i;
    nodes.add(_n('P$i', 50, y, role: NodeRole.plant, c: NodeComponent.pump));
    if (valves[k] >= 2) {
      nodes.add(_n('V$i', 25, y, c: NodeComponent.checkValve));
      edges
        ..add(_e('g$i', 'GT', 'V$i'))
        ..add(_e('h$i', 'V$i', 'P$i'));
    } else {
      edges.add(_e('h$i', 'GT', 'P$i'));
    }
    if (valves[k] >= 1) {
      nodes.add(_n('C$i', 75, y, c: NodeComponent.checkValve));
      edges
        ..add(_e('p$i', 'P$i', 'C$i'))
        ..add(_e('c$i', 'C$i', 'HDR'));
    } else {
      edges.add(_e('p$i', 'P$i', 'HDR'));
    }
  }
  for (var f = 0; f < 4; f++) {
    nodes
      ..add(_n('S$f', 150, 0, floor: f))
      ..add(_n('fx$f', 190, 0, floor: f, role: NodeRole.fixture));
    edges.add(_e('b$f', 'S$f', 'fx$f'));
    edges.add(f == 0
        ? _e('m', 'HDR', 'S0')
        : _e('s$f', 'S${f - 1}', 'S$f', k: EdgeKind.riser));
  }
  return Network(nodes: nodes, edges: edges);
}

List<String> _legEdges(int i, int valves) => [
      if (valves >= 2) 'g$i',
      'h$i',
      'p$i',
      if (valves >= 1) 'c$i',
    ];

void main() {
  test('the derivation: curve(16) = 0.6533 L/s, DN20 over 2 m/s', () {
    expect(_curve(16), closeTo(0.6533, 1e-4));
    expect(4 * 0.6533e-3 / (math.pi * 0.02 * 0.02), greaterThan(2.0));
  });

  for (final valves in const [
    [2, 2],
    [1, 2],
    [2, 1],
    [2, 0],
    [0, 2],
    [2, 2, 2],
    [1, 2, 1],
  ]) {
    for (final cal in [false, true]) {
      test('legs $valves (cal=$cal): every leg edge curve(16) DN25, standby '
          'legs mirrored', () {
        final par = <String>{};
        final s = autoSizeNetwork(
          _set(valves),
          const SizingContext(),
          leafDemand: {ServiceType.coldWater: const FlowRate(0)},
          leafFixtureUnits: {ServiceType.coldWater: 4},
          building: cal
              ? BuildingLevels([
                  for (var i = 0; i < 4; i++) const Floor('L', Length(3.0))
                ])
              : null,
          calibrationBySheet:
              cal ? const {'s1': ScaleCalibration(0.05)} : const {},
          parallelLegEdgeIdsOut: par,
        );
        for (var k = 0; k < valves.length; k++) {
          for (final id in _legEdges(k + 1, valves[k])) {
            expect(s[id]!.flow.inLitersPerSecond, closeTo(_curve(16), 1e-9),
                reason: '$valves $id');
            expect(s[id]!.diameter.inMillimeters.round(), 25,
                reason: '$valves $id');
          }
        }
        expect(s['m']!.flow.inLitersPerSecond, closeTo(_curve(16), 1e-9));
        expect(par, {
          for (var k = 1; k < valves.length; k++)
            ..._legEdges(k + 1, valves[k]),
        });
      });
    }
  }
}
