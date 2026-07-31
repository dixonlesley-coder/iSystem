import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/inspector/collapsible_inspector.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

import 'test_util.dart';

/// Seeds the demo sheets from the first frame (production launches EMPTY per
/// A1 — see `widget_test.dart`'s identical helper) so the Layout canvas has
/// something to fit/zoom to.
class _SeededSheetsController extends SheetsController {
  @override
  SheetsState build() => const SheetsState(sheets: kDemoSheets);
}

/// E-3 + R-4 — two small shell/chrome-polish fixes:
///
///  · E-3: the top-bar zoom pill used to render a literal '—' on the
///    Riser/Electrical workspaces and every hub screen (where the pill can't
///    read a truthful Layout zoom). It is now OMITTED there entirely — only
///    the Layout canvas shows a zoom readout.
///  · R-4: [CollapsibleInspector]'s body used to sit in a `centerLeft`
///    [OverflowBox], so a shrink-wrapped child (the Riser inspector's
///    `SingleChildScrollView`-around-a-`Column`) rendered vertically
///    CENTERED in the available height, leaving dead space above its first
///    section. The body now fills the available height (top-aligned).
void main() {
  group('E-3 — the zoom pill', () {
    testWidgets(
        'renders a percentage on Layout, and is entirely absent (never a '
        "bare '—') off Layout", (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sheetsControllerProvider.overrideWith(_SeededSheetsController.new),
        ],
        child: const MechXApp(),
      ));
      await tester.pump();
      await tester.pump(); // run the post-frame fit
      await tester.pump(); // rebuild with the emitted transform
      final c = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );

      // Default state: ShellSection.design + WorkspaceView.plan (Layout), a
      // sheet loaded and fitted — the pill shows a real percentage, never
      // the em-dash fallback.
      expect(c.read(shellSectionProvider), ShellSection.design);
      expect(c.read(workspaceViewProvider), WorkspaceView.plan);
      expect(find.byKey(const ValueKey('zoom-pill')), findsOneWidget);
      expect(find.text('—'), findsNothing);
      expect(find.descendant(
          of: find.byKey(const ValueKey('zoom-pill')),
          matching: find.textContaining('%')), findsOneWidget);

      // Riser (schematic) workspace — the pill must be gone, not '—'.
      c.read(workspaceViewProvider.notifier).set(WorkspaceView.schematic);
      await tester.pump();
      expect(find.byKey(const ValueKey('zoom-pill')), findsNothing);
      expect(find.text('—'), findsNothing);

      // Electrical workspace — same.
      c.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
      await tester.pump();
      expect(find.byKey(const ValueKey('zoom-pill')), findsNothing);
      expect(find.text('—'), findsNothing);

      // A non-design hub screen — same.
      c.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);
      c.read(shellSectionProvider.notifier).set(ShellSection.review);
      await tester.pump();
      expect(find.byKey(const ValueKey('zoom-pill')), findsNothing);
      expect(find.text('—'), findsNothing);

      // Back on Layout, the pill returns.
      c.read(shellSectionProvider.notifier).set(ShellSection.design);
      await tester.pump();
      expect(find.byKey(const ValueKey('zoom-pill')), findsOneWidget);
    });
  });

  group('R-4 — CollapsibleInspector body alignment', () {
    testWidgets(
        'a short, shrink-wrapped body top-aligns to the panel top instead of '
        'centering in a tall parent', (tester) async {
      const bodyKey = Key('shrink-wrapped-body');
      const theme = MechXThemeData.light;

      await tester.pumpWidget(
        ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: MechXTheme(
              data: theme,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  // A tall parent (mirrors the real inspector column, which
                  // fills the full workspace height) around a body whose
                  // natural content is much shorter — exactly the Riser
                  // inspector's shape (goldens 04/07).
                  height: 600,
                  child: CollapsibleInspector(
                    expandedWidth: 260,
                    child: Column(
                      key: bodyKey,
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        SizedBox(height: 24, child: Text('Section')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final panelTop = tester.getTopLeft(find.byType(CollapsibleInspector)).dy;
      final bodyTop = tester.getTopLeft(find.byKey(bodyKey)).dy;

      // Before the fix, a `centerLeft` OverflowBox placed this short body at
      // roughly (600 - bodyHeight) / 2 below the panel top — visibly
      // "floating" dead space above it. Top-aligned + stretched, its top now
      // sits flush with the panel's own top.
      expect(bodyTop, closeTo(panelTop, 1.0));
    });
  });
}
