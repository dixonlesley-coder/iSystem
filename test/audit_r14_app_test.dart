// Round 14 (2026-10-18) — app-side findings:
//   regression-dutystandby-tank-root-doubles-pump-duty /
//   mech-props-3-standby-duty-double   — the pump duty skips mirrored legs;
//   mech-props-3-inline-booster-fan    — an inline fan still owns its duty;
//   regression-commit-on-dispose-deactivated-ref — no teardown commit; every
//   non-focus navigation commits first, while the host is mounted.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/shell/nav_rail.dart';
import 'package:mechx/ui/shell/workflow_stepper.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx/ui/widgets/mechx_text_field.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'test_util.dart';

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
}

ProviderContainer _c(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(MechXApp)),
    listen: false);

NetNode _n(String id, double x, double y,
        {NodeRole role = NodeRole.main,
        NodeComponent? component,
        FlowRate? airflow}) =>
    NetNode(
        id: id,
        sheetId: 's',
        x: x,
        y: y,
        floorIndex: 0,
        role: role,
        component: component,
        airflow: airflow);

NetEdge _e(String id, String a, String b, ServiceType s) =>
    NetEdge(id: id, fromId: a, toId: b, service: s);

final _nameProvider = StateProvider<String>((_) => 'Level 2');
final _hostVisible = StateProvider<bool>((_) => true);

