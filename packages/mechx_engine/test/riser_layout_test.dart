// Pure unit tests for [riserLayoutPositions] — the ONE horizontal-layout helper
// shared by the on-canvas Auto riser painter and the vector export (B7). It maps
// each visible node to a normalized column x in [0,1], snapping vertically
// co-linear nodes (a riser stack) to a single column so a stack stays vertical
// on BOTH surfaces regardless of how many nodes each floor carries.

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, int floor) =>
    NetNode(id: id, sheetId: 's1', x: x, y: 0, floorIndex: floor);

NetEdge _e(String id, String from, String to, ServiceType service) =>
    NetEdge(id: id, fromId: from, toId: to, service: service);

void main() {
  group('riserLayoutPositions', () {
    test('an empty network yields an empty map', () {
      expect(riserLayoutPositions(const Network(nodes: [], edges: [])),
          isEmpty);
    });

    test('a single node centres at 0.5', () {
      final net = Network(nodes: [_n('a', 42, 0)], edges: const []);
      expect(riserLayoutPositions(net)['a'], 0.5);
    });

    test('a single vertical column (all nodes aligned) centres at 0.5', () {
      // Three nodes sharing one world x across three floors → one column.
      final net = Network(
        nodes: [_n('a', 100, 0), _n('b', 100, 1), _n('c', 100, 2)],
        edges: const [],
      );
      final pos = riserLayoutPositions(net);
      expect(pos['a'], 0.5);
      expect(pos['b'], 0.5);
      expect(pos['c'], 0.5);
    });

    test('a stack stays in ONE column across floors with different node counts',
        () {
      // Floor 0 carries three nodes (x = 100 / 200 / 300); floor 1 carries only
      // two (x = 100 / 300). The x=100 stack and the x=300 stack must land in
      // the SAME column on both floors despite the differing counts — the exact
      // jog the old per-floor rank spread produced (0/2 vs 0/1 etc.).
      final net = Network(
        nodes: [
          _n('a0', 100, 0),
          _n('b0', 200, 0),
          _n('c0', 300, 0),
          _n('a1', 100, 1),
          _n('c1', 300, 1),
        ],
        edges: const [],
      );
      final pos = riserLayoutPositions(net);
      // Three distinct columns → ranks 0 / 1 / 2 → normalized 0.0 / 0.5 / 1.0.
      expect(pos['a0'], 0.0);
      expect(pos['b0'], 0.5);
      expect(pos['c0'], 1.0);
      // The stacks are vertical: the x=100 and x=300 columns match across floors.
      expect(pos['a1'], pos['a0']);
      expect(pos['c1'], pos['c0']);
    });

    test('non-stack nodes keep their left→right rank order', () {
      final net = Network(
        nodes: [_n('mid', 150, 0), _n('left', 50, 0), _n('right', 250, 0)],
        edges: const [],
      );
      final pos = riserLayoutPositions(net);
      expect(pos['left']! < pos['mid']!, isTrue);
      expect(pos['mid']! < pos['right']!, isTrue);
      // Evenly ranked across the band.
      expect(pos['left'], 0.0);
      expect(pos['mid'], 0.5);
      expect(pos['right'], 1.0);
    });

    test('near-identical x values snap into the same column', () {
      // Two nodes within the column bucket tolerance ride one column (vertical),
      // while a node a full bucket away gets its own.
      final net = Network(
        nodes: [
          _n('a', 200, 0),
          _n('b', 205, 1), // within kRiserColumnBucket of a
          _n('c', 400, 0),
        ],
        edges: const [],
      );
      final pos = riserLayoutPositions(net);
      expect(pos['a'], pos['b']); // snapped to one column
      expect(pos['a'], isNot(pos['c'])); // distinct column
    });

    test('focus restricts the layout to that service\'s node set', () {
      final net = Network(
        nodes: [
          _n('cwA', 100, 0),
          _n('cwB', 300, 0),
          _n('drn', 500, 0),
        ],
        edges: [
          _e('cw', 'cwA', 'cwB', ServiceType.coldWater),
          _e('d', 'cwB', 'drn', ServiceType.drainage),
        ],
      );
      final cwOnly =
          riserLayoutPositions(net, focus: ServiceType.coldWater);
      // Only the cold-water endpoints are laid out; the drainage-only node is
      // excluded, so the two CW nodes span the full band (0.0 / 1.0).
      expect(cwOnly.keys.toSet(), {'cwA', 'cwB'});
      expect(cwOnly['cwA'], 0.0);
      expect(cwOnly['cwB'], 1.0);
    });
  });

  group('fflLabel (E6 — one shared elevation notation)', () {
    test('formats the finished-floor-level datum with FFL + two decimals', () {
      // The industry FFL notation the export gutter and the live canvas now
      // share: the abbreviation, a leading '+', and exactly two decimals.
      expect(fflLabel(0), 'FFL +0.00');
      expect(fflLabel(4), 'FFL +4.00');
      expect(fflLabel(7.5), 'FFL +7.50'); // one-decimal input still prints two
      expect(fflLabel(12.345), 'FFL +12.35'); // rounds to two decimals
    });
  });
}
