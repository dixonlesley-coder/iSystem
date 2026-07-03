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
import '../ai/glm_client.dart';
import '../ai/openai_client.dart';
import 'annotation_store.dart';
import 'app_state.dart';
import 'network_store.dart';
import 'project_store.dart';
import 'selection_store.dart';
import 'sheets_store.dart';

/// Where the copilot is in the loop. [applied] is reported only when a plan was
/// partially applied (some commands skipped) — a fully-clean apply returns to
/// [idle] (the changed drawing is the feedback).
enum CopilotPhase { idle, thinking, proposed, error, applied }

/// The honest account of applying a plan: how many mutating commands were
/// applied vs proposed, and a human reason for each one skipped (a hallucinated /
/// invalid command — an invented sheet id, an unknown component/service/room).
/// Returned by [CopilotController.applyPlan] so the UI (and tests) can report
/// "Applied M of N — K skipped" instead of silently dropping bad commands.
@immutable
class ApplyOutcome {
  /// Mutating commands actually applied.
  final int applied;

  /// Mutating commands in the plan (excludes text-only suggestions).
  final int proposed;

  /// One human-readable line per skipped command — its preview plus the reason.
  final List<String> skipped;

  const ApplyOutcome({
    required this.applied,
    required this.proposed,
    this.skipped = const [],
  });

  int get skippedCount => skipped.length;
  bool get allApplied => skippedCount == 0;

  /// "Applied 2 of 3 changes — 1 skipped".
  String get summary =>
      'Applied $applied of $proposed change${proposed == 1 ? '' : 's'}'
      '${skippedCount > 0 ? ' — $skippedCount skipped' : ''}';
}

@immutable
class CopilotState {
  final CopilotPhase phase;
  final AiPlan? plan; // set in [CopilotPhase.proposed]
  final String? message; // disabled/error explanation, or the model's rationale

  /// Set in [CopilotPhase.applied] — the partial-apply account.
  final ApplyOutcome? applyReport;

