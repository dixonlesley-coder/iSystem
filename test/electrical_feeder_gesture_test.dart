/// The electrical single-line canvas's FEEDER gestures, driven with real
/// pointer sequences.
///
/// Two long-standing defects motivated these:
///
///  • the outlet handle was mounted at `Positioned(right: -13)`, so half the
///    visible dot hung OUTSIDE the card — and a `RenderBox` rejects a hit
///    outside its own bounds, so that half was dead. A drag started there fell
///    through to the canvas, which armed a rubber-band marquee instead. The
///    handle is now a right-edge BAND wholly inside the card (≥ 26 screen px of
///    grab at any zoom), so a grab anywhere along the card's right edge starts a
///    feeder and never a marquee.
///  • dropping an UNFED board onto another board did nothing but move it. It
///    now wires the feeder (one undo step with the move), which is the direct-
///    manipulation counterpart of dragging the outlet.
///
/// Everything here goes through the real widget tree + real store intents — no
/// hand-called handlers — so a regression in the hit geometry fails the test.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart';
import 'package:mechx/ui/electrical/panel_geometry.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

// ── A small, fully-positioned fixture ────────────────────────────────────────
// Every board carries exactly one way, so each summary card is the minimum
// 280 x 168 world px — predictable geometry the pointer math can target.

final double _cardW = panelCardWidth(1);
const double _cardH = kPanelChrome + kPanelSummaryBodyH;

ElectricalPanel _board(String id, String tag, double x, double y) =>
    ElectricalPanel(
      id: id,
      name: 'Board $tag',
      tag: tag,
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      x: x,
      y: y,
      circuits: [
        ElectricalCircuit(
          id: '$id-c1',
          name: 'Lighting $tag',
          loadKind: LoadKind.lighting,
          isLighting: true,
          loadW: 1200,
          length: const Length(20),
        ),
      ],
    );

/// A · B side by side, C below A — none of them fed.
ElectricalProject _fixture() => ElectricalProject(
      id: 'gesture',
      name: 'Feeder gestures',
      panels: [
        _board('a', 'A', 0, 0),
        _board('b', 'B', 400, 0),
        _board('c', 'C', 0, 400),
      ],
    );

class _Harness {
  final WidgetTester tester;
  final ProviderContainer container;
  final ElectricalCanvasState state;
  const _Harness(this.tester, this.container, this.state);

  ElectricalProjectController get ctrl =>
      container.read(electricalProjectProvider.notifier);

  ElectricalProject get project => container.read(electricalProjectProvider);

  ElectricalPanel panel(String id) =>
      project.panels.firstWhere((p) => p.id == id);

  /// Which board (if any) feeds [id].
  String? parentOf(String id) {
    for (final p in project.panels) {
      if (p.circuits.any((c) => c.feedsPanelId == id)) return p.id;
    }
    return null;
  }

  /// World point → the global tester coordinate it is painted at.
  Offset globalOf(Offset world) {
    final rect = tester.getRect(find.byType(ElectricalCanvas));
    return rect.topLeft + state.transform.worldToScreen(world);
  }

  /// A point inside [id]'s outlet grab BAND (the right-edge strip), [inset]
  /// world px left of the card's right edge, vertically centred.
  Offset outletGrab(String id, {double inset = 8}) {
    final at = Offset(panel(id).x!, panel(id).y!);
    return globalOf(Offset(at.dx + _cardW - inset, at.dy + _cardH / 2));
  }

  /// The centre of [id]'s card.
  Offset cardCentre(String id) {
    final at = Offset(panel(id).x!, panel(id).y!);
    return globalOf(Offset(at.dx + _cardW / 2, at.dy + _cardH / 2));
  }

  /// Assert every supplied point is really on the canvas (so a "failed" gesture
  /// can never be an off-screen coordinate masquerading as a hit-test bug).
  void expectOnCanvas(List<Offset> points) {
    final rect = tester.getRect(find.byType(ElectricalCanvas));
    for (final p in points) {
      expect(rect.contains(p), isTrue,
          reason: '$p must land inside the canvas $rect');
    }
  }

