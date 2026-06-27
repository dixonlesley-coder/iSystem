import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ai/ai_client.dart';
import 'package:mechx/ai/commands.dart';
import 'package:mechx/ai/openai_client.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/ai_copilot_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';

void main() {
  group('AiCommand JSON', () {
    test('round-trips a placeComponent command', () {
      const c = AiCommand(
        kind: AiCommandKind.placeComponent,
        sheetId: 's1',
        floor: 0,
        x: 100,
        y: 150,
        component: 'pump',
      );
      final back = AiCommand.fromJson('placeComponent', c.toJson())!;
      expect(back.kind, AiCommandKind.placeComponent);
      expect(back.sheetId, 's1');
      expect(back.x, 100);
      expect(back.y, 150);
      expect(back.component, 'pump');
    });

    test('an unknown kind decodes to null (hallucination guard)', () {
      expect(AiCommand.fromJson('nukeEverything', const {}), isNull);
    });

    test('preview is human-readable', () {
      const c = AiCommand(
          kind: AiCommandKind.autoPlaceRoomTerminals, roomId: 'r1');
      expect(c.preview, contains('r1'));
    });

    test('tool schemas cover every mutating command kind', () {
      final names = aiToolSchemas().map((t) => t['name']).toSet();
      expect(names, contains('placeComponent'));
      expect(names, contains('autoPlaceRoomTerminals'));
      expect(names, contains('suggest'));
    });
  });

  group('CopilotController loop (offline, fake client)', () {
    ProviderContainer withClient(AiClient client) {
      final c = ProviderContainer(
        overrides: [aiClientProvider.overrideWithValue(client)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('no API key → disabled message surfaces as error phase', () async {
      // Real client, no key → AiDisabled.
      final c = withClient(AnthropicAiClient());
      await c.read(copilotProvider.notifier).ask('design this room');
      final st = c.read(copilotProvider);
      expect(st.phase, CopilotPhase.error);
      expect(st.message, isNotNull);
      expect(c.read(copilotEnabledProvider), isFalse);
    });

    test('a proposed plan is NOT applied until applyPlan()', () async {
      final c = withClient(FakeAiClient((_) => const AiOk(AiPlan(commands: [
            AiCommand(
              kind: AiCommandKind.placeComponent,
              sheetId: 's1',
              floor: 0,
              x: 40,
              y: 60,
              component: 'pump',
            ),
          ], rationale: 'Add a supply pump.'))));

      await c.read(copilotProvider.notifier).ask('add a pump');
      // Proposed, but the network is still empty.
      expect(c.read(copilotProvider).phase, CopilotPhase.proposed);
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);

      // Apply → the node lands, one undo step, and the loop returns to idle.
      c.read(copilotProvider.notifier).applyPlan();
      final net = c.read(networkControllerProvider).network;
      expect(net.nodes.length, 1);
      expect(net.nodes.single.component?.name, 'pump');
      expect(c.read(copilotProvider).phase, CopilotPhase.idle);

      // Each applied command is undoable.
      c.read(networkControllerProvider.notifier).undo();
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
    });

    test('discard drops the plan, applies nothing', () async {
      final c = withClient(FakeAiClient((_) => const AiOk(AiPlan(commands: [
            AiCommand(
              kind: AiCommandKind.placeTerminal,
              sheetId: 's1',
              x: 10,
              y: 10,
            ),
          ]))));
      await c.read(copilotProvider.notifier).ask('add a terminal');
      c.read(copilotProvider.notifier).discard();
      expect(c.read(copilotProvider).phase, CopilotPhase.idle);
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
    });

    test('an empty plan is reported, not applied', () async {
      final c = withClient(
          FakeAiClient((_) => const AiOk(AiPlan(commands: [], rationale: 'No change needed.'))));
      await c.read(copilotProvider.notifier).ask('hi');
      expect(c.read(copilotProvider).phase, CopilotPhase.error);
      expect(c.read(copilotProvider).message, contains('No change'));
    });

    test('an empty prompt is a no-op (stays idle)', () async {
      final c = withClient(FakeAiClient((_) => const AiError('should not run')));
      await c.read(copilotProvider.notifier).ask('   ');
      expect(c.read(copilotProvider).phase, CopilotPhase.idle);
    });
  });

  group('DesignSettings persistence', () {
    test('API key + model round-trip', () {
      const s = DesignSettings(
          anthropicApiKey: 'sk-ant-test', aiModel: 'claude-sonnet-4-6');
      final back = DesignSettings.fromJson(s.toJson());
      expect(back.anthropicApiKey, 'sk-ant-test');
      expect(back.aiModel, 'claude-sonnet-4-6');
    });

    test('an older file (no AI keys) loads with safe defaults', () {
      final back = DesignSettings.fromJson(const {'occupancy': 'private'});
      expect(back.anthropicApiKey, '');
      expect(back.aiModel, 'claude-sonnet-4-6');
      // No provider key on an older file → Anthropic (the primary).
      expect(back.aiProvider, 'anthropic');
    });

    test('aiProvider round-trips; unknown falls back to anthropic', () {
      const s = DesignSettings(aiProvider: 'openai');
      expect(DesignSettings.fromJson(s.toJson()).aiProvider, 'openai');
      // A hand-edited / unknown value is tolerated → anthropic.
      expect(
        DesignSettings.fromJson(const {'aiProvider': 'gemini'}).aiProvider,
        'anthropic',
      );
    });
  });

  group('Provider selection', () {
    test('aiClientProvider resolves the chosen backend', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      // Default → Anthropic.
      expect(c.read(aiProviderProvider), AiProviderKind.anthropic);
      expect(c.read(aiClientProvider), isA<AnthropicAiClient>());
      // Switch → OpenAI client.
      c.read(aiProviderProvider.notifier).set(AiProviderKind.openai);
      expect(c.read(aiClientProvider), isA<OpenAiAiClient>());
    });

    test('aiProviderFromName is tolerant', () {
      expect(aiProviderFromName('openai'), AiProviderKind.openai);
      expect(aiProviderFromName('anthropic'), AiProviderKind.anthropic);
      expect(aiProviderFromName(null), AiProviderKind.anthropic);
      expect(aiProviderFromName('mystery'), AiProviderKind.anthropic);
    });

    test('defaultModelForProvider gives a family-correct default', () {
      expect(defaultModelForProvider(AiProviderKind.anthropic),
          startsWith('claude'));
      expect(defaultModelForProvider(AiProviderKind.openai), startsWith('gpt'));
    });
  });
}
