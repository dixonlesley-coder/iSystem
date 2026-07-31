/// Hub-polish batch (C1/V1/V2/P1/PR1) — Commercial's electrical-BOM heading,
/// the Review hub's balanced stat grid, duplicate design-issue rows collapsing
/// with a live count, the Projects export groups naming their own inventory,
/// and the Preferences software-update card getting its own section. Display
/// only; no engine / `.mechx` change.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart' show AppLocale;
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/commercial/electrical_bom_view.dart';
import 'package:mechx/ui/review/issues_card.dart';
import 'package:mechx/ui/review/review_hub.dart';
import 'package:mechx/ui/shell/preferences_screen.dart';
import 'package:mechx/ui/shell/projects_screen.dart';
import 'package:mechx/ui/strings/app_strings.dart' show MechXStringsData, StringKey;
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/network/network.dart' show ServiceType;
import 'package:mechx_engine/sizing/pipe_optimizer.dart'
    show PipeCutGroup, StockCutPlan;

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

Widget _themed(Widget child, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(textDirection: TextDirection.ltr, child: child),
      ),
    );

void main() {
  setUpAll(_loadFonts);

  group('C1 — the Commercial electrical BOM heading', () {
    testWidgets('reads "Electrical BOM", matching the Mechanical BOM sibling',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(_themed(const ElectricalBomView()));
      await tester.pump();

      expect(find.text('Electrical BOM'), findsOneWidget);
      // The bare, ambiguous 'BOM' heading is gone.
      expect(find.text('BOM'), findsNothing);
    });

    test('Bahasa Indonesia string table reads "BOM elektrikal"', () {
      // The rendered widget always resolves EN in isolation (no MechXStrings
      // ancestor — see i18n_test.dart), so the ID table is checked directly,
      // matching that file's own convention.
      const id = MechXStringsData(AppLocale.id);
      expect(id(StringKey.commercialBomTitle), 'BOM elektrikal');
      const en = MechXStringsData(AppLocale.en);
      expect(en(StringKey.commercialBomTitle), 'Electrical BOM');
    });
  });

  group('V1 — the Review hub stat grid stays balanced', () {
    testWidgets(
        'all five stat tiles sit on ONE row (no lone trailing tile) at the '
        "hub's content width", (tester) async {
      setDesktopSurface(tester);
      final plan = [
        const PipeCutGroup(
          service: ServiceType.coldWater,
          diameterMm: 20,
          stockLengthM: 4.0,
          plan: StockCutPlan(
            stockLengthM: 4.0,
            fullBars: 2,
            packedBars: [],
            requiredM: 7.5,
          ),
        ),
      ];
      await tester.pumpWidget(_themed(
        const ReviewHub(),
        overrides: [pipeCutPlanProvider.overrideWithValue(plan)],
      ));
      await tester.pump();

      // The cut-plan trio joined the grid — five tiles total.
      for (final label in const [
        'Panels sized',
        'BOM line items',
        'Stock pipes',
        'Pipe required',
        'Offcut waste',
      ]) {
        expect(find.text(label), findsOneWidget, reason: 'missing tile "$label"');
      }

      // Every tile's label sits at the SAME y — one row, not a wrapped 4+1.
      final ys = [
        for (final label in const [
          'Panels sized',
          'BOM line items',
          'Stock pipes',
          'Pipe required',
          'Offcut waste',
        ])
          tester.getTopLeft(find.text(label)).dy,
      ];
      for (final y in ys.skip(1)) {
        expect(y, closeTo(ys.first, 0.5));
      }
    });
  });

  group('V2 — duplicate design-issue rows collapse', () {
    Widget hostIssues(List<DesignIssue> issues) => _themed(
          const Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 420, child: IssuesCard()),
          ),
          overrides: [designIssuesProvider.overrideWithValue(issues)],
        );

    testWidgets(
        'N near-identical warnings (same kind class + title) fold into ONE '
        'row with a live xN count and a per-instance Locate action',
        (tester) async {
      setDesktopSurface(tester);
      const issues = [
        DesignIssue(
          severity: IssueSeverity.warning,
          kind: 'sheet-uncalibrated:s1',
          title: 'Sheet not calibrated',
          message: '"Ground Floor" has no scale set.',
          locate: IssueLocation('s1'),
        ),
        DesignIssue(
          severity: IssueSeverity.warning,
          kind: 'sheet-uncalibrated:s2',
          title: 'Sheet not calibrated',
          message: '"First Floor" has no scale set.',
          locate: IssueLocation('s2'),
        ),
        DesignIssue(
          severity: IssueSeverity.warning,
          kind: 'sheet-uncalibrated:s3',
          title: 'Sheet not calibrated',
          message: '"Roof Plan" has no scale set.',
          locate: IssueLocation('s3'),
        ),
      ];
      await tester.pumpWidget(hostIssues(issues));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(IssuesCard)),
        listen: false,
      );
      // Sheet names, so the per-instance Locate label can name the sheet.
      container.read(sheetsControllerProvider.notifier).loadSheets(const [
        Sheet(id: 's1', name: 'Ground Floor'),
        Sheet(id: 's2', name: 'First Floor'),
        Sheet(id: 's3', name: 'Roof Plan'),
      ]);
      await tester.pump();

      // ONE row: the bare title is gone, replaced by the counted one.
      expect(find.text('Sheet not calibrated'), findsNothing);
      expect(find.text('Sheet not calibrated x3'), findsOneWidget);
      // Body = the FIRST member's message only (not repeated three times).
      expect(find.text('"Ground Floor" has no scale set.'), findsOneWidget);
      expect(find.text('"First Floor" has no scale set.'), findsNothing);
      expect(find.text('"Roof Plan" has no scale set.'), findsNothing);
      // Every instance still gets its own reachable action, side by side —
      // the sheet name distinguishes each from the others.
      expect(find.text('Ground Floor'), findsOneWidget);
      expect(find.text('First Floor'), findsOneWidget);
      expect(find.text('Roof Plan'), findsOneWidget);
    });

    testWidgets('a singleton group renders exactly as a plain row (unchanged)',
        (tester) async {
      setDesktopSurface(tester);
      const issue = DesignIssue(
        severity: IssueSeverity.warning,
        kind: 'duct-over-capacity',
        title: 'Duct over capacity',
        message: 'A duct clamped to its largest standard size.',
        locate: IssueLocation('s1', edgeId: 'e1'),
      );
      await tester.pumpWidget(hostIssues(const [issue]));
      await tester.pumpAndSettle();

      expect(find.text('Duct over capacity'), findsOneWidget);
      // No count suffix for a group of one.
      expect(find.text('Duct over capacity x1'), findsNothing);
      expect(find.text('Locate'), findsOneWidget);
    });
  });

  group('P1 — Projects export groups name their inventory', () {
    testWidgets(
        'each group header carries a (N) count matching its real action list',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(_themed(const ProjectsScreen()));
      await tester.pump();

      // MechXSectionLabel renders UPPERCASE. Drawings=3, Reports=2, Data=2 —
      // matching the buttons those disclosures actually hold.
      expect(find.text('DRAWINGS (3)'), findsOneWidget);
      expect(find.text('REPORTS (2)'), findsOneWidget);
      expect(find.text('DATA (2)'), findsOneWidget);
    });
  });

  group('PR1 — the software-update caption gets its own home', () {
    testWidgets(
        'a labelled section + card, not a floating caption between cards',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(_themed(const PreferencesScreen()));
      await tester.pump();

      // Its own section label (uppercase, matching the page's other sections).
      expect(find.text('SOFTWARE UPDATE'), findsOneWidget);
      // The now-redundant 'Software update — ' prefix is gone from the body.
      expect(find.textContaining('Software update — '), findsNothing);
      // In this (non-release) test build the updater is disabled with a
      // fixed, unprefixed reason string.
      expect(find.text('Auto-update runs in the installed app.'),
          findsOneWidget);
    });
  });
}
