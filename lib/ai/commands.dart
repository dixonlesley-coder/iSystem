/// The Claude-copilot COMMAND REGISTRY — a typed, closed set of actions the AI
/// (or a user) can ask for, each mapping to ONE existing `NetworkController`
/// method. Commands are PURE DATA (decode + a human preview string); the actual
/// mutation lives in `store/ai_copilot_store.dart` so all Riverpod access stays
/// in one place and the registry is unit-testable with no Flutter/ref.
///
/// Every applied command records one undo step (via the controller's `_commit`),
/// so a multi-command plan is undoable step by step.
library;

import 'package:flutter/foundation.dart';

/// What kind of action a command performs. Kept as a closed enum so a decoded
/// (or AI-emitted) command can never name a method the app doesn't implement.
enum AiCommandKind {
  placeComponent,
  placeTerminal,
  placeFitting,
  placeSegment,
  autoPlaceRoomTerminals,
  suggest,
}

/// One AI-proposed action. Immutable, JSON-round-trippable, with a plain-language
/// [preview] for the plan-review UI. Coordinates are sheet/world pixels.
@immutable
class AiCommand {
  final AiCommandKind kind;
  final String sheetId;
  final int floor;
  final double x;
  final double y;

  /// For [AiCommandKind.placeComponent] — the `NodeComponent` name (e.g. `pump`).
  final String? component;

  /// For [AiCommandKind.placeSegment] — the `ServiceType` name (e.g. `coldWater`).
  final String? service;

  /// For [AiCommandKind.autoPlaceRoomTerminals] — the target room id.
  final String? roomId;

  /// For [AiCommandKind.suggest] — text-only advice, no mutation.
  final String? message;

  const AiCommand({
    required this.kind,
    this.sheetId = '',
    this.floor = 0,
    this.x = 0,
    this.y = 0,
    this.component,
    this.service,
    this.roomId,
    this.message,
  });

  /// A human-readable one-line description for the plan-review list.
  String get preview {
    switch (kind) {
      case AiCommandKind.placeComponent:
        return 'Place ${component ?? 'component'} at '
            '(${x.round()}, ${y.round()})';
      case AiCommandKind.placeTerminal:
        return 'Place a terminal at (${x.round()}, ${y.round()})';
      case AiCommandKind.placeFitting:
        return 'Place a fitting at (${x.round()}, ${y.round()})';
      case AiCommandKind.placeSegment:
        return 'Draw a ${service ?? 'service'} run near '
            '(${x.round()}, ${y.round()})';
      case AiCommandKind.autoPlaceRoomTerminals:
        return 'Auto-place sized air terminals in room ${roomId ?? '?'}';
      case AiCommandKind.suggest:
        return message ?? 'Suggestion';
    }
  }

  /// Whether this command mutates the network (vs a text-only suggestion).
  bool get mutates => kind != AiCommandKind.suggest;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (sheetId.isNotEmpty) 'sheetId': sheetId,
        'floor': floor,
        'x': x,
        'y': y,
        if (component != null) 'component': component,
        if (service != null) 'service': service,
        if (roomId != null) 'roomId': roomId,
        if (message != null) 'message': message,
      };

  /// Tolerant decode of an AI tool-use input (or persisted command). Unknown
  /// `kind` ⇒ null (dropped), so a hallucinated command never reaches apply.
  static AiCommand? fromJson(String kindName, Map<dynamic, dynamic> args) {
    final kind =
        AiCommandKind.values.where((k) => k.name == kindName).cast<AiCommandKind?>().firstWhere(
              (_) => true,
              orElse: () => null,
            );
    if (kind == null) return null;
    double num_(Object? v) => v is num ? v.toDouble() : 0.0;
    return AiCommand(
      kind: kind,
      sheetId: args['sheetId'] is String ? args['sheetId'] : '',
      floor: args['floor'] is num ? (args['floor'] as num).toInt() : 0,
      x: num_(args['x']),
      y: num_(args['y']),
      component: args['component'] is String ? args['component'] : null,
      service: args['service'] is String ? args['service'] : null,
      roomId: args['roomId'] is String ? args['roomId'] : null,
      message: args['message'] is String ? args['message'] : null,
    );
  }
}

/// An ordered, reviewable plan the copilot proposes — a list of [commands] plus
/// the model's [rationale]. Never applied until the engineer confirms.
@immutable
class AiPlan {
  final List<AiCommand> commands;
  final String rationale;
  const AiPlan({required this.commands, this.rationale = ''});

  bool get isEmpty => commands.isEmpty;

  /// How many commands actually mutate the drawing (excludes text suggestions).
  int get mutatingCount => commands.where((c) => c.mutates).length;
}

/// The Anthropic tool-use tool definitions for the command registry — emitted in
/// the Messages API request so the model returns structured `tool_use` blocks
/// the app can decode back into [AiCommand]s. Pure data (no network).
List<Map<String, dynamic>> aiToolSchemas() {
  Map<String, dynamic> obj(Map<String, dynamic> props, List<String> required) =>
      {
        'type': 'object',
        'properties': props,
        'required': required,
        'additionalProperties': false,
      };
  const numProp = {'type': 'number'};
  const strProp = {'type': 'string'};
  // The sheet a placement lands on MUST be one of the ids given in the context —
  // an invented id creates a node that renders on no sheet (and the app rejects
  // it at apply). Spell that out in the schema so the model doesn't guess.
  const sheetIdProp = {
    'type': 'string',
    'description':
        'A sheet id copied verbatim from the context — never invent one.',
  };
  return [
    {
      'name': 'placeComponent',
      'description': 'Place an equipment/component node (pump, roofTank, '
          'gateValve, supplyDiffuser, ahu, fcu, acCassette, …) on a sheet. '
          'component is a NodeComponent name.',
      'input_schema': obj({
        'sheetId': sheetIdProp,
        'floor': {'type': 'integer'},
        'x': numProp,
        'y': numProp,
        'component': strProp,
      }, [
        'sheetId',
        'floor',
        'x',
        'y',
        'component'
      ]),
    },
    {
      'name': 'placeTerminal',
      'description': 'Place a fixture/terminal node at a point on a sheet.',
      'input_schema': obj({
        'sheetId': sheetIdProp,
        'floor': {'type': 'integer'},
        'x': numProp,
        'y': numProp,
      }, [
        'sheetId',
        'floor',
        'x',
        'y'
      ]),
    },
    {
      'name': 'placeFitting',
      'description': 'Place a bare junction/fitting node at a point on a sheet.',
      'input_schema': obj({
        'sheetId': sheetIdProp,
        'floor': {'type': 'integer'},
        'x': numProp,
        'y': numProp,
      }, [
        'sheetId',
        'floor',
        'x',
        'y'
      ]),
    },
    {
      'name': 'placeSegment',
      'description': 'Drop a short horizontal run of the given service '
          '(coldWater, hotWater, drainage, supplyAir, …) centred at a point.',
      'input_schema': obj({
        'sheetId': sheetIdProp,
        'floor': {'type': 'integer'},
        'x': numProp,
        'y': numProp,
        'service': strProp,
      }, [
        'sheetId',
        'floor',
        'x',
        'y',
        'service'
      ]),
    },
    {
      'name': 'autoPlaceRoomTerminals',
      'description': 'Auto-size and place the supply diffusers + a return grille '
          'a room needs (ACH air sizing) by room id.',
      'input_schema': obj({'roomId': strProp}, ['roomId']),
    },
    {
      'name': 'suggest',
      'description': 'Give the engineer a text-only suggestion (no drawing '
          'change).',
      'input_schema': obj({'message': strProp}, ['message']),
    },
  ];
}
