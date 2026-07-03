// Wave-5 coverage for the solved-duty MEP→E bridge (G1) and the hardened
// copilot loop (I5) — context frame, command validation, honest apply report.
// All offline via FakeAiClient + a bare ProviderContainer (no key, no network).
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ai/ai_client.dart';
import 'package:mechx/ai/commands.dart';
import 'package:mechx/store/ai_copilot_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx_engine/electrical/load_list.dart';

void main() {
  // designStandpipe / duty providers touch no platform channels, but the golden
  // fonts loader isn't needed here — ensure a binding for any widget-free deps.
  WidgetsFlutterBinding.ensureInitialized();

  group('G1 — the solved-duty MEP → electrical bridge', () {
    test('mepAutoFeedCircuitsProvider gates the solved duties behind the opt-in',
        () {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      // Default OFF: the auto-feed is placed-only (nothing placed ⇒ empty), so
      // an untouched project is byte-identical to the prior wiring.
      final placed = c.read(placedEquipmentCircuitsProvider);
      expect(c.read(mepAutoFeedCircuitsProvider), same(placed));

      // Opt in: now it carries the solved DUTY circuits too (the full feed).
      c.read(mepDutyFeedEnabledProvider.notifier).enable();
      final full = c.read(mepAutoFeedCircuitsProvider);
      expect(full.length, greaterThan(placed.length));
      expect(full, same(c.read(mepEquipmentCircuitsProvider)));
    });

    test('the always-on fire-pump duty maps to a LIFE-SAFETY source circuit', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      final loads = c.read(mepEquipmentLoadsProvider);
      expect(loads.any((l) => l.source == MepLoadSource.firePump), isTrue,
          reason: 'a standpipe fire pump is derived from the building height');

      final circuits = c.read(mepEquipmentCircuitsProvider);
      final fire =
          circuits.where((cc) => cc.sourceEquipmentId == 'fire-pump').firstOrNull;
      expect(fire, isNotNull);
      expect(fire!.lifeSafety, isTrue);
    });

    test('opting in folds the duty into the MEP panel; opting out removes it',
        () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      // Keep the electrical project (and its reactive sync) alive.
      final sub = c.listen(electricalProjectProvider, (_, _) {},
          fireImmediately: true);
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        c.read(electricalProjectProvider).panels
            .where((p) => p.id == kMepEquipmentPanelId),
        isEmpty,
      );

      c.read(mepDutyFeedEnabledProvider.notifier).enable();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final mep = c.read(electricalProjectProvider).panels
          .where((p) => p.id == kMepEquipmentPanelId)
          .firstOrNull;
      expect(mep, isNotNull,
          reason: 'the solved duties should fold into an MEP panel');
      expect(mep!.circuits, isNotEmpty);

      c.read(mepDutyFeedEnabledProvider.notifier).disable();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        c.read(electricalProjectProvider).panels
            .where((p) => p.id == kMepEquipmentPanelId),
        isEmpty,
      );
    });
  });

  group('I5 — copilot context, validation and honest reporting', () {
    ProviderContainer withPlan(AiPlan plan, {void Function(AiRequest)? onAsk}) {
      final c = ProviderContainer(overrides: [
        aiClientProvider.overrideWithValue(FakeAiClient((req) {
          onAsk?.call(req);
          return AiOk(plan);
        })),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('the request carries the placement FRAME (sheet id + extent + floors)',
        () async {
      String? captured;
      final c = withPlan(const AiPlan(commands: []),
          onAsk: (req) => captured = req.contextSummary);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();

      await c.read(copilotProvider.notifier).ask('what can you do?');
      expect(captured, isNotNull);
      expect(captured, contains('active sheet: s1'));
      expect(captured, contains('extent'));
      expect(captured, contains('floors'));
      expect(captured, contains('never invent a sheet id'));
    });

    test('applyPlan validates — a hallucinated sheet / component is SKIPPED',
        () async {
      final c = withPlan(const AiPlan(commands: [
        // Valid: a terminal on the real ground-floor sheet.
        AiCommand(
            kind: AiCommandKind.placeTerminal,
            sheetId: 's1',
            floor: 0,
            x: 100,
            y: 100),
        // Hallucinated sheet id → rejected (would render on no sheet).
        AiCommand(
            kind: AiCommandKind.placeComponent,
            sheetId: 'GHOST',
            floor: 0,
            x: 200,
            y: 200,
            component: 'pump'),
        // Real sheet, unknown component name → rejected.
        AiCommand(
            kind: AiCommandKind.placeComponent,
            sheetId: 's1',
            floor: 0,
            x: 300,
            y: 300,
            component: 'flux_capacitor'),
      ], rationale: 'a mix'));
      // Sheets loaded so the membership check is active.
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();

      await c.read(copilotProvider.notifier).ask('do stuff');
      expect(c.read(copilotProvider).phase, CopilotPhase.proposed);

      final outcome = c.read(copilotProvider.notifier).applyPlan();
      expect(outcome.proposed, 3);
      expect(outcome.applied, 1);
      expect(outcome.skippedCount, 2);
      // Only the valid command landed; the two hallucinated ones did not.
      expect(c.read(networkControllerProvider).network.nodes.length, 1);
      // A partial apply is reported (not silently dropped).
      expect(c.read(copilotProvider).phase, CopilotPhase.applied);
      expect(c.read(copilotProvider).message, contains('Applied 1 of 3'));
    });

    test('a placement is REJECTED when no sheets are loaded (no orphan node)',
        () async {
      final c = withPlan(const AiPlan(commands: [
        AiCommand(
            kind: AiCommandKind.placeTerminal,
            sheetId: 's1',
            floor: 0,
            x: 100,
            y: 100),
      ], rationale: 'place on a sheet that does not exist yet'));
      // Deliberately DO NOT load any sheets — there is nowhere to place, so the
      // command must be skipped rather than fabricated onto an invented sheet id
      // (an orphan the canvas can't show yet the BOM/solve would count).
      await c.read(copilotProvider.notifier).ask('do stuff');
      final outcome = c.read(copilotProvider.notifier).applyPlan();
      expect(outcome.applied, 0);
      expect(outcome.skippedCount, 1);
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
    });

    test('a fully-valid multi-command plan applies all and each is undoable',
        () async {
      final c = withPlan(const AiPlan(commands: [
        AiCommand(
            kind: AiCommandKind.placeTerminal,
            sheetId: 's1',
            floor: 0,
            x: 10,
            y: 10),
        AiCommand(
            kind: AiCommandKind.placeTerminal,
            sheetId: 's1',
            floor: 0,
            x: 20,
            y: 20),
      ]));
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();

      await c.read(copilotProvider.notifier).ask('two terminals');
      final outcome = c.read(copilotProvider.notifier).applyPlan();
      expect(outcome.applied, 2);
      expect(outcome.allApplied, isTrue);
      // A clean apply returns to idle (the drawing is the feedback).
      expect(c.read(copilotProvider).phase, CopilotPhase.idle);
      expect(c.read(networkControllerProvider).network.nodes.length, 2);

      // Per-command undo granularity: one Ctrl+Z peels one placement.
      c.read(historyProvider.notifier).undo();
      expect(c.read(networkControllerProvider).network.nodes.length, 1);
      c.read(historyProvider.notifier).undo();
      expect(c.read(networkControllerProvider).network.nodes.length, 0);
    });
  });
}
