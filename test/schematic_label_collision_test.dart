/// R2/R3: unit tests for the Riser (Auto single-line) LABEL-COLLISION helpers,
/// plus a widget test for the R1 overflow-only chip-strip edge fade.
///
/// The collision helpers in `ui/schematic/schematic_view.dart` are deliberately
/// PURE top-level functions (no Canvas, no TextPainter, no randomness) so the
/// nudge geometry can be hand-derived here rather than eyeballed in a golden.
/// Every expectation below is derived from first principles in a comment —
/// `kSchematicLabelCharW` (0.6) and `kSchematicLabelLineH` (1.3) are the only
/// inputs.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart'
    show WorkspaceView, workspaceViewProvider;
import 'package:mechx/store/schematic_view_store.dart';
import 'package:mechx/ui/schematic/schematic_view.dart';

import 'test_util.dart';

void main() {
  group('estimateLabelRect', () {
    test('boxes a label from char count x per-size advance', () {
      // 'ABCD' at 10 px: w = 4 chars x 10 px x 0.6 = 24; h = 10 x 1.3 = 13.
      // pad 1 on every side ⇒ LTWH(10-1, 20-1, 24+2, 13+2).
      final r = estimateLabelRect('ABCD', const Offset(10, 20), 10);
      expect(r.left, 9);
      expect(r.top, 19);
      expect(r.width, 26);
      expect(r.height, 15);
      expect(r.right, 35);
      expect(r.bottom, 34);
    });

    test('centered anchors the label on its MIDDLE', () {
      // w = 24 ⇒ left = 100 - 12 = 88, minus the 1 px pad ⇒ 87; right = 113.
      final r =
          estimateLabelRect('ABCD', const Offset(100, 50), 10, centered: true);
      expect(r.left, 87);
      expect(r.right, 113);
      expect(r.top, 49);
    });

    test('pad 0 gives the bare estimate', () {
      // 'AB' at 20 px: w = 2 x 20 x 0.6 = 24; h = 20 x 1.3 = 26.
      final r = estimateLabelRect('AB', Offset.zero, 20, pad: 0);
      expect(r, const Rect.fromLTWH(0, 0, 24, 26));
    });

    test('a real pipe tag is wider than a real floor label', () {
      // '15-CW-PPR-GRAVITASI' = 19 chars at 10 px ⇒ 19 x 6 = 114 (+2 pad).
      final tag =
          estimateLabelRect('15-CW-PPR-GRAVITASI', Offset.zero, 10);
      expect(tag.width, 116);
      // 'Ground  FFL +0.00' = 17 chars at 13 px ⇒ 17 x 7.8 = 132.6 (+2).
      final floor = estimateLabelRect('Ground  FFL +0.00', Offset.zero, 13);
      expect(floor.width, closeTo(134.6, 1e-9));
    });
  });

  group('rect intersection', () {
    const a = Rect.fromLTWH(0, 0, 10, 10);

    test('rectHitsAny is false for a clear rect', () {
      expect(rectHitsAny(a, const [Rect.fromLTWH(20, 0, 10, 10)]), isFalse);
    });

    test('rectHitsAny is true for a 1x1 corner clip', () {
      // The occupied rect spans x 9..19, y 9..19 ⇒ overlaps a at 9..10 both ways.
      expect(rectHitsAny(a, const [Rect.fromLTWH(9, 9, 10, 10)]), isTrue);
    });

    test('exactly touching edges do NOT count as an overlap', () {
      expect(rectHitsAny(a, const [Rect.fromLTWH(10, 0, 10, 10)]), isFalse);
    });

    test('rectOverlapArea is the intersection area', () {
      // x 5..10 = 5 wide, y 5..10 = 5 tall ⇒ 25.
      expect(rectOverlapArea(a, const Rect.fromLTWH(5, 5, 10, 10)), 25);
      expect(rectOverlapArea(a, const Rect.fromLTWH(50, 50, 10, 10)), 0);
    });

    test('totalOverlapArea sums every occupied rect', () {
      // 25 (5x5) + 16 (4x4) = 41.
      expect(
        totalOverlapArea(a, const [
          Rect.fromLTWH(5, 5, 10, 10),
          Rect.fromLTWH(0, 0, 4, 4),
        ]),
        41,
      );
    });
  });

  group('run geometry', () {
    test('runUnitDirection normalises, degenerate falls back to horizontal', () {
      // (3,4) has length 5 ⇒ (0.6, 0.8).
      final u = runUnitDirection(const Offset(3, 4));
      expect(u.dx, closeTo(0.6, 1e-12));
      expect(u.dy, closeTo(0.8, 1e-12));
      expect(runUnitDirection(Offset.zero), const Offset(1, 0));
    });

    test('runNormal rotates the unit direction by -90deg', () {
      // Screen coords (+y down): a left-to-right run's normal points UP.
      expect(runNormal(const Offset(1, 0)), const Offset(0, -1));
      // A downward run's normal points RIGHT.
      expect(runNormal(const Offset(0, 1)), const Offset(1, 0));
    });

    test('signedPerpendicularOffset flips sign with the run direction', () {
      // A tag 8 px ABOVE a left-to-right run: dot((0,-8), (0,-1)) = +8.
      expect(
        signedPerpendicularOffset(const Offset(1, 0), const Offset(0, -8)),
        8,
      );
      // The SAME visual placement on a right-to-left run: normal is (0,1) ⇒ -8.
      expect(
        signedPerpendicularOffset(const Offset(-1, 0), const Offset(0, -8)),
        -8,
      );
    });
  });

  group('runLabelNudgeCandidates', () {
    test('is bounded, ordered, and starts in place', () {
      final c = runLabelNudgeCandidates(
        runDirection: const Offset(1, 0),
        perpendicularOffset: 8,
      );
      // 1 (in place) + 2 x 3 (along) + 1 (other side) + 2 x 3 (other side,
      // stepped along) = 14.
      expect(c.length, 14);
      expect(c.first, Offset.zero);
      // Along the run: +/- 14, 28, 42 px (step 14, steps 3).
      expect(c[1], const Offset(14, 0));
      expect(c[2], const Offset(-14, 0));
      expect(c[5], const Offset(42, 0));
      expect(c[6], const Offset(-42, 0));
      // The flip: normal (0,-1) x (-2 x 8) = (0, +16) — 8 px BELOW the run,
      // mirroring the 8 px above.
      expect(c[7], const Offset(0, 16));
      expect(c[8], const Offset(14, 16));
    });

    test('the other-side flip is direction-independent', () {
      // A right-to-left run carries a signed offset of -8 for the same visual
      // placement, and normal (0,1) x (+16) = (0,16) — still DOWN.
      final c = runLabelNudgeCandidates(
        runDirection: const Offset(-1, 0),
        perpendicularOffset: -8,
      );
      expect(c[7], const Offset(0, 16));
      // Along a right-to-left run, the first step goes left.
      expect(c[1], const Offset(-14, 0));
    });

    test('a vertical run steps VERTICALLY along itself', () {
      final c = runLabelNudgeCandidates(
        runDirection: const Offset(0, 40),
        perpendicularOffset: 0,
      );
      expect(c[1], const Offset(0, 14));
      expect(c[2], const Offset(0, -14));
      // Zero perpendicular offset ⇒ no other side to reach (the flip is a no-op).
      expect(c[7], Offset.zero);
    });

    test('steps/step are honoured', () {
      final c = runLabelNudgeCandidates(
        runDirection: const Offset(1, 0),
        perpendicularOffset: 5,
        step: 10,
        steps: 1,
      );
      // 1 + 2 + 1 + 2 = 6.
      expect(c.length, 6);
      expect(c[1], const Offset(10, 0));
      expect(c[3], const Offset(0, 10)); // flip = (0,-1) x (-10)
    });
  });

  group('resolveLabelDisplacement', () {
    const label = Rect.fromLTWH(0, 0, 10, 10);

    test('keeps a clear label exactly in place', () {
      expect(
        resolveLabelDisplacement(
          label,
          const [Rect.fromLTWH(50, 50, 10, 10)],
          const [Offset.zero, Offset(14, 0)],
        ),
        Offset.zero,
      );
    });

    test('takes the first CLEAR candidate in order', () {
      // Occupied spans x 5..15. In place ⇒ overlap 5..10. +14 ⇒ 14..24, still
      // clips 14..15. -14 ⇒ -14..-4, clear.
      expect(
        resolveLabelDisplacement(
          label,
          const [Rect.fromLTWH(5, 0, 10, 10)],
          const [Offset.zero, Offset(14, 0), Offset(-14, 0)],
        ),
        const Offset(-14, 0),
      );
    });

    test('never drops: falls back to the LEAST-overlapping candidate', () {
      // A wide bar y 0..10, x 0..100. In place ⇒ 10x10 = 100 overlap;
      // +20 along ⇒ still inside the bar, 100; up 5 ⇒ y -5..5, overlap 10x5 = 50.
      expect(
        resolveLabelDisplacement(
          label,
          const [Rect.fromLTWH(0, 0, 100, 10)],
          const [Offset.zero, Offset(20, 0), Offset(0, -5)],
        ),
        const Offset(0, -5),
      );
    });

    test('ties resolve to the EARLIEST candidate (stable, no randomness)', () {
      // Both +/-5 clip the 10x10 bar by 5x10 = 50; the first one wins.
      expect(
        resolveLabelDisplacement(
          label,
          const [Rect.fromLTWH(0, 0, 10, 10)],
          const [Offset(5, 0), Offset(-5, 0)],
        ),
        const Offset(5, 0),
      );
    });

    test('an empty candidate list is a no-op, not a crash', () {
      expect(
        resolveLabelDisplacement(label, const [Rect.fromLTWH(0, 0, 10, 10)],
            const <Offset>[]),
        Offset.zero,
      );
    });

    test('the end-to-end pipe-tag case clears the floor gutter label', () {
      // The real collision from golden 04: a run tag centred just above a run
      // whose midpoint sits on the left edge, over the floor gutter label.
      // Gutter label 'Ground  FFL +0.00' at (8, 4), 13 px ⇒ x 7..141.6, y 3..21.
      final gutter =
          estimateLabelRect('Ground  FFL +0.00', const Offset(8, 4), 13);
      // Tag '15-CW-PPR-GRAVITASI' centred at (60, 6): w 116 ⇒ x 1..117, y 5..20
      // — squarely on the gutter label.
      final tag = estimateLabelRect(
          '15-CW-PPR-GRAVITASI', const Offset(60, 6), 10,
          centered: true);
      expect(tag.overlaps(gutter), isTrue);
      final delta = resolveLabelDisplacement(
        tag,
        [gutter],
        runLabelNudgeCandidates(
          runDirection: const Offset(200, 0),
          perpendicularOffset: signedPerpendicularOffset(
              const Offset(200, 0), const Offset(0, -12)),
        ),
      );
      // The first clear candidate is the other side (24 px down: -2 x 12 flipped
      // through the up-pointing normal) — stepping along the horizontal run can
      // never escape a label that spans x 7..141.6 within +/-42 px.
      expect(delta, const Offset(0, 24));
      expect(tag.shift(delta).overlaps(gutter), isFalse);
    });
  });

  group('R1 chip strip edge fade', () {
    // The Edit-mode 'Riser service' strip inserts a ShaderMask ONLY when it
    // actually overflows; with room it renders as a bare scroll view (so a
    // strip with nothing to reveal can never be tinted). The whole app is
    // pumped because Edit mode mounts the Riser Draggable, which needs an
    // Overlay ancestor. `ShaderMask` appears nowhere else in `lib/`, so its
    // presence is an exact probe for the fade.
    Future<void> pumpRiserEdit(WidgetTester tester, Size size) async {
      setDesktopSurface(tester, size: size);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final c = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      c.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
      c.read(schematicViewProvider.notifier).setMode(SchematicMode.edit);
      await tester.pump();
      // The overflow state is applied in a post-frame callback (never during
      // layout), so settle one extra frame before probing.
      await tester.pump();
    }

    testWidgets('fades when the ten service chips overflow a 1440 window',
        (tester) async {
      await pumpRiserEdit(tester, const Size(1440, 900));
      expect(find.byType(ShaderMask), findsOneWidget);
    });

    testWidgets('no fade at all when the strip fits', (tester) async {
      await pumpRiserEdit(tester, const Size(3000, 900));
      expect(find.byType(ShaderMask), findsNothing);
    });

    testWidgets('Auto mode never mounts the Edit-strip fade', (tester) async {
      setDesktopSurface(tester, size: const Size(1440, 900));
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final c = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      c.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
      await tester.pump();
      await tester.pump();
      expect(c.read(schematicViewProvider).mode, SchematicMode.auto);
      expect(find.byType(ShaderMask), findsNothing);
    });
  });
}
