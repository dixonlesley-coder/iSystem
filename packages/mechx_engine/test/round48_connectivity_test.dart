// Round 48 — the two fire services are ONE connectivity class
// (mech-convergence-3-combined-standpipe-false-no-source).
import 'package:mechx_engine/network/connectivity.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:test/test.dart';

NetNode _n(String id, int f,
        {NodeRole role = NodeRole.main, NodeComponent? c, double x = 0}) =>
    NetNode(
        id: id,
        sheetId: 's$f',
        x: x,
        y: 0,
        floorIndex: f,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b, ServiceType s) =>
    NetEdge(id: id, fromId: a, toId: b, service: s);

/// GT -> FP -> header -> hydrant riser R0..R(n-1), a hydrant box per floor,
/// and a [heads]-head sprinkler branch tapped off every R_f as sprinkler
/// edges (the combined sprinkler/standpipe riser).
Network _combined(int floors, {int heads = 6, bool reverse = false}) {
  final riser = reverse ? ServiceType.fireSprinkler : ServiceType.fireHydrant;
  final tap = reverse ? ServiceType.fireHydrant : ServiceType.fireSprinkler;
  final nodes = <NetNode>[
    _n('GT', 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('FP', 0, role: NodeRole.plant, c: NodeComponent.pump, x: 10),
  ];
  final edges = <NetEdge>[
    _e('gt', 'GT', 'FP', riser),
    _e('fp', 'FP', 'R0', riser),
  ];
  for (var f = 0; f < floors; f++) {
    nodes.add(_n('R$f', f, x: 20));
    if (f > 0) edges.add(_e('r$f', 'R${f - 1}', 'R$f', riser));
    nodes.add(_n('HB$f', f, role: NodeRole.fixture, x: 25));
    edges.add(_e('hb$f', 'R$f', 'HB$f', riser));
    var prev = 'R$f';
    for (var h = 0; h < heads; h++) {
      final id = 'S${f}_$h';
      nodes.add(_n(id, f, role: NodeRole.fixture, x: 30.0 + 5 * h));
      edges.add(_e('s${f}_$h', prev, id, tap));
      prev = id;
    }
  }
  return Network(nodes: nodes, edges: edges);
}

void main() {
  test('a sprinkler branch tapped off a pumped hydrant riser is FED', () {
    expect(networkConnectivityDefects(_combined(20)), isEmpty);
  });

  test('the reverse drawing (hydrant boxes off a sprinkler riser) is fed', () {
    expect(networkConnectivityDefects(_combined(20, reverse: true)), isEmpty);
  });

  test('a sprinkler-only branch touching nothing fed is still no-source', () {
    final net = Network(nodes: [
      _n('A', 0),
      _n('H1', 0, role: NodeRole.fixture, x: 5),
    ], edges: [
      _e('a', 'A', 'H1', ServiceType.fireSprinkler),
    ]);
    final d = networkConnectivityDefects(net);
    expect(d, hasLength(1));
    expect(d.single.kind, NetworkDefectKind.noSource);
    expect(d.single.service, ServiceType.fireSprinkler);
  });

  test('a pumped hydrant net + a DETACHED sprinkler component is an island',
      () {
    final base = _combined(2, heads: 0);
    final net = Network(nodes: [
      ...base.nodes,
      _n('X', 1, x: 200),
      _n('XH', 1, role: NodeRole.fixture, x: 205),
    ], edges: [
      ...base.edges,
      _e('x', 'X', 'XH', ServiceType.fireSprinkler),
    ]);
    final d = networkConnectivityDefects(net);
    expect(d, hasLength(1));
    expect(d.single.kind, NetworkDefectKind.disconnectedIsland);
    expect(d.single.service, ServiceType.fireSprinkler);
    expect(d.single.nodeIds, ['X', 'XH']);
  });

  test('an unfed combined component reports one defect per fire service', () {
    // The same combined riser with no pump / tank: one noSource per service,
    // each listing only the nodes its own edges touch.
    final base = _combined(2, heads: 2);
    final net = Network(
        nodes: [for (final n in base.nodes) n.copyWith(role: NodeRole.main)],
        edges: base.edges);
    final d = networkConnectivityDefects(net);
    expect({for (final x in d) x.service},
        {ServiceType.fireHydrant, ServiceType.fireSprinkler});
    expect(d.every((x) => x.kind == NetworkDefectKind.noSource), isTrue);
    final spr = d.firstWhere((x) => x.service == ServiceType.fireSprinkler);
    expect(spr.nodeIds.toSet(), {'R0', 'R1', 'S0_0', 'S0_1', 'S1_0', 'S1_1'});
  });
}
