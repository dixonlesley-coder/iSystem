/// The injectable Claude-copilot client. The real [AnthropicAiClient] calls the
/// Anthropic Messages API (tool-use, BYO key); [FakeAiClient] returns canned
/// plans so the registry + plan loop are unit-testable offline with no key and
/// no network. All failures are TYPED ([AiResult]) — the copilot never throws.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'commands.dart';

/// A compact, model-facing snapshot of what the engineer is working on. Kept
/// small (counts + the selected room/floor) so the prompt stays well within the
/// token budget even for a large network.
class AiRequest {
  final String userText;
  final String apiKey;
  final String model;

  /// A short human/JSON description of the current selection + network the model
  /// reasons over (built by the copilot store from live state).
  final String contextSummary;

  const AiRequest({
    required this.userText,
    required this.apiKey,
    required this.model,
    this.contextSummary = '',
  });
}

/// The typed outcome of a copilot request — never an exception.
sealed class AiResult {
  const AiResult();
}

/// A proposed plan, ready for preview → confirm → apply.
class AiOk extends AiResult {
  final AiPlan plan;
  const AiOk(this.plan);
}

/// The copilot is unavailable by configuration (no API key) — not an error.
class AiDisabled extends AiResult {
  final String message;
  const AiDisabled(this.message);
}

/// A request failed (network down, bad key, API error, malformed response).
class AiError extends AiResult {
  final String message;
  const AiError(this.message);
}

/// The copilot client contract. Injected via a Riverpod provider so tests swap
/// in [FakeAiClient].
abstract interface class AiClient {
  Future<AiResult> proposePlan(AiRequest request);
}

/// Which LLM backend the copilot talks to. Anthropic is the primary; OpenAI and
/// GLM (Zhipu) are backups so an engineer with only one of those keys can still
/// use the copilot. All three speak the same tool-call shape behind [AiClient].
enum AiProviderKind { anthropic, openai, glm }

/// The default model for each provider — used when no explicit model is set, and
/// to re-seed the model field when the engineer switches providers so a model
/// string from the wrong family is never sent (e.g. a `claude-*` id to OpenAI).
const String kDefaultAnthropicModel = 'claude-sonnet-4-6';
const String kDefaultOpenAiModel = 'gpt-5.2';
const String kDefaultGlmModel = 'glm-4.6';

String defaultModelForProvider(AiProviderKind provider) => switch (provider) {
      AiProviderKind.anthropic => kDefaultAnthropicModel,
      AiProviderKind.openai => kDefaultOpenAiModel,
      AiProviderKind.glm => kDefaultGlmModel,
    };

/// A selectable model in the Preferences dropdown — the wire `id` plus a short
/// human label.
class AiModelOption {
  final String id;
  final String label;
  const AiModelOption(this.id, this.label);
}

/// The models offered per provider, newest/most-capable first. The default for
/// each provider (`defaultModelForProvider`) is the first entry. These are the
/// wire ids sent verbatim to the API; the label is display-only.
const List<AiModelOption> kAnthropicModels = [
  AiModelOption('claude-fable-5', 'Claude Fable 5'),
  AiModelOption('claude-opus-4-8', 'Claude Opus 4.8'),
  AiModelOption('claude-opus-4-7', 'Claude Opus 4.7'),
  AiModelOption('claude-sonnet-4-6', 'Claude Sonnet 4.6'),
  AiModelOption('claude-haiku-4-5', 'Claude Haiku 4.5'),
];

const List<AiModelOption> kOpenAiModels = [
  AiModelOption('gpt-5.5', 'GPT-5.5'),
  AiModelOption('gpt-5.5-pro', 'GPT-5.5 Pro'),
  AiModelOption('gpt-5.2', 'GPT-5.2'),
  AiModelOption('gpt-5.4-mini', 'GPT-5.4 mini'),
  AiModelOption('gpt-5.4-nano', 'GPT-5.4 nano'),
];

const List<AiModelOption> kGlmModels = [
  AiModelOption('glm-5.2', 'GLM-5.2'),
  AiModelOption('glm-4.6', 'GLM-4.6'),
  AiModelOption('glm-4.5', 'GLM-4.5'),
  AiModelOption('glm-4.5-air', 'GLM-4.5 Air'),
];

List<AiModelOption> modelsForProvider(AiProviderKind provider) =>
    switch (provider) {
      AiProviderKind.anthropic => kAnthropicModels,
      AiProviderKind.openai => kOpenAiModels,
      AiProviderKind.glm => kGlmModels,
    };

