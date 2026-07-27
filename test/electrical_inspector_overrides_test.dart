import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/ui/electrical/electrical_inspector.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/enclosure.dart';
import 'package:mechx_engine/electrical/geo_length.dart'
    show CircuitLengthSource, LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

/// The circuit / panel inspector RESULT blocks, the manual-override idiom
/// (`(set)` + Clear), the phase-pin picker, the layout-derived (read-only) run
/// length, and the panel's feed-from chooser / template action.
///
/// The through-line of every test here is HONESTY BY DATA-GATING: each of these
/// surfaces renders only from figures the host actually resolved, so an
/// inspector whose host wires nothing is exactly the form it was before.
void main() {
  // ── Fixtures ───────────────────────────────────────────────────────────────

  /// A three-phase board with one 1-phase socket way and one 3-phase motor way.
  ElectricalProject buildProject({
    Current? breakerOverrideA,
    double? cableOverrideMm2,
    int? groupingCountOverride,
    LayoutPos? loadPos,
  }) =>
      ElectricalProject(
        id: 'p',
        name: 'B',
        panels: [
          ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            circuits: [
              ElectricalCircuit(
                id: 'c1',
                name: 'Stop kontak lantai 1',
                loadKind: LoadKind.socket,
                loadW: 2200,
                cableType: 'NYY',
                length: const Length(24),
                breakerOverrideA: breakerOverrideA,
                cableOverrideMm2: cableOverrideMm2,
                groupingCountOverride: groupingCountOverride,
                loadPos: loadPos,
              ),
              const ElectricalCircuit(
                id: 'c2',
                name: 'Pompa',
                loadKind: LoadKind.motor,
                motorKw: 11,
                phases: 3,
                length: Length(18),
              ),
            ],
          ),
        ],
      );

  /// Pumps [child] under the app's own theme/locale-free scaffolding — the same
  /// standalone-inspector harness `electrical_starter_picker_test.dart` uses.
  Future<void> pump(
    WidgetTester tester,
    ProviderContainer container,
    Widget child,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: const MediaQueryData(),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 340, height: 800, child: child),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Scroll a control into the inspector's viewport before driving it — the
  /// inspector is a tall scrolling column, so a control below the fold is real
  /// but un-tappable.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pump();
  }

  ({
    ElectricalProjectController controller,
    ElectricalPanel panel,
    ElectricalSystemResult result,
  }) seed(ProviderContainer container, ElectricalProject project) {
    final controller = container.read(electricalProjectProvider.notifier);
    controller.setProject(project);
    final live = container.read(electricalProjectProvider);
    return (
      controller: controller,
      panel: live.panels.first,
      result: computeSystem(const PuilProfile(), live),
    );
  }

  // ── TASK A — the circuit inspector ─────────────────────────────────────────

  testWidgets('circuit result block prints the solved Ib / cable / phase / '
      'length basis when the host resolves them', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());
    final circuitResult =
        s.result.panels['MDP']!.circuits.firstWhere((c) => c.circuitId == 'c1');

    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: s.panel,
        circuit: s.panel.circuits.first,
        controller: s.controller,
        onClose: () {},
        inline: true,
        circuitResult: circuitResult,
        lengthSource: CircuitLengthSource.geo,
        effectiveLength: const Length(18.4),
      ),
    );

    // The block heading + every row the host could resolve.
    expect(find.text('RESULT'), findsOneWidget);
    expect(find.text('Ib'), findsOneWidget);
    expect(find.text('Cable'), findsOneWidget);
    expect(find.text('Vdrop'), findsOneWidget);
    expect(find.text('Phase'), findsOneWidget);
    // Cable notation matches the board schedule's PENGHANTAR cell (ASCII mm2).
    expect(find.textContaining('NYY 3x'), findsOneWidget);
    expect(find.textContaining('mm2'), findsWidgets);
    // The R/S/T drafting letter, not the IEC L1/L2/L3.
    expect(find.text(phaseLetterFor(circuitResult.phase)), findsWidgets);
    // The effective length names its BASIS, so a geo run can't read as typed.
    expect(find.text('18.4 m — from layout'), findsOneWidget);
  });

  testWidgets('a manual length is labelled manual, not "from layout"',
      (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());

    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: s.panel,
        circuit: s.panel.circuits.first,
        controller: s.controller,
        onClose: () {},
        inline: true,
        lengthSource: CircuitLengthSource.manual,
        effectiveLength: const Length(24),
      ),
    );

    expect(find.text('24 m — manual'), findsOneWidget);
  });

  testWidgets('with no host-resolved result the circuit inspector renders '
      'exactly its previous form (no result / placement rows)', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());

    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: s.panel,
        circuit: s.panel.circuits.first,
        controller: s.controller,
        onClose: () {},
        inline: true,
      ),
    );

    expect(find.text('RESULT'), findsNothing);
    expect(find.text('Ib'), findsNothing);
    expect(find.text('Placement'), findsNothing);
    expect(find.textContaining('— from layout'), findsNothing);
  });

  testWidgets('run length is READ-ONLY (greyed + hint) when it comes from the '
      'layout', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());

    // Manual basis: the field is a real editable input.
    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: s.panel,
        circuit: s.panel.circuits.first,
        controller: s.controller,
        onClose: () {},
        inline: true,
        lengthSource: CircuitLengthSource.manual,
      ),
    );
    final lengthField = find.byKey(const ValueKey('circuit-run-length'));
    expect(
      find.descendant(of: lengthField, matching: find.byType(EditableText)),
      findsOneWidget,
    );
    expect(find.text('From layout — remove from layout to edit'), findsNothing);

    // Geo basis: same field, no editor — and the figure in force is still shown.
    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: s.panel,
        circuit: s.panel.circuits.first,
        controller: s.controller,
        onClose: () {},
        inline: true,
        lengthSource: CircuitLengthSource.geo,
        effectiveLength: const Length(18.4),
      ),
    );
    expect(
      find.descendant(of: lengthField, matching: find.byType(EditableText)),
      findsNothing,
    );
    expect(
      find.descendant(of: lengthField, matching: find.text('18.4')),
      findsOneWidget,
    );
    expect(
        find.text('From layout — remove from layout to edit'), findsOneWidget);
  });

  testWidgets('placement row names where the load sits and offers un-placing',
      (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var unplaced = 0;
    final s = seed(
      container,
      buildProject(
        loadPos: const LayoutPos(sheetId: 's1', floorIndex: 1, x: 10, y: 20),
      ),
    );

    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: s.panel,
        circuit: s.panel.circuits.first,
        controller: s.controller,
        onClose: () {},
        inline: true,
        placementLabel: 'Level 2 · Denah lantai 2',
        onUnplace: () => unplaced++,
      ),
    );

    expect(find.text('Placed — Level 2 · Denah lantai 2'), findsOneWidget);
    await tester.tap(find.text('Remove from layout'));
    await tester.pump();
    expect(unplaced, 1);
  });

  testWidgets('an unplaced load says so instead of showing a dead action',
      (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());

    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: s.panel,
        circuit: s.panel.circuits.first,
        controller: s.controller,
        onClose: () {},
        inline: true,
        onUnplace: () {},
      ),
    );

    expect(find.text('Not placed — drag it from the Layout tray'),
        findsOneWidget);
    expect(find.text('Remove from layout'), findsNothing);
  });

  testWidgets('a breaker override is marked (set) and Clear hands sizing back '
      'to the engine', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(
      container,
      buildProject(breakerOverrideA: const Current(32)),
    );

    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: s.panel,
        circuit: s.panel.circuits.first,
        controller: s.controller,
        onClose: () {},
        inline: true,
      ),
    );
    await tapVisible(tester, find.text('ADVANCED'));
    await tester.pumpAndSettle();

    // The '(set)' marker distinguishes a hand-forced device from a sized one;
    // the two untouched overrides stay bare.
    expect(find.text('Breaker override (A) (set)'), findsOneWidget);
    expect(find.text('Min cable (mm2)'), findsOneWidget);
    expect(find.text('Grouping count'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);

    await tapVisible(tester, find.text('Clear'));

    final updated =
        container.read(electricalProjectProvider).panels.first.circuits.first;
    expect(updated.breakerOverrideA, isNull);
    // Clearing one override must not disturb the others.
    expect(updated.cableOverrideMm2, isNull);
    expect(updated.length, const Length(24));
  });

  testWidgets('typing a cable / grouping override writes it through setCircuit',
      (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());

    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: s.panel,
        circuit: s.panel.circuits.first,
        controller: s.controller,
        onClose: () {},
        inline: true,
      ),
    );
    await tapVisible(tester, find.text('ADVANCED'));
    await tester.pumpAndSettle();

    // Commit-on-blur: type, then submit (Enter) — one undo step, no per-key
    // intermediate value.
    final cableField = find.descendant(
      of: find.byKey(const ValueKey('circuit-cable-override')),
      matching: find.byType(EditableText),
    );
    await tester.ensureVisible(cableField);
    await tester.pumpAndSettle();
    await tester.enterText(cableField, '16');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    final groupingField = find.descendant(
      of: find.byKey(const ValueKey('circuit-grouping-override')),
      matching: find.byType(EditableText),
    );
    await tester.ensureVisible(groupingField);
    await tester.pumpAndSettle();
    await tester.enterText(groupingField, '4');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    final updated =
        container.read(electricalProjectProvider).panels.first.circuits.first;
    expect(updated.cableOverrideMm2, 16);
    expect(updated.groupingCountOverride, 4);
  });

  testWidgets('phase pin writes phaseOverride, and shows only for a 1-phase '
      'way on a 3-phase board', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());
    final solved = s.result.panels['MDP']!;
    final socketResult =
        solved.circuits.firstWhere((c) => c.circuitId == 'c1');
    final motorResult = solved.circuits.firstWhere((c) => c.circuitId == 'c2');
    expect(socketResult.threePhase, isFalse);
    expect(motorResult.threePhase, isTrue);

    // 1-phase way on a 3-phase board — pin offered.
    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: s.panel,
        circuit: s.panel.circuits.first,
        controller: s.controller,
        onClose: () {},
        inline: true,
        circuitResult: socketResult,
      ),
    );
    expect(find.text('Pin phase'), findsOneWidget);
    await tapVisible(tester, find.text('S'));
    expect(
      container.read(electricalProjectProvider).panels.first.circuits.first
          .phaseOverride,
      PhaseLine.l2,
    );

    // The 3-phase motor way spans every line — nothing to pin.
    final live = container.read(electricalProjectProvider).panels.first;
    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: live,
        circuit: live.circuits[1],
        controller: s.controller,
        onClose: () {},
        inline: true,
        circuitResult: motorResult,
      ),
    );
    expect(find.text('Pin phase'), findsNothing);

    // A single-phase BOARD has no other line either.
    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: live,
        circuit: live.circuits.first,
        controller: s.controller,
        onClose: () {},
        inline: true,
        circuitResult: socketResult,
        panelSystem: ElectricalSystem.singlePhase,
      ),
    );
    expect(find.text('Pin phase'), findsNothing);

    // And with NOTHING solved the phase count is unknown — the pin is not
    // offered on a way that may yet turn out to be three-phase.
    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: live,
        circuit: live.circuits.first,
        controller: s.controller,
        onClose: () {},
        inline: true,
      ),
    );
    expect(find.text('Pin phase'), findsNothing);
  });

  testWidgets('the kind picker offers power-factor correction (capacitor)',
      (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());

    await pump(
      tester,
      container,
      ElectricalCircuitInspector(
        panel: s.panel,
        circuit: s.panel.circuits.first,
        controller: s.controller,
        onClose: () {},
        inline: true,
      ),
    );

    final label = loadDefaults[LoadKind.capacitor]!.label;
    expect(find.text(label), findsOneWidget);
    await tester.tap(find.text(label));
    await tester.pump();
    expect(
      container
          .read(electricalProjectProvider)
          .panels
          .first
          .circuits
          .first
          .loadKind,
      LoadKind.capacitor,
    );
  });

  // ── TASK B — the panel inspector ───────────────────────────────────────────

  testWidgets('panel result block prints demand / incomer / busbar / sections '
      '/ imbalance / enclosure', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());

    await pump(
      tester,
      container,
      ElectricalPanelInspector(
        panel: s.panel,
        controller: s.controller,
        onClose: () {},
        inline: true,
        panelResult: s.result.panels['MDP'],
        enclosureResult: const EnclosureResult(
          widthMm: 600,
          heightMm: 800,
          depthMm: 250,
          sheetMm: 1.5,
          modules: 24,
          rows: 2,
          ventilation: Ventilation.fanFilter,
          tempRiseK: 12,
          withinTempLimit: true,
          ip: 'IP54',
          verifyItems: [],
        ),
      ),
    );

    expect(find.text('RESULT'), findsOneWidget);
    expect(find.text('Demand'), findsOneWidget);
    expect(find.text('Incomer'), findsOneWidget);
    expect(find.text('Busbar'), findsOneWidget);
    expect(find.text('Sections'), findsOneWidget);
    expect(find.text('Imbalance'), findsOneWidget);
    // ASCII 'x', the plural helper (never "row(s)"), and the ventilation word.
    expect(find.text('600x800x250 mm · 24M/2 rows · fan-filter'), findsOneWidget);
  });

  testWidgets('with no host-resolved result the panel inspector renders '
      'exactly its previous form (no result / fed-from rows)', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());

    await pump(
      tester,
      container,
      ElectricalPanelInspector(
        panel: s.panel,
        controller: s.controller,
        onClose: () {},
        inline: true,
      ),
    );

    expect(find.text('RESULT'), findsNothing);
    expect(find.text('Fed from'), findsNothing);
    expect(find.text('Feed from…'), findsNothing);
    expect(find.text('Pin phases'), findsNothing);
    expect(find.text('Apply template…'), findsNothing);
  });

  testWidgets('feed-from chooser lists the candidates, marks the current '
      'parent inert, and fires onFeedFrom', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());
    final picked = <String>[];

    await pump(
      tester,
      container,
      ElectricalPanelInspector(
        panel: s.panel,
        controller: s.controller,
        onClose: () {},
        inline: true,
        fedFromLabel: 'LVMDP',
        feedCandidates: const [
          (id: 'lv', label: 'LVMDP'),
          (id: 'sdp', label: 'SDP-2'),
        ],
        onFeedFrom: picked.add,
      ),
    );

    // Closed at rest: the row states the parent, the candidates stay hidden.
    expect(find.text('LVMDP'), findsOneWidget);
    expect(find.text('SDP-2'), findsNothing);

    await tester.tap(find.text('Feed from…'));
    await tester.pumpAndSettle();

    // The current parent is marked and inert; the alternative is pickable.
    expect(find.text('LVMDP (current)'), findsOneWidget);
    expect(find.text('SDP-2'), findsOneWidget);
    await tester.tap(find.text('LVMDP (current)'));
    await tester.pump();
    expect(picked, isEmpty);

    await tester.tap(find.text('SDP-2'));
    await tester.pumpAndSettle();
    expect(picked, ['sdp']);
    // Picking closes the chooser again.
    expect(find.text('LVMDP (current)'), findsNothing);
  });

  testWidgets('disconnect is offered only while the board is actually fed',
      (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());

    // Utility-fed board: no feeder to drop.
    await pump(
      tester,
      container,
      ElectricalPanelInspector(
        panel: s.panel,
        controller: s.controller,
        onClose: () {},
        inline: true,
        onDisconnectFeeder: () {},
      ),
    );
    expect(find.text('Utility supply'), findsOneWidget);
    expect(find.text('Disconnect feeder'), findsNothing);

    // Same board once it carries an incoming feeder.
    var disconnected = 0;
    await pump(
      tester,
      container,
      ElectricalPanelInspector(
        panel: s.panel.copyWith(fedByCircuitId: 'f1'),
        controller: s.controller,
        onClose: () {},
        inline: true,
        fedFromLabel: 'LVMDP',
        onDisconnectFeeder: () => disconnected++,
      ),
    );
    await tester.tap(find.text('Disconnect feeder'));
    await tester.pump();
    expect(disconnected, 1);
  });

  testWidgets('apply-template is offered only on an EMPTY board; pin-phases '
      'always explains itself', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());
    var templates = 0;
    var pins = 0;

    // Populated board — a template would duplicate real design work.
    await pump(
      tester,
      container,
      ElectricalPanelInspector(
        panel: s.panel,
        controller: s.controller,
        onClose: () {},
        inline: true,
        onApplyTemplate: () => templates++,
        onPinPhases: () => pins++,
      ),
    );
    expect(find.text('Apply template…'), findsNothing);
    expect(find.text('Pin phases'), findsOneWidget);
    expect(find.text('Fix every way to its current R/S/T line'), findsOneWidget);
    await tester.tap(find.text('Pin phases'));
    await tester.pump();
    expect(pins, 1);

    // Empty board — the preset is the fastest honest way to start.
    await pump(
      tester,
      container,
      ElectricalPanelInspector(
        panel: s.panel.copyWith(circuits: const []),
        controller: s.controller,
        onClose: () {},
        inline: true,
        onApplyTemplate: () => templates++,
      ),
    );
    expect(find.text('Apply template…'), findsOneWidget);
    await tester.tap(find.text('Apply template…'));
    await tester.pump();
    expect(templates, 1);
  });

  // ── TASK B — the context menus ─────────────────────────────────────────────

  testWidgets('the circuit menu offers "Remove from layout" only when placed',
      (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());
    var unplaced = 0;

    await pump(
      tester,
      container,
      ElectricalCircuitMenu(
        target: const ElectricalEditTarget('MDP', 'c1'),
        controller: s.controller,
        onEdit: () {},
        onDone: () {},
      ),
    );
    expect(find.text('Remove from layout'), findsNothing);

    await pump(
      tester,
      container,
      ElectricalCircuitMenu(
        target: const ElectricalEditTarget('MDP', 'c1'),
        controller: s.controller,
        onEdit: () {},
        onDone: () {},
        hasLoadPos: true,
        onUnplace: () => unplaced++,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from layout'));
    await tester.pump();
    expect(unplaced, 1);
  });

  testWidgets('the panel menu opens the SAME feeder chooser as the inspector',
      (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());
    final picked = <String>[];

    // Un-wired: byte-identical to the pre-existing menu.
    await pump(
      tester,
      container,
      ElectricalPanelMenu(
        panel: s.panel,
        controller: s.controller,
        onProperties: () {},
        onOpen: () {},
        onDone: () {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Feed from…'), findsNothing);
    expect(find.text('Pin phases'), findsNothing);

    await pump(
      tester,
      container,
      ElectricalPanelMenu(
        panel: s.panel,
        controller: s.controller,
        onProperties: () {},
        onOpen: () {},
        onDone: () {},
        fedFromLabel: 'LVMDP',
        feedCandidates: const [
          (id: 'lv', label: 'LVMDP'),
          (id: 'sdp', label: 'SDP-2'),
        ],
        onFeedFrom: picked.add,
        onPinPhases: () {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pin phases'), findsOneWidget);

    await tester.tap(find.text('Feed from…'));
    await tester.pumpAndSettle();
    // Same rows, same '(current)' marking as the inline chooser.
    expect(find.text('LVMDP (current)'), findsOneWidget);
    await tester.tap(find.text('SDP-2'));
    await tester.pump();
    expect(picked, ['sdp']);
  });
}
