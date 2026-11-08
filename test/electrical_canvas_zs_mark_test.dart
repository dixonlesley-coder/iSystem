/// Round 44 — the live single-line board schedule marks a way that FAILS
/// automatic disconnection with the SAME ` Zs!` token the issued PDF / DXF
/// schedule prints (`adsFailedCircuitIdsOf` over the fault study). Before,
/// the canvas never received the set, so the engineer's working view showed
/// a clean row for a way the issued drawing flags as an earth-fault-loop
/// failure.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_canvas.dart';
import 'package:mechx/ui/electrical/sld_sheet_painter.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

/// One 3φ MDP whose lighting way is hand-protected by a 63 A breaker on a
/// 300 m run: the earth-fault loop (source + 300 m of the load-sized cable
/// and its PE at the fault temperature) is far above the 63 A device's
/// U0 / Ia limit, so the fault study's ADS verdict fails on way S.
ElectricalProject _project() => const ElectricalProject(
      id: 'p',
      name: 'P',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          system: ElectricalSystem.threePhase,
          voltage: Voltage(400),
          circuits: [
            ElectricalCircuit(
              id: 'S',
              name: 'Lamp',
              loadKind: LoadKind.lighting,
              loadW: 3000,
              breakerOverrideA: Current(63),
              length: Length(300),
            ),
          ],
        ),
      ],
    );

void main() {
  testWidgets('the canvas board schedule prints the Zs! mark the export does',
      (tester) async {
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
    container.read(electricalProjectProvider.notifier).setProject(_project());
    await tester.pump();

    // Non-vacuous: the fault study fails ADS on way S and the export marks it.
    final failed =
        adsFailedCircuitIdsOf(container.read(electricalAdvancedProvider).fault);
    expect(failed, contains('S'));
    final exported = buildElectricalPanelDetail(
      project: container.read(electricalProjectProvider),
      result: container.read(electricalResultProvider),
      panelId: 'MDP',
      adsFailedCircuitIds: failed,
    );
    expect(
        exported.prims
            .whereType<SldLabel>()
            .any((l) => l.text.endsWith(' Zs!')),
        isTrue);

    tester
        .state<ElectricalCanvasState>(find.byType(ElectricalCanvas))
        .focusPanelSchedule('MDP');
    await tester.pumpAndSettle();
    final labels = [
      for (final painter in tester
          .widgetList<CustomPaint>(
              find.byWidgetPredicate((w) => w is CustomPaint))
          .map((w) => w.painter)
          .whereType<SldBoardSchedulePainter>())
        for (final p in painter.sheet.prims)
          if (p is SldLabel) p.text,
    ];
    expect(labels, isNotEmpty);
    expect(labels.any((t) => t.endsWith(' Zs!')), isTrue,
        reason: 'the live schedule must agree with the issued one');
  });
}
