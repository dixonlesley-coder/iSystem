import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/ui/electrical/electrical_inspector.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

/// The W6 in-place editing pages of the shared right-click menus: the circuit
/// menu's Breaker / Cable / Phase / Family value LADDERS and the panel menu's
/// System chooser — each one tap deep (the "Feed from…" paging idiom), writing
/// through the store's `setCircuit` override fields (one undo step each), with
/// every ladder value sourced from the engine's own PUIL profile tables.
void main() {
  const profile = PuilProfile();

  /// A three-phase board with one 1-phase socket way and one 3-phase motor way
  /// (the same fixture shape as `electrical_inspector_overrides_test.dart`).
  ElectricalProject buildProject() => const ElectricalProject(
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
                length: Length(24),
              ),
              ElectricalCircuit(
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
      result: computeSystem(profile, live),
    );
  }

  /// The live model row / solved result for a way, straight from the store —
  /// what a HOST would resolve before mounting the menu.
  ElectricalCircuit circuitOf(ProviderContainer c, String id) => c
      .read(electricalProjectProvider)
      .panels
      .first
      .circuits
      .firstWhere((x) => x.id == id);

  ElectricalCircuitResult resultOf(ElectricalSystemResult r, String id) =>
      r.panels['MDP']!.circuits.firstWhere((x) => x.circuitId == id);

  Future<void> pumpCircuitMenu(
    WidgetTester tester,
    ProviderContainer container,
    ElectricalProjectController controller, {
    required String circuitId,
    ElectricalCircuitResult? circuitResult,
    ElectricalSystem? panelSystem = ElectricalSystem.threePhase,
  }) =>
      pump(
        tester,
        container,
        // A fresh key per pump: in the app every pick closes the menu via
        // onDone (state resets); here the menu stays mounted, so remount to
        // land back on the root page.
        ElectricalCircuitMenu(
          key: UniqueKey(),
          target: ElectricalEditTarget('MDP', circuitId),
          controller: controller,
          circuit: circuitOf(container, circuitId),
          circuitResult: circuitResult,
          panelSystem: panelSystem,
          onEdit: () {},
          onDone: () {},
        ),
      );

  // ── Breaker ladder ─────────────────────────────────────────────────────────

  testWidgets('breaker ladder: engine-sourced rungs, pick writes the override '
      'in ONE undo step, Auto clears it, "(set)" marks it', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());
    final r1 = resultOf(s.result, 'c1');

    await pumpCircuitMenu(tester, container, s.controller,
        circuitId: 'c1', circuitResult: r1);

    // The root row leads with the engine-sized rating (no override yet).
    final sized = r1.breaker.ratingA.amperes;
    final sizedLabel =
        '${profile.breakerClassFor(sized) == BreakerClass.mcb ? 'MCB' : 'MCCB'} '
        '${sized.round()}A';
    expect(find.text('Breaker · $sizedLabel'), findsOneWidget);

    await tester.tap(find.text('Breaker · $sizedLabel'));
    await tester.pumpAndSettle();

    // The ladder page: Auto first (current), then the PROFILE's own ladder —
    // sentinel rungs pulled FROM the profile tables, not literals.
    expect(find.text('Auto (sized)'), findsOneWidget);
    expect(
        find.text('MCB ${profile.mcbRatingsA.last.round()}A'), findsOneWidget);
    expect(find.text('MCCB ${profile.mccbRatingsA.first.round()}A'),
        findsOneWidget);

    await tester.tap(find.text('MCB 25A'));
    await tester.pump();
    expect(circuitOf(container, 'c1').breakerOverrideA?.amperes, 25);

    // ONE undo step reverts the pick.
    container.read(historyProvider.notifier).undo();
    expect(circuitOf(container, 'c1').breakerOverrideA, isNull);

    // Re-apply, then the root row carries the '(set)' override mark.
    s.controller.setCircuit('MDP', 'c1', breakerOverrideA: const Current(25));
    await pumpCircuitMenu(tester, container, s.controller,
        circuitId: 'c1', circuitResult: r1);
    expect(find.text('Breaker · MCB 25A (set)'), findsOneWidget);

    // 'Auto (sized)' hands the device back to the sizer.
    await tester.tap(find.text('Breaker · MCB 25A (set)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto (sized)'));
    await tester.pump();
    expect(circuitOf(container, 'c1').breakerOverrideA, isNull);
  });

  // ── Cable ladder ───────────────────────────────────────────────────────────

  testWidgets('cable ladder: the profile CSA ladder as a labelled MINIMUM, '
      'pick writes cableOverrideMm2, Auto clears', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());
    final r1 = resultOf(s.result, 'c1');

    await pumpCircuitMenu(tester, container, s.controller,
        circuitId: 'c1', circuitResult: r1);

    await tester.tap(find.textContaining('Cable · '));
    await tester.pumpAndSettle();

    // The floor semantics are stated on the page, and the rungs are the
    // profile's own standard sections (1.5 first, 300 last).
    expect(find.text('Minimum section - auto-sizing may pick larger.'),
        findsOneWidget);
    expect(find.text('1.5 mm2'), findsOneWidget);
    expect(find.text('${profile.standardSectionsMm2.last.round()} mm2'),
        findsOneWidget);

    await tester.tap(find.text('4 mm2'));
    await tester.pump();
    expect(circuitOf(container, 'c1').cableOverrideMm2, 4);

    await pumpCircuitMenu(tester, container, s.controller,
        circuitId: 'c1', circuitResult: r1);
    expect(find.text('Cable · 4 mm2 (set)'), findsOneWidget);
    await tester.tap(find.text('Cable · 4 mm2 (set)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto (sized)'));
    await tester.pump();
    expect(circuitOf(container, 'c1').cableOverrideMm2, isNull);
  });

  // ── Phase page ─────────────────────────────────────────────────────────────

  testWidgets('phase page: hidden for a 3-phase way (and without a known 3ph '
      'board), writes PhaseLine.l2 for a 1ph way', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());

    // A 3-phase motor way spans every line — no Phase row.
    await pumpCircuitMenu(tester, container, s.controller,
        circuitId: 'c2', circuitResult: resultOf(s.result, 'c2'));
    expect(find.textContaining('Phase · '), findsNothing);

    // Without positive evidence of a 3-phase BOARD there is no row either.
    await pumpCircuitMenu(tester, container, s.controller,
        circuitId: 'c1',
        circuitResult: resultOf(s.result, 'c1'),
        panelSystem: null);
    expect(find.textContaining('Phase · '), findsNothing);

    // A known-1ph way on a known-3ph board: pick S (= PhaseLine.l2).
    await pumpCircuitMenu(tester, container, s.controller,
        circuitId: 'c1', circuitResult: resultOf(s.result, 'c1'));
    expect(find.textContaining('Phase · '), findsOneWidget);
    await tester.tap(find.textContaining('Phase · '));
    await tester.pumpAndSettle();
    expect(find.text('Auto (balanced)'), findsOneWidget);
    await tester.tap(find.text('S'));
    await tester.pump();
    expect(circuitOf(container, 'c1').phaseOverride, PhaseLine.l2);

    // '(set)' + Auto (balanced) clears the pin.
    await pumpCircuitMenu(tester, container, s.controller,
        circuitId: 'c1', circuitResult: resultOf(s.result, 'c1'));
    expect(find.text('Phase · S (set)'), findsOneWidget);
    await tester.tap(find.text('Phase · S (set)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto (balanced)'));
    await tester.pump();
    expect(circuitOf(container, 'c1').phaseOverride, isNull);
  });

  // ── Family page ────────────────────────────────────────────────────────────

  testWidgets('family page: one shared family ladder, writes cableType, the '
      'panel-default row clears it', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());

    await pumpCircuitMenu(tester, container, s.controller, circuitId: 'c1');
    expect(find.text('Family · NYY'), findsOneWidget);
    await tester.tap(find.text('Family · NYY'));
    await tester.pumpAndSettle();

    // Every family of the ONE shared ladder is offered.
    for (final f in kCableFamilies) {
      expect(find.text(f), findsOneWidget);
    }
    await tester.tap(find.text('NYM'));
    await tester.pump();
    expect(circuitOf(container, 'c1').cableType, 'NYM');

    await pumpCircuitMenu(tester, container, s.controller, circuitId: 'c1');
    await tester.tap(find.text('Family · NYM'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Panel default'));
    await tester.pump();
    expect(circuitOf(container, 'c1').cableType, isNull);
  });

  // ── An unwired host stays action-only ──────────────────────────────────────

  testWidgets('with no host-resolved circuit the menu renders exactly its '
      'previous action-only form', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());

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
    expect(find.textContaining('Breaker · '), findsNothing);
    expect(find.textContaining('Cable · '), findsNothing);
    expect(find.textContaining('Phase · '), findsNothing);
    expect(find.textContaining('Family · '), findsNothing);
    expect(find.text('Edit'), findsOneWidget);
  });

  // ── Panel System page ──────────────────────────────────────────────────────

  testWidgets('panel System page flips 3ph -> 1ph with the 220 V snap; the '
      'machine-owned MEP board offers no System row', (tester) async {
    setDesktopSurface(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = seed(container, buildProject());

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
    expect(find.text('System · 3ph 400 V'), findsOneWidget);

    await tester.tap(find.text('System · 3ph 400 V'));
    await tester.pumpAndSettle();
    expect(find.text('1ph 220 V'), findsOneWidget);
    expect(find.text('3ph 400 V'), findsOneWidget);
    await tester.tap(find.text('1ph 220 V'));
    await tester.pump();
    final live = container.read(electricalProjectProvider).panels.first;
    expect(live.system, ElectricalSystem.singlePhase);
    expect(live.voltage.volts, 220);

    // The MEP Equipment board's supply is derived from the plan — no row.
    await pump(
      tester,
      container,
      ElectricalPanelMenu(
        panel: s.panel.copyWith(id: kMepEquipmentPanelId),
        controller: s.controller,
        onProperties: () {},
        onOpen: () {},
        onDone: () {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('System · '), findsNothing);
  });
}
