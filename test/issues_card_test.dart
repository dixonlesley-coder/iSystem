import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/ui/review/issues_card.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_button.dart';

import 'test_util.dart';

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

Widget _host(List<DesignIssue> issues) => ProviderScope(
      overrides: [
        designIssuesProvider.overrideWithValue(issues),
      ],
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 420, child: IssuesCard()),
          ),
        ),
      ),
    );

void main() {
  setUpAll(_loadFonts);

  testWidgets('clean design shows an explicit positive success state',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(_host(const []));
    await tester.pumpAndSettle();

    // No more invisible void — the card states the design is clean.
    expect(find.text('No design issues found'), findsOneWidget);
    // And it surfaces the reassuring detail line.
    expect(find.textContaining('Air velocities are in band'), findsOneWidget);
  });

  testWidgets('issues render grouped Warnings + Advisory', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(_host(const [
      DesignIssue(
        severity: IssueSeverity.warning,
        title: 'Air velocity high',
        message: 'A supply duct is over 7 m/s.',
      ),
      DesignIssue(
        severity: IssueSeverity.info,
        title: 'Unverified standard',
        message: 'A value awaits the official SNI clause.',
      ),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Design issues'), findsOneWidget);
    expect(find.text('No design issues found'), findsNothing);
    expect(find.textContaining('Warnings'), findsOneWidget);
    expect(find.textContaining('Advisory'), findsOneWidget);
    expect(find.text('Air velocity high'), findsOneWidget);
    expect(find.text('Unverified standard'), findsOneWidget);
  });

  testWidgets('L2: the Locate action is keyboard-focusable and Enter fires it',
      (tester) async {
    setDesktopSurface(tester);
    const issue = DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'duct-velocity',
      title: 'Duct velocity out of band',
      message: 'A supply duct is over 7 m/s.',
      locate: IssueLocation('s1', edgeId: 'e1'),
    );
    await tester.pumpWidget(_host(const [issue]));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(IssuesCard)),
      listen: false,
    );
    // Start off the Layout view so the locate jump is observable.
    container
        .read(workspaceViewProvider.notifier)
        .set(WorkspaceView.electrical);

    final locate = find.text('Locate');
    expect(locate, findsOneWidget);
    // Focus the MechXFocusRing hosting the Locate label, then press Enter —
    // the mouse-only path the finding flagged is now keyboard-reachable.
    Focus.of(tester.element(locate)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // Enter fired the same callback a mouse tap would: jumped to Layout and
    // selected the flagged edge.
    expect(container.read(workspaceViewProvider), WorkspaceView.plan);
    expect(container.read(selectionProvider).edgeId, 'e1');
  });

  testWidgets(
      'I4: acknowledging an advisory prompts for initials, then records the '
      'audit metadata', (tester) async {
    setDesktopSurface(tester);
    const advisory = DesignIssue(
      severity: IssueSeverity.info,
      kind: 'verify:test',
      isVerify: true,
      title: 'Unverified: test value',
      message: 'A value awaits the official SNI clause.',
    );
    await tester.pumpWidget(_host(const [advisory]));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(IssuesCard)),
      listen: false,
    );
    expect(container.read(acknowledgedIssuesProvider), isEmpty);

    // The at-rest row shows a single 'Acknowledge' action (the inline form is
    // hidden). Tapping it opens the form rather than accepting silently.
    expect(find.text('Acknowledge'), findsOneWidget);
    await tester.tap(find.text('Acknowledge'));
    await tester.pumpAndSettle();
    // The form is now present (an initials field + a Cancel action).
    expect(find.text('Cancel'), findsOneWidget);

    // Confirm is DISABLED until initials are entered — tapping it is a no-op.
    await tester.tap(find.widgetWithText(MechXButton, 'Acknowledge'));
    await tester.pumpAndSettle();
    expect(container.read(acknowledgedIssuesProvider), isEmpty);

    // Enter initials (first field) + a reason (second), then confirm.
    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'LD');
    await tester.enterText(fields.at(1), 'accepted per memo');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MechXButton, 'Acknowledge'));
    await tester.pumpAndSettle();

    // The advisory is now acknowledged WITH its audit metadata.
    final acks = container.read(acknowledgedIssuesProvider);
    expect(acks, hasLength(1));
    final ack = acks[advisory.key]!;
    expect(ack.author, 'LD');
    expect(ack.note, 'accepted per memo');
    expect(ack.date, isNotEmpty); // app-stamped
  });
}
