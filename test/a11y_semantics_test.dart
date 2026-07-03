// I7 (accessibility semantics): the shared MechXButton announces as a labelled
// button, and the status-bar workflow-stepper chips are keyboard-focusable +
// announced as buttons. These assertions guard the semantics layer only —
// Semantics/ExcludeSemantics are layout/paint-transparent, so goldens are
// unaffected.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/shell/workflow_stepper.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_button.dart';
import 'package:mechx/ui/widgets/mechx_focus_ring.dart';

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
  final mono = FontLoader('Roboto Mono')
    ..addFont(bytes('assets/fonts/RobotoMono-Regular.ttf'));
  await mono.load();
}

Widget _themed(Widget child) => MechXTheme(
      data: MechXThemeData.dark,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: child),
      ),
    );

void main() {
  setUpAll(_loadFonts);

  testWidgets('MechXButton exposes a Semantics button label + tap action',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _themed(MechXButton(label: 'Export', onPressed: () {})),
    );

    expect(
      tester.getSemantics(find.byType(MechXButton)),
      isSemantics(
        label: 'Export',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a disabled MechXButton announces as a disabled button',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _themed(const MechXButton(label: 'Save', onPressed: null)),
    );

    expect(
      tester.getSemantics(find.byType(MechXButton)),
      isSemantics(
        label: 'Save',
        isButton: true,
        isEnabled: false,
        hasEnabledState: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('workflow-stepper chips are keyboard-focusable buttons',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(child: _themed(const WorkflowStepper())),
    );
    await tester.pump();

    // Each of the five stage chips is wrapped in a MechXFocusRing — the shared
    // keyboard-focus + Enter/Space-activation affordance.
    final rings = find.descendant(
      of: find.byType(WorkflowStepper),
      matching: find.byType(MechXFocusRing),
    );
    expect(rings, findsNWidgets(5));

    // The first chip (Calibrate) is a focusable, labelled button.
    expect(
      tester.getSemantics(rings.first),
      isSemantics(
        label: 'Calibrate',
        isButton: true,
        isFocusable: true,
      ),
    );
    handle.dispose();
  });
}
