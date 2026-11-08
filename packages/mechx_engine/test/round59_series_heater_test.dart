// Round 59 (plumbing-hvac-convergence-9-series-solar-booster-heater-zero-
// makeup) — a solar preheater -> electric booster heater chain roots the
// hot network at the heater where the COLD make-up enters (the solar
// heater, on a cold-water edge), never at the inline booster, whatever the
// ids or floors.
//
// First principles: 10 dual-fed fixtures at 20 UBAP; each loads the dual
// factor 3/4 onto each supply => 15 UBAP hot + 15 UBAP cold. Every litre of
// hot water passes the solar make-up, the solar -> booster transfer and the
// booster outlet: csol == se == eh == curve(10 x 15 = 150 UBAP). The pump
// discharge carries the cold shares AND the hot draw via the heater,
// combined to each fixture's total once (Round 48): curve(10 x 20 = 200).
library;

import 'dart:math' as math;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _sni = SniProfile();

NetNode _n(String id, double x, int f,
        {NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: f,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.coldWater, EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

/// [sol] / [eh]: the solar / booster heater ids; [ehFloor] the booster's
/// floor (the solar heater sits on the roof storey L9).
({Network net, Map<String, double> units}) _chain(String sol, String eh,
    {int ehFloor = 9}) {
  final nodes = <NetNode>[
    _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('P', 10, 0, role: NodeRole.plant, c: NodeComponent.pump),
    _n(sol, 40, 9, role: NodeRole.plant),
    _n(eh, 50, ehFloor, role: NodeRole.plant),
  ];
  final edges = <NetEdge>[
    _e('g', 'GT', 'P'),
    _e('pc', 'P', 'C0'),
    _e('csol', 'C9', sol),
    _e('se', sol, eh, s: ServiceType.hotWater),
    _e('eh', eh, 'H9', s: ServiceType.hotWater),
  ];
  final units = <String, double>{};
  for (var f = 0; f < 10; f++) {
    nodes.addAll([
      _n('C$f', 20, f),
      _n('H$f', 60, f),
      _n('F$f', 30, f, role: NodeRole.fixture),
    ]);
    units['F$f'] = 20;
    edges.addAll([
      _e('cf$f', 'C$f', 'F$f'),
      _e('hf$f', 'H$f', 'F$f', s: ServiceType.hotWater),
      if (f > 0) ...[
        _e('cr$f', 'C${f - 1}', 'C$f', k: EdgeKind.riser),
        _e('hr$f', 'H$f', 'H${f - 1}',
            s: ServiceType.hotWater, k: EdgeKind.riser),
      ],
    ]);
  }
  return (net: Network(nodes: nodes, edges: edges), units: units);
}

Map<String, EdgeSizing> _size(Network net, Map<String, double> units) =>
    autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {},
      leafFixtureUnits: const {
        ServiceType.coldWater: 0,
        ServiceType.hotWater: 0,
      },
      nodeFixtureUnits: units,
      building: BuildingLevels(
          [for (var i = 0; i < 10; i++) Floor('L$i', const Length(3.5))]),
    );

double _q(double ubap) =>
    _sni.probableFlowForFixtureUnits(ubap).cubicMetersPerSecond;

void main() {
  final cases = <(String, String, String, int)>[
    ('SOL/EH', 'SOL', 'EH', 9),
    ('ZSOL/EH', 'ZSOL', 'EH', 9),
    ('ASOL/EH', 'ASOL', 'EH', 9),
    ('booster on L0', 'SOL', 'EH', 0),
    ('booster on L0, ASOL', 'ASOL', 'EH', 0),
  ];
  for (final (name, sol, eh, f) in cases) {
    test(
        '$name: make-up, transfer and booster outlet carry curve(150); the '
        'pump discharge curve(200)', () {
      final c = _chain(sol, eh, ehFloor: f);
      final r = _size(c.net, c.units);
      for (final id in ['csol', 'se', 'eh']) {
        expect(r[id]!.flow.cubicMetersPerSecond, closeTo(_q(150), 1e-12),
            reason: id);
      }
      expect(r['se']!.flowFromId, sol);
      expect(r['csol']!.flowFromId, 'C9');
      expect(r['pc']!.flow.cubicMetersPerSecond, closeTo(_q(200), 1e-12));
    });
  }

  test('seeded property: id renames / flips / shuffles never move a size', () {
    final rnd = math.Random(5903);
    final c0 = _chain('SOL', 'EH');
    final base = _size(c0.net, c0.units);
    for (var t = 0; t < 30; t++) {
      final sol = '${rnd.nextBool() ? 'A' : 'Z'}${rnd.nextInt(99)}';
      final eh = '${rnd.nextBool() ? 'B' : 'Y'}${rnd.nextInt(99)}';
      final c = _chain(sol, eh, ehFloor: rnd.nextBool() ? 9 : 0);
      final edges = [
        for (final e in c.net.edges)
          rnd.nextBool()
              ? NetEdge(
                  id: e.id,
                  fromId: e.toId,
                  toId: e.fromId,
                  service: e.service,
                  kind: e.kind)
              : e,
      ]..shuffle(rnd);
      final nodes = [...c.net.nodes]..shuffle(rnd);
      final r = _size(Network(nodes: nodes, edges: edges), c.units);
      for (final id in ['csol', 'se', 'eh', 'pc', 'g']) {
        expect(r[id]!.diameter.inMillimeters, base[id]!.diameter.inMillimeters,
            reason: '$id trial $t');
        expect(r[id]!.flow.cubicMetersPerSecond,
            closeTo(base[id]!.flow.cubicMetersPerSecond, 1e-12),
            reason: '$id trial $t');
      }
    }
  });
}
