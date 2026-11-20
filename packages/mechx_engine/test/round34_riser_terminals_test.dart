/// Round 34 (fire-hvac-drawings-riser-terminals-unreadable) — a riser sheet
/// shows the riser, each floor's take-off and the COUNTED fan-out, never every
/// sprinkler head / diffuser; a tag printed in another floor band than the
/// element it names is counted unresolved.
library;

import 'dart:math';

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y, int f, {NodeComponent? c}) => NetNode(
    id: id,
    sheetId: 's',
    x: x,
    y: y,
    floorIndex: f,
    role: c?.role ?? NodeRole.main,
    component: c);

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

/// [floors] storeys, each: riser node R → header H → [lines] branch lines of
/// [perLine] inline terminals ([c]) on [service].
Network _building(
    {int floors = 3,
    int lines = 3,
    int perLine = 6,
    NodeComponent c = NodeComponent.sprinklerHead,
    ServiceType service = ServiceType.fireSprinkler}) {
  final nodes = <NetNode>[];
  final edges = <NetEdge>[];
  for (var f = 0; f < floors; f++) {
    nodes
      ..add(_n('R$f', 100, 100, f))
      ..add(_n('H$f', 200, 100, f));
    edges.add(_e('t$f', 'R$f', 'H$f', service));
    if (f > 0) {
      edges.add(_e('r$f', 'R${f - 1}', 'R$f', service, k: EdgeKind.riser));
    }
    for (var l = 0; l < lines; l++) {
      final b = 'B${f}_$l';
      nodes.add(_n(b, 200, 200.0 + 100 * l, f));
      edges.add(_e('h${f}_$l', 'H$f', b, service));
      var prev = b;
      for (var i = 0; i < perLine; i++) {
        final id = 'S${f}_${l}_$i';
        nodes.add(_n(id, 300.0 + 100 * i, 200.0 + 100 * l, f, c: c));
        edges.add(_e('s${f}_${l}_$i', prev, id, service));
        prev = id;
      }
    }
  }
  return Network(nodes: nodes, edges: edges);
}

const _building3 = BuildingLevels(
    [Floor('GF', Length(4)), Floor('L1', Length(4)), Floor('L2', Length(4))]);

List<String> _labels(SldSheet s) =>
    [for (final p in s.prims) if (p is SldLabel) p.text];

void main() {
  test('18 heads per floor collapse into the counted fan-out; the take-off '
      'stays', () {
    final net = _building();
    final drawn = collapseRiserTerminals(net);
    // Every head + every bare branch line goes; R (riser end) and the header
    // H (the take-off stub into the riser end) stay. Fix round 6 (T3) — and
    // ONE representative head per floor, the fewest hops from the riser end
    // (R -> H -> B -> S: 3 hops on every line, the least id S<f>_0_0) with
    // the pipe reaching it, so the counted kind is drawn.
    expect(drawn.nodes.map((n) => n.id).toSet(), {
      for (var f = 0; f < 3; f++) ...['R$f', 'H$f', 'B${f}_0', 'S${f}_0_0'],
    });
    expect(drawn.edges.map((e) => e.id).toSet(), {
      'r1', 'r2',
      for (var f = 0; f < 3; f++) ...['t$f', 'h${f}_0', 's${f}_0_0'],
    });
    final sheet = buildMechanicalRiserSld(
        network: net, building: _building3, focus: ServiceType.fireSprinkler);
    final heads =
        _labels(sheet).where((t) => t.contains('Sprinkler head x')).toList();
    // Stated ONCE per floor, as a count (3 lines x 6 heads = 18); the drawn
    // representative carries the plain kind name (or a key).
    expect(heads, List.filled(3, 'Sprinkler head x18'));
    expect(sheet.overlapCount, 0);
  });

  test('a floor with no more than 3 diffusers keeps them drawn (identical '
      'network)', () {
    final net = _building(
        lines: 1,
        perLine: 3,
        c: NodeComponent.supplyDiffuser,
        service: ServiceType.duct);
    expect(identical(collapseRiserTerminals(net), net), isTrue);
  });

  // Seeded property: for any floor size the drawn network never keeps a
  // collapsible terminal on an over-threshold floor, never drops a riser, and
  // the fan-out still counts every terminal.
  test('property: collapse is total and keeps every riser (seeded)', () {
    final rnd = Random(34);
    for (var t = 0; t < 30; t++) {
      final lines = 1 + rnd.nextInt(4), perLine = 1 + rnd.nextInt(6);
      final net = _building(lines: lines, perLine: perLine);
      final drawn = collapseRiserTerminals(net);
      final total = lines * perLine;
      final keptHeads = drawn.nodes
          .where((n) => n.component == NodeComponent.sprinklerHead)
          .length;
      // Fix round 6 (T3) — one representative per collapsed floor.
      expect(keptHeads, total > kRiserTerminalCollapseMin ? 3 : 3 * total);
      expect(drawn.edges.where((e) => e.kind == EdgeKind.riser).length, 2);
      final sheet = buildMechanicalRiserSld(
          network: net,
          building: _building3,
          focus: ServiceType.fireSprinkler);
      final fan = total == 1 ? 'Sprinkler head' : 'Sprinkler head x$total';
      expect(_labels(sheet).where((l) => l == fan).length,
          greaterThanOrEqualTo(3));
    }
  });
}