  /// A real pointer drag from [from] to [to], in a few steps.
  Future<void> drag(Offset from, Offset to) async {
    final g = await tester.startGesture(from);
    await tester.pump();
    final mid = Offset.lerp(from, to, 0.5)!;
    await g.moveTo(mid);
    await tester.pump();
    await g.moveTo(to);
    await tester.pump();
    await g.up();
    await tester.pump();
  }
}

Future<_Harness> _pump(WidgetTester tester, {ElectricalProject? project}) async {
  setDesktopSurface(tester);
  await tester.pumpWidget(const ProviderScope(child: MechXApp()));
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MechXApp)),
    listen: false,
  );
  container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
  container
      .read(electricalProjectProvider.notifier)
      .setProject(project ?? _fixture());
  await tester.pump();
  final state =
      tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));
  // Frame board A at a known SUMMARY-band zoom (0.60) so the pointer math below
  // is deterministic; every later zoom step is taken from here.
  state.collapseToSummary('a');
  await tester.pumpAndSettle();
  return _Harness(tester, container, state);
}

/// The status pill runs on a real 3 s Timer; clear it so the test's fake async
/// never ends with a pending timer.
Future<void> _clearStatus(_Harness h) async {
  h.container.read(statusMessageProvider.notifier).clear();
  await h.tester.pump();
}