  const CopilotState({
    this.phase = CopilotPhase.idle,
    this.plan,
    this.message,
    this.applyReport,
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
    AiProviderKind.glm => GlmAiClient(),
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

  /// Apply the proposed plan. Every mutating command is VALIDATED against live
  /// state first ([_validate]) — an invented sheet id, an unknown component /
  /// service / room is rejected rather than creating a node that renders on no
  /// sheet — then the accepted commands run through the matching controller
  /// method. Text-only `suggest` commands are advice, never applied. Returns an
  /// honest [ApplyOutcome] ("Applied M of N — K skipped"); a partial apply leaves
  /// the panel in [CopilotPhase.applied] with the account, a clean full apply
  /// returns to [idle]. No-op (empty outcome) unless a plan is proposed.
  ///
  /// Undo granularity: each accepted command records ONE undo step on the global
  /// timeline (via the existing `NetworkController` add* / auto-place methods), so
  /// a multi-command plan is undoable step-by-step (the last placement first).
  /// Coalescing the whole plan into a single Ctrl+Z would need a batch API on
  /// `NetworkController` (owned elsewhere); per-command granularity is a
  /// reasonable stand-in and never leaves a torn network (each add is atomic).
  ApplyOutcome applyPlan() {
    final plan = state.plan;
    if (plan == null) return const ApplyOutcome(applied: 0, proposed: 0);
    final mutating = plan.commands.where((c) => c.mutates).toList();
    final skipped = <String>[];
    var applied = 0;
    for (final cmd in mutating) {
      final reason = _validate(cmd);
      if (reason != null) {
        skipped.add('${cmd.preview} — $reason');
        continue;
      }
      _apply(cmd);
      applied++;
    }
    final outcome = ApplyOutcome(
      applied: applied,
      proposed: mutating.length,
      skipped: skipped,
    );
    state = outcome.allApplied
        ? CopilotState.idle
        : CopilotState(
            phase: CopilotPhase.applied,
            message: outcome.summary,
            applyReport: outcome,
          );
    return outcome;
  }

  /// Validate ONE command against live state — returns null when acceptable, else
  /// a short reason it should be skipped. The closed registry already rejects
  /// unknown KINDS at decode ([AiCommand.fromJson]); this guards the DATA a model
  /// (or a persisted plan) can still get wrong. A place command ALWAYS needs a
  /// real target sheet: with NO sheets loaded there is nowhere to place, so every
  /// placement is rejected (never fabricated onto an invented sheet id — that
  /// would create an orphan node the canvas can't show yet the BOM/solve counts).
  String? _validate(AiCommand cmd) {
    final sheets = ref.read(sheetsControllerProvider).sheets;
    bool sheetKnown(String id) => sheets.any((s) => s.id == id);
    final levelCount = ref.read(projectControllerProvider).building.levelCount;
    bool floorOk(int f) => f >= 0 && f < levelCount;

    switch (cmd.kind) {
      case AiCommandKind.placeComponent:
        if (!sheetKnown(cmd.sheetId)) return 'unknown sheet "${cmd.sheetId}"';
        if (!floorOk(cmd.floor)) return 'floor ${cmd.floor} out of range';
        if (_componentByName(cmd.component) == null) {
          return 'unknown component "${cmd.component ?? ''}"';
        }
        return null;
      case AiCommandKind.placeTerminal:
      case AiCommandKind.placeFitting:
        if (!sheetKnown(cmd.sheetId)) return 'unknown sheet "${cmd.sheetId}"';
        if (!floorOk(cmd.floor)) return 'floor ${cmd.floor} out of range';
        return null;
      case AiCommandKind.placeSegment:
        if (!sheetKnown(cmd.sheetId)) return 'unknown sheet "${cmd.sheetId}"';
        if (!floorOk(cmd.floor)) return 'floor ${cmd.floor} out of range';
        if (_serviceByName(cmd.service) == null) {
          return 'unknown service "${cmd.service ?? ''}"';
        }
        return null;
      case AiCommandKind.autoPlaceRoomTerminals:
        final rooms = ref.read(roomAreasProvider);
        if (cmd.roomId == null || !rooms.any((r) => r.id == cmd.roomId)) {
          return 'unknown room "${cmd.roomId ?? ''}"';
        }
        return null;
      case AiCommandKind.suggest:
        return null; // text-only, never mutates
    }
  }

  /// The model to actually send: the engineer's stored choice when it matches the
  /// active provider's family, else that provider's default — so a model id from
  /// the wrong family is never sent (e.g. a `claude-*` id to GLM), even from a
  /// hand-edited file.
  static String _effectiveModel(AiProviderKind provider, String stored) {
    final s = stored.trim();
    if (s.isEmpty || !modelFamilyMatches(provider, s)) {
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

  /// A compact snapshot the model reasons over — the placement FRAME (active
  /// sheet + its pixel extent, every sheet id, the floor list) plus the selection
  /// described in full, the network summary and the rooms. The system prompt
  /// demands sheet-pixel coordinates, so the frame is what stops the model from
  /// hallucinating a sheet id / extent (a node on no sheet). Deliberately small
  /// (counts + ids) to stay within the token budget even for a large network.
  String _buildContext() {
    final net = ref.read(networkControllerProvider).network;
    final sel = ref.read(selectionProvider);
    final rooms = ref.read(roomAreasProvider);
    final sheetsState = ref.read(sheetsControllerProvider);
    final building = ref.read(projectControllerProvider).building;
    final b = StringBuffer('Current design context:\n');

    // The active sheet + its pixel extent — the coordinate space for placements.
    final active = sheetsState.current;
    if (active != null) {
      b.writeln('- active sheet: ${active.id} "${active.name}" '
          '(extent ${active.sizePx.width.round()} x '
          '${active.sizePx.height.round()} px)');
    }
    if (sheetsState.sheets.isNotEmpty) {
      b.writeln('- sheets (id | name | w x h px):');
      for (final s in sheetsState.sheets) {
        b.writeln('    ${s.id} | ${s.name} | '
            '${s.sizePx.width.round()}x${s.sizePx.height.round()}');
      }
    } else {
      b.writeln('- sheets: none imported yet');
    }

    // Building floors — a place command carries a 0-based floor index.
    final floors = building.floors;
    if (floors.isNotEmpty) {
      b.writeln('- floors (index=name): ${[
        for (var i = 0; i < floors.length; i++) '$i=${floors[i].name}'
      ].join(', ')}');
    }

    b.writeln('- network: ${net.nodes.length} nodes, ${net.edges.length} edges');

    // The selected element the engineer is asking about — described, not just id.
    final selNode = sel.nodeId == null ? null : net.nodeById(sel.nodeId!);
    if (selNode != null) {
      b.writeln('- selected node: ${_describeNode(selNode)}');
    }
    final selEdge = sel.edgeId == null ? null : net.edgeById(sel.edgeId!);
    if (selEdge != null) {
      b.writeln('- selected edge: ${_describeEdge(selEdge, net)}');
    }

    if (rooms.isNotEmpty) {
      b.writeln('- rooms (id | sheet | type):');
      for (final r in rooms.take(12)) {
        b.writeln('    ${r.id} | ${r.sheetId} | ${r.roomType.name}');
      }
    }

    b.writeln('Place new elements only on a sheet id listed above, using its '
        'pixel extent for coordinates; never invent a sheet id.');
    return b.toString();
  }

  /// A one-line description of a node the model can reason about.
  static String _describeNode(NetNode n) {
    final parts = <String>[n.id];
    if (n.component != null) parts.add(n.component!.name);
    parts.add('role=${n.role.name}');
    if (n.fixture != null) parts.add('fixture=${n.fixture!.name}');
    if (n.airflow != null) parts.add('carries airflow');
    parts.add('on ${n.sheetId} floor ${n.floorIndex} '
        '@ (${n.x.round()}, ${n.y.round()})');
    return parts.join(' · ');
  }

  /// A one-line description of an edge (its service, kind and host sheet/floor).
  static String _describeEdge(NetEdge e, Network net) {
    final parts = <String>[e.id, e.service.name, 'kind=${e.kind.name}'];
    final a = net.nodeById(e.fromId);
    if (a != null) parts.add('on ${a.sheetId} floor ${a.floorIndex}');
    return parts.join(' · ');
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
