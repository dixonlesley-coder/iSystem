import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx_engine/network/network.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  /// A1: production launches EMPTY; the placeholder sheets are a test/golden
  /// seed only. Tests below that navigate/map sheets seed them explicitly.
  ProviderContainer makeSeededContainer() {
    final c = makeContainer();
    c.read(sheetsControllerProvider.notifier).loadDemoSheets();
    return c;
  }

  test('starts EMPTY — no placeholder sheets on first launch (A1)', () {
    final c = makeContainer();
    final s = c.read(sheetsControllerProvider);
    expect(s.isEmpty, isTrue);
    expect(s.sheets, isEmpty);
    expect(s.current, isNull);
  });

  test('loadDemoSheets seeds the demo project, first selected', () {
    final c = makeSeededContainer();
    final s = c.read(sheetsControllerProvider);
    expect(s.sheets.length, 3);
    expect(s.sheets, kDemoSheets);
    expect(s.currentIndex, 0);
    expect(s.current?.name, 'Ground Floor');
  });

  test('selectSheet changes the current sheet', () {
    final c = makeSeededContainer();
    c.read(sheetsControllerProvider.notifier).selectSheet(2);
    expect(c.read(sheetsControllerProvider).current?.id, 's3');
  });

  test('selectSheet ignores out-of-range indices', () {
    final c = makeSeededContainer();
    c.read(sheetsControllerProvider.notifier).selectSheet(99);
    expect(c.read(sheetsControllerProvider).currentIndex, 0);
  });

  test('viewport persists per sheet and restores; others stay unframed', () {
    final c = makeSeededContainer();
    final ctrl = c.read(sheetsControllerProvider.notifier);
    const vt = ViewportTransform(scale: 2.5, offset: Offset(12, 34));
    ctrl.setViewport('s2', vt);
    expect(c.read(sheetsControllerProvider).viewportFor('s2'), vt);
    expect(c.read(sheetsControllerProvider).viewportFor('s1'), isNull);
  });

  test('loadSheets replaces and resets selection + viewports', () {
    final c = makeSeededContainer();
    final ctrl = c.read(sheetsControllerProvider.notifier);
    ctrl.setViewport('s1', const ViewportTransform(scale: 3));
    ctrl.loadSheets(const [Sheet(id: 'x', name: 'X')]);
    final s = c.read(sheetsControllerProvider);
    expect(s.sheets.single.id, 'x');
    expect(s.currentIndex, 0);
    expect(s.viewportFor('s1'), isNull);
  });

  test('floorFor: positional default, explicit override, clamped', () {
    final c = makeSeededContainer();
    final ctrl = c.read(sheetsControllerProvider.notifier);
    // 3 demo sheets s1,s2,s3 → positional floors 0,1,2 within a 3-floor model.
    var s = c.read(sheetsControllerProvider);
    expect(s.floorFor('s1', 3), 0);
    expect(s.floorFor('s2', 3), 1);
    expect(s.floorFor('s3', 3), 2);
    // explicit override
    ctrl.setSheetFloor('s3', 0);
    s = c.read(sheetsControllerProvider);
    expect(s.floorFor('s3', 3), 0);
    // clamped to the building's level count
    expect(s.floorFor('s2', 1), 0); // positional 1 → clamp to 0 when 1 level
  });

  test('setSheetFloor is undoable via the global history timeline', () {
    final c = makeSeededContainer();
    final sheets = c.read(sheetsControllerProvider.notifier);
    final history = c.read(historyProvider.notifier);

    // s3's positional default is floor 2; override it to 0.
    sheets.setSheetFloor('s3', 0);
    expect(c.read(sheetsControllerProvider).floorFor('s3', 3), 0);
    expect(history.canUndo, isTrue);

    // Undo on the global timeline reverts the mapping to its positional default.
    history.undo();
    expect(c.read(sheetsControllerProvider).floorFor('s3', 3), 2);

    // Redo restores the override.
    history.redo();
    expect(c.read(sheetsControllerProvider).floorFor('s3', 3), 0);
  });

  test('setSheetFloor remaps the sheet\'s drawn nodes with the mapping (B7)', () {
    final c = makeSeededContainer();
    final sheets = c.read(sheetsControllerProvider.notifier);
    final net = c.read(networkControllerProvider.notifier);
    // s3's positional default is floor 2. Draw work on s3 (floor 2) and on s2
    // (floor 1); the s2 work must NOT move when only s3 is re-mapped.
    net.loadNetwork(const Network(nodes: [
      NetNode(id: 'a', sheetId: 's3', x: 0, y: 0, floorIndex: 2),
      NetNode(id: 'b', sheetId: 's3', x: 10, y: 0, floorIndex: 2),
      NetNode(id: 'd', sheetId: 's2', x: 0, y: 0, floorIndex: 1),
    ]));

    // Re-map s3 down to floor 0 — its nodes drop by 2 floors WITH it.
    sheets.setSheetFloor('s3', 0);
    final floors = {
      for (final n in c.read(networkControllerProvider).network.nodes)
        n.id: n.floorIndex
    };
    expect(floors['a'], 0);
    expect(floors['b'], 0);
    expect(floors['d'], 1); // other sheet — untouched
    expect(c.read(sheetsControllerProvider).floorFor('s3', 3), 0);
  });

  test('setSheetFloor shifts a floor-spanning riser as a pair (B7)', () {
    final c = makeSeededContainer();
    final sheets = c.read(sheetsControllerProvider.notifier);
    final net = c.read(networkControllerProvider.notifier);
    // A riser on s1: lower on floor 0, upper on floor 1, both on s1.
    net.loadNetwork(const Network(
      nodes: [
        NetNode(id: 'lo', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'hi', sheetId: 's1', x: 0, y: 0, floorIndex: 1),
      ],
      edges: [
        NetEdge(
            id: 'r',
            fromId: 'lo',
            toId: 'hi',
            service: ServiceType.coldWater,
            kind: EdgeKind.riser),
      ],
    ));

    // Move s1 up to floor 1 (+1): both endpoints shift, so the 1-floor span is
    // preserved (0→1 becomes 1→2).
    sheets.setSheetFloor('s1', 1);
    final floors = {
      for (final n in c.read(networkControllerProvider).network.nodes)
        n.id: n.floorIndex
    };
    expect(floors['lo'], 1);
    expect(floors['hi'], 2);
  });

  test('setSheetFloor restores the mapping AND node indices in ONE undo (B7)',
      () {
    final c = makeSeededContainer();
    final sheets = c.read(sheetsControllerProvider.notifier);
    final net = c.read(networkControllerProvider.notifier);
    final history = c.read(historyProvider.notifier);
    // Two nodes drawn on s3 (floor 2) plus one on s2 (floor 1, must not move).
    net.loadNetwork(const Network(nodes: [
      NetNode(id: 'a', sheetId: 's3', x: 0, y: 0, floorIndex: 2),
      NetNode(id: 'b', sheetId: 's3', x: 10, y: 0, floorIndex: 2),
      NetNode(id: 'd', sheetId: 's2', x: 0, y: 0, floorIndex: 1),
    ]));

    sheets.setSheetFloor('s3', 0);
    Map<String, int> floorsNow() => {
          for (final n in c.read(networkControllerProvider).network.nodes)
            n.id: n.floorIndex
        };
    expect(floorsNow(), {'a': 0, 'b': 0, 'd': 1});
    expect(c.read(sheetsControllerProvider).floorFor('s3', 3), 0);

    // The mapping change + the node remap are ONE structural entry: a SINGLE
    // undo restores BOTH the mapping and the node floors together (the old torn
    // behaviour needed two undos and left a stranded intermediate).
    history.undo();
    expect(floorsNow(), {'a': 2, 'b': 2, 'd': 1});
    expect(c.read(sheetsControllerProvider).floorFor('s3', 3), 2);
    expect(history.canUndo, isFalse); // exactly one entry consumed

    // Redo re-applies BOTH halves in the same one step.
    history.redo();
    expect(floorsNow(), {'a': 0, 'b': 0, 'd': 1});
    expect(c.read(sheetsControllerProvider).floorFor('s3', 3), 0);
  });

  test('setSheetFloor with no drawn nodes is one-step-undoable (no network step)',
      () {
    final c = makeSeededContainer();
    final sheets = c.read(sheetsControllerProvider.notifier);
    final net = c.read(networkControllerProvider.notifier);
    final history = c.read(historyProvider.notifier);

    sheets.setSheetFloor('s3', 0);
    // Empty network ⇒ the remap is a byte-identical no-op (no network entry);
    // the mapping change is a single structural step on the global timeline.
    expect(net.canUndo, isFalse);
    expect(history.canUndo, isTrue);

    history.undo();
    expect(c.read(sheetsControllerProvider).floorFor('s3', 3), 2);
    expect(history.canUndo, isFalse);
  });

  group('replaceSheetSource (A5 per-sheet plan revision, keeps the id)', () {
    test('swaps the source PDF path + size but KEEPS the sheet id and name', () {
      final c = makeContainer();
      final sheets = c.read(sheetsControllerProvider.notifier);
      sheets.loadSheets(const [
        Sheet(id: 'denah#0', name: 'Ground', pdfPath: '/old/denah.pdf'),
      ]);

      sheets.replaceSheetSource(
        'denah#0',
        const Sheet(
          id: 'revB#0', // the parsed sheet's id is IGNORED
          name: 'revB p1', //   and its name too
          pdfPath: '/new/denahRevB.pdf',
          pageIndex: 0,
          sizePx: Size(2000, 1400),
        ),
      );

      final s = c.read(sheetsControllerProvider).sheets.single;
      expect(s.id, 'denah#0'); // id preserved: calibration + nodes still marry
      expect(s.name, 'Ground'); // display name preserved
      expect(s.pdfPath, '/new/denahRevB.pdf'); // source swapped
      expect(s.sizePx, const Size(2000, 1400));
    });

    test('a PDF→DXF swap clears the stale pdfPath (source taken wholesale)', () {
      final c = makeContainer();
      final sheets = c.read(sheetsControllerProvider.notifier);
      sheets.loadSheets(const [
        Sheet(id: 'p#0', name: 'Plan', pdfPath: '/old/plan.pdf'),
      ]);

      sheets.replaceSheetSource(
        'p#0',
        const Sheet(id: 'q#0', name: 'q', dxfPath: '/new/plan.dxf'),
      );

      final s = c.read(sheetsControllerProvider).sheets.single;
      expect(s.pdfPath, isNull); // stale PDF path cleared
      expect(s.dxfPath, '/new/plan.dxf');
    });

    test('is a no-op when the sheet id is gone', () {
      final c = makeContainer();
      final sheets = c.read(sheetsControllerProvider.notifier);
      sheets.loadSheets(const [Sheet(id: 'a', name: 'A', pdfPath: '/a.pdf')]);
      final before = c.read(sheetsControllerProvider).sheets;

      sheets.replaceSheetSource(
          'missing', const Sheet(id: 'x', name: 'X', pdfPath: '/x.pdf'));

      expect(c.read(sheetsControllerProvider).sheets, same(before));
    });
  });

  group('addSheets (A6 multi-file add)', () {
    test('appends every incoming sheet, returning the count', () {
      final c = makeContainer();
      final ctrl = c.read(sheetsControllerProvider.notifier);
      final added = ctrl.addSheets(const [
        Sheet(id: 'a#0', name: 'A', pdfPath: '/a.pdf'),
        Sheet(id: 'b#0', name: 'B', dxfPath: '/b.dxf'),
      ]);
      expect(added, 2);
      expect(c.read(sheetsControllerProvider).sheets.map((s) => s.id),
          ['a#0', 'b#0']);
    });

    test('remaps an incoming id that collides with a LIVE sheet', () {
      final c = makeContainer();
      final ctrl = c.read(sheetsControllerProvider.notifier);
      ctrl.loadSheets(const [Sheet(id: 'a#0', name: 'A', pdfPath: '/a.pdf')]);
      ctrl.addSheets(const [
        Sheet(id: 'a#0', name: 'A again', pdfPath: '/dup.pdf'),
        Sheet(id: 'b#0', name: 'B', pdfPath: '/b.pdf'),
      ]);
      final ids = c.read(sheetsControllerProvider).sheets.map((s) => s.id);
      expect(ids, ['a#0', 'a#0-1', 'b#0']); // collision → fresh unique id
      expect(ids.toSet().length, 3);
    });

    test('remaps collisions WITHIN the incoming batch too', () {
      final c = makeContainer();
      final ctrl = c.read(sheetsControllerProvider.notifier);
      final added = ctrl.addSheets(const [
        Sheet(id: 'x#0', name: 'X1'),
        Sheet(id: 'x#0', name: 'X2'),
        Sheet(id: 'x#0', name: 'X3'),
      ]);
      expect(added, 3);
      expect(c.read(sheetsControllerProvider).sheets.map((s) => s.id),
          ['x#0', 'x#0-1', 'x#0-2']);
    });

    test('an empty batch is a no-op returning 0', () {
      final c = makeContainer();
      final ctrl = c.read(sheetsControllerProvider.notifier);
      expect(ctrl.addSheets(const []), 0);
      expect(c.read(sheetsControllerProvider).sheets, isEmpty);
    });
  });

  group('renameSheet (A6 rail context menu)', () {
    test('renames + trims, keeping the id and source', () {
      final c = makeContainer();
      final ctrl = c.read(sheetsControllerProvider.notifier);
      ctrl.loadSheets(const [Sheet(id: 's', name: 'Old', pdfPath: '/s.pdf')]);
      ctrl.renameSheet('s', '  New name  ');
      final s = c.read(sheetsControllerProvider).sheets.single;
      expect(s.id, 's'); // id preserved: calibration + nodes still marry
      expect(s.name, 'New name'); // trimmed
      expect(s.pdfPath, '/s.pdf'); // source untouched
    });

    test('no-op for empty, unchanged, or unknown id', () {
      final c = makeContainer();
      final ctrl = c.read(sheetsControllerProvider.notifier);
      ctrl.loadSheets(const [Sheet(id: 's', name: 'Keep')]);
      final before = c.read(sheetsControllerProvider).sheets;
      ctrl.renameSheet('s', '   '); // empty after trim
      ctrl.renameSheet('s', 'Keep'); // unchanged
      ctrl.renameSheet('missing', 'X'); // unknown id
      expect(c.read(sheetsControllerProvider).sheets, same(before));
    });
  });

  group('removeSheet (A6 undo-safe prune)', () {
    test('drops the sheet + its per-sheet viewport/floor maps, clamps index',
        () {
      final c = makeSeededContainer();
      final ctrl = c.read(sheetsControllerProvider.notifier);
      ctrl.setViewport('s2', const ViewportTransform(scale: 2));
      ctrl.setSheetFloor('s2', 0);
      ctrl.selectSheet(2); // s3

      ctrl.removeSheet('s3');
      var s = c.read(sheetsControllerProvider);
      expect(s.sheets.map((e) => e.id), ['s1', 's2']);
      expect(s.currentIndex, 1); // clamped from 2

      ctrl.removeSheet('s2');
      s = c.read(sheetsControllerProvider);
      expect(s.viewportFor('s2'), isNull);
      expect(s.sheetFloors.containsKey('s2'), isFalse);
    });

    test('keeps the selection on the same sheet when an EARLIER one is removed',
        () {
      final c = makeSeededContainer();
      final ctrl = c.read(sheetsControllerProvider.notifier);
      ctrl.selectSheet(2); // s3
      ctrl.removeSheet('s1'); // an earlier sheet
      final s = c.read(sheetsControllerProvider);
      expect(s.sheets.map((e) => e.id), ['s2', 's3']);
      expect(s.current?.id, 's3'); // selection followed the same sheet
    });

    test('prunes the removed sheet\'s nodes + edges, and is ONE undo/redo step',
        () {
      final c = makeSeededContainer();
      final sheets = c.read(sheetsControllerProvider.notifier);
      final net = c.read(networkControllerProvider.notifier);
      final history = c.read(historyProvider.notifier);
      net.loadNetwork(const Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's3', x: 0, y: 0, floorIndex: 2),
          NetNode(id: 'b', sheetId: 's3', x: 10, y: 0, floorIndex: 2),
          NetNode(id: 'k', sheetId: 's2', x: 0, y: 0, floorIndex: 1),
        ],
        edges: [
          NetEdge(
              id: 'e-ab',
              fromId: 'a',
              toId: 'b',
              service: ServiceType.coldWater,
              kind: EdgeKind.run),
        ],
      ));

      Set<String> nodeIds() => c
          .read(networkControllerProvider)
          .network
          .nodes
          .map((n) => n.id)
          .toSet();

      sheets.removeSheet('s3');
      // s3's nodes + the edge between them are gone; s2's node stays.
      expect(nodeIds(), {'k'});
      expect(c.read(networkControllerProvider).network.edges, isEmpty);
      expect(c.read(sheetsControllerProvider).sheets.map((e) => e.id),
          ['s1', 's2']);
      expect(history.canUndo, isTrue);

      // ONE undo restores BOTH the sheet AND its pruned nodes/edge together.
      history.undo();
      expect(nodeIds(), {'a', 'b', 'k'});
      expect(c.read(networkControllerProvider).network.edges.length, 1);
      expect(c.read(sheetsControllerProvider).sheets.map((e) => e.id),
          ['s1', 's2', 's3']);
      expect(history.canUndo, isFalse); // exactly one entry consumed

      // Redo re-removes both halves in the same one step.
      history.redo();
      expect(nodeIds(), {'k'});
      expect(c.read(sheetsControllerProvider).sheets.map((e) => e.id),
          ['s1', 's2']);
    });

    test('is a no-op (no history entry) for an unknown sheet id', () {
      final c = makeSeededContainer();
      final sheets = c.read(sheetsControllerProvider.notifier);
      final history = c.read(historyProvider.notifier);
      sheets.removeSheet('nope');
      expect(c.read(sheetsControllerProvider).sheets.length, 3);
      expect(history.canUndo, isFalse);
    });

    test(
        'removing a NON-LAST sheet remaps siblings\' drawn work down a floor '
        '(no silent hiding)', () {
      final c = makeSeededContainer();
      final sheets = c.read(sheetsControllerProvider.notifier);
      final net = c.read(networkControllerProvider.notifier);
      final history = c.read(historyProvider.notifier);
      // Positional defaults: s1->f0, s2->f1, s3->f2. Work drawn on s2 (floor 1)
      // and s3 (floor 2), frozen at those floor indices.
      net.loadNetwork(const Network(
        nodes: [
          NetNode(id: 'p', sheetId: 's2', x: 0, y: 0, floorIndex: 1),
          NetNode(id: 'q', sheetId: 's3', x: 0, y: 0, floorIndex: 2),
        ],
        edges: [],
      ));
      int floorOf(String id) => c
          .read(networkControllerProvider)
          .network
          .nodes
          .firstWhere((n) => n.id == id)
          .floorIndex;

      // Remove the FIRST sheet — s2 becomes positional floor 0, s3 floor 1.
      sheets.removeSheet('s1');
      // The drawn work followed the mapping instead of vanishing (canvas filters
      // on sheetId AND floorIndex, so a stale index would hide it).
      expect(floorOf('p'), 0, reason: 's2 work shifted 1 -> 0');
      expect(floorOf('q'), 1, reason: 's3 work shifted 2 -> 1');

      // ONE undo restores the sheet AND both node floor indices together.
      history.undo();
      expect(c.read(sheetsControllerProvider).sheets.map((e) => e.id),
          ['s1', 's2', 's3']);
      expect(floorOf('p'), 1);
      expect(floorOf('q'), 2);
    });
  });
}
