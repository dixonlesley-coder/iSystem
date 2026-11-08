// Round 68 (2026-10-18) — fire-convergence-20:
//
//  ring-pump-room-unsized — two pump rooms (GA -> PA -> R0, GB -> PB -> R5)
//    on a hydrant main closed into a RING (R0..R5 + Q0..Q5). The Round-14
//    peer-source mirror ran only on the TREE path, so on the ring the
//    demand-free GB -> PB bridge balanced to exactly zero flow and dropped
//    out of the result (no size, no BOM line, no NFPA 20 raise).
//  ring-through-roof-tank — a roof tank feeding BOTH riser tops (one tank,
//    two drops) closed a phantom "ring" through the tank, so a whole
//    sprinkler riser was sized at the 500 gpm standpipe flow.
//
// First principles: standpipeFlow(n) = 500 gpm + 250 gpm per extra stack,
// capped at 1250 gpm. 2 stacks = 750 gpm = 750 x 3.785411784 / 60
// = 47.318 L/s; 6 stacks = 1250 gpm = 78.863 L/s. Each pump room is a
// parallel peer source and carries the WHOLE set flow while the other is
// isolated. NFPA 20 Table 4.28(a): 750 gpm => suction DN150 / discharge
// DN150; 1250 gpm => DN200 / DN200.
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _hy = ServiceType.fireHydrant, _sp = ServiceType.fireSprinkler;

NetNode _n(String id, double x,
        {int f = 0,
        double y = 0,
        NodeRole r = NodeRole.main,
        NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: f,
        role: c?.role ?? r,
        component: c);

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

/// [drops] hydrant drops (R_i -> D_i on L1 -> box); [ring] closes R0..R5
/// through Q0..Q5.
Network _rooms({required Set<int> drops, required bool ring}) {
  final nodes = <NetNode>[
    _n('GA', -200, c: NodeComponent.groundTank),
    _n('PA', -100, c: NodeComponent.pump),
    _n('GB', 700, c: NodeComponent.groundTank),
    _n('PB', 600, c: NodeComponent.pump),
    for (var i = 0; i <= 5; i++) _n('R$i', 100.0 * i),
    if (ring)
      for (var i = 0; i <= 5; i++) _n('Q$i', 100.0 * i, y: 300),
    for (final i in drops) ...[
      _n('D$i', 100.0 * i, f: 1),
      _n('B$i', 100.0 * i, f: 1, y: 50, c: NodeComponent.hydrantBox),
    ],
  ];
  final edges = <NetEdge>[
    _e('ga', 'GA', 'PA', _hy),
    _e('pa', 'PA', 'R0', _hy),
    _e('gb', 'GB', 'PB', _hy),
    _e('pb', 'PB', 'R5', _hy),
    for (var i = 1; i <= 5; i++) _e('m$i', 'R${i - 1}', 'R$i', _hy),
    if (ring) ...[
      _e('q0', 'R0', 'Q0', _hy),
      for (var i = 1; i <= 5; i++) _e('q$i', 'Q${i - 1}', 'Q$i', _hy),
      _e('q6', 'Q5', 'R5', _hy),
    ],
    for (final i in drops) ...[
      _e('d$i', 'R$i', 'D$i', _hy, k: EdgeKind.riser),
      _e('b$i', 'D$i', 'B$i', _hy),
    ],
  ];
  return Network(nodes: nodes, edges: edges);
}

final _bld = BuildingLevels(
    [for (var i = 0; i < 3; i++) Floor('L$i', const Length(3.5))]);

Map<String, EdgeSizing> _size(Network net, int stacks, {Set<String>? legs}) =>
    autoSizeNetwork(net, const SizingContext(),
        leafDemand: const {_hy: FlowRate(0.005), _sp: FlowRate(0.0015)},
        hydrantDesignFlow: standpipeFlow(stacks),
        sprinklerDemandCap: const FlowRate(0.012),
        building: _bld,
        calibrationBySheet: const {'s1': ScaleCalibration(0.01)},
        parallelLegEdgeIdsOut: legs);

/// 25 storeys: GT (L12) -> SH -> P3 / P4 -> UH; UH -> hydrant riser
/// X12..X24 (a box per floor) and UH -> sprinkler riser S12..S24 (a head per
/// floor). [tank]: one roof tank RT on L24 feeding both riser tops through a
/// check valve each ([sprDrop] the sprinkler one).
Network _upperZone({required bool tank, required bool sprDrop}) {
  final nodes = <NetNode>[
    _n('GT', 0, f: 12, c: NodeComponent.groundTank),
    _n('SH', 50, f: 12),
    _n('P3', 100, f: 12, c: NodeComponent.pump),
    _n('P4', 100, f: 12, y: 40, c: NodeComponent.pump),
    _n('UH', 150, f: 12),
    for (var f = 12; f <= 24; f++) ...[
      _n('X$f', 200, f: f),
      _n('B$f', 260, f: f, c: NodeComponent.hydrantBox),
      _n('S$f', 400, f: f),
      _n('H$f', 460, f: f, c: NodeComponent.sprinklerHead),
    ],
    if (tank) ...[
      _n('RT', 300, f: 24, y: -80, c: NodeComponent.roofTank),
      _n('CV', 250, f: 24, y: -80, c: NodeComponent.checkValve),
      if (sprDrop) _n('CV2', 350, f: 24, y: -80, c: NodeComponent.checkValve),
    ],
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'SH', _hy),
    _e('s3', 'SH', 'P3', _hy),
    _e('s4', 'SH', 'P4', _hy),
    _e('d3', 'P3', 'UH', _hy),
    _e('d4', 'P4', 'UH', _hy),
    _e('ux', 'UH', 'X12', _hy),
    _e('us', 'UH', 'S12', _sp),
    for (var f = 13; f <= 24; f++) ...[
      _e('xr$f', 'X${f - 1}', 'X$f', _hy, k: EdgeKind.riser),
      _e('sr$f', 'S${f - 1}', 'S$f', _sp, k: EdgeKind.riser),
    ],
    for (var f = 12; f <= 24; f++) ...[
      _e('b$f', 'X$f', 'B$f', _hy),
      _e('h$f', 'S$f', 'H$f', _sp),
    ],
    if (tank) ...[
      _e('rt1', 'RT', 'CV', _hy),
      _e('rt2', 'CV', 'X24', _hy),
      if (sprDrop) ...[
        _e('rt3', 'RT', 'CV2', _sp),
        _e('rt4', 'CV2', 'S24', _sp),
      ],
    ],
  ];
  return Network(nodes: nodes, edges: edges);
}

