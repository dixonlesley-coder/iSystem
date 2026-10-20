import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/base_point_command_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/smart_input_store.dart';
import 'package:mechx/ui/canvas/base_point_overlay.dart'
    show rotateAboutForPreview, screenBearingDeg;
import 'package:mechx_engine/network/network.dart';

/// Drafting-feel batch 5 — the STORE / pure halves of the AutoCAD-convention
/// commands on the Layout canvas: M9 typed coordinates (`@dx,dy`, `len<ang`),
/// M8 base-point Move / Copy / Rotate (one undo step per placement, fresh ids
/// on copy, exact 90° / 45° turns), and the typed length that finishes a grip
/// stretch. The full-app input-routing halves live in
/// `drafting_feel_batch5_test.dart`.
void main() {
  const cw = ServiceType.coldWater;

  ProviderContainer make() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  Offset pos(Network n, String id) {
    final node = n.nodeById(id)!;
    return Offset(node.x, node.y);
  }

  NetNode node(String id, double x, double y, {int floor = 0, String s = 's'}) =>
      NetNode(id: id, sheetId: s, x: x, y: y, floorIndex: floor);
  NetEdge run(String id, String a, String b) =>
      NetEdge(id: id, fromId: a, toId: b, service: cw);

  group('M9 — typed coordinates (parseDrawingInput)', () {
    test('the original forms are unchanged', () {
      expect(parseDrawingInput('3000').lengthMm, 3000);
      final a = parseDrawingInput('3000 90');
      expect(a.lengthMm, 3000);
      expect(a.angleDeg, 90);
      expect(a.isCartesian, isFalse);
      expect(parseDrawingInput('1.500 45,5', indonesian: true).angleDeg, 45.5);
      expect(parseDrawingInput('2,5', indonesian: true).lengthMm, 2.5);
    });

    test('len<ang and @len<ang are polar (length + AutoCAD bearing)', () {
      for (final t in ['3000<45', '@3000<45', ' @ 3000 < 45 ']) {
        final p = parseDrawingInput(t);
        expect(p.ok, isTrue, reason: t);
        expect(p.lengthMm, 3000, reason: t);
        expect(p.angleDeg, 45, reason: t);
      }
      expect(parseDrawingInput('3000<-90').angleDeg, -90);
      expect(parseDrawingInput('1.500<22,5', indonesian: true).lengthMm, 1500);
      expect(parseDrawingInput('1.500<22,5', indonesian: true).angleDeg, 22.5);
      expect(parseDrawingInput('3000<').ok, isFalse);
      expect(parseDrawingInput('<45').ok, isFalse);
      expect(parseDrawingInput('0<45').ok, isFalse);
      expect(parseDrawingInput('3000<45<10').ok, isFalse);
    });

    test('@dx,dy is relative Cartesian (English: the comma separates)', () {
      final p = parseDrawingInput('@1500,-2000');
      expect(p.ok, isTrue);
      expect(p.isCartesian, isTrue);
      expect(p.dxMm, 1500);
      expect(p.dyMm, -2000);
      expect(p.lengthMm, isNull);
      // A semicolon always separates, so grouped thousands still read.
      final g = parseDrawingInput('@1,500;2,000');
      expect(g.dxMm, 1500);
      expect(g.dyMm, 2000);
      // Ambiguous comma counts are refused, never guessed.
      expect(parseDrawingInput('@1,500,2,000').ok, isFalse);
      expect(parseDrawingInput('@1,500,2,000').error, contains(';'));
      expect(parseDrawingInput('@0,0').ok, isFalse);
      expect(parseDrawingInput('@1500').ok, isFalse);
      expect(parseDrawingInput('@a,b').ok, isFalse);
    });

    test('Indonesian: `;` separates (decimal comma inside), a lone comma '
        'is the separator, two or more commas are refused', () {
      final p = parseDrawingInput('@1,5;-2,5', indonesian: true);
      expect(p.dxMm, 1.5);
      expect(p.dyMm, -2.5);
      final q = parseDrawingInput('@1.500;2.000', indonesian: true);
      expect(q.dxMm, 1500);
      expect(q.dyMm, 2000);
      final r = parseDrawingInput('@1500,2000', indonesian: true);
      expect(r.dxMm, 1500);
      expect(r.dyMm, 2000);
      final bad = parseDrawingInput('@1,5,2,5', indonesian: true);
      expect(bad.ok, isFalse);
      expect(bad.error, contains(';'));
    });

    test('non-finite numbers never parse (Round 10)', () {
      for (final t in ['@NaN,1', '@1,Infinity', '1e400<0', '3000<NaN']) {
        expect(parseDrawingInput(t).ok, isFalse, reason: t);
      }
    });

    test('drawInputTarget: AutoCAD axes (+x east, +y and 90 deg UP the '
        'screen, CCW positive)', () {
      const o = Offset(10, 10);
      const k = 0.1; // world px per mm
      Offset at(String t) => drawInputTarget(o, parseDrawingInput(t), k);
      expect(at('@1000,0'), const Offset(110, 10));
      expect(at('@0,1000'), const Offset(10, -90),
          reason: '+y is up the screen (screen y grows down)');
      expect(at('@-500,-500'), const Offset(-40, 60));
      final north = at('1000<90');
      expect(north.dx, closeTo(10, 1e-9));
      expect(north.dy, closeTo(-90, 1e-9));
      final west = at('1000<180');
      expect(west.dx, closeTo(-90, 1e-9));
      expect(west.dy, closeTo(10, 1e-9));
      final ne = at('@1000<45');
      expect(ne.dx - 10, closeTo(100 * math.sqrt1_2, 1e-9));
      expect(ne.dy - 10, closeTo(-100 * math.sqrt1_2, 1e-9));
      // A bare length runs toward the cursor.
      expect(
          drawInputTarget(o, parseDrawingInput('1000'), k,
              hover: const Offset(10, 500)),
          const Offset(10, 110));
    });

    test('describeDrawInput reads the entry back', () {
      expect(describeDrawInput(parseDrawingInput('3000<90')),
          '3000 mm = 3.00 m @ 90°');
      expect(describeDrawInput(parseDrawingInput('@1500,-2000')),
          '@ x 1.50 m, y -2.00 m');
      expect(describeDrawInput(parseDrawingInput('x')), '');
    });

    test('parseAngleInput', () {
      expect(parseAngleInput('90').degrees, 90);
      expect(parseAngleInput('<-45').degrees, -45);
      expect(parseAngleInput('22,5', indonesian: true).degrees, 22.5);
      expect(parseAngleInput('').degrees, isNull);
      expect(parseAngleInput('').error, isNull);
      expect(parseAngleInput('north').error, isNotNull);
    });
  });

  group('M8 — base-point transforms (network store)', () {
    test('translateSelection: one undo step, stretches the run to an '
        'unselected neighbour, refuses a zero delta', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(Network(
        nodes: [node('a', 0, 0), node('b', 100, 0), node('x', 100, 100)],
        edges: [run('ab', 'a', 'b'), run('bx', 'b', 'x')],
      ));
      expect(n.translateSelection(const {}, {'ab'}, Offset.zero), isFalse);
      expect(n.canUndo, isFalse);
      expect(n.translateSelection(const {}, {'ab'}, const Offset(30, -20)),
          isTrue);
      final net = c.read(networkControllerProvider).network;
      expect(pos(net, 'a'), const Offset(30, -20));
      expect(pos(net, 'b'), const Offset(130, -20));
      expect(pos(net, 'x'), const Offset(100, 100));
      c.read(historyProvider.notifier).undo();
      expect(pos(c.read(networkControllerProvider).network, 'a'), Offset.zero);
      expect(n.canUndo, isFalse, reason: 'exactly one step');
    });

    test('copySelectionBy: fresh ids, connectivity kept within the set, '
        'originals + selection untouched, each placement one undo step', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(Network(
        nodes: [node('a', 0, 0), node('b', 100, 0), node('x', 100, 100)],
        edges: [run('ab', 'a', 'b'), run('bx', 'b', 'x')],
      ));
      final first = n.copySelectionBy(const {}, {'ab'}, const Offset(0, 50));
      expect(first.nodeIds, hasLength(2));
      expect(first.edgeIds, hasLength(1));
      final second = n.copySelectionBy(const {}, {'ab'}, const Offset(0, 90));
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes, hasLength(7));
      expect(net.edges, hasLength(4));
      expect(first.nodeIds.intersection({'a', 'b', 'x'}), isEmpty);
      final e1 = net.edgeById(first.edgeIds.single)!;
      expect(first.nodeIds, {e1.fromId, e1.toId});
      expect(pos(net, e1.fromId), const Offset(0, 50));
      expect(pos(net, e1.toId), const Offset(100, 50));
      expect(e1.service, cw);
      expect(net.edgesAt(e1.toId), hasLength(1),
          reason: 'the copy does not drag the unselected b-x leg along');
      expect(second.nodeIds.intersection(first.nodeIds), isEmpty);
      expect(pos(net, 'a'), Offset.zero);
      final h = c.read(historyProvider.notifier);
      h.undo();
      expect(c.read(networkControllerProvider).network.nodes, hasLength(5));
      h.undo();
      expect(c.read(networkControllerProvider).network.nodes, hasLength(3));
    });

    test('copySelectionBy keeps a riser and every node on its own floor', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(Network(
        nodes: [node('lo', 50, 50), node('hi', 50, 50, floor: 1, s: 't')],
        edges: [
          const NetEdge(
              id: 'r', fromId: 'lo', toId: 'hi', service: cw, kind: EdgeKind.riser),
        ],
      ));
      final made = n.copySelectionBy(const {}, {'r'}, const Offset(40, 0));
      final net = c.read(networkControllerProvider).network;
      final e = net.edgeById(made.edgeIds.single)!;
      expect(e.kind, EdgeKind.riser);
      final lo = net.nodeById(e.fromId)!, hi = net.nodeById(e.toId)!;
      expect((lo.floorIndex, lo.sheetId), (0, 's'));
      expect((hi.floorIndex, hi.sheetId), (1, 't'));
      expect(Offset(lo.x, lo.y), const Offset(90, 50));
      expect(Offset(hi.x, hi.y), const Offset(90, 50));
    });

    test('rotateSelectionAbout 90: trig-free, East turns to North (CCW as '
        'seen), about the PICKED base, one undo step', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(Network(
        nodes: [node('a', 10, 10), node('b', 110, 10)],
        edges: [run('ab', 'a', 'b')],
      ));
      expect(
          n.rotateSelectionAbout(const {}, {'ab'}, const Offset(10, 10), 90),
          isTrue);
      final net = c.read(networkControllerProvider).network;
      expect(pos(net, 'a'), const Offset(10, 10));
      expect(pos(net, 'b'), const Offset(10, -90), reason: 'north = up');
      // -90 is clockwise: back to East.
      n.rotateSelectionAbout(const {}, {'ab'}, const Offset(10, 10), -90);
      expect(pos(c.read(networkControllerProvider).network, 'b'),
          const Offset(110, 10));
      expect(n.rotateSelectionAbout(const {}, {'ab'}, Offset.zero, 360),
          isFalse,
          reason: 'a full turn moves nothing, records nothing');
      // A single node turns about a pivot too (unlike the bbox rotate).
      expect(n.rotateSelectionAbout({'b'}, const {}, const Offset(10, 10), 180),
          isTrue);
      expect(pos(c.read(networkControllerProvider).network, 'b'),
          const Offset(-90, 10));
    });

    test('rotateSelectionAbout 45: an orthogonal layout comes out EXACTLY '
        'diagonal (|dx| == |dy| bit-for-bit), diagonals exactly axis-aligned',
        () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      // An L plus an (exactly) diagonal tail, off-origin and about an
      // awkward pivot so the trig arithmetic rounds.
      n.loadNetwork(Network(
        nodes: [
          node('a', 13.5, 21.25),
          node('b', 113.5, 21.25),
          node('d', 113.5, 71.25),
          node('e', 143.5, 101.25),
        ],
        edges: [run('ab', 'a', 'b'), run('bd', 'b', 'd'), run('de', 'd', 'e')],
      ));
      for (final angle in [45.0, 135.0, -45.0, 225.0]) {
        n.rotateSelectionAbout(
            const {}, {'ab', 'bd', 'de'}, const Offset(7.1, 3.3), angle);
        final net = c.read(networkControllerProvider).network;
        Offset d(String p, String q) => pos(net, q) - pos(net, p);
        // The axis runs are now exact diagonals…
        for (final (p, q) in [('a', 'b'), ('b', 'd')]) {
          final v = d(p, q);
          expect(v.dx.abs(), v.dy.abs(), reason: '$angle $p-$q $v');
        }
        // …and the diagonal tail is exactly axis-aligned (an odd number of
        // 45 deg turns in total so far alternates the two).
        final tail = d('d', 'e');
        expect(tail.dx == 0 || tail.dy == 0, isTrue, reason: '$angle $tail');
        // Lengths are kept (to float precision).
        expect(d('a', 'b').distance, closeTo(100, 1e-9));
        expect(tail.distance, closeTo(30 * math.sqrt2, 1e-9));
        // Turn back so the next angle starts from the orthogonal layout.
        n.rotateSelectionAbout(
            const {}, {'ab', 'bd', 'de'}, const Offset(7.1, 3.3), -angle);
        final back = c.read(networkControllerProvider).network;
        expect(pos(back, 'b').dy - pos(back, 'a').dy, 0,
            reason: 'the round trip re-squares too');
      }
    });

    test('rotateSelectionAbout 30: a plain rotation matching the preview', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(Network(
        nodes: [node('a', 0, 0), node('b', 100, 0)],
        edges: [run('ab', 'a', 'b')],
      ));
      n.rotateSelectionAbout(const {}, {'ab'}, Offset.zero, 30);
      final b = pos(c.read(networkControllerProvider).network, 'b');
      expect(b.dx, closeTo(100 * math.cos(math.pi / 6), 1e-9));
      expect(b.dy, closeTo(-100 * math.sin(math.pi / 6), 1e-9));
      final preview =
          rotateAboutForPreview(const Offset(100, 0), Offset.zero, 30);
      expect((preview - b).distance, lessThan(1e-9));
      expect(screenBearingDeg(Offset.zero, b), closeTo(30, 1e-9));
    });

    test('rotate / translate / copy refuse non-finite input', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(Network(
        nodes: [node('a', 0, 0), node('b', 100, 0)],
        edges: [run('ab', 'a', 'b')],
      ));
      expect(n.rotateSelectionAbout(const {}, {'ab'}, Offset.zero, double.nan),
          isFalse);
      expect(
          n.translateSelection(
              const {}, {'ab'}, const Offset(double.infinity, 0)),
          isFalse);
      expect(
          n
              .copySelectionBy(const {}, {'ab'}, const Offset(double.nan, 1))
              .nodeIds,
          isEmpty);
      expect(n.canUndo, isFalse);
    });
  });

  group('M8 — the base-point command state machine', () {
    ProviderContainer seeded() {
      final c = make();
      c.read(networkControllerProvider.notifier).loadNetwork(Network(
            nodes: [node('a', 0, 0), node('b', 100, 0)],
            edges: [run('ab', 'a', 'b')],
          ));
      return c;
    }

    test('Move: base, then target — moves by target - base and ENDS', () {
      final c = seeded();
      final cmd = c.read(basePointCommandProvider.notifier);
      expect(
          cmd.start(BasePointCommandKind.move,
              nodeIds: const {}, edgeIds: const {}, sheetId: 's', floorIndex: 0),
          isFalse,
          reason: 'nothing selected, nothing armed');
      cmd.start(BasePointCommandKind.move,
          nodeIds: const {}, edgeIds: {'ab'}, sheetId: 's', floorIndex: 0);
      expect(cmd.placeTarget(const Offset(5, 5)), isFalse,
          reason: 'no base point yet');
      cmd.setBase(const Offset(100, 0));
      expect(c.read(basePointCommandProvider)!.pickingBase, isFalse);
      expect(cmd.placeTarget(const Offset(150, 40)), isTrue);
      expect(c.read(basePointCommandProvider), isNull);
      final net = c.read(networkControllerProvider).network;
      expect(pos(net, 'a'), const Offset(50, 40));
      expect(pos(net, 'b'), const Offset(150, 40));
    });

    test('Copy MULTIPLE: stays armed, each target copies the ORIGINAL '
        'relative to the base, one undo step each', () {
      final c = seeded();
      final cmd = c.read(basePointCommandProvider.notifier);
      cmd.start(BasePointCommandKind.copy,
          nodeIds: const {}, edgeIds: {'ab'}, sheetId: 's', floorIndex: 0);
      cmd.setBase(Offset.zero);
      cmd.placeTarget(const Offset(0, 100));
      cmd.placeDisplacement(const Offset(0, 200));
      expect(c.read(basePointCommandProvider)!.placed, 2);
      final net = c.read(networkControllerProvider).network;
      expect(net.edges, hasLength(3));
      final ys = {for (final nd in net.nodes) nd.y};
      expect(ys, {0.0, 100.0, 200.0});
      c.read(historyProvider.notifier).undo();
      expect(c.read(networkControllerProvider).network.edges, hasLength(2));
      cmd.cancel();
      expect(c.read(basePointCommandProvider), isNull);
    });

    test('Rotate: rotateBy turns about the base and ends', () {
      final c = seeded();
      final cmd = c.read(basePointCommandProvider.notifier);
      cmd.start(BasePointCommandKind.rotate,
          nodeIds: const {}, edgeIds: {'ab'}, sheetId: 's', floorIndex: 0);
      expect(cmd.rotateBy(90), isFalse, reason: 'no pivot yet');
      cmd.setBase(Offset.zero);
      expect(cmd.placeDisplacement(const Offset(5, 0)), isFalse,
          reason: 'a rotate places no displacement');
      expect(cmd.rotateBy(-90), isTrue);
      expect(c.read(basePointCommandProvider), isNull);
      expect(pos(c.read(networkControllerProvider).network, 'b'),
          const Offset(0, 100), reason: '-90 is clockwise: east -> south');
    });

    test('arming a draw tool or an annotation mode backs out', () {
      final c = seeded();
      final cmd = c.read(basePointCommandProvider.notifier);
      cmd.start(BasePointCommandKind.move,
          nodeIds: const {}, edgeIds: {'ab'}, sheetId: 's', floorIndex: 0);
      c.read(networkControllerProvider.notifier).setTool(DrawTool.drawRun);
      expect(c.read(basePointCommandProvider), isNull);
      c.read(networkControllerProvider.notifier).setTool(DrawTool.select);
      cmd.start(BasePointCommandKind.copy,
          nodeIds: const {}, edgeIds: {'ab'}, sheetId: 's', floorIndex: 0);
      c.read(measureModeProvider.notifier).set(true);
      expect(c.read(basePointCommandProvider), isNull);
    });
  });

  group('Item 2 — a typed length finishing a grip stretch', () {
    test('setRunLength(duringDrag): the drag and the typed length are ONE '
        'undo step back to the pre-drag run', () {
      final c = make();
      final n = c.read(networkControllerProvider.notifier);
      n.loadNetwork(Network(
        nodes: [node('a', 0, 0), node('b', 100, 0)],
        edges: [run('ab', 'a', 'b')],
      ));
      n.pushUndoSnapshot(); // the grip's pan start
      n.moveNode('b', 60, 60); // dragged somewhere diagonal
      expect(n.setRunLength('ab', 2.0, 0.01, moveEndId: 'b', duringDrag: true),
          isTrue);
      final b = pos(c.read(networkControllerProvider).network, 'b');
      expect(b.distance, closeTo(200, 1e-9), reason: '2 m at 0.01 m/px');
      expect(b.dx, closeTo(b.dy, 1e-9), reason: 'along the drag direction');
      c.read(historyProvider.notifier).undo();
      expect(pos(c.read(networkControllerProvider).network, 'b'),
          const Offset(100, 0));
      expect(n.canUndo, isFalse);
    });

    test('the stretch provider marks typed and clears on a tool switch', () {
      final c = make();
      final s = c.read(endpointStretchProvider.notifier);
      s.begin('b', 'ab');
      expect(c.read(endpointStretchProvider)!.typed, isFalse);
      s.markTyped();
      expect(c.read(endpointStretchProvider)!.typed, isTrue);
      c.read(networkControllerProvider.notifier).setTool(DrawTool.drawRun);
      expect(c.read(endpointStretchProvider), isNull);
    });
  });
}
