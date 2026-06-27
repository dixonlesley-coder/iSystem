import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ai/ai_client.dart';
import 'package:mechx/ai/commands.dart';
import 'package:mechx/ai/openai_client.dart';

void main() {
  group('openAiToolsFromRegistry', () {
    test('wraps every registry tool in OpenAI function shape', () {
      final tools = OpenAiAiClient.openAiToolsFromRegistry();
      final registryNames = aiToolSchemas().map((t) => t['name']).toSet();

      // Same count + shape as the Anthropic registry.
      expect(tools.length, aiToolSchemas().length);
      for (final tool in tools) {
        expect(tool['type'], 'function');
        final fn = tool['function'] as Map;
        expect(fn['name'], isA<String>());
        expect(fn['description'], isA<String>());
        // input_schema → parameters, carried verbatim.
        expect(fn['parameters'], isA<Map>());
      }

      final names =
          tools.map((t) => (t['function'] as Map)['name']).toSet();
      expect(names, registryNames);
      expect(names, contains('placeComponent'));
      expect(names, contains('autoPlaceRoomTerminals'));
      expect(names, contains('suggest'));
    });

    test('parameters mirror the registry input_schema for placeComponent', () {
      final tools = OpenAiAiClient.openAiToolsFromRegistry();
      final place = tools.firstWhere(
          (t) => (t['function'] as Map)['name'] == 'placeComponent');
      final params = (place['function'] as Map)['parameters'] as Map;
      final source = aiToolSchemas()
          .firstWhere((t) => t['name'] == 'placeComponent')['input_schema'];
      expect(params, source);
    });
  });

  group('parseOpenAiResponse', () {
    test('decodes a tool_call + rationale into an AiOk plan', () {
      const body = '''
{
  "choices": [
    {
      "message": {
        "content": "Adding a supply pump.",
        "tool_calls": [
          {
            "id": "call_1",
            "type": "function",
            "function": {
              "name": "placeComponent",
              "arguments": "{\\"sheetId\\":\\"s1\\",\\"floor\\":0,\\"x\\":120,\\"y\\":80,\\"component\\":\\"pump\\"}"
            }
          }
        ]
      }
    }
  ]
}
''';
      final result = OpenAiAiClient.parseOpenAiResponse(body);
      expect(result, isA<AiOk>());
      final plan = (result as AiOk).plan;
      expect(plan.rationale, 'Adding a supply pump.');
      expect(plan.commands.length, 1);
      final cmd = plan.commands.single;
      expect(cmd.kind, AiCommandKind.placeComponent);
      expect(cmd.sheetId, 's1');
      expect(cmd.floor, 0);
      expect(cmd.x, 120);
      expect(cmd.y, 80);
      expect(cmd.component, 'pump');
    });

    test('a null content yields an empty rationale', () {
      const body = '''
{
  "choices": [
    {"message": {"content": null, "tool_calls": []}}
  ]
}
''';
      final result = OpenAiAiClient.parseOpenAiResponse(body);
      expect(result, isA<AiOk>());
      final plan = (result as AiOk).plan;
      expect(plan.rationale, '');
      expect(plan.commands, isEmpty);
    });

    test('malformed JSON yields an AiError', () {
      final result = OpenAiAiClient.parseOpenAiResponse('not json at all {');
      expect(result, isA<AiError>());
    });
  });

  group('OpenAiAiClient.proposePlan', () {
    test('empty API key is disabled (no network)', () async {
      final result = await OpenAiAiClient().proposePlan(
        const AiRequest(userText: 'x', apiKey: '', model: 'gpt-4o'),
      );
      expect(result, isA<AiDisabled>());
    });
  });
}
