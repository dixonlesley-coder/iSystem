import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/canvas/segment_palette.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/palette_card.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';

/// F5 — an untyped plumbing fixture is sized on a representative PLACEHOLDER
/// (2.0 UBAP on the supply side, 2.0 DFU on the sanitary side) and used to say
/// so nowhere. These cover the two halves of the fix: the honesty advisory, and
/// the per-fixture palette cards that let the engineer place a typed fixture in
/// the first place. Plus G4 — the motor-frame findings are advisories, not
/// permanent compliance blockers.
Widget _paletteHost(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(400, 3000)),
          child: MechXTheme(
            data: MechXThemeData.dark,
            // Draggable palette cards need an Overlay ancestor for drag feedback.
            child: Overlay(initialEntries: [
              OverlayEntry(
                builder: (_) => Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 340,
                    height: 3000,
                    child: SingleChildScrollView(child: const SegmentPalette()),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );

Network _fixtureOn(ServiceType service, {PlumbingFixture? fixture}) => Network(
      nodes: [
        NetNode(
          id: 'f',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture,
          fixture: fixture,
        ),
        const NetNode(id: 'j', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
      ],
      edges: [
        NetEdge(id: 'e', fromId: 'f', toId: 'j', service: service),
      ],
    );

List<DesignIssue> _untyped(ProviderContainer c) => c
    .read(designIssuesProvider)
    .where((i) => i.kind.startsWith('fixture-untyped:'))
    .toList();

void main() {
  group('F5 · untyped-fixture advisory', () {
    test('a cold-water fixture with no type names the 2.0 UBAP placeholder',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(_fixtureOn(ServiceType.coldWater));

      final issues = _untyped(c);
      expect(issues.length, 1);
      final i = issues.single;
      expect(i.severity, IssueSeverity.info, reason: 'honesty advisory');
      expect(i.isAcknowledgeable, isTrue);
      expect(i.kind, 'fixture-untyped:f');
      expect(i.message, contains('2.0 UBAP'));
      // Locatable to the node itself, so Review can jump to it.
      expect(i.locate!.nodeId, 'f');
      expect(i.locate!.sheetId, 's1');
    });

    test('a drainage-only fixture names the 2.0 DFU placeholder instead', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(_fixtureOn(ServiceType.drainage));

      final i = _untyped(c).single;
      expect(i.message, contains('2.0 DFU'));
      expect(i.message, isNot(contains('UBAP')));
    });

    test('a TYPED fixture raises nothing', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      c.read(networkControllerProvider.notifier).loadNetwork(
          _fixtureOn(ServiceType.coldWater,
              fixture: PlumbingFixture.lavatory));

      expect(_untyped(c), isEmpty);
    });

    test('a custom-library fixture id also counts as typed', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      c.read(networkControllerProvider.notifier).loadNetwork(const Network(
            nodes: [
              NetNode(
                id: 'f',
                sheetId: 's1',
                x: 0,
                y: 0,
                floorIndex: 0,
                role: NodeRole.fixture,
                customFixtureId: 'cf1',
              ),
              NetNode(id: 'j', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
            ],
            edges: [
              NetEdge(
                  id: 'e',
                  fromId: 'f',
                  toId: 'j',
                  service: ServiceType.coldWater),
            ],
          ));

      expect(_untyped(c), isEmpty);
    });

    test('an AIR terminal is NOT a plumbing fixture (no placeholder applies)',
        () {
      // A supply diffuser is a fixture-ROLE node too, but the air path sizes
      // from its airflow, not from a fixture-unit placeholder — the air side
      // already has its own `air-terminal-unsized` advisory.
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(_fixtureOn(ServiceType.duct));

      expect(_untyped(c), isEmpty);
    });

    test('a fire-service head is not fixture-unit sized either', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(_fixtureOn(ServiceType.fireSprinkler));

      expect(_untyped(c), isEmpty);
    });

    test('one row per untyped fixture, each individually acknowledgeable', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      c.read(networkControllerProvider.notifier).loadNetwork(const Network(
            nodes: [
              NetNode(
                  id: 'a',
                  sheetId: 's1',
                  x: 0,
                  y: 0,
                  floorIndex: 0,
                  role: NodeRole.fixture),
              NetNode(
                  id: 'b',
                  sheetId: 's1',
                  x: 50,
                  y: 0,
                  floorIndex: 0,
                  role: NodeRole.fixture),
              NetNode(id: 'j', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
            ],
            edges: [
              NetEdge(
                  id: 'e1',
                  fromId: 'a',
                  toId: 'j',
                  service: ServiceType.coldWater),
              NetEdge(
                  id: 'e2',
                  fromId: 'b',
                  toId: 'j',
                  service: ServiceType.coldWater),
            ],
          ));

      final issues = _untyped(c);
      expect(issues.length, 2);
      // Distinct keys ⇒ acknowledging one never hides the other.
      expect(issues.map((i) => i.key).toSet().length, 2);
    });
  });

  group('F5 · per-fixture palette cards', () {
    testWidgets('the Fixtures group offers the whole engine fixture set',
        (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(_paletteHost(c));
      await tester.pump();

      expect(find.text('FIXTURES'), findsOneWidget);
      for (final label in const [
        'WC · tank',
        'WC · valve',
        'Lavatory',
        'Shower',
        'Kitchen sink',
        'Urinal',
        'Bathtub',
        'Hose bibb',
      ]) {
        expect(find.text(label), findsOneWidget, reason: 'card "$label"');
      }
      // The generic untyped Terminal card stays — a placement with no type is
      // still legal (it is only advised in Review).
      expect(find.text('Terminal'), findsOneWidget);
    });

    testWidgets('the group follows the plumbing layer on both regimes',
        (tester) async {
      // Drainage (gravity) is a fixture placement too — a fixture carries both
      // its supply units and its drainage units.
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c
          .read(networkControllerProvider.notifier)
          .setService(ServiceType.drainage);
      await tester.pumpWidget(_paletteHost(c));
      await tester.pump();
      expect(find.text('FIXTURES'), findsOneWidget);
    });

    testWidgets('a keyboard-activated fixture card drops a TYPED terminal',
        (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      await tester.pumpWidget(_paletteHost(c));
      await tester.pump();

      // Focus the card and press Enter — the same store add-action a drag drop
      // takes (minus the merge/snap): it must land already carrying its type.
      final card = find.ancestor(
        of: find.text('Lavatory'),
        matching: find.byType(PaletteCard<PaletteItem>),
      );
      expect(card, findsOneWidget);
      Focus.of(tester.element(
              find.descendant(of: card, matching: find.byType(Text)).first))
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      final net = c.read(networkControllerProvider).network;
      final placed =
          net.nodes.where((n) => n.role == NodeRole.fixture).toList();
      expect(placed.length, 1);
      expect(placed.single.fixture, PlumbingFixture.lavatory);
      // …and so it raises no untyped advisory.
      expect(_untyped(c), isEmpty);
    });
  });

  group('G4 · the motor-frame findings are advisories, not blockers', () {
    // A duty past the top of the standard ladder is a real, honest finding —
    // but not a defect the app can be made to clear (no custom-motor field
    // exists, and a legitimately large building simply has one). As a WARNING
    // it was a permanent, unacknowledgeable compliance blocker.
    ProviderContainer withOversizedPump() {
      final c = ProviderContainer(overrides: [
        pumpDutyProvider.overrideWithValue(const PumpDuty(
          flow: FlowRate(0.05),
          head: Head(120),
          hydraulicPower: Power(58000),
          shaftPower: Power(90000), // past the 75 kW top frame
          motorInputPower: Power(95000),
          selectedMotor: Power(75000), // CLAMPED
          motorOversized: true,
        )),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('pump-motor-oversized is info-severity and acknowledgeable', () {
      final c = withOversizedPump();
      final issue = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'pump-motor-oversized');
      expect(issue.severity, IssueSeverity.info);
      expect(issue.isAcknowledgeable, isTrue,
          reason: 'a PASS must be reachable on a legitimately large building');
      // The copy points at where the figure actually lives.
      expect(issue.message, contains('Results'));
      expect(issue.message, isNot(contains('Specify a custom motor')));
    });

    test('a clean project raises neither motor finding', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final kinds = c.read(designIssuesProvider).map((i) => i.kind).toSet();
      expect(kinds.contains('pump-motor-oversized'), isFalse);
      expect(kinds.contains('fan-motor-oversized'), isFalse);
    });
  });
}
