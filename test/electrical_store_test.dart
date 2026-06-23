import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/layer_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

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

  group('Spatial-canvas intents (Wave 5)', () {
    test('setPanelPosition moves a panel; auto-layout falls back when null', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      // Seeded panels start with no saved layout.
      var mdp = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == 'mdp');
      expect(mdp.x, isNull);
      expect(mdp.y, isNull);

      ctrl.setPanelPosition('mdp', 320, 144);
      mdp = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == 'mdp');
      expect(mdp.x, 320);
      expect(mdp.y, 144);
    });

    test('addPanelAt + addFloatingLoad place a sized board at a position', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      ctrl.addPanelAt(name: 'Yard board', tag: 'YB-1', x: 500, y: 200);
      final added = c.read(electricalProjectProvider).panels.last;
      expect(added.x, 500);
      expect(added.y, 200);
      // The new board sizes (it appears with an incomer).
      final r = c.read(electricalResultProvider).panels[added.id];
      expect(r, isNotNull);
      expect(r!.incomer.breaker.ratingA.amperes, greaterThan(0));

      final beforeCount = c.read(electricalProjectProvider).panels.length;
      ctrl.addFloatingLoad(kind: LoadKind.socket, x: 640, y: 360, loadW: 2400);
      expect(c.read(electricalProjectProvider).panels.length, beforeCount + 1);
      final float = c.read(electricalProjectProvider).panels.last;
      expect(float.x, 640);
      expect(float.circuits.single.loadW, 2400);
      // It sizes too.
      expect(
          c.read(electricalResultProvider).panels[float.id]!.circuits.single
              .designCurrent.amperes,
          greaterThan(0));
    });

    test('connectFeeder wires a parent way + sets the child incomer', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      // Add a fresh utility board to feed from the MDP.
      ctrl.addPanelAt(name: 'Pump room', tag: 'PR-1', x: 400, y: 400);
      final target = c.read(electricalProjectProvider).panels.last;
      expect(target.fedByCircuitId, isNull);

      final waysBefore = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == 'mdp')
          .circuits
          .length;
      final res = ctrl.connectFeeder('mdp', target.id);
      expect(res.connected, isTrue);

      final mdp = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == 'mdp');
      expect(mdp.circuits.length, waysBefore + 1);
      final feeder =
          mdp.circuits.firstWhere((w) => w.feedsPanelId == target.id);
      final fed = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == target.id);
      expect(fed.fedByCircuitId, feeder.id);
      expect(fed.sourceType, PanelSource.feeder);
    });

    test('connectFeeder refuses self / second-parent / cycle', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      // Self-feed.
      expect(ctrl.connectFeeder('mdp', 'mdp').connected, isFalse);

      // lp1 is already fed by the MDP feeder in the sample → second parent.
      ctrl.addPanelAt(name: 'Other', tag: 'OT', x: 0, y: 0);
      final other = c.read(electricalProjectProvider).panels.last;
      final hasParent = ctrl.connectFeeder(other.id, 'lp1');
      expect(hasParent.connected, isFalse);
      expect(hasParent.reason, contains('already fed'));

      // Cycle: lp1 -> mdp would loop (mdp already feeds lp1).
      final cycle = ctrl.connectFeeder('lp1', 'mdp');
      expect(cycle.connected, isFalse);
      expect(cycle.reason, contains('loop'));
    });

    test('disconnectFeeder drops the way + makes the child utility-fed', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      // lp1 is fed by mdp-f1 in the sample.
      final waysBefore = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == 'mdp')
          .circuits
          .length;
      ctrl.disconnectFeeder('lp1');

      final mdp = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == 'mdp');
      expect(mdp.circuits.length, waysBefore - 1);
      expect(mdp.circuits.where((w) => w.feedsPanelId == 'lp1'), isEmpty);
      final lp1 = c.read(electricalProjectProvider).panels
          .firstWhere((p) => p.id == 'lp1');
      expect(lp1.fedByCircuitId, isNull);
      expect(lp1.sourceType, PanelSource.utility);
    });

    test('panel x/y round-trips through the model JSON codec', () {
      const panel = ElectricalPanel(id: 'p', name: 'P', x: 240, y: 96);
      final back = ElectricalPanel.fromJson(panel.toJson());
      expect(back.x, 240);
      expect(back.y, 96);
    });
  });

  group('ElectricalView canvas', () {
    testWidgets('the palette + canvas render in the electrical workspace',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      container
          .read(workspaceViewProvider.notifier)
          .set(WorkspaceView.electrical);
      await tester.pump();

      // The Loads palette renders, the Single-line tab is present.
      expect(find.text('Loads'), findsWidgets);
      expect(find.text('Single-line'), findsOneWidget);
      expect(find.text('Power one-line'), findsOneWidget);
      // The sample panels are on the canvas.
      expect(find.text('Main Distribution Panel'), findsOneWidget);
    });

    testWidgets('+ Panel toolbar action grows the system', (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      container
          .read(workspaceViewProvider.notifier)
          .set(WorkspaceView.electrical);
      await tester.pump();

      final before = container.read(electricalProjectProvider).panels.length;
      // The toolbar's '+ Panel' lives in a horizontally-scrollable row; under
      // the left-nav rail the canvas is narrower, so scroll it into view before
      // tapping rather than assuming a fixed position.
      final addPanel = find.text('+ Panel').first;
      await tester.ensureVisible(addPanel);
      await tester.pump();
      await tester.tap(addPanel);
      await tester.pump();
      expect(container.read(electricalProjectProvider).panels.length,
          before + 1);
    });

    testWidgets('switching to the Power one-line tab renders it',
        (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      container
          .read(workspaceViewProvider.notifier)
          .set(WorkspaceView.electrical);
      await tester.pump();

      await tester.tap(find.text('Power one-line'));
      await tester.pump();
      // The sample has no sources → the empty-state copy shows.
      expect(find.text('No energy sources'), findsOneWidget);
    });
  });

  group('Geo-layout intents (Wave 6)', () {
    // A one-panel, one-circuit project with a deliberately long MANUAL length, so
    // placing it on a calibrated layout (a short geo run) measurably shortens the
    // run the engine sizes against.
    void seed(ProviderContainer c) {
      c.read(electricalProjectProvider.notifier).setProject(
            const ElectricalProject(
              id: 'geo',
              name: 'Geo project',
              panels: [
                ElectricalPanel(
                  id: 'mdp',
                  name: 'MDP',
                  circuits: [
                    ElectricalCircuit(
                      id: 'c1',
                      name: 'Big load',
                      loadKind: LoadKind.general,
                      loadW: 8000,
                      cosPhi: 0.85,
                      length: Length(90), // manual fallback (long)
                    ),
                  ],
                ),
              ],
            ),
          );
      // Calibrate sheet s1: 1 px = 1 cm (so 300 px = 3.0 m planar).
      c
          .read(projectControllerProvider.notifier)
          .setCalibration('s1', const ScaleCalibration(0.01));
    }

    double dropOf(ProviderContainer c) => c
        .read(electricalResultProvider)
        .panels['mdp']!
        .circuits
        .single
        .voltageDrop
        .dropPercent;

    test('placing a panel + load drives the run length from geometry', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seed(c);
      final ctrl = c.read(electricalProjectProvider.notifier);

      // With nothing placed, the run uses the 90 m manual length.
      final manualDrop = dropOf(c);

      // Place the panel + its load on the same floor, 300 px = 3.0 m apart.
      ctrl.setPanelLayoutPos(
          'mdp', const LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0));
      ctrl.setLoadPos('mdp', 'c1',
          const LayoutPos(sheetId: 's1', floorIndex: 0, x: 300, y: 0));

      // Both placements landed on the model.
      final p = c.read(electricalProjectProvider).panels.single;
      expect(p.layoutPos, isNotNull);
      expect(p.circuits.single.loadPos, isNotNull);

      // The geo run (3 m) is far shorter than the manual 90 m → smaller drop.
      final geoDrop = dropOf(c);
      expect(geoDrop, lessThan(manualDrop));
      expect(geoDrop, lessThan(manualDrop * 0.2));
    });

    test('moving the placed load updates the geo length (drop grows)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seed(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.setPanelLayoutPos(
          'mdp', const LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0));

      // Load 3 m away.
      ctrl.setLoadPos('mdp', 'c1',
          const LayoutPos(sheetId: 's1', floorIndex: 0, x: 300, y: 0));
      final near = dropOf(c);

      // Drag it to 30 m away (3000 px) — a longer run, a bigger drop.
      ctrl.setLoadPos('mdp', 'c1',
          const LayoutPos(sheetId: 's1', floorIndex: 0, x: 3000, y: 0));
      final far = dropOf(c);
      expect(far, greaterThan(near));
    });

    test('an unplaced circuit keeps its manual length (geo not applied)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seed(c);
      final ctrl = c.read(electricalProjectProvider.notifier);

      final before = dropOf(c);
      // Place the PANEL only — the load has no loadPos, so the manual length
      // still governs and the result is unchanged.
      ctrl.setPanelLayoutPos(
          'mdp', const LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0));
      expect(dropOf(c), before);
    });

    test('addLoadAtLayout creates a placed, geo-sized way on a panel', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seed(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.setPanelLayoutPos(
          'mdp', const LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0));

      final before = c.read(electricalProjectProvider).panels.single.circuits.length;
      ctrl.addLoadAtLayout(
        'mdp',
        kind: LoadKind.socket,
        pos: const LayoutPos(sheetId: 's1', floorIndex: 0, x: 200, y: 0),
        loadW: 2400,
      );
      final added = c.read(electricalProjectProvider).panels.single.circuits.last;
      expect(c.read(electricalProjectProvider).panels.single.circuits.length,
          before + 1);
      expect(added.loadPos, isNotNull);
      // It sizes (appears in the result with a breaker).
      final r = c.read(electricalResultProvider).panels['mdp']!.circuits
          .firstWhere((rc) => rc.circuitId == added.id);
      expect(r.breaker.ratingA.amperes, greaterThan(0));
    });

    test('setLoadPos / setPanelLayoutPos with null clears the placement', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seed(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.setPanelLayoutPos(
          'mdp', const LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0));
      ctrl.setLoadPos('mdp', 'c1',
          const LayoutPos(sheetId: 's1', floorIndex: 0, x: 300, y: 0));
      expect(c.read(electricalProjectProvider).panels.single.layoutPos, isNotNull);

      ctrl.setLoadPos('mdp', 'c1', null);
      ctrl.setPanelLayoutPos('mdp', null);
      final p = c.read(electricalProjectProvider).panels.single;
      expect(p.layoutPos, isNull);
      expect(p.circuits.single.loadPos, isNull);
    });

    test('the geo placement is a DISTINCT space from the single-line x/y', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seed(c);
      final ctrl = c.read(electricalProjectProvider.notifier);

      // Set both the abstract single-line position AND a geo placement.
      ctrl.setPanelPosition('mdp', 640, 480);
      ctrl.setPanelLayoutPos(
          'mdp', const LayoutPos(sheetId: 's1', floorIndex: 0, x: 12, y: 34));

      final p = c.read(electricalProjectProvider).panels.single;
      expect(p.x, 640); // single-line schematic coord untouched
      expect(p.y, 480);
      expect(p.layoutPos!.x, 12); // geo placement is separate
      expect(p.layoutPos!.y, 34);
    });

    test('.mechx round-trip preserves layoutPos / loadPos', () {
      final doc = ProjectDocument(
        projectName: 'Geo doc',
        floors: const [Floor('Ground', Length(4.0))],
        calibrations: const {'s1': ScaleCalibration(0.01)},
        sheets: const [],
        network: const Network(),
        electrical: const ElectricalProject(
          id: 'ep',
          name: 'Geo electrical',
          panels: [
            ElectricalPanel(
              id: 'mdp',
              name: 'MDP',
              layoutPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 7, y: 8),
              circuits: [
                ElectricalCircuit(
                  id: 'c1',
                  name: 'Load',
                  loadKind: LoadKind.socket,
                  loadW: 2000,
                  loadPos: LayoutPos(sheetId: 's1', floorIndex: 0, x: 9, y: 10),
                ),
              ],
            ),
          ],
        ),
      );

      final decoded = ProjectDocument.decode(doc.encode());
      final panel = decoded.electrical!.panels.single;
      expect(panel.layoutPos,
          const LayoutPos(sheetId: 's1', floorIndex: 0, x: 7, y: 8));
      expect(panel.circuits.single.loadPos,
          const LayoutPos(sheetId: 's1', floorIndex: 0, x: 9, y: 10));
    });
  });

  // Electrical placement now lives on the UNIFIED Layout canvas (the Electrical
  // discipline layer over the shared PDF), reached via the Layout design view.
  group('unified Layout canvas — electrical layer', () {
    testWidgets('placing a panel + selecting the Electrical layer shows the '
        'marker on the shared sheet', (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      // Stay on the Layout design view (the default), make Electrical the active
      // layer, and place the sample MDP on demo sheet s1 (floor 0).
      container
          .read(activeDisciplineProvider.notifier)
          .set(DisciplineLayer.electrical);
      container.read(electricalProjectProvider.notifier).setPanelLayoutPos(
          'mdp', const LayoutPos(sheetId: 's1', floorIndex: 0, x: 400, y: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The layer switcher offers the three disciplines; the placed MDP marker
      // shows on the sheet (by its tag); the Loads palette is the inspector.
      expect(find.text('Plumbing'), findsWidgets);
      expect(find.text('HVAC'), findsWidgets);
      expect(find.text('Electrical'), findsWidgets);
      expect(find.text('MDP'), findsWidgets);
      expect(find.text('Loads'), findsWidgets);
    });

    testWidgets('a placed panel is hidden when the Electrical layer is toggled '
        'off', (tester) async {
      setDesktopSurface(tester);
      await tester.pumpWidget(const ProviderScope(child: MechXApp()));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MechXApp)),
        listen: false,
      );
      container
          .read(activeDisciplineProvider.notifier)
          .set(DisciplineLayer.plumbing); // electrical is now a faded layer
      container.read(electricalProjectProvider.notifier).setPanelLayoutPos(
          'mdp', const LayoutPos(sheetId: 's1', floorIndex: 0, x: 400, y: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // Faded but still drawn.
      expect(find.text('MDP'), findsWidgets);

      // Hide the electrical layer → its marker is gone.
      container
          .read(layerVisibilityProvider.notifier)
          .toggle(DisciplineLayer.electrical);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('MDP'), findsNothing);
    });
  });
}