void main() {
  setUpAll(_loadFonts);

  group('duty/standby — the pump delivers ONE set flow', () {
    test('a set drawn from the tank: curve(80), never curve(160)', () {
      final net = Network(nodes: [
        _n('T', 0, 0, role: NodeRole.plant, component: NodeComponent.groundTank),
        _n('P1', 40, -20, role: NodeRole.plant, component: NodeComponent.pump),
        _n('P2', 40, 20, role: NodeRole.plant, component: NodeComponent.pump),
        _n('CV1', 80, -20, component: NodeComponent.checkValve),
        _n('CV2', 80, 20, component: NodeComponent.checkValve),
        _n('HDR', 120, 0),
        for (var i = 0; i < 4; i++)
          _n('fx$i', 200, i * 30.0, role: NodeRole.fixture),
      ], edges: [
        _e('t1', 'T', 'P1', ServiceType.coldWater),
        _e('t2', 'T', 'P2', ServiceType.coldWater),
        _e('p1', 'P1', 'CV1', ServiceType.coldWater),
        _e('p2', 'P2', 'CV2', ServiceType.coldWater),
        _e('c1', 'CV1', 'HDR', ServiceType.coldWater),
        _e('c2', 'CV2', 'HDR', ServiceType.coldWater),
        for (var i = 0; i < 4; i++)
          _e('b$i', 'HDR', 'fx$i', ServiceType.coldWater),
      ]);
      final units = <String, double>{};
      final legs = <String>{};
      final sizing = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.coldWater: FlowRate(0)},
          leafFixtureUnits: const {ServiceType.coldWater: 20.0},
          fixtureUnitsOut: units,
          parallelLegEdgeIdsOut: legs);
      final root = serviceComponentRoots(net, ServiceType.coldWater,
          demandNodeIds: {for (var i = 0; i < 4; i++) 'fx$i'})['HDR']!;
      expect(root, 'T');
      const profile = SniProfile();
      final set = profile.probableFlowForFixtureUnits(80).inLitersPerSecond;
      final doubled = profile.probableFlowForFixtureUnits(160).inLitersPerSecond;
      // 4 × 20 UBAP = 80 UBAP: curve(80) = 2.553 L/s; summing the standby
      // suction leg too re-curves 160 UBAP = 4.053 L/s (+59 %).
      expect(set, closeTo(2.553, 5e-4));
      expect(doubled, closeTo(4.053, 5e-4));
      final withLegs = sourceDeliveredFlow(net, sizing, ServiceType.coldWater,
          root,
          edgeFixtureUnits: units, flushSystem: FlushSystem.flushTank);
      expect(withLegs.inLitersPerSecond, closeTo(doubled, 1e-9),
          reason: 'the defect being fixed');
      final delivered = sourceDeliveredFlow(net, sizing, ServiceType.coldWater,
          root,
          edgeFixtureUnits: units,
          flushSystem: FlushSystem.flushTank,
          excludeEdgeIds: legs);
      expect(delivered.inLitersPerSecond, closeTo(set, 1e-9));
    });
  });

  group('inline fan — the duty stays with the drawn machine', () {
    test('grilles → J → inline exhaust fan → louvre: fanNodeId is the fan', () {
      const q = FlowRate(0.1);
      final net = Network(nodes: [
        for (var i = 0; i < 4; i++)
          _n('g$i', 0, i * 30.0,
              role: NodeRole.fixture,
              component: NodeComponent.exhaustGrille,
              airflow: q),
        _n('J', 60, 45),
        _n('F', 120, 45,
            role: NodeRole.plant, component: NodeComponent.exhaustFan),
        _n('L', 180, 45),
      ], edges: [
        for (var i = 0; i < 4; i++) _e('g$i', 'g$i', 'J', ServiceType.exhaust),
        _e('jf', 'J', 'F', ServiceType.exhaust),
        _e('fl', 'F', 'L', ServiceType.exhaust),
      ]);
      final sizing = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {ServiceType.exhaust: FlowRate(0.03)},
          nodeFlowDemand: {for (var i = 0; i < 4; i++) 'g$i': q});
      final systems = airSystemsFor(
          net,
          sizing,
          const ProjectState(name: 'p', floors: []),
          ServiceType.exhaust);
      expect(systems, hasLength(1));
      // The system roots at the louvre (so the discharge carries 0.4 m³/s)…
      expect(systems.single.trunk.cubicMetersPerSecond, closeTo(0.4, 1e-12));
      // …but its duty belongs to the drawn fan node.
      expect(systems.single.fanNodeId, 'F');
    });
  });

  group('commit-on-dispose — no deactivated-ref lookup, no lost edit', () {
    testWidgets('a Consumer host removed by a provider flip never throws',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MechXTheme(
          data: MechXThemeData.dark,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Consumer(builder: (context, ref, _) {
              if (!ref.watch(_hostVisible)) return const SizedBox();
              return Consumer(
                builder: (context, ref, _) => MechXTextField(
                  value: ref.watch(_nameProvider),
                  onCommitted: (v) =>
                      ref.read(_nameProvider.notifier).state = v,
                ),
              );
            }),
          ),
        ),
      ));
      await tester.enterText(find.byType(EditableText), 'Roof deck');
      final c = ProviderScope.containerOf(
          tester.element(find.byType(MechXTextField)),
          listen: false);
      c.read(_hostVisible.notifier).state = false;
      await tester.pump();
      // Was: 'Looking up a deactivated widget's ancestor is unsafe.'
      expect(tester.takeException(), isNull);
    });

    Future<ProviderContainer> projectsPageWithTypedName(
        WidgetTester tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();
      final c = _c(tester);
      c.read(projectControllerProvider.notifier).setName('Tower');
      c.read(shellSectionProvider.notifier).set(ShellSection.projects);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final field = find.byWidgetPredicate(
          (w) => w is MechXTextField && w.value == 'Tower');
      expect(field, findsOneWidget);
      await tester.enterText(
          find.descendant(of: field, matching: find.byType(EditableText)),
          'Menara Satu');
      return c;
    }

    testWidgets('a workflow-stepper chip (no focus) keeps the typed name',
        (tester) async {
      final c = await projectsPageWithTypedName(tester);
      final chip = find.descendant(
          of: find.byType(WorkflowStepper), matching: find.text('Report'));
      expect(chip, findsOneWidget);
      await tester.tap(chip);
      await tester.pump();
      expect(c.read(shellSectionProvider), ShellSection.review);
      expect(c.read(projectControllerProvider).name, 'Menara Satu');
      expect(tester.takeException(), isNull);
    });

    testWidgets('any programmatic section switch (Locate) commits first',
        (tester) async {
      final c = await projectsPageWithTypedName(tester);
      c.read(shellSectionProvider.notifier).set(ShellSection.building);
      await tester.pump();
      expect(c.read(projectControllerProvider).name, 'Menara Satu');
      expect(tester.takeException(), isNull);
    });
  });
}
