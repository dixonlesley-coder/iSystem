/// A GLM (Zhipu AI) provider for the iSystem copilot, behind the same injectable
/// [AiClient] interface as [AnthropicAiClient] / [OpenAiAiClient]. GLM's v4
/// chat-completions endpoint is OpenAI-compatible (function-tools + `tool_calls`),
/// so this reuses [OpenAiAiClient]'s pure helpers (`openAiToolsFromRegistry` /
/// `parseOpenAiResponse`) and only swaps the endpoint, auth, and system prompt.
/// Offline-graceful exactly like the others: an empty key ⇒ [AiDisabled]; any
/// network/API failure ⇒ a TYPED [AiError] — it never throws.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_client.dart';
import 'openai_client.dart';

/// Calls the GLM (Zhipu) chat-completions API with the command registry mapped
/// to OpenAI-style function tools and decodes the returned `tool_calls` into an
/// [AiPlan].
class GlmAiClient implements AiClient {
  final http.Client _http;
  final Duration timeout;

  GlmAiClient(
      {http.Client? httpClient, this.timeout = const Duration(seconds: 30)})
      : _http = httpClient ?? http.Client();

  static const _endpoint =
      'https://open.bigmodel.cn/api/paas/v4/chat/completions';

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
          'Add your GLM (Zhipu) API key in Preferences to enable the copilot.');
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
      // GLM's v4 API reuses OpenAI's function-tool shape verbatim.
      'tools': OpenAiAiClient.openAiToolsFromRegistry(),
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
      return const AiError('GLM request timed out. Check your connection.');
    } catch (e) {
      return AiError('Could not reach GLM (offline?). $e');
    }
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      return const AiError('GLM rejected the API key (check Preferences).');
    }
    if (resp.statusCode != 200) {
      return AiError('GLM API error (${resp.statusCode}).');
    }
    // Identical response envelope to OpenAI — reuse the pure parser.
    return OpenAiAiClient.parseOpenAiResponse(resp.body);
  }
}