/// A display label for a model id — the catalog label if known, else the raw id
/// (so a hand-edited custom model still shows something sensible).
String modelLabelFor(AiProviderKind provider, String id) {
  for (final m in modelsForProvider(provider)) {
    if (m.id == id) return m.label;
  }
  return id;
}

/// Parse a persisted/free-form provider string, tolerant of unknown values
/// (anything unrecognised falls back to Anthropic — the primary).
AiProviderKind aiProviderFromName(String? name) => switch (name) {
      'openai' => AiProviderKind.openai,
      'glm' => AiProviderKind.glm,
      _ => AiProviderKind.anthropic,
    };

/// Whether a model id belongs to a provider's family — used to guard against a
/// hand-edited `.mechx` carrying, say, a `claude-*` id while the provider is GLM.
/// The dropdown only ever offers in-family ids, so this is a safety net.
bool modelFamilyMatches(AiProviderKind provider, String id) {
  final s = id.trim().toLowerCase();
  return switch (provider) {
    AiProviderKind.anthropic => s.startsWith('claude'),
    AiProviderKind.openai => s.startsWith('gpt') || s.startsWith('o'),
    AiProviderKind.glm => s.startsWith('glm'),
  };
}

/// Calls the Anthropic Messages API with the command registry as tools and
/// decodes the returned `tool_use` blocks into an [AiPlan]. Offline-graceful:
/// an empty key ⇒ [AiDisabled]; any network/API failure ⇒ [AiError].
class AnthropicAiClient implements AiClient {
  final http.Client _http;
  final Duration timeout;

  AnthropicAiClient({http.Client? httpClient, this.timeout = const Duration(seconds: 30)})
      : _http = httpClient ?? http.Client();

  static const _endpoint = 'https://api.anthropic.com/v1/messages';

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
          'Add your Anthropic API key in Preferences to enable the Claude copilot.');
    }
    final body = jsonEncode({
      'model': request.model,
      'max_tokens': 1024,
      'system': _systemPrompt,
      'tools': aiToolSchemas(),
      'messages': [
        {
          'role': 'user',
          'content': request.contextSummary.isEmpty
              ? request.userText
              : '${request.contextSummary}\n\nRequest: ${request.userText}',
        },
      ],
    });
    http.Response resp;
    try {
      resp = await _http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'content-type': 'application/json',
              'x-api-key': request.apiKey.trim(),
              'anthropic-version': '2023-06-01',
            },
            body: body,
          )
          .timeout(timeout);
    } on TimeoutException {
      return const AiError('Claude request timed out. Check your connection.');
    } catch (e) {
      return AiError('Could not reach Claude (offline?). $e');
    }
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      return const AiError('Anthropic rejected the API key (check Preferences).');
    }
    if (resp.statusCode != 200) {
      return AiError('Claude API error (${resp.statusCode}).');
    }
    return _parse(resp.body);
  }

  /// Decode the Messages-API response into an [AiPlan]: every `tool_use` block
  /// becomes an [AiCommand]; `text` blocks join into the rationale.
  static AiResult _parse(String responseBody) {
    Map<dynamic, dynamic> json;
    try {
      json = jsonDecode(responseBody) as Map<dynamic, dynamic>;
    } catch (_) {
      return const AiError('Claude returned a malformed response.');
    }
    final content = json['content'];
    if (content is! List) return const AiError('Claude returned no content.');
    final commands = <AiCommand>[];
    final prose = <String>[];
    for (final block in content) {
      if (block is! Map) continue;
      final type = block['type'];
      if (type == 'tool_use') {
        final name = block['name'];
        final input = block['input'];
        if (name is String && input is Map) {
          final cmd = AiCommand.fromJson(name, input);
          if (cmd != null) commands.add(cmd);
        }
      } else if (type == 'text' && block['text'] is String) {
        prose.add(block['text'] as String);
      }
    }
    return AiOk(AiPlan(commands: commands, rationale: prose.join('\n').trim()));
  }
}

/// A deterministic client for tests / offline demos — returns whatever its
/// [responder] computes for the request. No key, no network.
class FakeAiClient implements AiClient {
  final FutureOr<AiResult> Function(AiRequest request) responder;
  const FakeAiClient(this.responder);

  @override
  Future<AiResult> proposePlan(AiRequest request) async =>
      responder(request);
}
