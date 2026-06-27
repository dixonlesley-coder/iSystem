/// An OpenAI provider for the iSystem copilot, behind the same injectable
/// [AiClient] interface as [AnthropicAiClient]. It calls the OpenAI
/// chat-completions API with the command registry mapped into OpenAI's
/// function-tool shape and decodes the returned `tool_calls` into an [AiPlan].
/// Offline-graceful exactly like the Anthropic client: an empty key ⇒
/// [AiDisabled]; any network/API failure ⇒ a TYPED [AiError] — it never throws.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_client.dart';
import 'commands.dart';

/// Calls the OpenAI chat-completions API with the command registry as
/// function tools and decodes the returned `tool_calls` into an [AiPlan].
class OpenAiAiClient implements AiClient {
  final http.Client _http;
  final Duration timeout;

  OpenAiAiClient({http.Client? httpClient, this.timeout = const Duration(seconds: 30)})
      : _http = httpClient ?? http.Client();

  static const _endpoint = 'https://api.openai.com/v1/chat/completions';

  static const _systemPrompt =
      'You are a design copilot embedded in iSystem, an offline MEP (mechanical/'
      'electrical/plumbing) CAD app for Indonesian SNI/PUIL buildings. The '
      'engineer selects a room or floor and asks you to design or change it. '
      'Use the provided tools to PLACE nodes, draw runs, and auto-place a room\'s '
      'air terminals; the app auto-sizes everything after you place it. Prefer '
      'a small number of precise tool calls. Coordinates are sheet pixels. If '
      'you only have advice, call the suggest tool. Keep any prose brief.';

  @override
  Future<AiResult> proposePlan(AiRequest request) async {
    if (request.apiKey.trim().isEmpty) {
      return const AiDisabled(
          'Add your OpenAI API key in Preferences to enable the copilot.');
    }
    final body = jsonEncode({
      'model': request.model,
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        {
          'role': 'user',
          'content': request.contextSummary.isEmpty
              ? request.userText
              : '${request.contextSummary}\n\nRequest: ${request.userText}',
        },
      ],
      'tools': openAiToolsFromRegistry(),
      'tool_choice': 'auto',
    });
    http.Response resp;
    try {
      resp = await _http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'content-type': 'application/json',
              'Authorization': 'Bearer ${request.apiKey.trim()}',
            },
            body: body,
          )
          .timeout(timeout);
    } on TimeoutException {
      return const AiError('OpenAI request timed out. Check your connection.');
    } catch (e) {
      return AiError('Could not reach OpenAI (offline?). $e');
    }
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      return const AiError('OpenAI rejected the API key (check Preferences).');
    }
    if (resp.statusCode != 200) {
      return AiError('OpenAI API error (${resp.statusCode}).');
    }
    return parseOpenAiResponse(resp.body);
  }

  /// Map the Anthropic-shaped registry (`{name, description, input_schema}`)
  /// into OpenAI's function-tool shape (`{type, function:{name, description,
  /// parameters}}`). Pure — no network — so it is unit-testable.
  static List<Map<String, dynamic>> openAiToolsFromRegistry() {
    return [
      for (final tool in aiToolSchemas())
        {
          'type': 'function',
          'function': {
            'name': tool['name'],
            'description': tool['description'],
            'parameters': tool['input_schema'],
          },
        },
    ];
  }

  /// Decode a 200 chat-completions response into an [AiPlan]: each entry in
  /// `choices[0].message.tool_calls` becomes an [AiCommand] (its `arguments`
  /// string is itself JSON), and `message.content` is the rationale. Malformed
  /// JSON ⇒ [AiError].
  static AiResult parseOpenAiResponse(String responseBody) {
    Map<dynamic, dynamic> json;
    try {
      json = jsonDecode(responseBody) as Map<dynamic, dynamic>;
    } catch (_) {
      return const AiError('OpenAI returned a malformed response.');
    }
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) {
      return const AiError('OpenAI returned no choices.');
    }
    final first = choices.first;
    if (first is! Map) return const AiError('OpenAI returned no message.');
    final message = first['message'];
    if (message is! Map) return const AiError('OpenAI returned no message.');

    final commands = <AiCommand>[];
    final toolCalls = message['tool_calls'];
    if (toolCalls is List) {
      for (final call in toolCalls) {
        if (call is! Map) continue;
        final fn = call['function'];
        if (fn is! Map) continue;
        final name = fn['name'];
        final argsRaw = fn['arguments'];
        if (name is! String || argsRaw is! String) continue;
        Map<dynamic, dynamic> args;
        try {
          final decoded = jsonDecode(argsRaw);
          if (decoded is! Map) continue;
          args = decoded;
        } catch (_) {
          continue;
        }
        final cmd = AiCommand.fromJson(name, args);
        if (cmd != null) commands.add(cmd);
      }
    }
    final content = message['content'];
    final rationale = content is String ? content.trim() : '';
    return AiOk(AiPlan(commands: commands, rationale: rationale));
  }
}
