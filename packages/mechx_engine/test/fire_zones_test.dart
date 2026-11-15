// Backlog Z-1 (2026-11-14) — designed fire vertical zones: the zone chain
// read from a drawn break tank, the lower riser sized for the relay fill,
// the relay fill head and the break-tank requirement.
//
// Two-zone drawing (6 storeys of 4.0 m, 0.02 m/px):
//   zone 1: FT (L0 ground tank) -s1- P1 (L0) -d1- H0; riser H0-H1-H2 with a
//           hydrant box on L0..L2 (one stack, Class I); fill H2 -f- BT.
//   zone 2: BT (L2 roof-typed tank below the top storey: its own floor
//           surface, 8.0 m) -s2- P2 (L2) -d2- K2; TWO stacks K2-A3..A5 and
//           K2-C3..C5, a box on each of L3..L5.
// First principles: one Class I stack = 500 gpm = 31.5451 L/s; two stacks
// = 500 + 250 = 750 gpm x 0.0630902 = 47.3176 L/s (NFPA 14). Zone 2 draws
// 47.3176 L/s from BT, so zone 1 must refill BT at 47.3176 L/s: its fill
// path H0-H1-H2-BT carries max(31.5451, 47.3176) = 47.3176 L/s (never the
// sum: one fire event), the box legs keep their own outlet flow.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/fire_zones.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const double _floorH = 4.0;
const int _floors = 6;
final BuildingLevels _building = BuildingLevels(
    [for (var i = 0; i < _floors; i++) Floor('L$i', const Length(_floorH))]);

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's$floor',
        x: x,
        y: y,
        floorIndex: floor,
        role: c == null
            ? role
            : (c == NodeComponent.hydrantBox || c == NodeComponent.sprinklerHead
                ? NodeRole.fixture
                : NodeRole.plant),
        component: c);

NetEdge _e(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.fireHydrant, kind: k);

/// The two-zone drawing; [breakDrawn] false draws zone 1 alone (no BT, no
/// zone 2): the single-zone reading of the same lower room.
Network _twoZone({bool breakDrawn = true}) => Network(nodes: [
      _n('FT', 100, 300, c: NodeComponent.groundTank),
      _n('P1', 100, 250, c: NodeComponent.pump),
      for (var f = 0; f <= 2; f++) ...[
        _n('H$f', 100, 200, floor: f),
        _n('BX$f', 200, 200, floor: f, c: NodeComponent.hydrantBox),
      ],
      if (breakDrawn) ...[
        _n('BT', 100, 300, floor: 2, c: NodeComponent.roofTank),
        _n('P2', 100, 250, floor: 2, c: NodeComponent.pump),
        _n('K2', 100, 150, floor: 2),
        for (var f = 3; f <= 5; f++) ...[
          _n('A$f', 300, 150, floor: f),
          _n('AX$f', 400, 150, floor: f, c: NodeComponent.hydrantBox),
          _n('C$f', 0, 150, floor: f),
          _n('CX$f', 0, 50, floor: f, c: NodeComponent.hydrantBox),
        ],
        _n('A2', 300, 150, floor: 2),
        _n('C2', 0, 150, floor: 2),
      ],
    ], edges: [
      _e('s1', 'FT', 'P1'),
      _e('d1', 'P1', 'H0'),
      _e('r1', 'H0', 'H1', k: EdgeKind.riser),
      _e('r2', 'H1', 'H2', k: EdgeKind.riser),
      for (var f = 0; f <= 2; f++) _e('b$f', 'H$f', 'BX$f'),
      if (breakDrawn) ...[
        _e('f', 'H2', 'BT'),
        _e('s2', 'BT', 'P2'),
        _e('d2', 'P2', 'K2'),
        _e('ka', 'K2', 'A2'),
        _e('kc', 'K2', 'C2'),
        for (var f = 3; f <= 5; f++) ...[
          _e('ra$f', 'A${f - 1}', 'A$f', k: EdgeKind.riser),
          _e('rc$f', 'C${f - 1}', 'C$f', k: EdgeKind.riser),
          _e('ba$f', 'A$f', 'AX$f'),
          _e('bc$f', 'C$f', 'CX$f'),
        ],
      ],
    ]);

double _z(NetNode n) => nodeElevation(n, _building).meters;

