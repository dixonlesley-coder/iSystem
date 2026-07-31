import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/review/issues_card.dart';
import 'package:mechx/ui/review/review_hub.dart';
import 'package:mechx/ui/strings/app_strings.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mep_report.dart' show ComplianceItem;

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

void main() {
  setUpAll(_loadFonts);

  testWidgets(
      'Review hub shows a pass/fail compliance roll-up and no placeholder prose',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: ReviewHub(),
          ),
        ),
      ),
    );
    await tester.pump();

    // The "coming together" placeholder lead is gone.
    expect(find.textContaining('coming together'), findsNothing);
    // The new lead is present.
    expect(find.textContaining('Check the design before you issue it'),
        findsOneWidget);

    // The compliance roll-up renders an overall verdict + the three category
    // rows. With the default const standards profiles carrying // VERIFY items,
    // the Standards row must be REVIEW (so the overall verdict is REVIEW
    // REQUIRED).
    expect(find.text('Velocity'), findsOneWidget);
    expect(find.text('Sheet calibration'), findsOneWidget);
    expect(find.text('Standards verification'), findsOneWidget);
    expect(find.text('REVIEW REQUIRED'), findsOneWidget);
    // 'REVIEW' verdict labels appear at least for the Standards row.
    expect(find.text('REVIEW'), findsWidgets);

    // J3: the hub ends in an 'Export deliverables' card leading with the
    // verdict (the "check, then issue" pairing), followed by the reused
    // export buttons — no new export path, just the existing Projects-screen
    // functions surfaced here too.
    expect(find.text('Export deliverables'), findsOneWidget);
    expect(
      find.text('REVIEW REQUIRED — you decide whether to issue'),
      findsOneWidget,
    );
    expect(find.text('Export calc report (MD)'), findsOneWidget);
    expect(find.text('Export unified MEP report (MD)'), findsOneWidget);
    // H8: the MD equipment-schedule export also writes a CSV sibling — the
    // button says so.
    expect(find.text('Export equipment schedule (MD + CSV)'), findsOneWidget);
  });

  testWidgets(
      'H2: the compliance verdict re-computes LIVE as issues are fixed '
      '(no stale snapshot)', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: ReviewHub(),
          ),
        ),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReviewHub)),
      listen: false,
    );

    // Seed three uncalibrated sheets — the calibration row must flip to
    // REVIEW on the ALREADY-MOUNTED cards (pre-H2 the const-mounted cards
    // kept the boot-time verdict until the user left and returned). A BLANK
    // uncalibrated sheet is only an INFO advisory (nothing measurable is
    // wrong yet), so a drawn edge on s1 gives it a real (failing) finding —
    // s2/s3 stay blank/info and don't count toward the row.
    container.read(sheetsControllerProvider.notifier).loadDemoSheets();
    const nodeA = NetNode(id: 'na', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
    const nodeB = NetNode(id: 'nb', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
    const edge = NetEdge(
        id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater);
    container.read(networkControllerProvider.notifier).loadNetwork(
          const Network(nodes: [nodeA, nodeB], edges: [edge]),
        );
    await tester.pump();
    expect(find.text('1 uncalibrated'), findsWidgets);

    // Fix the issue in place: calibrate every sheet → the row re-verdicts to
    // PASS without remounting the screen.
    final project = container.read(projectControllerProvider.notifier);
    for (final s in kDemoSheets) {
      project.setCalibration(s.id, const ScaleCalibration(0.01));
    }
    await tester.pump();
    expect(find.text('1 uncalibrated'), findsNothing);
    expect(find.text('all sheets calibrated'), findsWidgets);
  });

  testWidgets(
      'A5: a compliance category row REVEALS its issue group in the card below',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: ReviewHub(),
          ),
        ),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReviewHub)),
      listen: false,
    );
    expect(container.read(issueFocusProvider), isNull);

    // The 'Standards verification' row is REVIEW by default (the // VERIFY
    // register), and the actionable copy sits in the IssuesCard below the fold.
    await tester.tap(find.text('Standards verification'));
    await tester.pump();

    final focus = container.read(issueFocusProvider);
    expect(focus, isNotNull);
    // It points at a group that genuinely EXISTS in the live issue list — the
    // first unverified-standards advisory the same fan-in counted.
    final verify =
        container.read(designIssuesProvider).where((i) => i.isVerify).toList();
    expect(verify, isNotEmpty);
    expect(focus, issueGroupKey(verify.first));
  });

  test('A5: complianceRowGroupKey mirrors the compliance fan-in claim rules',
      () {
    const s = MechXStringsData(AppLocale.en);
    const velocity = DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'duct-velocity',
      title: 'Duct velocity out of band',
      message: 'over 7 m/s',
    );
    const uncalibrated = DesignIssue(
      severity: IssueSeverity.critical,
      kind: 'sheet-uncalibrated:s1',
      title: 'Sheet not calibrated',
      message: 'no scale',
    );
    const verify = DesignIssue(
      severity: IssueSeverity.info,
      kind: 'verify:sni',
      isVerify: true,
      title: 'Unverified: max supply velocity',
      message: 'awaiting the clause',
    );
    const electrical = DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'electrical:non-selective',
      title: 'Electrical: non-selective',
      message: 'upstream device too close',
    );
    const other = DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'unconnected-loose-end:n1',
      title: 'Run end not connected',
      message: 'ends in mid air',
    );
    const issues = [velocity, uncalibrated, verify, electrical, other];

    String? keyFor(String category) => complianceRowGroupKey(
        ComplianceItem(category, pass: false), issues, s);

    expect(keyFor(s(StringKey.complianceCategoryAirVelocity)),
        issueGroupKey(velocity));
    expect(keyFor(s(StringKey.complianceCategorySheetCalibration)),
        issueGroupKey(uncalibrated));
    expect(keyFor(s(StringKey.complianceCategoryStandardsVerification)),
        issueGroupKey(verify));
    expect(keyFor(s(StringKey.complianceCategoryElectricalSizing)),
        issueGroupKey(electrical));
    // A remainder row is keyed by the issue TITLE, exactly as the fan-in groups
    // it.
    expect(keyFor('Run end not connected'), issueGroupKey(other));
    // A row with nothing to reveal (a clean check, or an acknowledgement-log
    // entry) stays inert rather than linking to a group it never counted.
    expect(keyFor('Acknowledged: something else'), isNull);
    expect(
        complianceRowGroupKey(
            ComplianceItem(s(StringKey.complianceCategoryAirVelocity),
                pass: true),
            const [],
            s),
        isNull);
  });

  test('A5: a category spanning several groups points at the FAILING one', () {
    const s = MechXStringsData(AppLocale.en);
    const advisory = DesignIssue(
      severity: IssueSeverity.info,
      kind: 'terminal-velocity',
      title: 'Terminal face velocity out of band',
      message: 'noted',
    );
    const failing = DesignIssue(
      severity: IssueSeverity.warning,
      kind: 'duct-velocity',
      title: 'Duct velocity out of band',
      message: 'over 7 m/s',
    );
    expect(
      complianceRowGroupKey(
          ComplianceItem(s(StringKey.complianceCategoryAirVelocity),
              pass: false),
          const [advisory, failing],
          s),
      issueGroupKey(failing),
    );
  });
}
