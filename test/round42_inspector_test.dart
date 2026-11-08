// Round 42 (2026-10-18) — the circuit inspector reads the schedule's own
// tokens, and never offers a star-delta starter on a single-phase way.
//
//  * elec-ui-journey-3-inspector-protection-diverges-from-schedule — a 1φ
//    feeder off a 3φ board is 2-pole and a TT feeder RCD is time-delayed
//    (' S') on the inspector exactly as on the board schedule.
//  * elec-props-8-star-delta-on-single-phase-way — the picker omits
//    Star-delta on a single-phase way.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_inspector.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

Future<void> _pump(WidgetTester tester, ProviderContainer container,
    ElectricalPanel panel, ElectricalCircuit circuit,
    {ElectricalCircuitResult? result}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: ElectricalCircuitInspector(
              panel: panel,
              circuit: circuit,
              controller: container.read(electricalProjectProvider.notifier),
              onClose: () {},
              inline: true,
              circuitResult: result,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a 1φ TT feeder off a 3φ board: 2P + RCD ... S, as scheduled',
      (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const project = ElectricalProject(
      id: 'p',
      name: 'B',
      earthingSystem: EarthingSystem.tt,
      panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          ElectricalCircuit(
              id: 'f',
              name: 'F-SP',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'SP',
              length: Length(20)),
        ]),
        ElectricalPanel(
          id: 'SP',
          name: 'SP',
          system: ElectricalSystem.singlePhase,
          voltage: Voltage(230),
          circuits: [
            ElectricalCircuit(
                id: 'l',
                name: 'Lamps',
                loadKind: LoadKind.lighting,
                loadW: 3000,
                length: Length(15)),
          ],
        ),
      ],
    );
    container.read(electricalProjectProvider.notifier).setProject(project);
    final sys = computeSystem(const PuilProfile(), project);
    final r = sys.panels['MDP']!.circuits.single;
    expect(r.threePhase, isFalse);
    expect(r.rcd.required && r.rcd.timeDelayed, isTrue);
    final panel = project.panels.first;
    await _pump(tester, container, panel, panel.circuits.single, result: r);

    final token = breakerScheduleLabel(r.breaker, 1, twoPole: true);
    expect(token, contains('2P'));
    // The inspector's protection row …
    final rowText = find.textContaining(token);
    expect(rowText, findsWidgets);
    final shown = tester.widget<Text>(rowText.first).data!;
    expect(shown, contains(' S'));
    // … and the schedule's DEVICE cell carry the same breaker + RCD tokens.
    final cell = buildElectricalSld(project: project, result: sys)
        .prims
        .whereType<SldLabel>()
        .map((l) => l.text)
        .firstWhere((t) => t.startsWith(token));
    expect(cell, contains('RCD ${r.rcd.ratingMa}mA'));
    expect(cell, contains(' S'));
  });

  testWidgets('Star-delta is not offered on a single-phase pump way',
      (tester) async {
    setDesktopSurface(tester);
    for (final phases in [1, 3]) {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final project = ElectricalProject(id: 'p', name: 'B', panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          ElectricalCircuit(
              id: 'jp',
              name: 'Jockey',
              loadKind: LoadKind.pump,
              motorKw: 2.2,
              phases: phases,
              length: const Length(10)),
        ]),
      ]);
      container.read(electricalProjectProvider.notifier).setProject(project);
      final sys = computeSystem(const PuilProfile(), project);
      final panel = project.panels.first;
      await _pump(tester, container, panel, panel.circuits.single,
          result: sys.panels['MDP']!.circuits.single);
      await tester.ensureVisible(find.text('ADVANCED'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ADVANCED'));
      await tester.pumpAndSettle();
      expect(find.text('Star-delta'),
          phases == 1 ? findsNothing : findsOneWidget,
          reason: '$phases ph');
    }
  });
}
