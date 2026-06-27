/// The Claude-copilot store: the plan → preview → confirm → apply loop. The
/// engineer asks (with the current room/floor/selection as context); the
/// injected [AiClient] proposes an [AiPlan]; nothing changes until [applyPlan].
/// Applying runs each command through the existing `NetworkController` methods —
/// so every step is a normal, undoable mutation and the sizing recomputes
/// reactively. Offline-graceful: no key ⇒ a calm disabled state, never a crash.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Offset;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../ai/ai_client.dart';
import '../ai/commands.dart';
import '../ai/openai_client.dart';
import 'annotation_store.dart';
import 'app_state.dart';
import 'network_store.dart';
import 'project_store.dart';
import 'selection_store.dart';

/// Where the copilot is in the loop.
enum CopilotPhase { idle, thinking, proposed, error }

@immutable
class CopilotState {
  final CopilotPhase phase;
  final AiPlan? plan; // set in [CopilotPhase.proposed]
  final String? message; // disabled/error explanation, or the model's rationale

  const CopilotState({
    this.phase = CopilotPhase.idle,
    this.plan,
    this.message,
  });

  static const idle = CopilotState();
}

/// The injectable copilot client. Resolves to the real HTTP client for the
/// chosen provider (Anthropic primary, OpenAI backup); tests
/// `overrideWithValue(FakeAiClient(...))`.
final aiClientProvider = Provider<AiClient>((ref) {
  return switch (ref.watch(aiProviderProvider)) {
    AiProviderKind.anthropic => AnthropicAiClient(),
    AiProviderKind.openai => OpenAiAiClient(),
  };
});

class CopilotController extends Notifier<CopilotState> {
  @override
  CopilotState build() => CopilotState.idle;

  /// Ask Claude to design or change the current selection. Gathers a compact
  /// context snapshot, calls the injected client, and stores the proposed plan
  /// WITHOUT applying it.
  Future<void> ask(String userText) async {
    final text = userText.trim();
    if (text.isEmpty) return;
    state = const CopilotState(phase: CopilotPhase.thinking);

    final provider = ref.read(aiProviderProvider);
    final result = await ref.read(aiClientProvider).proposePlan(AiRequest(
          userText: text,
          apiKey: ref.read(aiApiKeyProvider),
          model: _effectiveModel(provider, ref.read(aiModelProvider)),
          contextSummary: _buildContext(),
        ));

    switch (result) {
      case AiOk(:final plan):
        if (plan.isEmpty) {
          state = CopilotState(
            phase: CopilotPhase.error,
            message: plan.rationale.isEmpty
                ? 'Claude had no actions to propose.'
                : plan.rationale,
          );
        } else {
          state = CopilotState(
            phase: CopilotPhase.proposed,
            plan: plan,
            message: plan.rationale.isEmpty ? null : plan.rationale,
          );
        }
      case AiDisabled(:final message):
      case AiError(:final message):
        state = CopilotState(phase: CopilotPhase.error, message: message);
    }
  }

  /// Apply the proposed plan — each command runs through the matching controller
  /// method (one undo step each). Text-only `suggest` commands are skipped. No-op
  /// unless a plan is currently proposed.
  void applyPlan() {
    final plan = state.plan;
    if (plan == null) return;
    for (final cmd in plan.commands) {
      _apply(cmd);
    }
    state = CopilotState.idle;
  }

  /// The model to actually send: the engineer's stored choice when it matches the
  /// active provider's family, else that provider's default — so a Claude model
  /// string is never sent to OpenAI (or vice-versa), even from a hand-edited file.
  static String _effectiveModel(AiProviderKind provider, String stored) {
    final s = stored.trim();
    if (s.isEmpty) return defaultModelForProvider(provider);
    final looksAnthropic = s.startsWith('claude');
    final providerIsAnthropic = provider == AiProviderKind.anthropic;
    if (looksAnthropic != providerIsAnthropic) {
      return defaultModelForProvider(provider);
    }
    return s;
  }

  /// Drop the proposed plan without applying anything.
  void discard() => state = CopilotState.idle;

