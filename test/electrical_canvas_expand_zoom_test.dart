/// D9 — the summary card's expand chevron (`focusPanelSchedule`) framed the
/// board schedule at the documented "comfortable reading" scale
/// (`kBoardScheduleThreshold`, fit-clamped to the viewport), while
/// double-tapping the adjacent merged "N loads" node zoomed to only
/// `kLodThreshold + 0.06` — barely past the summary/detail tier boundary, far
/// smaller than the chevron's framing. Both "reveal panel detail" gestures now
/// converge on the exact same `focusPanelSchedule` call, so they must produce
/// an identical transform.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      'the expand chevron and a double-tap on the merged loads node land on '
      'the same transform', (tester) async {
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
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();

    final state = tester.state<ElectricalCanvasState>(
      find.byType(ElectricalCanvas),
    );

    // Path 1 — the summary card's explicit expand chevron. `pumpAndSettle`
    // between transform changes so the per-panel summary<->schedule
    // AnimatedSwitcher (a 220 ms cross-fade) finishes before the next one
    // starts — otherwise its two keyed children collide mid-transition.
    state.collapseToSummary('mdp');
    await tester.pumpAndSettle();
    expect(state.currentScale, lessThan(kLodThreshold),
        reason: 'the summary card only renders below the LOD threshold');
    state.focusPanelSchedule('mdp');
    await tester.pumpAndSettle();
    final chevronScale = state.transform.scale;
    final chevronOffset = state.transform.offset;

    // Path 2 — double-tapping the merged "N loads" node beside the (now
    // zoomed-out again) summary card.
    state.collapseToSummary('mdp');
    await tester.pumpAndSettle();
    expect(state.currentScale, lessThan(kLodThreshold));

    // Both 'mdp' and 'lp1' carry real loads, so each gets a merged node — take
    // the LEFTMOST one: 'mdp' is the service root (depth 0, laid out
    // left-most) and a panel's merged node sits immediately to ITS right, so
    // 'mdp'\'s merged node is the one at the smaller x.
    final mergedNodes = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_MergedLoadsNode',
    );
    expect(mergedNodes, findsNWidgets(2),
        reason: 'both sample panels carry real loads');
    final centres = mergedNodes
        .evaluate()
        .map((e) => tester.getCenter(find.byWidget(e.widget)))
        .toList()
      ..sort((a, b) => a.dx.compareTo(b.dx));
    final centre = centres.first;
    // A manual double-tap: two taps inside the recognizer's timeout window
    // (the fake test clock does not advance between them).
    await tester.tapAt(centre);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(centre);
    await tester.pumpAndSettle();

    expect(state.transform.scale, chevronScale,
        reason: 'both "reveal panel detail" gestures should land on the same '
            'scale');
    expect(state.transform.offset, chevronOffset,
        reason: 'both gestures should land on the same viewport offset too');
  });
}
