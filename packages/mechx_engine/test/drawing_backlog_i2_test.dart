// Drawing backlog I-2 (2026-11-13) — plant-level riser pages tag their plant
// directly: the plant group (tanks, pumps, booster, PRV, water meter and the
// trunks between them) is drawn in its own row under the fixture band, or on
// its own '<floor> - PLANT' page when the two bands do not fit at 7 pt.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart' show kMinPlotLabelPt;
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/riser_pagination.dart';
import 'package:mechx_engine/report/riser_tags.dart' show riserLayoutPositions;
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:test/test.dart';

import 'reference/apartment.dart';

SldSheet _sheet({
  int keys = 0,
  int plantKeys = 0,
  int overlap = 0,
  double h = 300,
  String tag = 'X',
}) =>
    SldSheet(
        prims: [SldLabel(0, 10, tag, size: 8)],
        minX: 0,
        minY: 0,
        maxX: 600,
        maxY: h,
        legend: const [],
        supplyNote: '',
        overlapCount: overlap,
        keyCount: keys,
        plantKeyCount: plantKeys);

Set<String> _texts(SldSheet s) =>
    s.prims.whereType<SldLabel>().map((l) => l.text).toSet();

void main() {
  final apt = buildApartment();
  final net = apt.network;
  List<NetNode> floor0(Network n) =>
      n.nodes.where((m) => m.floorIndex == 0).toList();

  group('the plant group of a floor', () {
    test('tanks, pumps, meter and PRV join; fixtures and riser ends never',
        () {
      final g = riserPlantGroup(net, floor0(net));
      final byId = {for (final n in net.nodes) n.id: n};
      expect(g, isNotEmpty);
      for (final id in g) {
        final n = byId[id]!;
        expect(n.role, isNot(NodeRole.fixture), reason: id);
      }
      // Every plant component on the floor is a member.
      for (final n in floor0(net)) {
        if (kRiserPlantComponents.contains(n.component)) {
          expect(g, contains(n.id));
        }
      }
      // Order-independent.
      final shuffled = Network(
          nodes: net.nodes.reversed.toList(),
          edges: net.edges.reversed.toList());
      expect(riserPlantGroup(shuffled, floor0(shuffled)), g);
      expect(
          riserPlantOrder(shuffled, g, riserLayoutPositions(shuffled)),
          riserPlantOrder(net, g, riserLayoutPositions(net)));
    });

    test('a member between two members joins (a valve between two pumps)',
        () {
      const n = Network(nodes: [
        NetNode(
            id: 'p1',
            sheetId: 's',
            x: 0,
            y: 0,
            floorIndex: 0,
            role: NodeRole.plant,
            component: NodeComponent.pump),
        NetNode(
            id: 'v',
            sheetId: 's',
            x: 10,
            y: 0,
            floorIndex: 0,
            component: NodeComponent.gateValve),
        NetNode(
            id: 'p2',
            sheetId: 's',
            x: 20,
            y: 0,
            floorIndex: 0,
            role: NodeRole.plant,
            component: NodeComponent.pump),
        NetNode(id: 'j', sheetId: 's', x: 30, y: 0, floorIndex: 0),
      ], edges: [
        NetEdge(id: 'a', fromId: 'p1', toId: 'v', service: ServiceType.coldWater),
        NetEdge(id: 'b', fromId: 'v', toId: 'p2', service: ServiceType.coldWater),
        NetEdge(id: 'c', fromId: 'p2', toId: 'j', service: ServiceType.coldWater),
      ]);
      expect(riserPlantGroup(n, n.nodes), {'p1', 'v', 'p2'});
      // The trunk chain lays out adjacent, left to right.
      expect(riserPlantOrder(n, {'p1', 'v', 'p2'}, {'p1': 0.9, 'v': 0.1, 'p2': 0.5}),
          ['v', 'p2', 'p1']);
    });
  });

  test('the plant row packs left to right and wraps at the band edge', () {
    final rows = riserPlantRows(['a', 'b', 'c'], (id) => 100, lo: 0, hi: 250);
    expect(rows.length, 2);
    expect([for (final m in rows[0]) m.id], ['a', 'b']);
    expect([for (final m in rows[0]) m.x], [50, 150]);
    expect([for (final m in rows[1]) m.x], [50]);
  });

  test('a plant row replaces the page only with fewer plant keys, no more '
      'overprints and a width-bound drawing', () {
    final best = _sheet(plantKeys: 3, h: 280);
    expect(riserPlantRowWins(best: best, row: _sheet(plantKeys: 1, h: 290)),
        isTrue);
    expect(riserPlantRowWins(best: best, row: _sheet(plantKeys: 3, h: 290)),
        isFalse);
    expect(
        riserPlantRowWins(
            best: best, row: _sheet(plantKeys: 0, overlap: 1, h: 290)),
        isFalse);
    // Too tall: no longer width-bound (h / w > 0.5 and taller than best).
    expect(riserPlantRowWins(best: best, row: _sheet(plantKeys: 0, h: 400)),
        isFalse);
  });

  group('the plant split', () {
    SldSheet part(int k) => buildMechanicalRiserSld(
        network: net,
        building: apt.building,
        floorRange: (lo: 0, hi: 0),
        columnPart: k,
        plant: MechRiserPlant.split);
    test('part 1 hands its plant runs to the PLANT page, which names it', () {
      final p1 = _texts(part(1)), p2 = _texts(part(2));
      expect(p1, contains('LANJUT KE Lantai 1 - PLANT'));
      expect(p1, isNot(contains('Lantai 1 - PLANT')));
      expect(p2, contains('Lantai 1 - PLANT'));
      // Fix round 3 (O2) — each 'LANJUTAN DARI' mark names its pipe tag.
      final marks = p2.where((t) => t.startsWith('LANJUTAN DARI Lantai 1'));
      expect(marks, isNotEmpty);
      for (final m in marks) {
        expect(m, matches(RegExp(r'^LANJUTAN DARI Lantai 1 \(.+\)$')),
            reason: m);
      }
      // No column-split captions on a plant split.
      expect(p1.where((t) => t.startsWith('BAGIAN')), isEmpty);
      expect(p2.where((t) => t.startsWith('BAGIAN')), isEmpty);
      // The PLANT page keys fewer plant items than the floor drawn whole.
      final whole = buildMechanicalRiserSld(
          network: net,
          building: apt.building,
          floorRange: (lo: 0, hi: 0),
          plant: MechRiserPlant.none);
      expect(part(2).plantKeyCount, lessThan(whole.plantKeyCount));
    });

    test('a page without plant keys is built as before (byte-identical)', () {
      const r = (lo: 5, hi: 5);
      final auto = buildMechanicalRiserSld(
          network: net, building: apt.building, floorRange: r);
      final none = buildMechanicalRiserSld(
          network: net,
          building: apt.building,
          floorRange: r,
          plant: MechRiserPlant.none);
      expect(auto.plantKeyCount, 0);
      expect(auto.prims.length, none.prims.length);
      expect(_texts(auto), _texts(none));
      expect(auto.maxY, none.maxY);
    });
  });

  group('the paginator gives the plant its row or its own page', () {
    // One storey (a lone plant-level page) at 7 pt with 4 plant keys.
    List<SldSheet> paginate({
      required SldSheet row,
      required List<SldSheet> parts,
    }) =>
        paginatedRiserSheets(
          build: (r) => r == null || r.lo != r.hi
              ? _sheet(h: 9000, tag: 'TALL')
              : _sheet(keys: 10, plantKeys: 4, tag: 'WHOLE'),
          levelCount: 2,
          buildPlantRow: (r, bare) => row,
          buildPlantPart: (r, k, bare) => parts[k - 1],
        );

    test('the row when it keys fewer plant items at the same size', () {
      // Two storeys never share a page (too tall at 7 pt).
      final out = paginatedRiserSheets(
        build: (r) => r == null || r.lo != r.hi
            ? _sheet(plantKeys: 4, h: 9000, tag: 'TALL')
            : _sheet(keys: 10, plantKeys: 4, tag: 'F${r.lo}'),
        levelCount: 2,
        buildPlantRow: (r, bare) => _sheet(keys: 6, tag: 'ROW${r.lo}'),
        buildPlantPart: (r, k, bare) => _sheet(tag: 'PART$k'),
      );
      final tags = [for (final p in out) _texts(p).single];
      expect(tags.where((t) => t.startsWith('ROW')), isNotEmpty);
      expect(tags.where((t) => t.startsWith('PART')), isEmpty);
    });

    test('the PLANT page when the row would print below 7 pt', () {
      final out = paginatedRiserSheets(
        build: (r) => r == null || r.lo != r.hi
            ? _sheet(plantKeys: 4, h: 9000, tag: 'TALL')
            : _sheet(keys: 10, plantKeys: 4, tag: 'F${r.lo}'),
        levelCount: 2,
        // Far too tall for the A3 drawing area: prints below 7 pt.
        buildPlantRow: (r, bare) => _sheet(h: 40000, tag: 'ROW${r.lo}'),
        buildPlantPart: (r, k, bare) => _sheet(tag: 'F${r.lo}-PART$k'),
      );
      final tags = [for (final p in out) _texts(p).single];
      expect(tags.where((t) => t.startsWith('ROW')), isEmpty);
      // Each floor page is followed by its PLANT page (top floor first).
      expect(tags, ['F1-PART1', 'F1-PART2', 'F0-PART1', 'F0-PART2']);
      for (final p in out) {
        expect(p.belowMinLabelPt, isNull);
      }
    });

    test('neither when they key no fewer plant items', () {
      final out = paginate(
        row: _sheet(keys: 9, plantKeys: 4),
        parts: [_sheet(plantKeys: 2), _sheet(plantKeys: 2)],
      );
      expect([for (final p in out) _texts(p).single], everyElement('WHOLE'));
      expect(kMinPlotLabelPt, 7);
    });
  });
}