  /// Clear an error/disabled message back to idle.
  void reset() => state = CopilotState.idle;

  // ── Applying one command via the existing controllers ───────────────────────

  void _apply(AiCommand cmd) {
    final net = ref.read(networkControllerProvider.notifier);
    final world = Offset(cmd.x, cmd.y);
    switch (cmd.kind) {
      case AiCommandKind.placeComponent:
        final c = _componentByName(cmd.component);
        if (c != null) net.addComponentNode(cmd.sheetId, cmd.floor, world, c);
      case AiCommandKind.placeTerminal:
        net.addTerminal(cmd.sheetId, cmd.floor, world);
      case AiCommandKind.placeFitting:
        net.addFitting(cmd.sheetId, cmd.floor, world);
      case AiCommandKind.placeSegment:
        net.addSegment(cmd.sheetId, cmd.floor, world,
            service: _serviceByName(cmd.service));
      case AiCommandKind.autoPlaceRoomTerminals:
        _applyAutoPlaceRoom(cmd.roomId);
      case AiCommandKind.suggest:
        break; // text-only, nothing to apply
    }
  }

  void _applyAutoPlaceRoom(String? roomId) {
    if (roomId == null) return;
    final rooms = ref.read(roomAreasProvider);
    final room = rooms.where((r) => r.id == roomId).cast<RoomArea?>().firstWhere(
          (_) => true,
          orElse: () => null,
        );
    if (room == null) return;
    final cal = ref.read(projectControllerProvider).calibrationFor(room.sheetId);
    if (cal == null) return;
    final ducts = ref.read(ductSettingsProvider);
    ref.read(networkControllerProvider.notifier).autoPlaceRoomTerminals(
          room: room,
          metersPerPixel: cal.metersPerPixel,
          ductShape: ducts.shape,
          ductMethod: ducts.method,
        );
  }

  static NodeComponent? _componentByName(String? name) {
    if (name == null) return null;
    return NodeComponent.values
        .where((c) => c.name == name)
        .cast<NodeComponent?>()
        .firstWhere((_) => true, orElse: () => null);
  }

  static ServiceType? _serviceByName(String? name) {
    if (name == null) return null;
    return ServiceType.values
        .where((s) => s.name == name)
        .cast<ServiceType?>()
        .firstWhere((_) => true, orElse: () => null);
  }

  /// A compact snapshot the model reasons over — selection + room/floor + a
  /// network summary. Deliberately small to stay within the token budget.
  String _buildContext() {
    final net = ref.read(networkControllerProvider).network;
    final sel = ref.read(selectionProvider);
    final rooms = ref.read(roomAreasProvider);
    final b = StringBuffer('Current design context:\n');
    b.writeln('- network: ${net.nodes.length} nodes, ${net.edges.length} edges');
    if (sel.nodeId != null) b.writeln('- selected node: ${sel.nodeId}');
    if (sel.edgeId != null) b.writeln('- selected edge: ${sel.edgeId}');
    if (rooms.isNotEmpty) {
      b.writeln('- rooms (id · sheet · type):');
      for (final r in rooms.take(12)) {
        b.writeln('    ${r.id} · ${r.sheetId} · ${r.roomType.name}');
      }
    }
    return b.toString();
  }
}

final copilotProvider =
    NotifierProvider<CopilotController, CopilotState>(CopilotController.new);

/// True when the copilot can run (a non-empty API key is configured). Drives the
/// UI's enabled/disabled affordance.
final copilotEnabledProvider = Provider<bool>(
    (ref) => ref.watch(aiApiKeyProvider).trim().isNotEmpty);

/// Whether the copilot panel overlay is open. Transient UI state — the overlay
/// renders nothing when closed (so the goldens are byte-identical).
final copilotOpenProvider =
    NotifierProvider<CopilotOpenController, bool>(CopilotOpenController.new);

class CopilotOpenController extends Notifier<bool> {
  @override
  bool build() => false;

  void open() => state = true;
  void close() => state = false;
  void toggle() => state = !state;
}
