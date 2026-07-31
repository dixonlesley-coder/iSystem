import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/inspector_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/reveal_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/review/issues_card.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_button.dart';
import 'package:mechx_engine/network/network.dart';

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

Widget _host(List<DesignIssue> issues,
        {List<IssueBatchAction>? batchActions}) =>
    ProviderScope(
      overrides: [
        designIssuesProvider.overrideWithValue(issues),
        if (batchActions != null)
          issueBatchActionsProvider.overrideWithValue(batchActions),
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

/// A two-node cold-water run on sheet `s1` (floor 0) — the mechanical element
/// a locate test jumps to.
const _nodeA = NetNode(id: 'na', sheetId: 's1', x: 100, y: 40, floorIndex: 0);
const _nodeB = NetNode(id: 'nb', sheetId: 's1', x: 300, y: 40, floorIndex: 0);
const _edge = NetEdge(
    id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater);
const _network = Network(nodes: [_nodeA, _nodeB], edges: [_edge]);

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
      'A1: locating a MECHANICAL issue leaves the Review hub for the DESIGN '
      'workspace (the section the electrical branch always set)', (tester) async {
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
    // The engineer is standing on the Review hub — where the card lives.
    container.read(shellSectionProvider.notifier).set(ShellSection.review);
    expect(container.read(shellSectionProvider), ShellSection.review);

    await tester.tap(find.text('Locate'));
    await tester.pump();

    // The jump now actually leaves Review (pre-A1 the sheet/selection/view
    // moved while the shell stayed on the hub).
    expect(container.read(shellSectionProvider), ShellSection.design);
    expect(container.read(workspaceViewProvider), WorkspaceView.plan);
    expect(container.read(selectionProvider).edgeId, 'e1');
  });

  testWidgets('A1: a QUICK-FIX batch action leaves Review too', (tester) async {
    setDesktopSurface(tester);
    const issue = DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'duct-velocity',
      title: 'Duct velocity out of band',
      message: 'A supply duct is over 7 m/s.',
      locate: IssueLocation('s1', edgeId: 'e1'),
    );
    await tester.pumpWidget(_host(
      const [issue],
      batchActions: const [
        IssueBatchAction(
          kind: IssueBatchKind.selectVelocityWarnings,
          label: 'Select velocity warnings',
          enabled: true,
          edgeIds: {'e1'},
        ),
      ],
    ));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(IssuesCard)),
      listen: false,
    );
    container.read(shellSectionProvider.notifier).set(ShellSection.review);

    await tester.tap(find.text('Select velocity warnings'));
    await tester.pump();

    expect(container.read(shellSectionProvider), ShellSection.design);
    expect(container.read(workspaceViewProvider), WorkspaceView.plan);
    expect(container.read(selectionProvider).edgeIds, {'e1'});
  });

  testWidgets(
      'A2: locating an element REQUESTS a reveal at its world midpoint',
      (tester) async {
    setDesktopSurface(tester);
    const issue = DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'water-velocity',
      title: 'Water velocity out of band',
      message: 'A cold-water run is over 2.0 m/s.',
      locate: IssueLocation('s1', edgeId: 'e1'),
    );
    await tester.pumpWidget(_host(const [issue]));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(IssuesCard)),
      listen: false,
    );
    container.read(networkControllerProvider.notifier).loadNetwork(_network);
    await tester.pump();
    expect(container.read(revealTargetProvider), isNull);

    await tester.tap(find.text('Locate'));
    await tester.pump();

    // The run spans (100,40) -> (300,40) on s1: the reveal centres its midpoint
    // so the selected element actually arrives on screen.
    final reveal = container.read(revealTargetProvider);
    expect(reveal, isNotNull);
    expect(reveal!.sheetId, 's1');
    expect(reveal.x, 200);
    expect(reveal.y, 40);
  });

  testWidgets('A2: a NODE target reveals the node itself', (tester) async {
    setDesktopSurface(tester);
    const issue = DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'unconnected-loose-end:nb',
      title: 'Run end not connected',
      message: 'A cold-water run ends in mid air.',
      locate: IssueLocation('s1', nodeId: 'nb'),
    );
    await tester.pumpWidget(_host(const [issue]));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(IssuesCard)),
      listen: false,
    );
    container.read(networkControllerProvider.notifier).loadNetwork(_network);
    await tester.pump();

    await tester.tap(find.text('Locate'));
    await tester.pump();

    final reveal = container.read(revealTargetProvider);
    expect(reveal, isNotNull);
    expect(reveal!.x, 300);
    expect(reveal.y, 40);
  });

  testWidgets(
      'A3: locating restores the element CONTEXT — discipline, visibility, '
      'lock, isolate and the inspector', (tester) async {
    setDesktopSurface(tester);
    const issue = DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'water-velocity',
      title: 'Water velocity out of band',
      message: 'A cold-water run is over 2.0 m/s.',
      locate: IssueLocation('s1', edgeId: 'e1'),
    );
    await tester.pumpWidget(_host(const [issue]));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(IssuesCard)),
      listen: false,
    );
    container.read(networkControllerProvider.notifier).loadNetwork(_network);
    // The engineer was routing DUCTS, with plumbing locked as a reference
    // layer, cold water isolated OFF, and the inspector collapsed for canvas
    // room — every way the target could arrive invisible or inert.
    container.read(activeDisciplineProvider.notifier).set(DisciplineLayer.hvac);
    container
        .read(lockedDisciplinesProvider.notifier)
        .toggle(DisciplineLayer.plumbing);
    container.read(hiddenServicesProvider.notifier).toggle(ServiceType.coldWater);
    container.read(inspectorCollapsedProvider.notifier).set(true);
    await tester.pump();
    expect(container.read(lockedDisciplinesProvider),
        contains(DisciplineLayer.plumbing));

    await tester.tap(find.text('Locate'));
    await tester.pump();

    // The cold-water run's own discipline is active, drawn, unlocked and no
    // longer isolated away — and its editor is on screen.
    expect(container.read(activeDisciplineProvider), DisciplineLayer.plumbing);
    expect(container.read(layerVisibilityProvider),
        contains(DisciplineLayer.plumbing));
    expect(container.read(lockedDisciplinesProvider),
        isNot(contains(DisciplineLayer.plumbing)));
    expect(container.read(hiddenServicesProvider),
        isNot(contains(ServiceType.coldWater)));
    expect(container.read(inspectorCollapsedProvider), isFalse);
    // Other services' isolates are left exactly as the engineer set them.
    expect(container.read(inertServicesProvider),
        isNot(contains(ServiceType.coldWater)));
  });

  testWidgets(
      'A3: a whole-SHEET issue changes no discipline context (nothing to '
      'derive)', (tester) async {
    setDesktopSurface(tester);
    const issue = DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'sheet-uncalibrated:s1',
      title: 'Sheet not calibrated',
      message: 'Ground Floor has no scale.',
      locate: IssueLocation('s1'),
    );
    await tester.pumpWidget(_host(const [issue]));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(IssuesCard)),
      listen: false,
    );
    container.read(activeDisciplineProvider.notifier).set(DisciplineLayer.hvac);
    await tester.pump();

    await tester.tap(find.text('Locate'));
    await tester.pump();

    // No element, so no discipline is guessed — and nothing to centre on.
    expect(container.read(activeDisciplineProvider), DisciplineLayer.hvac);
    expect(container.read(revealTargetProvider), isNull);
    // The jump still leaves Review and selects nothing.
    expect(container.read(shellSectionProvider), ShellSection.design);
  });

  testWidgets(
      'A4: a grouped row speaks with its WORST member and labels each link '
      'with sheet + element tag', (tester) async {
    setDesktopSurface(tester);
    // Two same-class findings: the second is the severe, specific one.
    const issues = [
      DesignIssue(
        severity: IssueSeverity.warning,
        kind: 'water-velocity',
        title: 'Water velocity out of band',
        message: 'A run is out of band.',
        locate: IssueLocation('s1', edgeId: 'e1'),
      ),
      DesignIssue(
        severity: IssueSeverity.critical,
        kind: 'water-velocity',
        title: 'Water velocity out of band',
        message: 'A cold-water run runs at 3.4 m/s.',
        locate: IssueLocation('s1', edgeId: 'e2'),
      ),
    ];
    await tester.pumpWidget(_host(issues));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(IssuesCard)),
      listen: false,
    );
    container.read(sheetsControllerProvider.notifier).loadDemoSheets();
    container.read(networkControllerProvider.notifier).loadNetwork(
          const Network(
            nodes: [
              _nodeA,
              _nodeB,
              NetNode(id: 'nc', sheetId: 's1', x: 300, y: 200, floorIndex: 0),
            ],
            edges: [
              _edge,
              NetEdge(
                  id: 'e2',
                  fromId: 'nb',
                  toId: 'nc',
                  service: ServiceType.coldWater),
            ],
          ),
        );
    await tester.pump();

    // The group line carries the count and the WORST member's message.
    expect(find.text('Water velocity out of band x2'), findsOneWidget);
    expect(find.text('A cold-water run runs at 3.4 m/s.'), findsOneWidget);
    // Each link names its own place: sheet + the SAME stable element tag the
    // plan labels / BOM / calc report print — not two identical 'Locate's.
    expect(find.text('Locate'), findsNothing);
    expect(find.text('Ground Floor · CW-F1'), findsNWidgets(2));
  });

  testWidgets(
      'A5: a reveal request expands + highlights its group, and the group can '
      'be folded away again', (tester) async {
    setDesktopSurface(tester);
    const issues = [
      DesignIssue(
        severity: IssueSeverity.warning,
        kind: 'sheet-uncalibrated:s1',
        title: 'Sheet not calibrated',
        message: 'Ground Floor has no scale.',
        locate: IssueLocation('s1'),
      ),
      DesignIssue(
        severity: IssueSeverity.warning,
        kind: 'sheet-uncalibrated:s2',
        title: 'Sheet not calibrated',
        message: 'First Floor has no scale.',
        locate: IssueLocation('s2'),
      ),
    ];
    await tester.pumpWidget(_host(issues));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(IssuesCard)),
      listen: false,
    );
    container.read(sheetsControllerProvider.notifier).loadDemoSheets();
    await tester.pump();

    // Grouped, with a per-sheet link each and the expand hook.
    expect(find.text('Sheet not calibrated x2'), findsOneWidget);
    expect(find.text('Ground Floor'), findsOneWidget);
    expect(find.text('First Floor'), findsOneWidget);

    // Fold the group away: the links go, the summary line stays.
    await tester.tap(find.text('Hide locations'));
    await tester.pumpAndSettle();
    expect(find.text('Ground Floor'), findsNothing);
    expect(find.text('Sheet not calibrated x2'), findsOneWidget);

    // A compliance-card reveal request re-opens exactly that group.
    container
        .read(issueFocusProvider.notifier)
        .reveal(issueGroupKey(issues.first));
    await tester.pumpAndSettle();
    expect(find.text('Ground Floor'), findsOneWidget);
    expect(find.text('First Floor'), findsOneWidget);
  });

  test('A4: worstOfGroup ranks by severity, then by a named magnitude', () {
    const vague = DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'k',
      title: 't',
      message: 'out of band',
    );
    const specific = DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'k',
      title: 't',
      message: 'runs at 3.4 m/s',
    );
    const critical = DesignIssue(
      severity: IssueSeverity.critical,
      kind: 'k',
      title: 't',
      message: 'no scale',
    );
    // Severity wins outright.
    expect(worstOfGroup(const [vague, critical]), same(critical));
    expect(worstOfGroup(const [critical, specific]), same(critical));
    // Equal severity: the member that names a figure speaks.
    expect(worstOfGroup(const [vague, specific]), same(specific));
    // Deterministic when neither names one.
    expect(worstOfGroup(const [vague, vague]), same(vague));
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
