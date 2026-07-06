/// C6 — cos phi / Demand factor / Diversity factor are 0-1 RATIO fields and
/// Headroom spare is a 0-100 PERCENT field, but all four used to render
/// through the same bare `ElectricalNumInput` with no unit suffix, range
/// hint, or error state — so typing '85' meaning 85% into a ratio field
/// silently clamped to 1.0 (100%) with no signal anything was rejected.
/// Ratio fields now show an honest '(0-1)' range in their label and REJECT
/// (an inline field-error message, no clamp) an out-of-range commit; the
/// percent field bakes a '%' suffix onto its display. One test per kind.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_controls.dart';
import 'package:mechx_engine/electrical/model.dart' show ElectricalCircuit;

import 'test_util.dart';

void main() {
  Future<ProviderContainer> setup(WidgetTester tester) async {
    setDesktopSurface(tester, size: const Size(1440, 900));
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
    container
        .read(electricalProjectProvider.notifier)
        .setProject(sampleElectricalProject());
    await tester.pump();
    return container;
  }

  Future<void> expandAdvanced(WidgetTester tester) async {
    final expand = find.bySemanticsLabel('Expand Advanced section');
    await tester.ensureVisible(expand);
    await tester.pump();
    await tester.tap(expand);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Finder editableTextFor(String labelText) => find.descendant(
        of: find.ancestor(
          of: find.text(labelText),
          matching: find.byType(ElectricalField),
        ),
        matching: find.byType(EditableText),
      );

  testWidgets(
      'a 0-1 ratio field (cos phi) rejects an out-of-range commit with an '
      'inline error, instead of silently clamping', (tester) async {
    final container = await setup(tester);
    container
        .read(electricalInspectorTargetProvider.notifier)
        .editCircuit('lp1', 'lp1-c1');
    await tester.pump();
    await expandAdvanced(tester);

    // C6: the label itself now names the honest 0-1 range.
    expect(find.text('cos phi (0-1)'), findsOneWidget);

    ElectricalCircuit circuit() => container
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == 'lp1')
        .circuits
        .firstWhere((c) => c.id == 'lp1-c1');
    expect(circuit().cosPhi, 0.9);

    final field = editableTextFor('cos phi (0-1)');
    await tester.enterText(field, '85');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    // Rejected, not clamped to 1.0 — the model is untouched and an inline
    // error names the valid range.
    expect(circuit().cosPhi, 0.9);
    expect(find.textContaining('between 0 and 1'), findsOneWidget);

    // A well-formed, in-range value still commits normally.
    await tester.enterText(field, '0.75');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(circuit().cosPhi, 0.75);
    expect(find.textContaining('between 0 and 1'), findsNothing);
  });

  testWidgets(
      'the 0-100 percent field (headroom spare) bakes an honest % suffix '
      'onto its display and accepts an in-range commit', (tester) async {
    final container = await setup(tester);
    container
        .read(electricalInspectorTargetProvider.notifier)
        .editPanel('lp1');
    await tester.pump();
    await expandAdvanced(tester);

    // Default headroom is none (0%): the field shows the bare number and a
    // '%' suffix rides alongside it (never a bare '0' indistinguishable from
    // the adjacent 0-1 ratio fields).
    final headroomField = find.ancestor(
      of: find.text('Headroom — spare demand (%)'),
      matching: find.byType(ElectricalField),
    );
    final field = find.descendant(
        of: headroomField, matching: find.byType(EditableText));
    expect(tester.widget<EditableText>(field).controller.text, '0');
    expect(
        find.descendant(of: headroomField, matching: find.text('%')),
        findsOneWidget);

    await tester.enterText(field, '35');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    final panel = container
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == 'lp1');
    expect(panel.headroom?.sparePercentage, 35);
    expect(tester.widget<EditableText>(field).controller.text, '35');
    expect(
        find.descendant(of: headroomField, matching: find.text('%')),
        findsOneWidget);
  });
}