Map<String, EdgeSizing> _sizeZone(Network net) => autoSizeNetwork(
    net, const SizingContext(),
    leafDemand: const {_hy: FlowRate(0.005), _sp: FlowRate(0.0015)},
    hydrantDesignFlow: standpipeFlow(1),
    sprinklerDemandCap: const FlowRate(0.006),
    building: BuildingLevels(
        [for (var i = 0; i < 25; i++) Floor('L$i', const Length(3.5))]),
    calibrationBySheet: const {'s1': ScaleCalibration(0.01)});

Network _reversed(Network n) => Network(
    nodes: n.nodes.reversed.toList(), edges: n.edges.reversed.toList());

void main() {
  group('ring-pump-room-unsized: both pump rooms sized on a ring main', () {
    for (final (drops, lps, mm) in [
      ({1, 4}, 47.318, 150.0),
      ({0, 1, 2, 3, 4, 5}, 78.863, 200.0),
    ]) {
      test('${drops.length} drops: gb/pb == the tree drawing', () {
        final n = drops.length;
        final treeLegs = <String>{}, ringLegs = <String>{};
        final tree =
            _size(_rooms(drops: drops, ring: false), n, legs: treeLegs);
        final ring = _size(_rooms(drops: drops, ring: true), n, legs: ringLegs);
        final rev = _size(_reversed(_rooms(drops: drops, ring: true)), n);
        for (final id in ['ga', 'pa', 'gb', 'pb']) {
          for (final (what, r) in [('ring', ring), ('reversed', rev)]) {
            final s = r[id];
            expect(s, isNotNull, reason: '$what $id sized');
            expect(s!.flow.inLitersPerSecond, closeTo(lps, 0.001),
                reason: '$what $id flow');
            expect(s.diameter.inMillimeters, mm, reason: '$what $id DN');
            expect(s.diameter.inMillimeters, tree[id]!.diameter.inMillimeters,
                reason: '$what $id DN == tree');
            expect(s.flowFromId, tree[id]!.flowFromId,
                reason: '$what $id direction == tree');
          }
        }
        // The peer room's legs are recorded as parallel legs on both
        // drawings (one set flow, never added twice).
        final treePeer = treeLegs.intersection({'ga', 'pa', 'gb', 'pb'});
        expect(treePeer, isNotEmpty);
        expect(ringLegs.intersection({'ga', 'pa', 'gb', 'pb'}), treePeer);
        // Hand check of the bore: 150 % flow at <= 4.57 m/s.
        final a = math.pi * math.pow(mm / 1000, 2) / 4;
        expect(1.5 * lps / 1000 / a, lessThanOrEqualTo(4.57));
      });
    }
  });

  group('ring-through-roof-tank: one roof tank feeding both riser tops', () {
    final both = _sizeZone(_upperZone(tank: true, sprDrop: true));
    final hyOnly = _sizeZone(_upperZone(tank: true, sprDrop: false));
    final none = _sizeZone(_upperZone(tank: false, sprDrop: false));
    final sprIds = ['us', for (var f = 13; f <= 24; f++) 'sr$f'];
    test('the sprinkler riser == the drawing with no tank / no sprinkler drop',
        () {
      // OH1: 5 mm/min x 72 m2 = 360 L/min = 6.0 L/s on the sprinkler
      // trunk us; never the 31.545 L/s standpipe ring flow.
      expect(both['us']!.flow.inLitersPerSecond, closeTo(6.0, 1e-6));
      for (final id in sprIds) {
        for (final (what, r) in [('no drop', hyOnly), ('no tank', none)]) {
          expect(both[id]?.diameter.inMillimeters,
              r[id]?.diameter.inMillimeters,
              reason: '$what $id DN');
          expect(both[id]!.flow.inLitersPerSecond,
              closeTo(r[id]!.flow.inLitersPerSecond, 1e-9),
              reason: '$what $id flow');
        }
        expect(both[id]!.flow.inLitersPerSecond, lessThan(31.0),
            reason: '$id never the standpipe flow');
      }
    });
    test('the tank legs flow OUT of the tank, through the check valves', () {
      expect(both['rt1']!.flowFromId, 'RT');
      expect(both['rt2']!.flowFromId, 'CV');
      expect(both['rt3']!.flowFromId, 'RT');
      expect(both['rt4']!.flowFromId, 'CV2');
      expect(hyOnly['rt1']!.flowFromId, 'RT');
    });
  });
}
