/// H3 — the interactive single-line canvas's board-schedule LOD threads the
/// SAME per-panel breaking-capacity (Icu, kA) map the PDF/DXF export uses
/// (`breakerIcuKaByPanel`), so the on-screen kA a designer edits against
/// matches what gets issued — instead of silently falling back to the raw
/// (un-rounded, non-standard) busbar-withstand prospective fault.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart';
import 'package:mechx/ui/electrical/sld_sheet_painter.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';

import 'test_util.dart';

/// All [SldLabel] text drawn by the [CustomPaint] using [SldBoardSchedulePainter]
/// whose sheet contains a label matching [ownedBy] — more than one panel can be
/// at the detail LOD simultaneously (zoom is canvas-wide), so `.first` alone
/// would pick an arbitrary board.
List<String> _scheduleLabels(
  WidgetTester tester,
  Finder finder,
  bool Function(List<String>) ownedBy,
) {
  final painters = tester
      .widgetList<CustomPaint>(finder)
      .map((w) => w.painter)
      .whereType<SldBoardSchedulePainter>();
  for (final painter in painters) {
    final labels = [
      for (final p in painter.sheet.prims)
        if (p is SldLabel) p.text,
    ];
    if (ownedBy(labels)) return labels;
  }
  return const [];
}

void main() {
  testWidgets(
      "the canvas board schedule's kA suffix matches the fault-study's chosen "
      'device rating, not the raw busbar-withstand fallback', (tester) async {
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

    // Independently resolve what the EXPORT path would print for 'lp1', and
    // what a pre-fix canvas (no map threaded) would have shown — these must
    // differ for this fixture, or the test proves nothing.
    final project = container.read(electricalProjectProvider);
    final result = container.read(electricalResultProvider);
    final mapped = container
        .read(electricalAdvancedProvider)
        .fault
        .panels['lp1']
        ?.incomerKa;
    expect(mapped, isNotNull);
    final withMap = buildElectricalPanelDetail(
      project: project,
      result: result,
      panelId: 'lp1',
      breakerIcuKaByPanelId: {'lp1': mapped!},
    );
    final withoutMap = buildElectricalPanelDetail(
      project: project,
      result: result,
      panelId: 'lp1',
    );
    String? kaLabel(SldSheet s) => [
          for (final p in s.prims)
            if (p is SldLabel && p.text.contains('kA')) p.text,
        ].first;
    final expectedWithMap = kaLabel(withMap);
    final expectedWithoutMap = kaLabel(withoutMap);
    expect(expectedWithMap, isNot(equals(expectedWithoutMap)),
        reason: "lp1's fault-study Icu (ladder-selected) must differ from its "
            'raw busbar-withstand fault for this fixture, or this test cannot '
            'discriminate the two sources');

    // Now zoom the LIVE canvas into lp1's board schedule and read what it
    // actually painted.
    final state = tester.state<ElectricalCanvasState>(
      find.byType(ElectricalCanvas),
    );
    state.focusPanelSchedule('lp1');
    await tester.pumpAndSettle();

    final onCanvas = _scheduleLabels(
      tester,
      find.byWidgetPredicate((w) => w is CustomPaint),
      // The board's own HEADER label ('Lighting Panel  [LP-1]') — not a
      // feeder row's "-> Lighting Panel" KETERANGAN cell on ANOTHER board.
      (labels) => labels.any((t) => t.contains('[LP-1]')),
    );
    expect(onCanvas, isNotEmpty,
        reason: "lp1's board schedule must be painted at the detail LOD");
    expect(onCanvas.any((t) => t == expectedWithMap), isTrue,
        reason: 'the canvas must show the SAME kA-bearing label the export '
            'would print');
    expect(onCanvas.any((t) => t == expectedWithoutMap), isFalse,
        reason: 'the canvas must NOT fall back to the raw busbar-withstand '
            'value now that the fault-study map is threaded through');
  });
}
