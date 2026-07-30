/// E-1 + E-2 on the electrical single-line canvas.
///
/// **E-1 — feeder labels must not overpaint.** Every feeder leaves a board at
/// the SAME outlet point, so the old per-feeder anchor (`start.dy - 7`) printed
/// two near-identical cable/breaker labels on ONE row: a parent feeding two
/// sub-boards rendered garbage like `... MCB 16A 3ph h` — the tail of the label
/// underneath showing past the one on top (user-reported). Placement is now a
/// PURE function ([feederLabelAnchors]) that stacks one parent's labels a line
/// apart, and this file is its spec: the stack can never overlap, it is
/// deterministic regardless of input order, and a board feeding exactly ONE
/// sub-board keeps its legacy anchor to the pixel.
///
/// **E-2 — the LOD tier switch must dissolve, not pop.** The card body
/// cross-fades across the summary/schedule boundary. It is VISUAL ONLY:
/// [panelLodFor] stays pure and the geometry (footprints, hit-tests, feeder
/// endpoints) still reads the instantaneous tier — checked here by driving the
/// real canvas across the boundary, both with motion and with the OS
/// reduced-motion flag on (where the resolved [Duration.zero] must swap
/// instantly and assert nothing).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart';
import 'package:mechx/ui/electrical/panel_geometry.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

// ── E-1 fixtures ─────────────────────────────────────────────────────────────

/// One feeder's placement input. All feeders from one parent share [start]
/// (that is the whole problem), so only [midX] / [childY] / [childId] vary.
FeederLabelSpec _spec(
  String key, {
  required String childId,
  Offset start = const Offset(100, 200),
  double midX = 150,
  required double childY,
}) =>
    FeederLabelSpec(
      key: key,
      childId: childId,
      start: start,
      midX: midX,
      childY: childY,
    );

// ── E-2 fixture: one parent feeding TWO boards ───────────────────────────────

ElectricalPanel _board(
  String id,
  String tag,
  double x,
  double y, {
  String? fedByCircuitId,
  List<ElectricalCircuit> extra = const [],
}) =>
    ElectricalPanel(
      id: id,
      name: 'Board $tag',
      tag: tag,
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      sourceType:
          fedByCircuitId == null ? PanelSource.utility : PanelSource.feeder,
      fedByCircuitId: fedByCircuitId,
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
        ...extra,
      ],
    );

/// A feeds B and C — two feeders out of ONE outlet, the collision case.
ElectricalProject _fixture() => ElectricalProject(
      id: 'stagger',
      name: 'Feeder labels',
      panels: [
        _board('a', 'A', 0, 0, extra: const [
          ElectricalCircuit(
            id: 'a-f1',
            name: 'Feeder to B',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'b',
            length: Length(15),
          ),
          ElectricalCircuit(
            id: 'a-f2',
            name: 'Feeder to C',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'c',
            length: Length(18),
          ),
        ]),
        _board('b', 'B', 600, 0, fedByCircuitId: 'a-f1'),
        _board('c', 'C', 600, 300, fedByCircuitId: 'a-f2'),
      ],
    );

