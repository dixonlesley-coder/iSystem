// Pure unit tests for the single-line riser FUNCTION-suffix heuristic and the
// per-service riser-tag numbering (no widget, no Flutter binding needed).

import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/schematic/riser_tags.dart';
import 'package:mechx_engine/network/network.dart';

NetNode _n(
  String id,
  double x,
  int floor, {
  NodeRole role = NodeRole.main,
  NodeComponent? component,
}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: 0,
      floorIndex: floor,
      role: role,
      component: component,
    );

NetEdge _e(
  String id,
  String from,
  String to,
  ServiceType service, {
  EdgeKind kind = EdgeKind.run,
}) =>
    NetEdge(id: id, fromId: from, toId: to, service: service, kind: kind);

void main() {
  group('riserFunctionFor — function suffix heuristic', () {
    test('(a) groundTank -> roofTank riser => TRANSFER', () {
      final net = Network(
        nodes: [
          _n('g', 100, 0, role: NodeRole.plant, component: NodeComponent.groundTank),
          _n('r', 100, 3, role: NodeRole.plant, component: NodeComponent.roofTank),
        ],
        edges: [_e('e', 'g', 'r', ServiceType.coldWater, kind: EdgeKind.riser)],
      );
      expect(
        riserFunctionFor(net, net.edges.first, downfeed: false),
        RiserFunction.transfer,
      );
    });

    test('(b) run downstream of a pump => BOOSTER', () {
      final net = Network(
        nodes: [
          _n('p', 100, 0, role: NodeRole.plant, component: NodeComponent.pump),
          _n('m', 200, 0),
        ],
        edges: [_e('e', 'p', 'm', ServiceType.coldWater)],
      );
      expect(
        riserFunctionFor(net, net.edges.first, downfeed: false),
        RiserFunction.booster,
      );
    });

    test('(b2) upfeed ascending pressurized CW riser with a pump => BOOSTER',
        () {
      // The pump sits on a separate junction of the same service; an ascending
      // CW riser (no tank/pump on its own endpoints) reads as the booster riser.
      final net = Network(
        nodes: [
          _n('p', 100, 0, role: NodeRole.plant, component: NodeComponent.pump),
          _n('j', 100, 0), // junction the pump feeds
          _n('a', 100, 0),
          _n('b', 100, 1),
        ],
        edges: [
          _e('feed', 'p', 'j', ServiceType.coldWater),
          _e('riser', 'a', 'b', ServiceType.coldWater, kind: EdgeKind.riser),
        ],
      );
      final riser = net.edgeById('riser')!;
      expect(
        riserFunctionFor(net, riser, downfeed: false),
        RiserFunction.booster,
      );
    });

    test('(c) CW run descending/distributing from a roofTank (downfeed) => '
        'GRAVITASI', () {
      final net = Network(
        nodes: [
          _n('r', 100, 3, role: NodeRole.plant, component: NodeComponent.roofTank),
          _n('m', 200, 3),
        ],
        edges: [_e('e', 'r', 'm', ServiceType.coldWater)],
      );
      expect(
        riserFunctionFor(net, net.edges.first, downfeed: true),
        RiserFunction.gravitasi,
      );
    });

    test('(c2) downfeed distribution main, no pump, water => GRAVITASI', () {
      final net = Network(
        nodes: [_n('a', 100, 2), _n('b', 200, 2)],
        edges: [_e('e', 'a', 'b', ServiceType.coldWater)],
      );
      expect(
        riserFunctionFor(net, net.edges.first, downfeed: true),
        RiserFunction.gravitasi,
      );
    });

    test('(d) air duct edge => null (no suffix on air)', () {
      final net = Network(
        nodes: [
          _n('a', 100, 0, role: NodeRole.plant, component: NodeComponent.ahu),
          _n('b', 200, 0, role: NodeRole.fixture, component: NodeComponent.supplyDiffuser),
        ],
        edges: [_e('e', 'a', 'b', ServiceType.duct)],
      );
      expect(riserFunctionFor(net, net.edges.first, downfeed: false), isNull);
    });

    test('(e) ambiguous plain run, no plant/tank, upfeed => null', () {
      final net = Network(
        nodes: [_n('a', 100, 1), _n('b', 200, 1)],
        edges: [_e('e', 'a', 'b', ServiceType.coldWater)],
      );
      expect(riserFunctionFor(net, net.edges.first, downfeed: false), isNull);
    });

    test('TRANSFER preferred when a riser could read as booster too', () {
      // Pump (lower) up to a roof tank (upper): both rules could fire; TRANSFER
      // wins (the unambiguous tank lift).
      final net = Network(
        nodes: [
          _n('p', 100, 0, role: NodeRole.plant, component: NodeComponent.pump),
          _n('r', 100, 3, role: NodeRole.plant, component: NodeComponent.roofTank),
        ],
        edges: [_e('e', 'p', 'r', ServiceType.coldWater, kind: EdgeKind.riser)],
      );
      expect(
        riserFunctionFor(net, net.edges.first, downfeed: false),
        RiserFunction.transfer,
      );
    });
  });

  group('riserTags — deterministic per-service numbering', () {
    // Two CW riser stacks at distinct x across 3 floors + one HW riser.
    Network build() => Network(
          nodes: [
            // CW stack A at x=100, floors 0-1-2.
            _n('a0', 100, 0), _n('a1', 100, 1), _n('a2', 100, 2),
            // CW stack B at x=300, floors 0-1-2.
            _n('b0', 300, 0), _n('b1', 300, 1), _n('b2', 300, 2),
            // HW stack at x=200, floors 0-1.
            _n('h0', 200, 0), _n('h1', 200, 1),
          ],
          edges: [
            _e('a01', 'a0', 'a1', ServiceType.coldWater, kind: EdgeKind.riser),
            _e('a12', 'a1', 'a2', ServiceType.coldWater, kind: EdgeKind.riser),
            _e('b01', 'b0', 'b1', ServiceType.coldWater, kind: EdgeKind.riser),
            _e('b12', 'b1', 'b2', ServiceType.coldWater, kind: EdgeKind.riser),
            _e('h01', 'h0', 'h1', ServiceType.hotWater, kind: EdgeKind.riser),
          ],
        );

    test('two CW stacks -> CW-R1 / CW-R2 by ascending x; HW -> HW-R1', () {
      final tags = riserTags(build(), null);
      // Co-linear risers in stack A share one index.
      expect(tags['a01'], 'CW-R1');
      expect(tags['a12'], 'CW-R1');
      // Stack B (larger x) is CW-R2.
      expect(tags['b01'], 'CW-R2');
      expect(tags['b12'], 'CW-R2');
      // The hot-water riser is its own service series.
      expect(tags['h01'], 'HW-R1');
    });

    test('focus restricts tagging to one service', () {
      final tags = riserTags(build(), ServiceType.coldWater);
      expect(tags.containsKey('a01'), isTrue);
      expect(tags.containsKey('b01'), isTrue);
      expect(tags.containsKey('h01'), isFalse);
    });

    test('deterministic across repeated calls', () {
      final net = build();
      expect(riserTags(net, null), riserTags(net, null));
    });

    test('non-riser edges are not tagged', () {
      final net = Network(
        nodes: [_n('a', 100, 0), _n('b', 200, 0)],
        edges: [_e('run', 'a', 'b', ServiceType.coldWater)],
      );
      expect(riserTags(net, null), isEmpty);
    });
  });

  group('floorFanOuts — per-floor branch fan-out', () {
    NetNode fix(String id, double x, int floor) =>
        _n(id, x, floor, role: NodeRole.fixture);

    test('fixtures grouped per floor, ordered by x', () {
      final net = Network(
        nodes: [
          fix('f0b', 300, 0),
          fix('f0a', 100, 0),
          fix('f1', 200, 1),
          _n('junc', 500, 0), // a non-fixture junction — excluded
        ],
        edges: const [],
      );
      final fans = floorFanOuts(net, labelOf: (n) => n.id);
      expect(fans.map((f) => f.floorIndex), [0, 1]);
      // Floor 0: ordered by x (f0a at 100 before f0b at 300).
      expect(fans[0].labels, ['f0a', 'f0b']);
      expect(fans[0].overflow, 0);
      expect(fans[1].labels, ['f1']);
    });

    test('cap + overflow surfaced (6 fixtures, max 4 => 4 labels + overflow 2)',
        () {
      final net = Network(
        nodes: [
          for (var i = 0; i < 6; i++) fix('f$i', i * 100.0, 0),
        ],
        edges: const [],
      );
      final fans = floorFanOuts(net, labelOf: (n) => n.id, max: 4);
      expect(fans, hasLength(1));
      expect(fans.first.labels, ['f0', 'f1', 'f2', 'f3']);
      expect(fans.first.overflow, 2);
    });

    test('focus filter excludes nodes not in the visible set', () {
      final net = Network(
        nodes: [fix('keep', 100, 0), fix('drop', 200, 0)],
        edges: const [],
      );
      final fans = floorFanOuts(
        net,
        visibleNodeIds: {'keep'},
        labelOf: (n) => n.id,
      );
      expect(fans, hasLength(1));
      expect(fans.first.labels, ['keep']);
      expect(fans.first.overflow, 0);
    });

    test('floors with no fixtures are omitted', () {
      final net = Network(
        nodes: [
          fix('f', 100, 2),
          _n('j', 200, 0), // junction-only floor 0 => omitted
        ],
        edges: const [],
      );
      final fans = floorFanOuts(net, labelOf: (n) => n.id);
      expect(fans.map((f) => f.floorIndex), [2]);
    });

    test('deterministic across repeated calls', () {
      final net = Network(
        nodes: [fix('a', 100, 0), fix('b', 200, 0)],
        edges: const [],
      );
      String labels(List<FloorFanOut> f) =>
          f.map((e) => '${e.floorIndex}:${e.labels.join(",")}').join('|');
      expect(labels(floorFanOuts(net, labelOf: (n) => n.id)),
          labels(floorFanOuts(net, labelOf: (n) => n.id)));
    });
  });
}
