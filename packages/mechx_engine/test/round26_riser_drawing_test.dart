// Round 26 (2026-10-18) — riser drawing fidelity:
//
//   riser-drafting-3-6  a paginated set prints the HWR recirc pump ONCE, on
//                        the page holding the building's lowest HW riser node
//   hot-water-2-phantom  one dashed HWR return leg per riser STACK (never one
//                        per storey segment) and no HWR PUMP beside a pump
//                        already drawn on the hot-water service
//   riser-drafting-3-3  the B5 coincident spread is ONE shared pure helper
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, int floor,
        {NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.hotWater, EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

BuildingLevels _building(int storeys) => BuildingLevels([
      for (var i = 0; i < storeys; i++) Floor('Lantai ${i + 1}', const Length(3.5))
    ]);

/// A heater on the ground floor feeding a 4-storey hot-water riser stack
/// (3 riser SEGMENTS, one stack), a shower on every floor; [pumpDrawn] puts
/// a recirculation pump on the heater outlet.
Network _hw({bool pumpDrawn = false}) {
  final nodes = <NetNode>[
    _n('H', 100, 0, role: NodeRole.plant),
    if (pumpDrawn) _n('P', 150, 0, role: NodeRole.plant, c: NodeComponent.pump),
    for (var f = 0; f < 4; f++) ...[
      _n('R$f', 200, f),
      _n('S$f', 400, f, role: NodeRole.fixture),
    ],
  ];
  final edges = <NetEdge>[
    if (pumpDrawn) ...[_e('hp', 'H', 'P'), _e('pr', 'P', 'R0')] else
      _e('hr', 'H', 'R0'),
    for (var f = 0; f < 3; f++)
      _e('r$f', 'R$f', 'R${f + 1}', k: EdgeKind.riser),
    for (var f = 0; f < 4; f++) _e('s$f', 'R$f', 'S$f'),
  ];
  return Network(nodes: nodes, edges: edges);
}

int _count(SldSheet s, String text) =>
    s.prims.whereType<SldLabel>().where((l) => l.text == text).length;

void main() {
  final b = _building(4);

  test('one stack of three segments draws ONE HWR leg and one HWR PUMP', () {
    final s = buildMechanicalRiserSld(
        network: _hw(), building: b, focus: ServiceType.hotWater,
        hotWaterRecirc: true);
    expect(_count(s, 'HWR'), 1);
    expect(_count(s, 'HWR PUMP'), 1);
  });

  test('a recirc pump already drawn on the HW service gets no phantom twin',
      () {
    final s = buildMechanicalRiserSld(
        network: _hw(pumpDrawn: true), building: b,
        focus: ServiceType.hotWater, hotWaterRecirc: true);
    expect(_count(s, 'HWR PUMP'), 0);
  });

  test('a paginated set prints the HWR PUMP on the lowest page only', () {
    SldSheet page(int lo, int hi) => buildMechanicalRiserSld(
        network: _hw(), building: b, focus: ServiceType.hotWater,
        hotWaterRecirc: true, floorRange: (lo: lo, hi: hi));
    expect(_count(page(2, 3), 'HWR PUMP'), 0, reason: 'upper page');
    expect(_count(page(0, 1), 'HWR PUMP'), 1, reason: 'ground page');
  });

  group('coincidentSpreadDx', () {
    test('two nodes on one floor + x are centred apart by one step', () {
      // base 100, step 18, group sorted by id [a, b]:
      //   a → 100 + (0 − 0.5)·18 = 91 (dx −9); b → 100 + 0.5·18 = 109 (+9).
      final dx = coincidentSpreadDx(
          x: {'b': 100, 'a': 100, 'c': 100, 'd': 300},
          floorOf: {'a': 0, 'b': 0, 'c': 1, 'd': 0},
          step: 18);
      expect(dx['a'], -9);
      expect(dx['b'], 9);
      expect(dx.containsKey('c'), isFalse, reason: 'alone on its floor');
      expect(dx.containsKey('d'), isFalse);
    });

    test('property: a spread group never stays coincident (seeded sizes)', () {
      for (var n = 2; n <= 7; n++) {
        final ids = [for (var i = 0; i < n; i++) 'n$i'];
        final dx = coincidentSpreadDx(
            x: {for (final id in ids) id: 50.0},
            floorOf: {for (final id in ids) id: 2},
            step: 24);
        final xs = [for (final id in ids) 50.0 + dx[id]!]..sort();
        for (var i = 1; i < xs.length; i++) {
          expect(xs[i] - xs[i - 1], closeTo(24, 1e-9));
        }
        // Centred on the shared point.
        expect(xs.reduce((a, c) => a + c) / n, closeTo(50, 1e-9));
      }
    });
  });
}
