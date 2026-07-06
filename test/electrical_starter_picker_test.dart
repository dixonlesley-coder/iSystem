import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_inspector.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart' show StarterType;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

/// C5 — the starter/control picker on the circuit editor. Picking a VFD on a
/// motor way sets `ElectricalCircuit.starterType`, which the board-schedule
/// drafter then prints as a `· VFD` control token on that way's DEVICE cell.
void main() {
  testWidgets('picking VFD on a motor way sets starterType (schedule shows VFD)',
      (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const project = ElectricalProject(
      id: 'p',
      name: 'B',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          circuits: [
            ElectricalCircuit(
              id: 'm1',
              name: 'Pompa',
              loadKind: LoadKind.motor,
              motorKw: 5.5,
              cableType: 'NYY',
              length: Length(20),
            ),
          ],
        ),
      ],
    );
    final controller = container.read(electricalProjectProvider.notifier);
    controller.setProject(project);
    final panel = container.read(electricalProjectProvider).panels.first;
    final circuit = panel.circuits.first;

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
                controller: controller,
                onClose: () {},
                inline: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The starter picker lives under the collapsed "Advanced" disclosure
    // (MechXSectionLabel renders the name upper-cased).
    await tester.tap(find.text('ADVANCED'));
    await tester.pumpAndSettle();

    // Pick VFD.
    expect(find.text('VFD'), findsOneWidget);
    await tester.tap(find.text('VFD'));
    await tester.pump();

    final updated = container
        .read(electricalProjectProvider)
        .panels
        .first
        .circuits
        .first;
    expect(updated.starterType, StarterType.vfd);

    // End-to-end: the board schedule now prints the `· VFD` control token.
    const puil = PuilProfile();
    final result = computeSystem(
        puil, container.read(electricalProjectProvider));
    final sheet = buildElectricalSld(
        project: container.read(electricalProjectProvider), result: result);
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    expect(joined, contains('VFD'));
  });
}