void main() {
  testWidgets(
      'a: dragging a board\'s outlet band onto another board feeds it — at the '
      'default summary zoom AND zoomed out near 0.4', (tester) async {
    final h = await _pump(tester);
    expect(h.state.currentScale, closeTo(0.60, 1e-9));

    // ── At ~0.6 ───────────────────────────────────────────────────────────────
    var from = h.outletGrab('a');
    var to = h.cardCentre('b');
    h.expectOnCanvas([from, to]);
    await h.drag(from, to);
    expect(h.parentOf('b'), 'a',
        reason: 'the outlet drag should have wired A -> B');
    await _clearStatus(h);

    // Undo back to the unfed fixture, then repeat further zoomed out. Two
    // zoom-out steps from 0.60 land at 0.4167 — still the summary band, but the
    // outlet band is now much WIDER in world px (it holds 26 screen px), which
    // is exactly the geometry the fix introduces.
    h.container.read(historyProvider.notifier).undo();
    await tester.pump();
    expect(h.parentOf('b'), isNull);

    h.state.zoomOut();
    await tester.pumpAndSettle();
    h.state.zoomOut();
    await tester.pumpAndSettle();
    expect(h.state.currentScale, closeTo(0.6 / 1.44, 1e-6));

    from = h.outletGrab('a');
    to = h.cardCentre('b');
    h.expectOnCanvas([from, to]);
    await h.drag(from, to);
    expect(h.parentOf('b'), 'a',
        reason: 'the outlet band must stay grabbable when zoomed out');
    await _clearStatus(h);
  });

  testWidgets(
      'b: a drag starting just INSIDE the card\'s right edge (the old half-dead '
      'strip) connects, and arms no marquee / selection', (tester) async {
    final h = await _pump(tester);
    expect(h.state.selectedPanelIds, isEmpty);

    // 2 world px inside the right edge — under the old `right: -13` mount this
    // sat in the dot's dead outer half and fell through to the canvas.
    final from = h.outletGrab('a', inset: 2);
    final to = h.cardCentre('b');
    h.expectOnCanvas([from, to]);
    await h.drag(from, to);

    expect(h.parentOf('b'), 'a');
    expect(h.state.selectedPanelIds, isEmpty,
        reason: 'a feeder drag must not rubber-band-select anything');
    // A marquee would also have moved nothing — assert the boards stayed put.
    expect(h.panel('a').x, 0);
    expect(h.panel('b').x, 400);
    await _clearStatus(h);
  });

  testWidgets('c: a drag that would close a feeder loop is refused, and the '
      'topology is untouched', (tester) async {
    final h = await _pump(tester);
    // A already feeds B; dragging B's outlet back onto A would loop.
    h.ctrl.connectFeeder('a', 'b');
    await tester.pump();
    expect(h.parentOf('b'), 'a');
    final waysBefore = h.panel('b').circuits.length;

    final from = h.outletGrab('b');
    final to = h.cardCentre('a');
    h.expectOnCanvas([from, to]);
    await h.drag(from, to);

    final message = h.container.read(statusMessageProvider);
    expect(message, isNotNull,
        reason: 'the refusal must reach the shared status pill');
    expect(message, contains('loop'));
    expect(h.parentOf('a'), isNull, reason: 'A must not have gained a parent');
    expect(h.parentOf('b'), 'a', reason: 'B keeps its original parent');
    expect(h.panel('b').circuits.length, waysBefore,
        reason: 'a refused connect adds no feeder way');
    await _clearStatus(h);
  });

  testWidgets(
      'd: dropping on an already-fed board RE-PARENTS it (old way gone, toast '
      'says what it was, one undo restores)', (tester) async {
    final h = await _pump(tester);
    h.ctrl.connectFeeder('a', 'c');
    await tester.pump();
    expect(h.parentOf('c'), 'a');
    final aWaysBefore = h.panel('a').circuits.length;

    final from = h.outletGrab('b');
    final to = h.cardCentre('c');
    h.expectOnCanvas([from, to]);
    await h.drag(from, to);

    expect(h.parentOf('c'), 'b', reason: 'C should now hang off B');
    expect(h.panel('a').circuits.any((x) => x.feedsPanelId == 'c'), isFalse,
        reason: "A's feeder way to C must be gone, not duplicated");
    expect(h.panel('a').circuits.length, aWaysBefore - 1);
    expect(h.container.read(statusMessageProvider), contains('was'),
        reason: 'a re-parent must name the board it was moved off');

    // ONE undo puts C back under A.
    h.container.read(historyProvider.notifier).undo();
    await tester.pump();
    expect(h.parentOf('c'), 'a');
    expect(h.panel('a').circuits.length, aWaysBefore);
    await _clearStatus(h);
  });

  testWidgets(
      'e: an UNFED board body-dropped onto another is fed + repositioned in one '
      'undo step; a FED board body-drop is a pure move', (tester) async {
    final h = await _pump(tester);

    // ── unfed B dropped over A ────────────────────────────────────────────────
    // Grab B's body well clear of its own outlet band, then drag it so its card
    // overlaps A's.
    final grab = h.globalOf(const Offset(400 + 50, _cardH / 2));
    final drop = h.globalOf(const Offset(100 + 50, _cardH / 2));
    h.expectOnCanvas([grab, drop]);
    await h.drag(grab, drop);

    expect(h.parentOf('b'), 'a',
        reason: 'an unfed board dropped on another should be fed by it');
    final movedX = h.panel('b').x!;
    expect(movedX, greaterThan(400),
        reason: 'the newly-fed board is tidied to its parent\'s right');

    // ONE undo reverts BOTH the move and the connect.
    h.container.read(historyProvider.notifier).undo();
    await tester.pump();
    expect(h.parentOf('b'), isNull);
    expect(h.panel('b').x, 400);
    await _clearStatus(h);

    // ── already-fed B dropped over A ─────────────────────────────────────────
    h.ctrl.connectFeeder('c', 'b');
    await tester.pump();
    expect(h.parentOf('b'), 'c');
    final cWays = h.panel('c').circuits.length;

    final grab2 = h.globalOf(const Offset(400 + 50, _cardH / 2));
    final drop2 = h.globalOf(const Offset(100 + 50, _cardH / 2));
    h.expectOnCanvas([grab2, drop2]);
    await h.drag(grab2, drop2);

    expect(h.parentOf('b'), 'c',
        reason: 'a board that already has a parent is only MOVED');
    expect(h.panel('c').circuits.length, cWays);
    expect(h.panel('a').circuits.any((x) => x.feedsPanelId == 'b'), isFalse);
    expect(h.panel('b').x, lessThan(400), reason: 'but it did move');
    await _clearStatus(h);
  });
}
