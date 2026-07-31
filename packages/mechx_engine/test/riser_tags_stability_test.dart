/// B4 — riser TAGS must not renumber under a drag.
///
/// `riserTags` used to number the per-service stacks in ascending-x order, so
/// moving a riser sideways (the diagram declutter gesture, or any plan-side
/// endpoint drag) swapped `CW-R1` and `CW-R2` across the plan labels, the riser
/// single-line, the BOM tag column and the calc report between revisions — with
/// no diff and no warning. The numbering now seeds from a STABLE first-assigned
/// ordinal: the earliest position, in the network's node list (insertion =
/// creation order), of any node the stack touches.
library;

import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, int floor) =>
    NetNode(id: id, sheetId: 's1', x: x, y: 0, floorIndex: floor);

NetEdge _riser(String id, String from, String to, ServiceType service) =>
    NetEdge(
      id: id,
      fromId: from,
      toId: to,
      service: service,
      kind: EdgeKind.riser,
    );

void main() {
  // Two cold-water stacks drawn LEFT then RIGHT: stack A (x = 100) is drawn
  // first, so its nodes lead the node list; stack B (x = 300) follows.
  Network built({double aX = 100, double bX = 300}) => Network(
        nodes: [
          _n('n0', aX, 0), _n('n1', aX, 1),
          _n('n2', bX, 0), _n('n3', bX, 1),
        ],
        edges: [
          _riser('e0', 'n0', 'n1', ServiceType.coldWater),
          _riser('e1', 'n2', 'n3', ServiceType.coldWater),
        ],
      );

  test('the first-drawn stack is R1 (unchanged for the ordinary case)', () {
    final tags = riserTags(built(), null);
    expect(tags['e0'], 'CW-R1');
    expect(tags['e1'], 'CW-R2');
  });

  test('B4 — dragging a stack PAST another never renumbers either', () {
    final before = riserTags(built(), null);
    // Stack A (drawn first, R1) is dragged right, past stack B: it is now the
    // larger x. Under the old ascending-x numbering both tags swapped; the
    // first-assigned ordinal is untouched by geometry, so both keep theirs.
    final after = riserTags(built(aX: 900), null);
    expect(after['e0'], before['e0']);
    expect(after['e1'], before['e1']);
    expect(after['e0'], 'CW-R1');
    expect(after['e1'], 'CW-R2');
  });

  test('B4 — a NEW stack takes the next number, left of the others or not', () {
    // A third stack is drawn LAST but at the SMALLEST x. It appends to the node
    // list, so its first-assigned ordinal is the largest → CW-R3, and the two
    // existing stacks keep R1 / R2.
    final base = built();
    final grown = Network(
      nodes: [...base.nodes, _n('n4', 10, 0), _n('n5', 10, 1)],
      edges: [...base.edges, _riser('e2', 'n4', 'n5', ServiceType.coldWater)],
    );
    final tags = riserTags(grown, null);
    expect(tags['e0'], 'CW-R1');
    expect(tags['e1'], 'CW-R2');
    expect(tags['e2'], 'CW-R3');
  });

  test('co-linear risers across floors still share one stack tag', () {
    final net = Network(
      nodes: [_n('n0', 100, 0), _n('n1', 100, 1), _n('n2', 100, 2)],
      edges: [
        _riser('e0', 'n0', 'n1', ServiceType.coldWater),
        _riser('e1', 'n1', 'n2', ServiceType.coldWater),
      ],
    );
    final tags = riserTags(net, null);
    expect(tags['e0'], 'CW-R1');
    expect(tags['e1'], 'CW-R1');
  });

  test('each service keeps its own series, and the result is deterministic',
      () {
    final net = Network(
      nodes: [
        _n('n0', 100, 0), _n('n1', 100, 1), // CW
        _n('n2', 300, 0), _n('n3', 300, 1), // HW
      ],
      edges: [
        _riser('e0', 'n0', 'n1', ServiceType.coldWater),
        _riser('e1', 'n2', 'n3', ServiceType.hotWater),
      ],
    );
    final tags = riserTags(net, null);
    expect(tags['e0'], 'CW-R1');
    expect(tags['e1'], 'HW-R1');
    expect(riserTags(net, null), tags);
  });
}
