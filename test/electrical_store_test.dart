import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';

import 'test_util.dart';

/// The interactive-editor seam: the store's edit intents mutate the project
/// immutably (through `_withProject`) and the pure A4 engine re-sizes off the
/// result. Every test reads `electricalResultProvider` to prove the change took.
void main() {
  group('ElectricalProjectController edit intents', () {
    test('addCircuit appends a sized way with standards-derived defaults', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      final before = c.read(electricalResultProvider).panels['mdp']!.circuits.length;
      ctrl.addCircuit('mdp', kind: LoadKind.socket, name: 'New sockets');

      final panel = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == 'mdp');
      final added = panel.circuits.last;
      expect(panel.circuits.length, before + 1);
      expect(added.name, 'New sockets');
      expect(added.loadKind, LoadKind.socket);
      // cos φ + demand factor come from loadDefaults, not hand-coded.
      expect(added.cosPhi, loadDefaults[LoadKind.socket]!.cosPhi);
      expect(added.demandFactor, loadDefaults[LoadKind.socket]!.demandFactor);

      // The engine sizes the new way → it appears in the result with a breaker.
      final result = c.read(electricalResultProvider).panels['mdp']!;
      expect(result.circuits.length, before + 1);
      final sized = result.circuits.firstWhere((r) => r.name == 'New sockets');
      expect(sized.breaker.ratingA.amperes, greaterThan(0));
      expect(sized.designCurrent.amperes, greaterThan(0));
    });

    test('addCircuit for a motor seeds a kW load and sizes off it', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(electricalProjectProvider.notifier)
          .addCircuit('mdp', kind: LoadKind.pump, name: 'New pump');

      final added = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == 'mdp')
          .circuits
          .last;
      expect(added.motorKw, isNotNull);
      expect(added.motorKw, greaterThan(0));

      final sized = c.read(electricalResultProvider).panels['mdp']!.circuits
          .firstWhere((r) => r.name == 'New pump');
      expect(sized.designCurrent.amperes, greaterThan(0));
    });

    test('setCircuit changes one field and the engine re-sizes', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      final before = c.read(electricalResultProvider).panels['mdp']!.circuits
          .firstWhere((r) => r.circuitId == 'mdp-c1')
          .designCurrent
          .amperes;

      // Halve the chiller load → smaller design current.
      ctrl.setCircuit('mdp', 'mdp-c1', loadW: 9000);
      final after = c.read(electricalResultProvider).panels['mdp']!.circuits
          .firstWhere((r) => r.circuitId == 'mdp-c1')
          .designCurrent
          .amperes;
      expect(after, lessThan(before));

      // Only that field changed; the name is untouched.
      final model = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == 'mdp')
          .circuits
          .firstWhere((c0) => c0.id == 'mdp-c1');
      expect(model.loadW, 9000);
      expect(model.name, 'Chiller / HVAC');
    });

    test('setCircuit clear flags null the optional field', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      ctrl.setCircuit('mdp', 'mdp-c1', phases: 1, cableType: 'NYM');
      var model = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == 'mdp')
          .circuits
          .firstWhere((c0) => c0.id == 'mdp-c1');
      expect(model.phases, 1);
      expect(model.cableType, 'NYM');

      ctrl.setCircuit('mdp', 'mdp-c1', clearPhases: true, clearCableType: true);
      model = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == 'mdp')
          .circuits
          .firstWhere((c0) => c0.id == 'mdp-c1');
      expect(model.phases, isNull);
      expect(model.cableType, isNull);
    });

    test('deleteCircuit removes the way', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      final before = c.read(electricalResultProvider).panels['mdp']!.circuits.length;
      ctrl.deleteCircuit('mdp', 'mdp-c4'); // water heater
      final after = c.read(electricalResultProvider).panels['mdp']!.circuits;
      expect(after.length, before - 1);
      expect(after.where((r) => r.circuitId == 'mdp-c4'), isEmpty);
    });

    test('duplicateCircuit adds a fresh-id "(copy)" way', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      ctrl.duplicateCircuit('mdp', 'mdp-c4'); // water heater
      final circuits = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == 'mdp')
          .circuits;
      final copies = circuits.where((c0) => c0.name == 'Water heater (copy)');
      expect(copies, hasLength(1));
      final copy = copies.single;
      expect(copy.id, isNot('mdp-c4'));
      // Same defining fields, fresh identity.
      expect(copy.loadW, 3000);
      expect(copy.loadKind, LoadKind.heating);
      // Inserted directly after the original.
      final origIdx = circuits.indexWhere((c0) => c0.id == 'mdp-c4');
      expect(circuits[origIdx + 1].id, copy.id);
    });

    test('addPanel / deletePanel grow and shrink the system', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      final before = c.read(electricalProjectProvider).panels.length;
      ctrl.addPanel(name: 'Workshop board', tag: 'WB-1');
      final added = c.read(electricalProjectProvider).panels.last;
      expect(c.read(electricalProjectProvider).panels.length, before + 1);
      expect(added.name, 'Workshop board');
      expect(added.tag, 'WB-1');
      // The new panel is sized (appears as a result, with an incomer).
      final result = c.read(electricalResultProvider).panels[added.id];
      expect(result, isNotNull);
      expect(result!.incomer.breaker.ratingA.amperes, greaterThan(0));

      ctrl.deletePanel(added.id);
      expect(c.read(electricalProjectProvider).panels.length, before);
      expect(c.read(electricalResultProvider).panels[added.id], isNull);
    });

    test('renamePanel + flag toggles + diversity carry through', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      ctrl.renamePanel('lp1', 'Renamed LP');
      ctrl.setPanelEssential('lp1', true);
      ctrl.setPanelUpsBacked('lp1', true);
      ctrl.setPanelSubmeter('lp1', true);
      ctrl.setPanelDiversity('lp1', 0.6);

      final p = c.read(electricalProjectProvider).panels
          .firstWhere((p0) => p0.id == 'lp1');
      expect(p.name, 'Renamed LP');
      expect(p.essential, isTrue);
      expect(p.upsBacked, isTrue);
      expect(p.submeter, isTrue);
      expect(p.diversityFactor, 0.6);
    });

    test('REGRESSION: an edit preserves the additive A8 project fields', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      // Seed a project carrying every additive A8 field.
      ctrl.setProject(const ElectricalProject(
        id: 'p',
        name: 'A8 project',
        earthingSystem: EarthingSystem.tt,
        panels: [
          ElectricalPanel(
            id: 'mdp',
            name: 'MDP',
            circuits: [
              ElectricalCircuit(
                id: 'c1',
                name: 'Lighting',
                loadKind: LoadKind.lighting,
                loadW: 1500,
              ),
            ],
          ),
        ],
        sources: ElectricalSources(
          generator: GeneratorSource(backupFraction: 0.5),
          solar: SolarSource(panels: 20),
        ),
        dualTransformer: true,
        occupancy: 'office',
        soilResistivityOhmM: 120,
        groundFlashDensity: 8,
        externalLps: true,
        overheadSupply: true,
        buildingLengthM: 40,
        buildingWidthM: 25,
        buildingHeightM: 18,
      ));

      // Run every kind of edit.
      ctrl.addCircuit('mdp', kind: LoadKind.socket);
      ctrl.setCircuit('mdp', 'c1', loadW: 1800);
      ctrl.duplicateCircuit('mdp', 'c1');
      ctrl.renamePanel('mdp', 'Main board');
      ctrl.setPanelEssential('mdp', true);
      ctrl.addPanel(name: 'SP-1');

      final proj = c.read(electricalProjectProvider);
      // The additive A8 fields all survived.
      expect(proj.earthingSystem, EarthingSystem.tt);
      expect(proj.sources, isNotNull);
      expect(proj.sources!.generator!.backupFraction, 0.5);
      expect(proj.sources!.solar!.panels, 20);
      expect(proj.dualTransformer, isTrue);
      expect(proj.occupancy, 'office');
      expect(proj.soilResistivityOhmM, 120);
      expect(proj.groundFlashDensity, 8);
      expect(proj.externalLps, isTrue);
      expect(proj.overheadSupply, isTrue);
      expect(proj.buildingLengthM, 40);
      expect(proj.buildingWidthM, 25);
      expect(proj.buildingHeightM, 18);
      // And the edits all landed.
      expect(proj.name, 'A8 project'); // project name unchanged by panel rename
      expect(proj.panels.firstWhere((p) => p.id == 'mdp').name, 'Main board');
      expect(proj.panels.length, 2);

      // The advanced study still runs over the preserved fields.
      final adv = c.read(electricalAdvancedProvider);
      expect(adv.powerOneLine, isNotNull); // sources present
      expect(adv.electrode, isNotNull); // soil resistivity present
      expect(adv.lightning, isNotNull); // building geometry + Ng present
    });
  });

  group('ElectricalView interactive editor', () {
    testWidgets('palette is present and a "+ Way" adds a circuit', (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
      await tester.pump();

      // The palette card titled "Loads" renders.
      expect(find.text('Loads'), findsOneWidget);
      // Add-panel affordance.
      expect(find.text('+ Panel'), findsWidgets);

      final before = container
          .read(electricalResultProvider)
          .panels['mdp']!
          .circuits
          .length;

      // Tap the first "+ Way" button (MDP card, the first panel).
      await tester.tap(find.text('+ Way').first);
      await tester.pump();

      final after = container
          .read(electricalResultProvider)
          .panels['mdp']!
          .circuits
          .length;
      expect(after, before + 1);
    });

    testWidgets('right-click a row opens the menu; Edit opens the inspector',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
      await tester.pump();

      // Secondary-button press on the chiller row (the Listener checks
      // kSecondaryButton) opens the custom context menu. Scroll it into view
      // first — the palette + cards push the first panel's rows below the fold.
      await tester.ensureVisible(find.text('Chiller / HVAC').first);
      await tester.pump();
      final center = tester.getCenter(find.text('Chiller / HVAC').first);
      final pointer = await tester.startGesture(center, buttons: kSecondaryButton);
      await pointer.up();
      await tester.pump();

      // The custom context menu is shown.
      expect(find.text('Duplicate'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);

      // Choosing "Edit" opens the inspector drawer.
      await tester.tap(find.text('Edit'));
      await tester.pump();
      expect(find.text('Edit circuit'), findsOneWidget);
      expect(find.text('Run length (m)'.toUpperCase()), findsOneWidget);
    });

    testWidgets('right-click Delete removes the way', (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      container.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);
      await tester.pump();

      final before = container
          .read(electricalResultProvider)
          .panels['mdp']!
          .circuits
          .length;

      await tester.ensureVisible(find.text('Water heater').first);
      await tester.pump();
      final center = tester.getCenter(find.text('Water heater').first);
      final pointer = await tester.startGesture(center, buttons: kSecondaryButton);
      await pointer.up();
      await tester.pump();
      await tester.tap(find.text('Delete'));
      await tester.pump();

      final after = container
          .read(electricalResultProvider)
          .panels['mdp']!
          .circuits
          .length;
      expect(after, before - 1);
    });
  });
}
