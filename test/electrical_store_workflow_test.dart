/// W1.A — the electrical STORE workflow contract the later UI waves code
/// against: id-returning creation intents, panel templates, one-gesture fed
/// sub-panels, feeder RE-PARENTING (with a pure refusal query the canvas can
/// preview with), delete hygiene via the engine's `sanitizeFeederTopology`, the
/// widened per-field overrides, durable phase pins, the MEP board's first-sync
/// auto-feed, and the session-only phase-stability cache.
///
/// Container-level (mirrors `electrical_store_test.dart`): every assertion goes
/// through the real providers, and anything undoable is proved to be ONE step on
/// the shared global timeline.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/panel_templates.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';

/// The mdp (+ its LP-1 sub-board) fixture the sibling suite uses.
void seedSample(ProviderContainer c) => c
    .read(electricalProjectProvider.notifier)
    .setProject(sampleElectricalProject());

ElectricalProject proj(ProviderContainer c) =>
    c.read(electricalProjectProvider);

ElectricalPanel panel(ProviderContainer c, String id) =>
    proj(c).panels.firstWhere((p) => p.id == id);

ElectricalCircuit circuit(ProviderContainer c, String panelId, String id) =>
    panel(c, panelId).circuits.firstWhere((x) => x.id == id);

void main() {
  group('kDefaultCircuitLength (10 m creation default)', () {
    // CONTRACT CHANGE (W1.A): every creation site used to hard-code 20 m. A
    // just-dropped way has no geometry, so the placeholder is now a short,
    // honest 10 m stub — small enough that an unplaced way can't quietly
    // inflate a voltage-drop or cable total before the engineer places it (at
    // which point `resolveCircuitLength` takes over and this is never read).
    test('is 10 m', () => expect(kDefaultCircuitLength.meters, 10));

    test('every creation intent seeds it', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);

      final wayId = ctrl.addCircuit('mdp', kind: LoadKind.socket);
      expect(circuit(c, 'mdp', wayId).length.meters, 10);

      final floating = ctrl.addFloatingLoad(kind: LoadKind.socket, x: 0, y: 0);
      expect(circuit(c, floating.panelId, floating.circuitId).length.meters, 10);

      const pos = LayoutPos(sheetId: 's1', floorIndex: 0, x: 10, y: 10);
      final placed = ctrl.addLoadAtLayout('mdp', kind: LoadKind.socket, pos: pos);
      expect(circuit(c, 'mdp', placed).length.meters, 10);

      final floatPlaced =
          ctrl.addFloatingLoadAtLayout(kind: LoadKind.socket, pos: pos);
      expect(
          circuit(c, floatPlaced.panelId, floatPlaced.circuitId).length.meters,
          10);

      // The feeder way connectFeeder mints, too.
      final target = ctrl.addPanelAt(name: 'Yard', x: 0, y: 0);
      expect(ctrl.connectFeeder('mdp', target).connected, isTrue);
      final feeder =
          panel(c, 'mdp').circuits.firstWhere((w) => w.feedsPanelId == target);
      expect(feeder.length.meters, 10);

      // …and the one addFedPanelAt mints.
      final fed = ctrl.addFedPanelAt(fromPanelId: 'mdp', x: 0, y: 0);
      final fedWay =
          panel(c, 'mdp').circuits.firstWhere((w) => w.feedsPanelId == fed);
      expect(fedWay.length.meters, 10);
    });
  });

  group('creation intents return their new ids', () {
    test('addCircuit / addLoadAtLayout / addPanelAt / the floating pair', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);

      final wayId = ctrl.addCircuit('mdp', kind: LoadKind.socket);
      expect(panel(c, 'mdp').circuits.last.id, wayId);

      final panelId = ctrl.addPanelAt(name: 'Yard board', x: 1, y: 2);
      expect(proj(c).panels.last.id, panelId);

      final placed = ctrl.addLoadAtLayout('mdp',
          kind: LoadKind.lighting,
          pos: const LayoutPos(sheetId: 's1', floorIndex: 0, x: 1, y: 1));
      expect(panel(c, 'mdp').circuits.last.id, placed);

      final f1 = ctrl.addFloatingLoad(kind: LoadKind.socket, x: 0, y: 0);
      expect(proj(c).panels.last.id, f1.panelId);
      expect(proj(c).panels.last.circuits.single.id, f1.circuitId);

      final f2 = ctrl.addFloatingLoadAtLayout(
          kind: LoadKind.socket,
          pos: const LayoutPos(sheetId: 's1', floorIndex: 0, x: 5, y: 5));
      expect(proj(c).panels.last.id, f2.panelId);
      expect(proj(c).panels.last.circuits.single.id, f2.circuitId);
    });
  });

  group('default-name de-duplication', () {
    test('a repeated DEFAULT name gains the first free " N" suffix', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final base = loadDefaults[LoadKind.lighting]!.label;

      final a = ctrl.addCircuit('mdp', kind: LoadKind.lighting);
      final b = ctrl.addCircuit('mdp', kind: LoadKind.lighting);
      final d = ctrl.addCircuit('mdp', kind: LoadKind.lighting);
      expect(circuit(c, 'mdp', a).name, base);
      expect(circuit(c, 'mdp', b).name, '$base 2');
      expect(circuit(c, 'mdp', d).name, '$base 3');

      // addLoadAtLayout shares the rule (same board, same counter).
      final e = ctrl.addLoadAtLayout('mdp',
          kind: LoadKind.lighting,
          pos: const LayoutPos(sheetId: 's1', floorIndex: 0, x: 0, y: 0));
      expect(circuit(c, 'mdp', e).name, '$base 4');
    });

    test('an EXPLICIT caller-supplied name is used verbatim (never renamed)',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);

      final a = ctrl.addCircuit('mdp', kind: LoadKind.socket, name: 'Kitchen');
      final b = ctrl.addCircuit('mdp', kind: LoadKind.socket, name: 'Kitchen');
      expect(circuit(c, 'mdp', a).name, 'Kitchen');
      // The engineer typed it — de-duplicating would silently rewrite input.
      expect(circuit(c, 'mdp', b).name, 'Kitchen');
    });
  });

  group('setCircuit — per-field override set + clear', () {
    ProviderContainer seeded() {
      final c = ProviderContainer();
      c.read(electricalProjectProvider.notifier).setProject(
            const ElectricalProject(
              id: 'p',
              name: 'P',
              panels: [
                ElectricalPanel(
                  id: 'mdp',
                  name: 'MDP',
                  circuits: [
                    ElectricalCircuit(
                        id: 'c1',
                        name: 'Way',
                        loadKind: LoadKind.socket,
                        loadW: 2000,
                        phases: 1),
                  ],
                ),
              ],
            ),
          );
      return c;
    }

    test('breakerOverrideA', () {
      final c = seeded();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.setCircuit('mdp', 'c1', breakerOverrideA: const Current(32));
      expect(circuit(c, 'mdp', 'c1').breakerOverrideA!.amperes, 32);
      ctrl.setCircuit('mdp', 'c1', clearBreakerOverrideA: true);
      expect(circuit(c, 'mdp', 'c1').breakerOverrideA, isNull);
    });

    test('cableOverrideMm2', () {
      final c = seeded();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.setCircuit('mdp', 'c1', cableOverrideMm2: 6);
      expect(circuit(c, 'mdp', 'c1').cableOverrideMm2, 6);
      ctrl.setCircuit('mdp', 'c1', clearCableOverrideMm2: true);
      expect(circuit(c, 'mdp', 'c1').cableOverrideMm2, isNull);
    });

    test('groupingCountOverride', () {
      final c = seeded();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.setCircuit('mdp', 'c1', groupingCountOverride: 4);
      expect(circuit(c, 'mdp', 'c1').groupingCountOverride, 4);
      ctrl.setCircuit('mdp', 'c1', clearGroupingCountOverride: true);
      expect(circuit(c, 'mdp', 'c1').groupingCountOverride, isNull);
    });

    test('phaseOverride', () {
      final c = seeded();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.setCircuit('mdp', 'c1', phaseOverride: PhaseLine.l3);
      expect(circuit(c, 'mdp', 'c1').phaseOverride, PhaseLine.l3);
      ctrl.setCircuit('mdp', 'c1', clearPhaseOverride: true);
      expect(circuit(c, 'mdp', 'c1').phaseOverride, isNull);
    });

    test('laying', () {
      final c = seeded();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.setCircuit('mdp', 'c1', laying: 'ground');
      expect(circuit(c, 'mdp', 'c1').laying, 'ground');
      ctrl.setCircuit('mdp', 'c1', clearLaying: true);
      expect(circuit(c, 'mdp', 'c1').laying, isNull);
    });

    test('setting one override leaves the others untouched', () {
      final c = seeded();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.setCircuit('mdp', 'c1',
          breakerOverrideA: const Current(32),
          cableOverrideMm2: 6,
          groupingCountOverride: 4,
          phaseOverride: PhaseLine.l2,
          laying: 'air');
      // Clearing ONE must not sweep the rest.
      ctrl.setCircuit('mdp', 'c1', clearCableOverrideMm2: true);
      final w = circuit(c, 'mdp', 'c1');
      expect(w.cableOverrideMm2, isNull);
      expect(w.breakerOverrideA!.amperes, 32);
      expect(w.groupingCountOverride, 4);
      expect(w.phaseOverride, PhaseLine.l2);
      expect(w.laying, 'air');
    });
  });

  group('feederRefusalReason (pure query — the canvas hover/menu preview)', () {
    test('null when connectable, and the three hard refusals', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final before = proj(c);

      // Connectable: an unfed board.
      final yard = ctrl.addPanelAt(name: 'Yard', x: 0, y: 0);
      expect(ctrl.feederRefusalReason('mdp', yard), isNull);
      // Connectable under RE-PARENT semantics even though lp1 is already fed —
      // "already fed" is not a refusal, it is a move.
      expect(ctrl.feederRefusalReason(yard, 'lp1'), isNull);

      expect(ctrl.feederRefusalReason('mdp', 'mdp'),
          'A panel cannot feed itself.');
      expect(ctrl.feederRefusalReason('mdp', 'nope'), 'Panel not found.');
      expect(ctrl.feederRefusalReason('nope', 'mdp'), 'Panel not found.');
      // mdp already feeds lp1, so lp1 -> mdp would close a loop.
      expect(ctrl.feederRefusalReason('lp1', 'mdp'), contains('loop'));

      // PURE: nothing above mutated the project beyond the one addPanelAt.
      expect(proj(c).panels.length, before.panels.length + 1);
    });

    test('connectFeeder returns exactly the reason the query predicted', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      for (final pair in [
        ('mdp', 'mdp'),
        ('mdp', 'nope'),
        ('lp1', 'mdp'),
      ]) {
        final predicted = ctrl.feederRefusalReason(pair.$1, pair.$2);
        final actual = ctrl.connectFeeder(pair.$1, pair.$2);
        expect(actual.connected, isFalse);
        expect(actual.reason, predicted);
      }
    });
  });

  group('connectFeeder RE-PARENT', () {
    test('atomically moves the child: old way gone, one parent, ONE undo', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final hist = c.read(historyProvider.notifier);

      // lp1 starts fed by mdp-f1 on the MDP.
      expect(panel(c, 'lp1').fedByCircuitId, 'mdp-f1');
      final newParent = ctrl.addPanelAt(name: 'Riser board', tag: 'RB-1', x: 0, y: 0);

      final res = ctrl.connectFeeder(newParent, 'lp1');
      expect(res.connected, isTrue);
      // The caption names the board it was moved OFF (tag preferred over name).
      expect(res.reparentedFromLabel, 'MDP');

      // Exactly ONE way in the whole project targets lp1, and it lives on the
      // new parent — no torn two-parent state.
      final feeders = [
        for (final p in proj(c).panels)
          for (final w in p.circuits)
            if (w.feedsPanelId == 'lp1') (p.id, w.id),
      ];
      expect(feeders, hasLength(1));
      expect(feeders.single.$1, newParent);
      expect(panel(c, 'lp1').fedByCircuitId, feeders.single.$2);
      expect(panel(c, 'lp1').sourceType, PanelSource.feeder);
      // The MDP's original feeder way is gone.
      expect(panel(c, 'mdp').circuits.any((w) => w.id == 'mdp-f1'), isFalse);

      // ONE global undo puts the whole move back.
      hist.undo();
      expect(panel(c, 'lp1').fedByCircuitId, 'mdp-f1');
      expect(panel(c, 'mdp').circuits.any((w) => w.id == 'mdp-f1'), isTrue);
      expect(
          panel(c, newParent).circuits.where((w) => w.feedsPanelId == 'lp1'),
          isEmpty);
    });

    test('a plain connect of an UNFED board reports no reparentedFromLabel', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final yard = ctrl.addPanelAt(name: 'Yard', x: 0, y: 0);
      final res = ctrl.connectFeeder('mdp', yard);
      expect(res.connected, isTrue);
      expect(res.reparentedFromLabel, isNull);
    });

    test('a loop is STILL refused under re-parent semantics', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final before = proj(c);

      final res = ctrl.connectFeeder('lp1', 'mdp');
      expect(res.connected, isFalse);
      expect(res.reason, contains('loop'));
      // A refusal never mutates.
      expect(proj(c), same(before));
    });

    test('robust against a DESYNCED file: every way targeting the child is '
        'swept, not just the recorded back-pointer', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      // Two boards both claim to feed `child`, and the back-pointer names only
      // one of them — the shape a hand-edited / older-build document can carry.
      c.read(electricalProjectProvider.notifier).setProject(
            const ElectricalProject(
              id: 'p',
              name: 'P',
              panels: [
                ElectricalPanel(id: 'a', name: 'A', circuits: [
                  ElectricalCircuit(
                      id: 'a-f',
                      name: 'to child',
                      loadKind: LoadKind.feeder,
                      feedsPanelId: 'child'),
                ]),
                ElectricalPanel(id: 'b', name: 'B', circuits: [
                  ElectricalCircuit(
                      id: 'b-f',
                      name: 'to child',
                      loadKind: LoadKind.feeder,
                      feedsPanelId: 'child'),
                ]),
                ElectricalPanel(
                    id: 'child',
                    name: 'Child',
                    sourceType: PanelSource.feeder,
                    fedByCircuitId: 'a-f'),
                ElectricalPanel(id: 'new', name: 'New'),
              ],
            ),
          );
      final ctrl = c.read(electricalProjectProvider.notifier);
      expect(ctrl.connectFeeder('new', 'child').connected, isTrue);

      final feeders = [
        for (final p in proj(c).panels)
          for (final w in p.circuits)
            if (w.feedsPanelId == 'child') p.id,
      ];
      expect(feeders, ['new']); // BOTH stale claims removed.
      expect(panel(c, 'a').circuits, isEmpty);
      expect(panel(c, 'b').circuits, isEmpty);
    });

    test('record: false mutates without touching either undo timeline', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final hist = c.read(historyProvider.notifier);
      final yard = ctrl.addPanelAt(name: 'Yard', x: 0, y: 0);

      // The gesture-composition path: ONE snapshot up front, then a
      // record-free connect — so the whole drag collapses into a single step
      // instead of double-snapshotting.
      ctrl.pushUndoSnapshot();
      expect(ctrl.connectFeeder('mdp', yard, record: false).connected, isTrue);
      expect(panel(c, yard).sourceType, PanelSource.feeder);

      hist.undo(); // one step reverts the whole gesture
      expect(panel(c, yard).sourceType, PanelSource.utility);
      expect(panel(c, yard).fedByCircuitId, isNull);
    });
  });

  group('delete hygiene (sanitizeFeederTopology inside the same commit)', () {
    test('deleting a FEEDER way clears the child back-pointer', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final hist = c.read(historyProvider.notifier);

      ctrl.deleteCircuit('mdp', 'mdp-f1');
      final lp1 = panel(c, 'lp1');
      expect(lp1.fedByCircuitId, isNull);
      expect(lp1.sourceType, PanelSource.utility);

      // ONE undo restores both halves (way + back-pointer) together.
      hist.undo();
      expect(panel(c, 'mdp').circuits.any((w) => w.id == 'mdp-f1'), isTrue);
      expect(panel(c, 'lp1').fedByCircuitId, 'mdp-f1');
    });

    test('deleting a FED panel drops the parent way', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final hist = c.read(historyProvider.notifier);

      ctrl.deletePanel('lp1');
      expect(panel(c, 'mdp').circuits.any((w) => w.feedsPanelId == 'lp1'),
          isFalse);
      expect(panel(c, 'mdp').circuits.any((w) => w.id == 'mdp-f1'), isFalse);

      hist.undo();
      expect(proj(c).panels.any((p) => p.id == 'lp1'), isTrue);
      expect(panel(c, 'mdp').circuits.any((w) => w.id == 'mdp-f1'), isTrue);
    });

    test('deletePanels sweeps dangling feeders too (multi-select parity)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      c.read(electricalProjectProvider.notifier).deletePanels(['lp1']);
      expect(panel(c, 'mdp').circuits.any((w) => w.feedsPanelId == 'lp1'),
          isFalse);
    });

    test('deleteCircuit with an unknown id is a strict no-op (no phantom undo)',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final before = proj(c);
      c.read(electricalProjectProvider.notifier).deleteCircuit('mdp', 'nope');
      c.read(electricalProjectProvider.notifier).deleteCircuit('nope', 'c1');
      expect(proj(c), same(before));
      expect(c.read(historyProvider.notifier).canUndo, isFalse);
    });

    test('setProject repairs a desynced document on load, identity-preserving '
        'on a clean one', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      // Clean input loads verbatim (same instance — no phantom repair).
      final clean = sampleElectricalProject();
      ctrl.setProject(clean);
      expect(proj(c), same(clean));

      // A dangling back-pointer (the feeding way no longer exists) is cleared.
      ctrl.setProject(const ElectricalProject(
        id: 'p',
        name: 'P',
        panels: [
          ElectricalPanel(id: 'a', name: 'A'),
          ElectricalPanel(
              id: 'b',
              name: 'B',
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'ghost'),
        ],
      ));
      expect(panel(c, 'b').fedByCircuitId, isNull);
      expect(panel(c, 'b').sourceType, PanelSource.utility);
    });
  });

  group('duplicates are non-feeders', () {
    test('duplicateCircuit copies a feeder with a NULL target', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      c.read(electricalProjectProvider.notifier)
          .duplicateCircuit('mdp', 'mdp-f1');

      final copy = panel(c, 'mdp')
          .circuits
          .firstWhere((w) => w.name.endsWith('(copy)'));
      // Was the `''` sentinel — which `sanitizeFeederTopology` treats as an
      // invalid target and DELETES, so the copy used to evaporate on the next
      // delete/reload. A real null is a genuine non-feeder that survives.
      expect(copy.feedsPanelId, isNull);
      expect(panel(c, 'lp1').fedByCircuitId, 'mdp-f1'); // original untouched

      // Proof it survives the sanitizer: an unrelated delete keeps the copy.
      c.read(electricalProjectProvider.notifier)
          .deleteCircuit('mdp', 'mdp-c1');
      expect(
          panel(c, 'mdp').circuits.where((w) => w.name.endsWith('(copy)')),
          hasLength(1));
    });

    test('duplicatePanel copies every way with a NULL feeder target', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      c.read(electricalProjectProvider.notifier).duplicatePanel('mdp');

      final copy = proj(c).panels.last;
      expect(copy.name, contains('(copy)'));
      expect(copy.circuits.every((w) => w.feedsPanelId == null), isTrue);
      // The copy feeds nothing, so lp1 still has exactly one parent.
      final feeders = [
        for (final p in proj(c).panels)
          for (final w in p.circuits)
            if (w.feedsPanelId == 'lp1') p.id,
      ];
      expect(feeders, ['mdp']);
    });
  });

  group('addFloatingLoadAtLayout — the two position spaces never alias', () {
    test('REGRESSION: the stub board leaves its single-line x/y NULL', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);

      const pos = LayoutPos(sheetId: 's1', floorIndex: 2, x: 1234, y: 987);
      final ids = ctrl.addFloatingLoadAtLayout(kind: LoadKind.socket, pos: pos);
      final p = panel(c, ids.panelId);

      // The geo placement rides the CIRCUIT's loadPos …
      expect(p.circuits.single.loadPos, pos);
      // … and the abstract single-line coordinate stays unset (auto-layout).
      // `model.dart` is explicit that the two spaces "never alias"; copying
      // sheet pixels into x/y flung the board to a nonsense schematic spot.
      expect(p.x, isNull);
      expect(p.y, isNull);
      expect(p.layoutPos, isNull); // only the LOAD is placed, not the board
    });
  });

  group('panel templates', () {
    final lighting = panelTemplateById('lighting')!;

    test('addPanelAt(templateId) populates circuits + headroom in ONE undo step',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final hist = c.read(historyProvider.notifier);

      final id = ctrl.addPanelAt(
          name: 'Sub-panel 1', tag: 'SP-1', x: 0, y: 0, templateId: 'lighting');
      final p = panel(c, id);
      expect(p.circuits, hasLength(lighting.circuits.length));
      expect(p.circuits.map((w) => w.name).toList(),
          lighting.circuits.map((t) => t.name).toList());
      expect(p.headroom, isNotNull);
      expect(p.headroom!.sparePercentage, lighting.headroom!.sparePercentage);
      expect(p.headroom!.spareWays, lighting.headroom!.spareWays);
      // Creation defaults ride the template circuits too.
      final first = p.circuits.first;
      expect(first.length.meters, 10);
      expect(first.cosPhi, loadDefaults[LoadKind.lighting]!.cosPhi);
      expect(first.loadW, lighting.circuits.first.loadW);
      // The board sizes immediately.
      expect(c.read(electricalResultProvider).panels[id]!.circuits,
          hasLength(lighting.circuits.length));

      // ONE step: a single undo removes the whole populated board.
      hist.undo();
      expect(proj(c).panels, isEmpty);
    });

    test('applyPanelTemplate appends to an existing board, de-duping names, in '
        'ONE undo step', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final hist = c.read(historyProvider.notifier);

      final id = ctrl.addPanelAt(
          name: 'SP', x: 0, y: 0, templateId: 'lighting');
      final afterFirst = panel(c, id).circuits.length;

      ctrl.applyPanelTemplate(id, 'lighting');
      final names = panel(c, id).circuits.map((w) => w.name).toList();
      expect(names, hasLength(afterFirst * 2));
      // The second batch never repeats a name already on the schedule.
      expect(names.toSet(), hasLength(names.length));
      expect(names[afterFirst], '${lighting.circuits.first.name} 2');

      hist.undo();
      expect(panel(c, id).circuits, hasLength(afterFirst));
    });

    test('applyPanelTemplate keeps an explicit headroom the engineer set', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final id = ctrl.addPanelAt(name: 'SP', x: 0, y: 0);
      ctrl.setPanelHeadroom(
          id, const HeadroomSpec(sparePercentage: 50, spareWays: 6));
      ctrl.applyPanelTemplate(id, 'lighting');
      expect(panel(c, id).headroom!.sparePercentage, 50);
      expect(panel(c, id).headroom!.spareWays, 6);
    });

    test('an unknown template id, an unknown panel and the MEP board are no-ops',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.syncMepEquipment(const [
        ElectricalCircuit(
            id: 'mep-1',
            name: 'Pump',
            loadKind: LoadKind.pump,
            motorKw: 5.5,
            sourceEquipmentId: 'node-1'),
      ]);
      final before = proj(c);

      ctrl.applyPanelTemplate(kMepEquipmentPanelId, 'lighting'); // machine-owned
      ctrl.applyPanelTemplate('nope', 'lighting');
      final id = ctrl.addPanelAt(name: 'SP', x: 0, y: 0);
      ctrl.applyPanelTemplate(id, 'not-a-template');

      expect(panel(c, kMepEquipmentPanelId).circuits,
          hasLength(before.panels
              .firstWhere((p) => p.id == kMepEquipmentPanelId)
              .circuits
              .length));
      expect(panel(c, id).circuits, isEmpty);
    });
  });

  group('addFedPanelAt (one gesture = a fed, populated board)', () {
    test('mints the sub-panel, the feeder way and the back-pointer in ONE step',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final hist = c.read(historyProvider.notifier);
      final mdpWaysBefore = panel(c, 'mdp').circuits.length;

      final id = ctrl.addFedPanelAt(
          fromPanelId: 'mdp', x: 300, y: 120, templateId: 'power');
      final p = panel(c, id);

      // Named off the shared SP-N mint.
      expect(p.name, 'Sub-panel 1');
      expect(p.tag, 'SP-1');
      expect(p.x, 300);
      expect(p.y, 120);
      // Fed: the parent gained exactly one feeder way, and the child points back.
      expect(panel(c, 'mdp').circuits, hasLength(mdpWaysBefore + 1));
      final feeder =
          panel(c, 'mdp').circuits.firstWhere((w) => w.feedsPanelId == id);
      expect(p.sourceType, PanelSource.feeder);
      expect(p.fedByCircuitId, feeder.id);
      // Populated by the template.
      expect(p.circuits, hasLength(panelTemplateById('power')!.circuits.length));
      expect(p.headroom, isNotNull);
      // The engine sees it as a real sub-board on the tree.
      expect(c.read(electricalResultProvider).panels[id], isNotNull);

      // ONE undo removes board + feeder together.
      hist.undo();
      expect(proj(c).panels.any((x) => x.id == id), isFalse);
      expect(panel(c, 'mdp').circuits, hasLength(mdpWaysBefore));
    });

    test('phases: 1 mints a 1-phase 220 V board; null/3 a 3-phase 400 V one',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);

      final single = ctrl.addFedPanelAt(fromPanelId: 'mdp', x: 0, y: 0, phases: 1);
      expect(panel(c, single).system, ElectricalSystem.singlePhase);
      expect(panel(c, single).voltage.volts, 220);

      final three = ctrl.addFedPanelAt(fromPanelId: 'mdp', x: 0, y: 0);
      expect(panel(c, three).system, ElectricalSystem.threePhase);
      expect(panel(c, three).voltage.volts, 400);
    });

    test('an unknown source degrades to a plain utility board (never silent)',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);

      final id = ctrl.addFedPanelAt(fromPanelId: 'ghost', x: 5, y: 6);
      final p = panel(c, id);
      expect(p.sourceType, PanelSource.utility);
      expect(p.fedByCircuitId, isNull);
      // No stray feeder way was left on any board.
      expect(
        [
          for (final q in proj(c).panels)
            for (final w in q.circuits)
              if (w.feedsPanelId == id) w.id,
        ],
        isEmpty,
      );
    });
  });

  group('pinPanelPhases (the DURABLE phase story)', () {
    test('bulk-writes phaseOverride in one step and the solve honours it', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final hist = c.read(historyProvider.notifier);
      ctrl.setProject(const ElectricalProject(
        id: 'p',
        name: 'P',
        panels: [
          ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
            ElectricalCircuit(
                id: 'c1', name: 'A', loadW: 2000, cosPhi: 1, phases: 1),
            ElectricalCircuit(
                id: 'c2', name: 'B', loadW: 2000, cosPhi: 1, phases: 1),
          ]),
        ],
      ));

      ctrl.pinPanelPhases('mdp', {'c1': PhaseLine.l3, 'c2': PhaseLine.l3});
      expect(circuit(c, 'mdp', 'c1').phaseOverride, PhaseLine.l3);
      expect(circuit(c, 'mdp', 'c2').phaseOverride, PhaseLine.l3);
      // A pin is an INPUT — the balancer honours it verbatim (deliberately
      // accepting the imbalance the engineer asked for).
      final r = c.read(electricalResultProvider).panels['mdp']!;
      expect(r.circuits.every((x) => x.phase == PhaseAssignment.l3), isTrue);

      hist.undo(); // ONE step
      expect(circuit(c, 'mdp', 'c1').phaseOverride, isNull);
      expect(circuit(c, 'mdp', 'c2').phaseOverride, isNull);
    });

    test('an empty map, or one naming no way on the board, is a strict no-op',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      final before = proj(c);
      ctrl.pinPanelPhases('mdp', const {});
      ctrl.pinPanelPhases('mdp', {'ghost': PhaseLine.l1});
      expect(proj(c), same(before));
      expect(c.read(historyProvider.notifier).canUndo, isFalse);
    });
  });

  group('MEP Equipment first-sync auto-feed', () {
    ElectricalCircuit derived(String src) => ElectricalCircuit(
          id: 'mep-$src',
          name: 'Pump $src',
          loadKind: LoadKind.pump,
          loadW: 6000,
          motorKw: 5.5,
          sourceEquipmentId: src,
          flaOverrideA: const Current(10),
        );

    test('exactly ONE unfed board ⇒ the MEP board is created fed from it', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      // MDP (root) feeding LP-1 — one unfed board, unambiguous.
      seedSample(c);

      ctrl.syncMepEquipment([derived('node-1')]);
      final mep = panel(c, kMepEquipmentPanelId);
      expect(mep.sourceType, PanelSource.feeder);
      expect(mep.fedByCircuitId, isNotNull);
      final feeder = panel(c, 'mdp')
          .circuits
          .firstWhere((w) => w.feedsPanelId == kMepEquipmentPanelId);
      expect(feeder.id, mep.fedByCircuitId);
      expect(feeder.name, 'Feeder to MEP Equipment');
      expect(feeder.length.meters, 10);
      // It is a real sub-board on the solved tree now, not an orphan.
      expect(c.read(electricalResultProvider).panels[kMepEquipmentPanelId],
          isNotNull);
    });

    test('TWO unfed boards ⇒ ambiguous, so it stays utility-fed', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.setProject(const ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(id: 'a', name: 'A'),
        ElectricalPanel(id: 'b', name: 'B'),
      ]));

      ctrl.syncMepEquipment([derived('node-1')]);
      final mep = panel(c, kMepEquipmentPanelId);
      expect(mep.sourceType, PanelSource.utility);
      expect(mep.fedByCircuitId, isNull);
      expect(
        [
          for (final p in proj(c).panels)
            for (final w in p.circuits)
              if (w.feedsPanelId == kMepEquipmentPanelId) w.id,
        ],
        isEmpty,
      );
    });

    test('NO existing board ⇒ utility-fed (nothing to feed from)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.syncMepEquipment([derived('node-1')]);
      expect(panel(c, kMepEquipmentPanelId).sourceType, PanelSource.utility);
      expect(proj(c).panels, hasLength(1));
    });

    test('the auto-feed is UNDO-EXEMPT like the rest of the sync', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      expect(c.read(historyProvider.notifier).canUndo, isFalse);
      ctrl.syncMepEquipment([derived('node-1')]);
      expect(c.read(historyProvider.notifier).canUndo, isFalse);
    });

    test('a RE-SYNC never touches feeding — a hand-rewired feed survives', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.syncMepEquipment([derived('node-1')]);

      // The engineer moves the MEP board under a different board.
      final riser = ctrl.addPanelAt(name: 'Riser board', tag: 'RB-1', x: 0, y: 0);
      expect(ctrl.connectFeeder(riser, kMepEquipmentPanelId).connected, isTrue);
      final rewired = panel(c, kMepEquipmentPanelId).fedByCircuitId;
      expect(rewired, isNotNull);
      expect(panel(c, 'mdp').circuits
          .any((w) => w.feedsPanelId == kMepEquipmentPanelId), isFalse);

      // A plan change re-syncs the board's WAYS; the feed is untouched.
      ctrl.syncMepEquipment([derived('node-1'), derived('node-2')]);
      expect(panel(c, kMepEquipmentPanelId).circuits, hasLength(2));
      expect(panel(c, kMepEquipmentPanelId).fedByCircuitId, rewired);
      expect(
        panel(c, riser).circuits.where((w) =>
            w.feedsPanelId == kMepEquipmentPanelId),
        hasLength(1),
      );
    });

    test('removing the last derived way drops the board AND its feeder way', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      seedSample(c);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.syncMepEquipment([derived('node-1')]);
      expect(panel(c, 'mdp').circuits
          .any((w) => w.feedsPanelId == kMepEquipmentPanelId), isTrue);

      ctrl.syncMepEquipment(const []);
      expect(proj(c).panels.any((p) => p.id == kMepEquipmentPanelId), isFalse);
      // No dangling feeder pointing at a board that no longer exists.
      expect(panel(c, 'mdp').circuits
          .any((w) => w.feedsPanelId == kMepEquipmentPanelId), isFalse);
    });
  });

  group('phase-stability cache (session-only)', () {
    // Three single-phase ways on a 3-phase board whose currents are 3 : 2 : 1.
    // The greedy balancer lands them L1 / L2 / L3. Growing the SMALLEST way
    // 10x re-orders a from-scratch solve completely (the big way takes L1), so
    // this fixture makes the stickiness observable rather than vacuous.
    ElectricalProject fixture({required double c3LoadW}) => ElectricalProject(
          id: 'p',
          name: 'P',
          panels: [
            ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
              const ElectricalCircuit(
                  id: 'c1', name: 'A', loadW: 3000, cosPhi: 1, phases: 1),
              const ElectricalCircuit(
                  id: 'c2', name: 'B', loadW: 2000, cosPhi: 1, phases: 1),
              ElectricalCircuit(
                  id: 'c3', name: 'C', loadW: c3LoadW, cosPhi: 1, phases: 1),
            ]),
          ],
        );

    Map<String, PhaseAssignment> phasesOf(ElectricalSystemResult r) => {
          for (final x in r.panels['mdp']!.circuits) x.circuitId: x.phase,
        };

    test('an unchanged way KEEPS its line when a neighbour is edited', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.setProject(fixture(c3LoadW: 1000));

      final first = phasesOf(c.read(electricalResultProvider));
      // The cache captured that solve.
      expect(c.read(phasePriorCacheProvider).prior['mdp'], first);

      // Grow c3 ten-fold — a genuine re-balance opportunity.
      ctrl.setCircuit('mdp', 'c3', loadW: 10000);
      final second = phasesOf(c.read(electricalResultProvider));

      // STICKINESS: every circuit keeps the line the previous solve gave it,
      // so an installed board is not re-labelled behind the engineer's back.
      expect(second, first);

      // …and this is NOT vacuous: a from-scratch solve of the SAME project
      // (no prior, the engine default) reassigns at least one way.
      final fresh = phasesOf(
          computeSystem(const PuilProfile(), proj(c)));
      expect(fresh, isNot(second));
    });

    test('the cache DAMPS churn, it does not LOCK: a gain above the threshold '
        'still re-labels', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(electricalProjectProvider.notifier);
      ctrl.setProject(fixture(c3LoadW: 1000));
      final before = phasesOf(c.read(electricalResultProvider));

      // A big NEW way has no prior entry, so the greedy places it freely — and
      // the resulting imbalance is worth more than kPhaseStickinessA to fix, so
      // a seeded way genuinely moves rather than being frozen in place.
      final added = ctrl.addCircuit('mdp',
          kind: LoadKind.general, name: 'New', loadW: 6000, phases: 1);
      final after = phasesOf(c.read(electricalResultProvider));

      expect(after[added], isNot(PhaseAssignment.threePhase)); // it got a line
      final moved = [
        for (final id in before.keys)
          if (after[id] != before[id]) id,
      ];
      expect(moved, isNotEmpty,
          reason: 'a spread gain above kPhaseStickinessA must still be taken');
    });

    test('the cache does NOT leak across containers', () {
      final a = ProviderContainer();
      addTearDown(a.dispose);
      final b = ProviderContainer();
      addTearDown(b.dispose);

      // Container A builds a prior, then mutates → its solve is STICKY.
      a.read(electricalProjectProvider.notifier).setProject(fixture(c3LoadW: 1000));
      a.read(electricalResultProvider);
      a.read(electricalProjectProvider.notifier)
          .setCircuit('mdp', 'c3', loadW: 10000);
      final sticky = phasesOf(a.read(electricalResultProvider));

      // Container B loads the SAME end-state cold → it must solve FRESH.
      b.read(electricalProjectProvider.notifier).setProject(fixture(c3LoadW: 10000));
      final cold = phasesOf(b.read(electricalResultProvider));
      final fresh = phasesOf(
          computeSystem(const PuilProfile(), b.read(electricalProjectProvider)));

      expect(cold, fresh);
      expect(cold, isNot(sticky)); // no cross-container bleed
      expect(a.read(phasePriorCacheProvider),
          isNot(same(b.read(phasePriorCacheProvider))));
    });
  });
}
