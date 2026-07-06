/// B9 (toolbar half) — the electrical toolbar's action row used to be a
/// `Spacer()` (an idle `Expanded`) followed by a `Flexible` holding a
/// horizontally-scrolling `Row` (`reverse: true`). Two flex:1 siblings split
/// the leftover width 50/50, so the actions only ever got HALF the room they
/// were owed, and whichever button that squeeze scrolled past the
/// scrollview's own clip rect painted only a sliver at the boundary — golden
/// 11 shipped exactly this: a stray fragment of the danger-toned "Electrical
/// issues" badge floating near the tabs. The fix replaces the Spacer+Flexible
/// pair with one `Expanded` (so the actions claim the full leftover width) and
/// swaps the scrolling `Row` for a right-aligned `Wrap` (a button that
/// doesn't fit the line flows onto a new one in FULL — a `Wrap` cannot
/// silently clip or squish a child's text). These tests exercise the real
/// sample project (which has live warnings, unlike an empty project whose
/// short toolbar never overflowed in the first place) at the golden's
/// 1440x900 surface.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_view.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      'the Issues button never renders clipped off the visible workspace, '
      'nor squished onto multiple lines, at the golden 1440px surface width',
      (tester) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    // Match golden 11's actual repro: the sample switchboard (which has real
    // warnings, so the label is the wider 'Electrical issues (N)' form) —
    // an empty project's short toolbar never overflowed in the first place.
    container.read(electricalProjectProvider.notifier).resetToSample();
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // No RenderFlex overflow / layout exception from the new Row/Expanded/Wrap
    // arrangement.
    expect(tester.takeException(), isNull);

    // The label reads 'Electrical issues' with no count, or 'Electrical
    // issues (N)' once the seeded/live project has warnings — either way it
    // contains this substring.
    final issuesFinder = find.textContaining('Electrical issues');
    expect(issuesFinder, findsOneWidget);

    // Structural proof the old clip-prone mechanism is gone: the button no
    // longer sits inside a horizontally-scrolling (and therefore
    // clip-boundary-cutting) `SingleChildScrollView` — a `Wrap` never clips a
    // child, it only ever flows it onto a new line.
    expect(
        find.ancestor(
            of: issuesFinder, matching: find.byType(SingleChildScrollView)),
        findsNothing,
        reason: 'the Issues button is still inside a scrollable toolbar row, '
            'which can clip it at the viewport boundary');

    final issuesRect = tester.getRect(issuesFinder);
    final viewRect = tester.getRect(find.byType(ElectricalView));

    // Fully inside the visible workspace bounds — not scrolled/clipped past
    // either edge (the old bug: a fragment poking out near the tabs).
    expect(issuesRect.left, greaterThanOrEqualTo(viewRect.left),
        reason: 'the Issues button is clipped off the left edge of the '
            'toolbar (scrolled out of view)');
    expect(issuesRect.right, lessThanOrEqualTo(viewRect.right + 0.5),
        reason: 'the Issues button overflows the right edge of the '
            'toolbar');

    // Single-line, not internally wrapped/squished onto two lines — the
    // other failure mode a too-narrow flex slice could produce (each label
    // line is ~17px tall at the default toolbar text style).
    expect(issuesRect.height, lessThan(20),
        reason: 'the Issues label wrapped onto multiple lines instead of '
            'getting its own full-width line: $issuesRect');
  });
}