Map<String, EdgeSizing> _size(Network net) => autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {
        ServiceType.fireHydrant: FlowRate(0.005),
        ServiceType.fireSprinkler: FlowRate(0.001),
      },
      hydrantDesignFlow: standpipeFlow(2),
      building: _building,
      calibrationBySheet: {
        for (var f = 0; f < _floors; f++)
          's$f': const ScaleCalibration(0.02),
      },
    );

/// [net] with every id prefixed and both lists reversed.
Network _renamedShuffled(Network net, String p) => Network(
      nodes: [
        for (final n in net.nodes.reversed)
          NetNode(
              id: '$p${n.id}',
              sheetId: n.sheetId,
              x: n.x,
              y: n.y,
              floorIndex: n.floorIndex,
              role: n.role,
              component: n.component,
              tankCapacityLitres: n.tankCapacityLitres),
      ],
      edges: [
        for (final e in net.edges.reversed)
          NetEdge(
              id: '$p${e.id}',
              fromId: '$p${e.fromId}',
              toId: '$p${e.toId}',
              service: e.service,
              kind: e.kind,
              sizeOverride: e.sizeOverride),
      ],
    );

void main() {
  const q500 = 31.5451; // L/s, 500 gpm
  const q750 = 47.3176; // L/s, 750 gpm

  test('hand figures: 500 / 750 gpm', () {
    expect(standpipeFlow(1).inLitersPerSecond, closeTo(q500, 1e-4));
    expect(standpipeFlow(2).inLitersPerSecond, closeTo(q750, 1e-4));
  });

  group('two zones', () {
    final net = _twoZone();
    final zones = fireZones(net, elevationOf: _z);

    test('zone 1 fills BT, zone 2 draws from it', () {
      expect(zones, hasLength(2));
      expect(fireZoned(zones), isTrue);
      final z1 = zones[0], z2 = zones[1];
      expect(z1.number, 1);
      expect(z1.pumpIds, ['P1']);
      expect(z1.suctionTankId, isNull);
      expect(z1.fillTankId, 'BT');
      expect(z1.upstream, isNull);
      expect(z2.number, 2);
      expect(z2.pumpIds, ['P2']);
      expect(z2.suctionTankId, 'BT');
      expect(z2.fillTankId, isNull);
      expect(z2.upstream, 0);
    });

    test('the fill path is the lower riser to BT (pump legs excluded)', () {
      expect(fireFillPathEdgeIds(net, zones[0].system, 'BT'),
          {'r1', 'r2', 'f'});
    });

    test('the fill path carries the upper zone flow 47.3176 L/s', () {
      final s = _size(net);
      for (final id in ['r1', 'r2', 'f']) {
        expect(s[id]!.flow.inLitersPerSecond, closeTo(q750, 1e-4), reason: id);
      }
      // Each box leg keeps its own outlet flow; the drawn-alone lower room's
      // riser carries its own one-stack 500 gpm.
      final alone = _size(_twoZone(breakDrawn: false));
      for (final id in ['r1', 'r2']) {
        expect(alone[id]!.flow.inLitersPerSecond, closeTo(q500, 1e-4),
            reason: id);
        expect(s[id]!.diameter.inMillimeters,
            greaterThanOrEqualTo(alone[id]!.diameter.inMillimeters));
      }
      for (var f = 0; f <= 2; f++) {
        expect(s['b$f']!.flow.cubicMetersPerSecond,
            closeTo(alone['b$f']!.flow.cubicMetersPerSecond, 1e-12));
      }
    });

    test('renamed + shuffled: same zones, same sizes', () {
      final r = _renamedShuffled(net, 'z_');
      final rz = fireZones(r, elevationOf: _z);
      expect([for (final z in rz) z.number], [1, 2]);
      expect(rz[0].pumpIds, ['z_P1']);
      expect(rz[0].fillTankId, 'z_BT');
      expect(rz[1].suctionTankId, 'z_BT');
      expect(rz[1].upstream, 0);
      expect(fireFillPathEdgeIds(r, rz[0].system, 'z_BT'),
          {'z_r1', 'z_r2', 'z_f'});
      final a = _size(net), b = _size(r);
      for (final e in net.edges) {
        expect(b['z_${e.id}']!.diameter.inMillimeters,
            a[e.id]!.diameter.inMillimeters,
            reason: e.id);
        expect(b['z_${e.id}']!.flow.cubicMetersPerSecond,
            closeTo(a[e.id]!.flow.cubicMetersPerSecond, 1e-12),
            reason: e.id);
      }
    });
  });

  test('relay fill head: lift + friction + the 5 m inlet residual', () {
    // BT on L2 = 2 x 4.0 = 8.0 m above P1 (L0 surface).
    final net = _twoZone();
    final lift = _z(net.nodeById('BT')!) - _z(net.nodeById('P1')!);
    expect(lift, closeTo(8.0, 1e-12));
    expect(fireRelayFillHeadM(liftM: lift, frictionM: 1.25),
        closeTo(8.0 + 1.25 + 5.0, 1e-12));
    // Negative terms read as 0, the residual always stands.
    expect(fireRelayFillHeadM(liftM: -2, frictionM: -1), closeTo(5.0, 1e-12));
  });

  test('break tank requirement: 47.3176 L/s x 30 min = 85 171.8 L', () {
    const r = FireBreakTankRequirement(ratedFlow: FlowRate(q750 / 1000));
    expect(r.durationMin, kFireBreakTankDurationMin);
    expect(kFireBreakTankDurationMin, 30);
    expect(r.volumeLitres, closeTo(q750 * 30 * 60, 1e-6)); // 85 171.68
    expect(r.volumeLitres, closeTo(85171.68, 0.01));
    expect(r.fillFlow.inLitersPerSecond, closeTo(q750, 1e-12));
  });

  // Seeded property: a random SINGLE-zone tower (one pump room from a
  // ground tank, 1..3 stacks, an optional sprinkler riser) reads as one
  // zone numbered 1 with no break tank, and its sizing is invariant under a
  // rename + shuffle.
  test('seeded: single-zone towers are one zone, order-independent', () {
    final rnd = math.Random(2026);
    for (var t = 0; t < 25; t++) {
      final nF = 2 + rnd.nextInt(_floors - 1);
      final stacks = 1 + rnd.nextInt(3);
      final sprinkler = rnd.nextBool();
      final nodes = <NetNode>[
        _n('FT', 100, 300, c: NodeComponent.groundTank),
        _n('P', 100, 250, c: NodeComponent.pump),
        _n('FH', 100, 200),
      ];
      final edges = <NetEdge>[_e('s', 'FT', 'P'), _e('d', 'P', 'FH')];
      for (var k = 0; k < stacks; k++) {
        final x = 200.0 + 100 * k;
        for (var f = 0; f < nF; f++) {
          nodes
            ..add(_n('R$k-$f', x, 200, floor: f))
            ..add(_n('X$k-$f', x, 100, floor: f, c: NodeComponent.hydrantBox));
          edges
            ..add(f == 0
                ? _e('t$k', 'FH', 'R$k-0')
                : _e('r$k-$f', 'R$k-${f - 1}', 'R$k-$f', k: EdgeKind.riser))
            ..add(_e('b$k-$f', 'R$k-$f', 'X$k-$f'));
        }
      }
      if (sprinkler) {
        for (var f = 0; f < nF; f++) {
          nodes.add(_n('S$f', 100, 50, floor: f));
          edges.add(f == 0
              ? const NetEdge(
                  id: 'sp0',
                  fromId: 'FH',
                  toId: 'S0',
                  service: ServiceType.fireSprinkler)
              : NetEdge(
                  id: 'sp$f',
                  fromId: 'S${f - 1}',
                  toId: 'S$f',
                  service: ServiceType.fireSprinkler,
                  kind: EdgeKind.riser));
        }
        nodes.add(_n('SP', 50, 50, floor: nF - 1, c: NodeComponent.sprinklerHead));
        edges.add(NetEdge(
            id: 'sph',
            fromId: 'S${nF - 1}',
            toId: 'SP',
            service: ServiceType.fireSprinkler));
      }
      final net = Network(nodes: nodes, edges: edges);
      final zones = fireZones(net, elevationOf: _z);
      expect(zones, hasLength(1), reason: 'case $t');
      expect(zones.single.number, 1);
      expect(zones.single.suctionTankId, isNull);
      expect(zones.single.fillTankId, isNull);
      expect(fireZoned(zones), isFalse);
      final r = _renamedShuffled(net, 'q_');
      final a = _size(net), b = _size(r);
      for (final e in net.edges) {
        expect(b['q_${e.id}']?.diameter.inMillimeters,
            a[e.id]?.diameter.inMillimeters,
            reason: 'case $t ${e.id}');
        expect(b['q_${e.id}']?.flow.cubicMetersPerSecond,
            a[e.id]?.flow.cubicMetersPerSecond,
            reason: 'case $t ${e.id}');
      }
    }
  });
}
