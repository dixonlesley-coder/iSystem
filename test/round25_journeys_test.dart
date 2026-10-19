// Round 25 — the user-journey + whole-building app findings:
//
//   whole-building-2-downfeed-underpressure-silent   a drawn roof tank below
//     the SNI minimum raises a Review warning + a failing compliance row;
//     between the SNI minimum and the comfort target it is an advisory and
//     the row passes (Round 32, binding-1).
//   ui-journeys-4-direct-mains-feed-contradiction   a meter-fed network is an
//     acknowledgeable 'fed from the mains' advisory, and the inspector shows
//     no phantom roof-tank booster.
//   ui-journeys-4-blank-project-pass-ready-to-issue   an empty project can
//     never read PASS.
//   ui-journeys-4-undo-skips-riser-drag-and-acknowledge   acknowledgements
//     are one undo step on the global timeline.
//   ui-journeys-4-electrical-empty-state / submittal-hint   copy matches UI.
//   ui-journeys-4-building-heights-rounded-to-0p1   heights at 2 dp.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/compliance_store.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sample_project.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/shell/building_screen.dart' show trimmedMetres;
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx/ui/strings/app_strings.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('roof-tank downfeed below the target residual is reported', () {
    /// The sample (meter → lavatory → drain) with the meter turned into a
    /// drawn ROOF TANK: a real gravity downfeed.
    ProviderContainer roofTankSample(List<Floor> floors) {
      final c = _c();
      loadSampleLayoutProjectTo(c.read);
      c.read(projectControllerProvider.notifier).setFloors(floors);
      final net = c.read(networkControllerProvider).network;
      c.read(networkControllerProvider.notifier).loadNetwork(Network(
            nodes: [
              for (final n in net.nodes)
                n.component == NodeComponent.waterMeter
                    ? n.copyWith(
                        component: NodeComponent.roofTank,
                        role: NodeRole.plant)
                    : n,
            ],
            edges: net.edges,
          ));
      return c;
    }

    test('the sample floors (roof 11 m) meet the SNI minimum, below the '
        'comfort target: an advisory + a passing row', () {
      // Tank at the roof (4 + 3.5 + 3.5 = 11 m) over a ground lavatory: about
      // 10 m of static head ≈ 98 kPa, below the 225 kPa comfort target but
      // above the SNI 8153 faucet minimum (0.5 kgf/cm² = 49 kPa; no flush
      // valve on the path). Round 32 (binding-1): an acknowledgeable INFO
      // advisory recommending the booster; the 'Supply pressure' row PASSES.
      final c = roofTankSample(kSampleFloors);
      expect(c.read(gravityDownfeedDrawnProvider), isTrue);
      final d = c.read(downfeedDeliveredProvider)!;
      expect(d.gravitySufficient, isFalse);
      expect(d.minResidual.pascals,
          lessThan(c.read(targetResidualProvider).pascals));
      expect(d.minResidual.inKiloPascals, greaterThan(49.03));
      expect(c.read(downfeedSniMinimumResidualProvider)!.inKiloPascals,
          closeTo(49.03, 0.01));
      final issue = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'downfeed-below-target');
      expect(issue.severity, IssueSeverity.info);
      expect(issue.isAcknowledgeable, isTrue);
      expect(issue.message, contains('SNI 8153 minimum of 49 kPa is met'));
      expect(issue.message,
          contains('+${d.boosterHeadRequired.meters.toStringAsFixed(1)} m'));
      final row = c
          .read(complianceSummaryProvider)
          .items
          .firstWhere((i) => i.category == 'Supply pressure');
      expect(row.pass, isTrue);
      expect(row.detail, 'SNI minimum met; below comfort target (advisory)');
    });

    test('a single 4 m storey is below the SNI minimum: a blocking warning',
        () {
      // Tank on the roof of ONE 4 m storey over a ground lavatory: ≈ 3 m of
      // head ≈ 28 kPa < the 49 kPa SNI 8153 faucet minimum.
      final c = roofTankSample(const [Floor('Ground', Length(4.0))]);
      final d = c.read(downfeedDeliveredProvider)!;
      expect(d.minResidual.inKiloPascals, lessThan(49.03));
      final issue = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'downfeed-below-target');
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.message, contains('SNI 8153 minimum of 49 kPa'));
      expect(issue.message,
          contains('+${d.boosterHeadRequired.meters.toStringAsFixed(1)} m'));
      final row = c
          .read(complianceSummaryProvider)
          .items
          .firstWhere((i) => i.category == 'Supply pressure');
      expect(row.pass, isFalse);
      expect(c.read(complianceSummaryProvider).allPass, isFalse);
    });

    test('a tall enough building (roof 88 m) passes the pressure row', () {
      final c = roofTankSample([
        const Floor('Ground', Length(4.0)),
        for (var i = 1; i < 25; i++) Floor('Level $i', const Length(3.5)),
      ]);
      expect(c.read(downfeedDeliveredProvider)!.gravitySufficient, isTrue);
      expect(
          c
              .read(designIssuesProvider)
              .where((i) => i.kind == 'downfeed-below-target'),
          isEmpty);
      final row = c
          .read(complianceSummaryProvider)
          .items
          .firstWhere((i) => i.category == 'Supply pressure');
      expect(row.pass, isTrue);
      expect(row.detail, 'target residual met');
    });
  });

  group('a meter-fed network is fed from the mains', () {
    test('acknowledgeable advisory, never the no-source warning', () {
      final c = _c();
      loadSampleLayoutProjectTo(c.read);
      expect(c.read(feedStrategyProvider), FeedStrategy.downfeed);
      expect(c.read(gravityDownfeedDrawnProvider), isFalse);
      final issues = c.read(designIssuesProvider);
      expect(issues.where((i) => i.kind == 'no-source:coldWater'), isEmpty);
      final mains = issues.firstWhere((i) => i.kind == 'mains-fed:coldWater');
      expect(mains.isAcknowledgeable, isTrue);
      // No phantom roof-tank judgement either.
      expect(issues.where((i) => i.kind == 'downfeed-below-target'), isEmpty);
    });

    testWidgets('the Results inspector shows direct mains, no phantom booster',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      await tester.ensureVisible(find.text('Load plumbing sample'));
      await tester.tap(find.text('Load plumbing sample'));
      await tester.pumpAndSettle();
      expect(find.text('Direct mains: no booster duty', skipOffstage: false),
          findsOneWidget);
      expect(find.text('Downfeed booster', skipOffstage: false), findsNothing);
      expect(find.text('Top residual', skipOffstage: false), findsNothing);
    });
  });

  group('an empty project never reads PASS', () {
    test('a failing Design content row + honest n/a details', () {
      final c = _c();
      final open = c.read(complianceSummaryProvider);
      expect(open.items.first.category, 'Design content');
      expect(open.items.first.pass, isFalse);
      final byCat = {for (final i in open.items) i.category: i};
      expect(byCat['Sheet calibration']!.detail, 'n/a: no sheets');
      expect(byCat['Velocity']!.detail, 'n/a: nothing drawn');
      expect(byCat['Electrical circuit sizing']!.detail, 'n/a: no panels');
      // Acknowledging every advisory still cannot make it PASS.
      final ackable = [
        for (final i in c.read(designIssuesProvider))
          if (i.isAcknowledgeable) i.key,
      ];
      c
          .read(acknowledgedIssuesProvider.notifier)
          .acknowledgeAll(ackable, author: 'LD', date: '2026-10-18');
      expect(c.read(complianceSummaryProvider).allPass, isFalse);
    });

    test('drawing the sample clears the Design content row', () {
      final c = _c();
      loadSampleLayoutProjectTo(c.read);
      final items = c.read(complianceSummaryProvider).items;
      expect(items.where((i) => i.category == 'Design content'), isEmpty);
      expect(
          items.firstWhere((i) => i.category == 'Sheet calibration').detail,
          isNot(startsWith('n/a')));
    });
  });

  group('acknowledgements are one undo step', () {
    test('Ctrl+Z after Acknowledge all un-acknowledges, not an older edit', () {
      final c = _c();
      c.read(projectControllerProvider.notifier)
        ..setName('A')
        ..setName('B');
      final acks = c.read(acknowledgedIssuesProvider.notifier);
      acks.acknowledgeAll(['k1', 'k2', 'k3'], author: 'LD', date: '2026-10-18');
      expect(c.read(acknowledgedIssuesProvider), hasLength(3));
      final history = c.read(historyProvider.notifier);
      history.undo();
      expect(c.read(acknowledgedIssuesProvider), isEmpty);
      expect(c.read(projectControllerProvider).name, 'B');
      history.redo();
      expect(c.read(acknowledgedIssuesProvider), hasLength(3));
      acks.unacknowledge('k2');
      expect(c.read(acknowledgedIssuesProvider).containsKey('k2'), isFalse);
      history.undo();
      expect(c.read(acknowledgedIssuesProvider).containsKey('k2'), isTrue);
      // Withdrawing a key that is not acknowledged records nothing: the next
      // undo still reverts the Acknowledge all.
      acks.unacknowledge('nope');
      history.undo();
      expect(c.read(acknowledgedIssuesProvider), isEmpty);
      expect(c.read(projectControllerProvider).name, 'B');
    });
  });

  group('copy matches the UI', () {
    test('the electrical empty state names the Supply button', () {
      for (final locale in AppLocale.values) {
        final s = MechXStringsData(locale);
        final body = s.format(StringKey.electricalEmptyBody,
            {'supply': s(StringKey.electricalSupply)});
        expect(body, contains(s(StringKey.electricalSupply)));
        expect(body, isNot(contains('Service & Earthing')));
        expect(body, isNot(contains('Sambungan & Pembumian')));
        expect(body, isNot(contains('{supply}')));
      }
    });

    test('the submittal hint says every sheet; ID uses paket submittal', () {
      const en = MechXStringsData(AppLocale.en);
      expect(en(StringKey.reviewSubmittalHint), contains("every sheet's"));
      expect(en(StringKey.reviewSubmittalHint), isNot(contains('current')));
      const id = MechXStringsData(AppLocale.id);
      expect(id(StringKey.reviewSubmittalHint), contains('Paket submittal'));
      expect(id(StringKey.reviewSubmittalHint), isNot(contains('serah')));
      expect(id(StringKey.reviewExportSubmittalPackage),
          contains('paket submittal'));
    });
  });

  group('Building heights print at 2 dp', () {
    test('trimmedMetres keeps centimetres, trims one trailing zero', () {
      expect(trimmedMetres(3.25), '3.25');
      expect(trimmedMetres(3.5), '3.5');
      expect(trimmedMetres(3.0), '3.0');
      expect(trimmedMetres(13.75), '13.75');
    });

    testWidgets('a 3.25 m storey reads 3.25 and the level above elev +7.25',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final c = ProviderScope.containerOf(
          tester.element(find.byType(MechXApp)),
          listen: false);
      c.read(projectControllerProvider.notifier)
        ..setFloors(const [
          Floor('Ground', Length(4.0)),
          Floor('Level 1', Length(3.5)),
          Floor('Level 2', Length(3.5)),
        ])
        ..setFloorHeight(1, const Length(3.25));
      await tester.pump();
      await tester.tap(find.descendant(
          of: find.byType(NavRail), matching: find.text('Building')));
      await tester.pumpAndSettle();
      // Level 2 sits at 4.0 + 3.25 = 7.25 m (FFL +7.25 on the drawings).
      expect(find.text('elev +7.25 m', skipOffstage: false), findsOneWidget);
      expect(find.text('3.25 m', skipOffstage: false), findsOneWidget);
      // Total 4.0 + 3.25 + 3.5 = 10.75 m.
      expect(find.text('10.75 m', skipOffstage: false), findsWidgets);
    });
  });
}