Finder _byType(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

void main() {
  group('E-1 — feederLabelAnchors (pure)', () {
    test('a board feeding ONE sub-board keeps the legacy anchor exactly', () {
      final anchors = feederLabelAnchors(
        [_spec('a-f1', childId: 'b', childY: 200)],
        lineHeight: 16,
      );
      // Hand-computed: the single label sits at the feeder's mid-X channel,
      // kFeederLabelRise (7) px above the outlet row — byte-identical to the
      // pre-stagger `Offset(midX, start.dy - 7)`.
      expect(anchors, {'a-f1': const Offset(150, 193)});
      expect(kFeederLabelRise, 7);
    });

    test('the single-feeder anchor is independent of the line height', () {
      for (final lh in const [0.0, 6.4, 16.0, 48.0]) {
        expect(
          feederLabelAnchors(
            [_spec('only', childId: 'b', childY: 12)],
            lineHeight: lh,
          )['only'],
          const Offset(150, 193),
          reason: 'nothing to spread ⇒ the stagger term must vanish',
        );
      }
    });

    test('two feeders out of one outlet stack a full line apart', () {
      final anchors = feederLabelAnchors(
        [
          // Deliberately out of order: C is the LOWER child.
          _spec('a-f2', childId: 'c', midX: 150, childY: 500),
          _spec('a-f1', childId: 'b', midX: 150, childY: 100),
        ],
        lineHeight: 16,
      );
      // The bottom-most child keeps the legacy row (200 - 7 = 193); the child
      // above it steps up ONE line (193 - 16 = 177).
      expect(anchors['a-f2'], const Offset(150, 193));
      expect(anchors['a-f1'], const Offset(150, 177));
      expect((anchors['a-f1']!.dy - anchors['a-f2']!.dy).abs(), 16);
    });

    test('three feeders: distinct rows, exactly one line apart, top child '
        'highest', () {
      final anchors = feederLabelAnchors(
        [
          _spec('f-mid', childId: 'mid', childY: 300),
          _spec('f-low', childId: 'low', childY: 900),
          _spec('f-top', childId: 'top', childY: 50),
        ],
        lineHeight: 16,
      );
      // 193 is the legacy row; the stack grows upward from it.
      expect(anchors['f-low']!.dy, 193);
      expect(anchors['f-mid']!.dy, 193 - 16);
      expect(anchors['f-top']!.dy, 193 - 32);
      // The screen order matches the child order — the label stack reads like
      // the boards it annotates.
      expect(anchors['f-top']!.dy, lessThan(anchors['f-mid']!.dy));
      expect(anchors['f-mid']!.dy, lessThan(anchors['f-low']!.dy));
      // …and NO two labels share a row (the E-1 contract).
      final rows = anchors.values.map((o) => o.dy).toSet();
      expect(rows.length, anchors.length);
    });

    test('the result is order-independent and stable (sorted by child row, '
        'then child id)', () {
      final specs = [
        _spec('f1', childId: 'b', midX: 120, childY: 400),
        _spec('f2', childId: 'c', midX: 140, childY: 100),
        _spec('f3', childId: 'd', midX: 160, childY: 250),
      ];
      final forwards = feederLabelAnchors(specs, lineHeight: 16);
      final backwards =
          feederLabelAnchors(specs.reversed, lineHeight: 16);
      expect(backwards, forwards);
      // A permutation that is neither order, for good measure.
      expect(
        feederLabelAnchors([specs[1], specs[0], specs[2]], lineHeight: 16),
        forwards,
      );
    });

    test('feeders landing on the SAME child row are ordered by child id', () {
      final anchors = feederLabelAnchors(
        [
          _spec('f-zz', childId: 'zz', childY: 250),
          _spec('f-aa', childId: 'aa', childY: 250),
        ],
        lineHeight: 16,
      );
      // Same row ⇒ the tiebreak decides, and it must be the STABLE one: 'aa'
      // sorts first, so it takes the upper slot every run.
      expect(anchors['f-aa']!.dy, 177);
      expect(anchors['f-zz']!.dy, 193);
      expect(
        feederLabelAnchors(
          [
            _spec('f-aa', childId: 'aa', childY: 250),
            _spec('f-zz', childId: 'zz', childY: 250),
          ],
          lineHeight: 16,
        ),
        anchors,
      );
    });

    test("each label keeps its OWN feeder's mid-X channel", () {
      final anchors = feederLabelAnchors(
        [
          _spec('f1', childId: 'b', midX: 120, childY: 100),
          _spec('f2', childId: 'c', midX: 480, childY: 700),
        ],
        lineHeight: 16,
      );
      expect(anchors['f1']!.dx, 120);
      expect(anchors['f2']!.dx, 480);
    });

    test('no feeders ⇒ no anchors', () {
      expect(feederLabelAnchors(const [], lineHeight: 16), isEmpty);
    });

    test('the line-height constant clears the label pill at every zoom', () {
      // The pill is a 9-px Roboto line plus 4 px of padding. Roboto's line box
      // is ~1.17 × the font size, so the tallest the pill gets is
      //   9 × 1.2 + 4 = 14.8 px  (1.2 taken as a conservative upper bound)
      // and BOTH terms scale with the canvas, so one comparison at scale 1
      // settles every zoom.
      expect(kFeederLabelLineH, greaterThan(9 * 1.2 + 4));
      // Scaling is the caller's job (lineHeight = kFeederLabelLineH × scale);
      // the spacing must track it linearly so the guarantee survives zoom-out.
      for (final scale in const [0.4, 1.0, 2.5]) {
        final anchors = feederLabelAnchors(
          [
            _spec('f1', childId: 'b', childY: 100),
            _spec('f2', childId: 'c', childY: 700),
          ],
          lineHeight: kFeederLabelLineH * scale,
        );
        final gap = (anchors['f1']!.dy - anchors['f2']!.dy).abs();
        expect(gap, closeTo(kFeederLabelLineH * scale, 1e-9));
        // …which is more than the pill needs at that same scale.
        expect(gap, greaterThan((9 * 1.2 + 4) * scale));
      }
    });
  });

  group('E-2 — the LOD tier body cross-fades', () {
    testWidgets('panelLodFor stays a pure, hysteresis-free mapping', (t) async {
      // Pinned again here because the cross-fade must NOT have introduced a
      // sticky tier: the geometry reads this function every frame.
      expect(panelLodFor(kMicroThreshold - 0.001), PanelLod.micro);
      expect(panelLodFor(kMicroThreshold), PanelLod.summary);
      expect(panelLodFor(kLodThreshold - 0.001), PanelLod.summary);
      expect(panelLodFor(kLodThreshold), PanelLod.schedule);
    });

    testWidgets('both bodies are mounted mid-transition and only the new one '
        'at rest', (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      container
          .read(workspaceViewProvider.notifier)
          .set(WorkspaceView.electrical);
      container.read(electricalProjectProvider.notifier).setProject(_fixture());
      await tester.pump();

      final state =
          tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));

      state.collapseToSummary('a');
      await tester.pumpAndSettle();
      expect(panelLodFor(state.currentScale), PanelLod.summary);
      expect(_byType('_PanelSummaryBody'), findsWidgets);
      expect(_byType('_PanelScheduleBody'), findsNothing);

      // Cross the boundary: the schedule body arrives while the summary body is
      // still fading out — that overlap IS the cross-fade.
      state.focusPanelSchedule('a');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      expect(panelLodFor(state.currentScale), PanelLod.schedule);
      expect(_byType('_PanelScheduleBody'), findsWidgets);
      expect(_byType('_PanelSummaryBody'), findsWidgets,
          reason: 'the outgoing tier is still on screen, dissolving');

      await tester.pumpAndSettle();
      expect(_byType('_PanelSummaryBody'), findsNothing,
          reason: 'at rest only the current tier is mounted');
      expect(_byType('_PanelScheduleBody'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion swaps the tiers instantly, asserting nothing',
        (tester) async {
      // AnimatedSwitcher takes Duration.zero happily (unlike AnimatedSize) —
      // pinned here because the gate resolves to zero on a machine with the OS
      // "reduce motion" setting on, and the canvas must simply swap.
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      container
          .read(workspaceViewProvider.notifier)
          .set(WorkspaceView.electrical);
      container.read(electricalProjectProvider.notifier).setProject(_fixture());
      await tester.pump();
      expect(
        MediaQuery.disableAnimationsOf(
          tester.element(find.byType(ElectricalCanvas)),
        ),
        isTrue,
        reason: 'the gate must actually see the reduced-motion flag',
      );

      final state =
          tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));
      state.collapseToSummary('a');
      await tester.pumpAndSettle();
      expect(_byType('_PanelSummaryBody'), findsWidgets);

      state.focusPanelSchedule('a');
      await tester.pump();
      await tester.pump();
      expect(_byType('_PanelScheduleBody'), findsWidgets);
      expect(_byType('_PanelSummaryBody'), findsNothing,
          reason: 'zero duration ⇒ no dissolve, the old body is gone at once');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a parent feeding TWO boards paints both feeder labels at '
        'every tier without throwing', (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      container
          .read(workspaceViewProvider.notifier)
          .set(WorkspaceView.electrical);
      container.read(electricalProjectProvider.notifier).setProject(_fixture());
      await tester.pump();

      final state =
          tester.state<ElectricalCanvasState>(find.byType(ElectricalCanvas));
      // Schedule tier, then summary, then micro — the painter walks the same
      // label-stagger path at all three (the anchors are screen-space, so the
      // scale is the only thing that changes).
      state.focusPanelSchedule('a');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      state.collapseToSummary('a');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      var guard = 0;
      while (state.currentScale >= kMicroThreshold && guard++ < 20) {
        state.zoomOut();
        await tester.pumpAndSettle();
      }
      expect(panelLodFor(state.currentScale), PanelLod.micro);
      expect(tester.takeException(), isNull);
    });
  });
}
