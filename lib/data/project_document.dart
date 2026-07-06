import 'dart:convert';

import 'package:flutter/widgets.dart' show Brightness, Offset, Size;
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/custom_fixture.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/sizing/storm_sizing.dart'
    show kDefaultRunoffCoefficient;
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import '../store/annotation_store.dart';
import '../store/models/sheet.dart';
import '../ui/canvas/viewport.dart';

/// Thrown by [ProjectDocument.decode]/[ProjectDocument.fromJson] when a file is
/// not a readable MechX document (malformed JSON, missing required structure,
/// or a newer schema this build can't read). Carries a human-readable [message]
/// the UI can surface.
class ProjectDocumentException implements Exception {
  final String message;
  const ProjectDocumentException(this.message);
  @override
  String toString() => 'ProjectDocumentException: $message';
}

/// Resolve [name] to a [values] entry, falling back to [fallback] when the name
/// is unknown — so a `.mechx` written by a newer build (with an enum value this
/// build doesn't have) loads with a sensible default instead of throwing.
T _enumOr<T extends Enum>(List<T> values, Object? name, T fallback) {
  if (name is! String) return fallback;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

/// Like [_enumOr] but returns null for an unknown/absent name (optional fields).
T? _enumOrNull<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}

/// Persisted design inputs that are NOT part of the drawn network but still
/// drive sizing/solve and presentation: occupancy class, feed strategy, duct
/// preferences, design rainfall, fire hazard class, and theme brightness.
///
/// Every field defaults to its provider's initial value, so a `.mechx` written
/// by an older build (no `settings` block) loads with today's defaults rather
/// than throwing. `feedStrategy` is stored as a bool to keep this data layer
/// free of the app's `FeedStrategy` enum; the app layer maps the two.
class DesignSettings {
  final Occupancy occupancy;

  /// `true` ⇒ upfeed pump; `false` ⇒ roof-tank downfeed.
  final bool upfeed;

  /// G1 — whether the solved MEP pump/fan/fire-pump duties are folded into the
  /// auto "MEP Equipment" electrical panel (opt-in; default false). Persisted so
  /// the choice survives a reload — otherwise reopening a project saved with the
  /// feed ON would silently prune the duty circuits back to placed-only.
  final bool mepDutyFeedEnabled;

  final DuctShape ductShape;
  final DuctSizingMethod ductMethod;
  final double rainfallMmPerHr;

  /// Storm runoff coefficient C (dimensionless, 0–1): the fraction of design
  /// rainfall that becomes runoff at the outlet (rational method). Additive —
  /// absent on an older file ⇒ the impervious-roof default (// VERIFY).
  final double runoffCoefficientStorm;

  final FireHazardClass fireHazard;
  final Brightness brightness;

  /// UI language code: `'en'` (English, the default) or `'id'` (Bahasa
  /// Indonesia). Stored as a string to keep this data layer free of the app's
  /// `AppLocale` enum (the app layer maps the two), mirroring `upfeed`. Tolerant
  /// on load: a missing/unknown code falls back to `'en'`.
  final String localeCode;

  /// Commercial pricelist: catalogue `sku → unit price`. Prices are NEVER baked
  /// into the committed parts catalogue (a separate concern, see
  /// `electrical/costing.dart`), so they live with the project. Defaults to
  /// empty — a project that has never been priced loads with no prices.
  final Map<String, double> priceList;

  /// Commercial quote settings: labour rate per hour + overhead / contingency /
  /// margin percentages used to turn the priced material estimate into a sell
  /// price (`electrical/quotation.dart`). The defaults mirror the engine's
  /// `buildQuotation` defaults so an untouched project quotes identically.
  final double labourRatePerHour;
  final double overheadPct;
  final double contingencyPct;
  final double marginPct;

  /// User-defined fixture library: custom plumbing fixture types (with their
  /// UBAP supply + DFU drainage loads) the project's nodes can reference by id
  /// (`NetNode.customFixtureId`). Defaults to empty — a project that never
  /// defined a custom fixture loads with none, byte-identical to before.
  final List<CustomFixture> fixtureLibrary;

  /// Cooling-load estimation method: `'simple'` (the area-density rule in
  /// `cooling_load.dart`, the default) or `'detailed'` (the heat-gain component
  /// breakdown in `cooling_load_detailed.dart`). Additive — absent ⇒ `'simple'`,
  /// byte-identical to before. Tolerant on load (unknown ⇒ `'simple'`).
  final String coolingLoadMethod;

  /// Multi-zone HVAC diversity / coincidence factor (0–1] applied to the summed
  /// per-room airflow + cooling when one AHU serves several rooms
  /// (`room_air.dart` `multiZoneAirSystem`). Defaults to 0.9 (`// VERIFY`).
  final double multiZoneDiversityFactor;

  /// Multi-zone supply/extract balance strategy: `'return_all'` (the default),
  /// `'supply_all'`, or `'balanced'` (maps to `ExhaustStrategy`). Additive —
  /// absent ⇒ `'return_all'`, tolerant on load.
  final String multiZoneExhaustStrategy;

  /// BYO Anthropic API key for the in-app Claude copilot. Empty ⇒ the copilot is
  /// disabled (offline-graceful). Stored in the `.mechx` file; the engineer is
  /// warned not to share a project file carrying their key.
  final String anthropicApiKey;

  /// Model id the copilot calls. Defaults to `claude-sonnet-4-6`.
  final String aiModel;

  /// Which LLM backend the copilot uses: `'anthropic'` (primary) or `'openai'`
  /// (backup). Defaults to Anthropic; unknown values fall back to it on load.
  final String aiProvider;

  /// Document-control identity fields feeding every report head + PDF/DXF title
  /// block: the drawing/document number, the current revision tag (e.g. `'A'`),
  /// the client name, and the preparer/checker/approver names (a DRAWN/CHECKED/
  /// APPROVED block). All nullable — a project that has never set them prints no
  /// document-control chrome, byte-identical to before this feature.
  final String? documentNumber;
  final String? revisionTag;
  final String? clientName;
  final String? preparedBy;
  final String? checkedBy;
  final String? approvedBy;

  /// The revision history (date + description), reusing the engine's own
  /// `Revision` value object (`standards/sni.dart`) so this is the one revision
  /// table type in the app, not a duplicate. Defaults to empty — an untouched
  /// project has no revision table.
  final List<Revision> revisions;

  /// Reusable, re-stampable assemblies / blocks (E5): named groups of drawn
  /// nodes + edges — the WC toilet group, the pump-room hookup, a shaft riser
  /// set — saved once and re-stamped across projects. Each carries the SAME
  /// network node/edge JSON the drawn network uses, so re-instantiation with
  /// fresh ids (the clipboard clone path) is free. Defaults to empty — a project
  /// that never saved a block is byte-identical to before.
  final List<SavedAssembly> savedAssemblies;

  /// H1 — the design-issue keys the engineer has ACKNOWLEDGED (see
  /// `design_issues_store.dart` `DesignIssue.key`): advisory/`secondarySource`
  /// items accepted so they no longer block a PASS compliance verdict. Errors
  /// and warnings are never acknowledgeable, so this can only ever relax an
  /// advisory. Defaults empty — a project that has acknowledged nothing loads
  /// byte-identical to before, and compliance still can't PASS until something
  /// is acknowledged.
  final List<String> acknowledgedIssueKeys;

  /// N23 — editable per-equipment "Model / spec" free text, keyed by the
  /// STABLE equipment tag the schedule already assigns (e.g. `"P-01"`,
  /// `"AHU-03"`) → a datasheet model/spec string the engineer types once so
  /// every exported equipment schedule (Markdown / CSV / PDF) carries it
  /// instead of the engine's `'—'` placeholder (`report/equipment_schedule.dart`
  /// `PumpScheduleItem.modelSpec` / `FanScheduleItem.modelSpec`). Keyed by tag
  /// rather than row identity — the tag is the one handle that survives a
  /// re-solve (duties change, the procured pump doesn't). Defaults to empty —
  /// a project that has never entered a spec is byte-identical to before this
  /// feature.
  final Map<String, String> equipmentModelSpecs;

  const DesignSettings({
    this.occupancy = Occupancy.private,
    this.upfeed = false,
    this.mepDutyFeedEnabled = false,
    this.ductShape = DuctShape.round,
    this.ductMethod = DuctSizingMethod.velocity,
    this.rainfallMmPerHr = 200.0,
    this.runoffCoefficientStorm = kDefaultRunoffCoefficient,
    this.fireHazard = FireHazardClass.ordinaryHazard1,
    this.brightness = Brightness.dark,
    this.localeCode = 'en',
    this.priceList = const {},
    this.labourRatePerHour = 150000,
    this.overheadPct = 10,
    this.contingencyPct = 5,
    this.marginPct = 15,
    this.fixtureLibrary = const [],
    this.coolingLoadMethod = 'simple',
    this.multiZoneDiversityFactor = 0.9,
    this.multiZoneExhaustStrategy = 'return_all',
    this.anthropicApiKey = '',
    this.aiModel = 'claude-sonnet-4-6',
    this.aiProvider = 'anthropic',
    this.documentNumber,
    this.revisionTag,
    this.clientName,
    this.preparedBy,
    this.checkedBy,
    this.approvedBy,
    this.revisions = const [],
    this.savedAssemblies = const [],
    this.acknowledgedIssueKeys = const [],
    this.equipmentModelSpecs = const {},
  });

  Map<String, dynamic> toJson() => {
        'occupancy': occupancy.name,
        'upfeed': upfeed,
        // Written only when opted in, so a default project stays byte-identical.
        if (mepDutyFeedEnabled) 'mepDutyFeed': true,
        'ductShape': ductShape.name,
        'ductMethod': ductMethod.name,
        'rainfall_mmhr': rainfallMmPerHr,
        'runoff_c': runoffCoefficientStorm,
        'fireHazard': fireHazard.name,
        'brightness': brightness == Brightness.dark ? 'dark' : 'light',
        'locale': localeCode,
        // Commercial settings (additive; absent on an older file → defaults).
        'priceList': priceList,
        'labourRatePerHour': labourRatePerHour,
        'overheadPct': overheadPct,
        'contingencyPct': contingencyPct,
        'marginPct': marginPct,
        // User fixture library (additive; absent on an older file → empty).
        'fixtureLibrary': [for (final f in fixtureLibrary) f.toJson()],
        // Cooling-load + multi-zone HVAC settings (additive; absent → defaults).
        'coolingLoadMethod': coolingLoadMethod,
        'multiZoneDiversityFactor': multiZoneDiversityFactor,
        'multiZoneExhaustStrategy': multiZoneExhaustStrategy,
        // BYO AI copilot model + provider (non-secret) round-trip; the API KEY
        // is a secret and is NO LONGER written here (B8) — it lives machine-local
        // in `app_settings.dart`, kept out of the shareable `.mechx`. A legacy
        // in-file key is still READ (see [fromJson]) for one-time migration.
        'aiModel': aiModel,
        'aiProvider': aiProvider,
        // Document control (additive; encoded only when set/non-empty so an
        // untouched project stays byte-identical).
        if (documentNumber != null && documentNumber!.isNotEmpty)
          'documentNumber': documentNumber,
        if (revisionTag != null && revisionTag!.isNotEmpty)
          'revisionTag': revisionTag,
        if (clientName != null && clientName!.isNotEmpty) 'clientName': clientName,
        if (preparedBy != null && preparedBy!.isNotEmpty) 'preparedBy': preparedBy,
        if (checkedBy != null && checkedBy!.isNotEmpty) 'checkedBy': checkedBy,
        if (approvedBy != null && approvedBy!.isNotEmpty) 'approvedBy': approvedBy,
        if (revisions.isNotEmpty)
          'revisions': [
            for (final r in revisions) {'date': r.date, 'description': r.description},
          ],
        // Reusable assemblies (E5; additive — encoded only when non-empty so an
        // untouched project stays byte-identical).
        if (savedAssemblies.isNotEmpty)
          'savedAssemblies': [for (final a in savedAssemblies) a.toJson()],
        // Acknowledged advisory keys (H1; additive — encoded only when non-empty
        // so an untouched project stays byte-identical).
        if (acknowledgedIssueKeys.isNotEmpty)
          'acknowledgedIssueKeys': acknowledgedIssueKeys,
        // Equipment-schedule model/spec overrides (N23; additive — encoded only
        // when non-empty so an untouched project stays byte-identical).
        if (equipmentModelSpecs.isNotEmpty)
          'equipmentModelSpecs': equipmentModelSpecs,
      };

  /// Tolerant decode: every field falls back to its default on an
  /// unknown/absent value (forward/backward compatible).
  factory DesignSettings.fromJson(Map<dynamic, dynamic> json) => DesignSettings(
        occupancy:
            _enumOr(Occupancy.values, json['occupancy'], Occupancy.private),
        upfeed: json['upfeed'] == true,
        mepDutyFeedEnabled: json['mepDutyFeed'] == true,
        ductShape:
            _enumOr(DuctShape.values, json['ductShape'], DuctShape.round),
        ductMethod: _enumOr(
          DuctSizingMethod.values,
          json['ductMethod'],
          DuctSizingMethod.velocity,
        ),
        rainfallMmPerHr: (json['rainfall_mmhr'] as num?)?.toDouble() ?? 200.0,
        runoffCoefficientStorm: (json['runoff_c'] as num?)?.toDouble() ??
            kDefaultRunoffCoefficient,
        fireHazard: _enumOr(
          FireHazardClass.values,
          json['fireHazard'],
          FireHazardClass.ordinaryHazard1,
        ),
        brightness:
            json['brightness'] == 'light' ? Brightness.light : Brightness.dark,
        // Tolerant: only the known codes are accepted; anything else → 'en'.
        localeCode: json['locale'] == 'id' ? 'id' : 'en',
        priceList: _priceListFromJson(json['priceList']),
        labourRatePerHour:
            (json['labourRatePerHour'] as num?)?.toDouble() ?? 150000,
        overheadPct: (json['overheadPct'] as num?)?.toDouble() ?? 10,
        contingencyPct: (json['contingencyPct'] as num?)?.toDouble() ?? 5,
        marginPct: (json['marginPct'] as num?)?.toDouble() ?? 15,
        fixtureLibrary: _fixtureLibraryFromJson(json['fixtureLibrary']),
        // Tolerant: only the known method/strategy codes are accepted.
        coolingLoadMethod:
            json['coolingLoadMethod'] == 'detailed' ? 'detailed' : 'simple',
        multiZoneDiversityFactor:
            _clampDiversity((json['multiZoneDiversityFactor'] as num?)
                ?.toDouble()),
        multiZoneExhaustStrategy: _exhaustStrategyOr(
            json['multiZoneExhaustStrategy'], 'return_all'),
        anthropicApiKey:
            json['anthropicApiKey'] is String ? json['anthropicApiKey'] : '',
        aiModel: json['aiModel'] is String && (json['aiModel'] as String).isNotEmpty
            ? json['aiModel']
            : 'claude-sonnet-4-6',
        aiProvider: const {'openai', 'glm'}.contains(json['aiProvider'])
            ? json['aiProvider'] as String
            : 'anthropic',
        documentNumber: json['documentNumber'] is String
            ? json['documentNumber'] as String
            : null,
        revisionTag:
            json['revisionTag'] is String ? json['revisionTag'] as String : null,
        clientName:
            json['clientName'] is String ? json['clientName'] as String : null,
        preparedBy:
            json['preparedBy'] is String ? json['preparedBy'] as String : null,
        checkedBy:
            json['checkedBy'] is String ? json['checkedBy'] as String : null,
        approvedBy:
            json['approvedBy'] is String ? json['approvedBy'] as String : null,
        revisions: _revisionsFromJson(json['revisions']),
        savedAssemblies: _savedAssembliesFromJson(json['savedAssemblies']),
        acknowledgedIssueKeys:
            _stringListFromJson(json['acknowledgedIssueKeys']),
        equipmentModelSpecs:
            _equipmentModelSpecsFromJson(json['equipmentModelSpecs']),
      );

  /// Tolerantly read a list of strings: a non-list (or absent) value yields an
  /// empty list; non-string entries are dropped.
  static List<String> _stringListFromJson(Object? raw) {
    if (raw is! List) return const [];
    return [for (final e in raw) if (e is String) e];
  }

  /// Clamp the multi-zone diversity factor into (0,1]; absent/invalid ⇒ 0.9.
  static double _clampDiversity(double? raw) {
    if (raw == null || raw.isNaN || raw <= 0) return 0.9;
    return raw > 1.0 ? 1.0 : raw;
  }

  /// Tolerantly read the multi-zone exhaust strategy code.
  static String _exhaustStrategyOr(Object? raw, String fallback) {
    const known = {'return_all', 'supply_all', 'balanced'};
    return raw is String && known.contains(raw) ? raw : fallback;
  }

  /// Tolerantly read the fixture library: a non-list (or absent) value yields an
  /// empty library; each entry that fails to decode (missing id/name) is dropped.
  static List<CustomFixture> _fixtureLibraryFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <CustomFixture>[];
    for (final e in raw) {
      final f = CustomFixture.fromJson(e);
      if (f != null) out.add(f);
    }
    return out;
  }

  /// Tolerantly read the revision history: a non-list (or absent) value yields
  /// an empty history; each entry missing `date`/`description` is dropped.
  static List<Revision> _revisionsFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <Revision>[];
    for (final e in raw) {
      if (e is Map && e['date'] is String && e['description'] is String) {
        out.add(Revision(e['date'] as String, e['description'] as String));
      }
    }
    return out;
  }

  /// Tolerantly read saved assemblies (E5): a non-list (or absent) value yields
  /// an empty list; each entry that fails to decode (missing id/name or a
  /// malformed node/edge) is dropped rather than failing the whole load.
  static List<SavedAssembly> _savedAssembliesFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <SavedAssembly>[];
    for (final e in raw) {
      try {
        final a = SavedAssembly.fromJson(e);
        if (a != null) out.add(a);
      } catch (_) {
        // Drop a malformed assembly rather than throwing.
      }
    }
    return out;
  }

  /// Tolerantly read a `sku → unit price` map: a non-map (or absent) value, a
  /// non-string key, or a non-numeric / non-positive price is dropped.
  static Map<String, double> _priceListFromJson(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, double>{};
    raw.forEach((k, v) {
      if (k is String && v is num && v > 0) out[k] = v.toDouble();
    });
    return out;
  }

  /// Tolerantly read the N23 equipment `tag → model/spec` map: a non-map (or
  /// absent) value, a non-string key, a non-string value, or a blank value is
  /// dropped (mirrors [_priceListFromJson]'s shape for a string-valued map).
  static Map<String, String> _equipmentModelSpecsFromJson(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, String>{};
    raw.forEach((k, v) {
      if (k is String && v is String && v.trim().isNotEmpty) out[k] = v;
    });
    return out;
  }
}

// ── Shared network node/edge JSON (the ONE serialization) ────────────────────
// [ProjectDocument]'s network AND the re-stampable [SavedAssembly] (E5) both go
// through these four functions, so a saved block serializes exactly like a drawn
// node/edge and re-instantiation with fresh ids (the clipboard clone path) is
// free. Optional fields are omitted when null ⇒ a plain node/edge stays compact
// and byte-identical.

Map<String, dynamic> _netNodeToJson(NetNode n) => {
      'id': n.id,
      'sheetId': n.sheetId,
      'x': n.x,
      'y': n.y,
      'floor': n.floorIndex,
      'role': n.role.name,
      if (n.elevation != null) 'elev_m': n.elevation!.meters,
      if (n.mountHeight != null) 'mount_h_m': n.mountHeight!.meters,
      if (n.fixture != null) 'fixture': n.fixture!.name,
      if (n.airflow != null) 'airflow_lps': n.airflow!.inLitersPerSecond,
      if (n.customFixtureId != null) 'customFixtureId': n.customFixtureId,
      if (n.roofAreaM2 != null) 'roof_area_m2': n.roofAreaM2,
      if (n.component != null) 'component': n.component!.name,
      if (n.tankCapacityLitres != null) 'tank_l': n.tankCapacityLitres,
      if (n.electricalLoadW != null) 'elec_w': n.electricalLoadW,
      if (n.faceWidthMm != null) 'face_w_mm': n.faceWidthMm,
      if (n.faceHeightMm != null) 'face_h_mm': n.faceHeightMm,
      if (n.fittingType != null && n.fittingType != JunctionFitting.auto)
        'fitting': n.fittingType!.name,
    };

NetNode _netNodeFromJson(Map n) => NetNode(
      id: n['id'] as String,
      sheetId: n['sheetId'] as String,
      x: (n['x'] as num).toDouble(),
      y: (n['y'] as num).toDouble(),
      floorIndex: (n['floor'] as num).toInt(),
      role: _enumOr(NodeRole.values, n['role'], NodeRole.main),
      elevation:
          n['elev_m'] == null ? null : Length((n['elev_m'] as num).toDouble()),
      // Per-node wall mounting height (above its floor). Tolerant: absent ⇒
      // null ⇒ the role-derived elevation.
      mountHeight: n['mount_h_m'] == null
          ? null
          : Length((n['mount_h_m'] as num).toDouble()),
      fixture: n['fixture'] == null
          ? null
          : _enumOrNull(PlumbingFixture.values, n['fixture']),
      airflow: n['airflow_lps'] == null
          ? null
          : FlowRate.litersPerSecond((n['airflow_lps'] as num).toDouble()),
      customFixtureId: n['customFixtureId'] as String?,
      roofAreaM2: (n['roof_area_m2'] as num?)?.toDouble(),
      // Tolerant: absent / unknown ⇒ null ⇒ an ordinary node.
      component: n['component'] == null
          ? null
          : _enumOrNull(NodeComponent.values, n['component']),
      tankCapacityLitres: (n['tank_l'] as num?)?.toDouble(),
      electricalLoadW: (n['elec_w'] as num?)?.toDouble(),
      faceWidthMm: (n['face_w_mm'] as num?)?.toDouble(),
      faceHeightMm: (n['face_h_mm'] as num?)?.toDouble(),
      fittingType: n['fitting'] == null
          ? null
          : _enumOrNull(JunctionFitting.values, n['fitting']),
    );

Map<String, dynamic> _netEdgeToJson(NetEdge e) => {
      'id': e.id,
      'from': e.fromId,
      'to': e.toId,
      'service': e.service.name,
      'kind': e.kind.name,
      if (e.pipeProduct != null) 'pipe_product': e.pipeProduct!.name,
      if (e.ductProduct != null) 'duct_product': e.ductProduct!.name,
      if (e.sizeOverride != null)
        'size_override_mm': e.sizeOverride!.inMillimeters,
    };

NetEdge _netEdgeFromJson(Map e) => NetEdge(
      id: e['id'] as String,
      fromId: e['from'] as String,
      toId: e['to'] as String,
      service: _enumOr(ServiceType.values, e['service'], ServiceType.coldWater),
      kind: _enumOr(EdgeKind.values, e['kind'], EdgeKind.run),
      pipeProduct: _enumOrNull(PipeProduct.values, e['pipe_product']),
      ductProduct: _enumOrNull(DuctProduct.values, e['duct_product']),
      sizeOverride: e['size_override_mm'] == null
          ? null
          : Diameter.mm((e['size_override_mm'] as num).toDouble()),
    );

/// A named, re-stampable group of drawn nodes + edges (E5) — a reusable "block":
/// the WC toilet group, the pump-room hookup, a shaft riser set. Persisted in
/// [DesignSettings.savedAssemblies]; the [nodes]/[edges] are captured value
/// copies serialized with the SAME network encoding a drawn node/edge uses, so a
/// stamp re-instantiates them with fresh ids via the existing clone path.
/// Coordinates are stored as captured (sheet px); the stamp re-bases them to the
/// drop point.
class SavedAssembly {
  final String id;
  final String name;
  final List<NetNode> nodes;
  final List<NetEdge> edges;

  const SavedAssembly({
    required this.id,
    required this.name,
    this.nodes = const [],
    this.edges = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'nodes': [for (final n in nodes) _netNodeToJson(n)],
        'edges': [for (final e in edges) _netEdgeToJson(e)],
      };

  /// Tolerant decode: returns null when [raw] is not a map or is missing its
  /// id/name. A missing/absent nodes/edges list yields an empty one.
  static SavedAssembly? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || name is! String) return null;
    final nodes = <NetNode>[
      for (final n in (raw['nodes'] as List? ?? const []))
        if (n is Map) _netNodeFromJson(n),
    ];
    final edges = <NetEdge>[
      for (final e in (raw['edges'] as List? ?? const []))
        if (e is Map) _netEdgeFromJson(e),
    ];
    return SavedAssembly(id: id, name: name, nodes: nodes, edges: edges);
  }
}

/// Versioned iSystem project document — the on-disk format (a `.mechx` JSON file;
/// the extension is kept for backward compatibility).
/// Pure (de)serialization only; callers handle file IO. A `version` header is
/// written from day one so the format can migrate.
class ProjectDocument {
  /// Bumped to 2 when the optional electrical sub-model ([electrical]) was
  /// added. The addition is ADDITIVE — a v1 file (no `electrical` key) loads
  /// fine with [electrical] == null, so no migration step is needed.
  static const int currentVersion = 2;

  final int version;
  final String projectName;
  final List<Floor> floors;
  final Map<String, ScaleCalibration> calibrations;
  final List<Sheet> sheets;
  final Network network;

  /// Per-sheet pan/zoom, so a reopened project restores each view (§4).
  final Map<String, ViewportTransform> viewports;

  /// Explicit sheet → building-floor overrides.
  final Map<String, int> sheetFloors;

  /// Non-network design inputs (occupancy, feed, ducts, rainfall, fire, theme).
  final DesignSettings settings;

  /// Measurement annotations (dimension lines on the calibrated sheets). Not part
  /// of the network — purely an overlay; defaults empty.
  final List<Measurement> measurements;

  /// Designated tank/reservoir areas on the calibrated sheets (footprint + depth
  /// + material → capacity). An annotation, not part of the network; empty by
  /// default.
  final List<TankArea> tanks;

  /// Designated room/zone areas on the calibrated sheets (footprint + ceiling +
  /// ACH → airflow). An annotation, not part of the network; empty by default.
  final List<RoomArea> rooms;

  /// Optional electrical sub-model (panels + earthing system). Added in v2;
  /// null for a v1 file or a project with no electrical design yet.
  final ElectricalProject? electrical;

  /// EMBEDDED source plans, keyed by the sheet path that references them, value =
  /// base64 of the file bytes. When present, the `.mechx` is self-contained /
  /// portable across machines: the referenced PDF/DXF need not travel alongside
  /// it. Empty when embedding is off (recovery snapshots) or no plan is loaded,
  /// so a path-only project stays byte-identical. Multi-page PDFs share one
  /// entry (keyed by the single source path). Additive — an older build ignores
  /// the key; a build without the source files falls back to the paths.
  final Map<String, String> assets;

  const ProjectDocument({
    this.version = currentVersion,
    required this.projectName,
    required this.floors,
    required this.calibrations,
    required this.sheets,
    required this.network,
    this.viewports = const {},
    this.sheetFloors = const {},
    this.settings = const DesignSettings(),
    this.electrical,
    this.measurements = const [],
    this.tanks = const [],
    this.rooms = const [],
    this.assets = const {},
  });

  /// A copy with [sheets] (and optionally [assets]) replaced — used by asset
  /// rehydration to repoint sheet paths at the extracted local files.
  ProjectDocument withSheets(List<Sheet> sheets, {Map<String, String>? assets}) =>
      ProjectDocument(
        version: version,
        projectName: projectName,
        floors: floors,
        calibrations: calibrations,
        sheets: sheets,
        network: network,
        viewports: viewports,
        sheetFloors: sheetFloors,
        settings: settings,
        electrical: electrical,
        measurements: measurements,
        tanks: tanks,
        rooms: rooms,
        assets: assets ?? this.assets,
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'project': {
          'name': projectName,
          'floors': [
            for (final f in floors) {'name': f.name, 'height_m': f.height.meters},
          ],
          'calibrations': {
            for (final e in calibrations.entries) e.key: e.value.metersPerPixel,
          },
        },
        'sheets': [
          for (final s in sheets)
            {
              'id': s.id,
              'name': s.name,
              'pdfPath': s.pdfPath,
              if (s.dxfPath != null) 'dxfPath': s.dxfPath,
              if (s.dwgPath != null) 'dwgPath': s.dwgPath,
              'pageIndex': s.pageIndex,
              'w': s.sizePx.width,
              'h': s.sizePx.height,
            },
        ],
        'viewports': {
          for (final e in viewports.entries)
            e.key: {
              'scale': e.value.scale,
              'dx': e.value.offset.dx,
              'dy': e.value.offset.dy,
            },
        },
        'sheetFloors': {
          for (final e in sheetFloors.entries) e.key: e.value,
        },
        'settings': settings.toJson(),
        'measurements': [for (final m in measurements) m.toJson()],
        'tanks': [for (final t in tanks) t.toJson()],
        'rooms': [for (final r in rooms) r.toJson()],
        if (electrical != null) 'electrical': electrical!.toJson(),
        // Embedded source plans (base64), only when present ⇒ path-only projects
        // stay byte-identical.
        if (assets.isNotEmpty) 'assets': assets,
        'network': {
          'nodes': [for (final n in network.nodes) _netNodeToJson(n)],
          'edges': [for (final e in network.edges) _netEdgeToJson(e)],
        },
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory ProjectDocument.fromJson(Map<String, dynamic> json) {
    final version = (json['version'] as num?)?.toInt() ?? currentVersion;
    if (version > currentVersion) {
      throw ProjectDocumentException(
        'This project was saved by a newer MechX (file format v$version; '
        'this build reads up to v$currentVersion). Please update MechX.',
      );
    }
    // Future versions < currentVersion would be migrated here before parsing.
    if (json['project'] is! Map) {
      throw const ProjectDocumentException(
        'Not an iSystem project file (missing "project" section).',
      );
    }
    final project = json['project'] as Map<String, dynamic>;
    final floors = [
      for (final f in project['floors'] as List)
        Floor(
          (f as Map)['name'] as String,
          Length((f['height_m'] as num).toDouble()),
        ),
    ];
    final calibrations = <String, ScaleCalibration>{
      for (final e in (project['calibrations'] as Map).entries)
        e.key as String: ScaleCalibration((e.value as num).toDouble()),
    };
    final sheets = [
      for (final s in json['sheets'] as List)
        Sheet(
          id: (s as Map)['id'] as String,
          name: s['name'] as String,
          pdfPath: s['pdfPath'] as String?,
          dxfPath: s['dxfPath'] as String?,
          dwgPath: s['dwgPath'] as String?,
          pageIndex: (s['pageIndex'] as num).toInt(),
          sizePx: Size((s['w'] as num).toDouble(), (s['h'] as num).toDouble()),
        ),
    ];
    final net = json['network'] as Map<String, dynamic>;
    final nodes = [
      for (final n in net['nodes'] as List) _netNodeFromJson(n as Map),
    ];
    final edges = [
      for (final e in net['edges'] as List) _netEdgeFromJson(e as Map),
    ];
    final viewports = <String, ViewportTransform>{};
    final rawViewports = json['viewports'];
    if (rawViewports is Map) {
      rawViewports.forEach((key, v) {
        if (v is Map && v['scale'] is num) {
          viewports[key as String] = ViewportTransform(
            scale: (v['scale'] as num).toDouble(),
            offset: Offset(
              (v['dx'] as num?)?.toDouble() ?? 0,
              (v['dy'] as num?)?.toDouble() ?? 0,
            ),
          );
        }
      });
    }
    final sheetFloors = <String, int>{};
    final rawFloors = json['sheetFloors'];
    if (rawFloors is Map) {
      rawFloors.forEach((key, v) {
        if (v is num) sheetFloors[key as String] = v.toInt();
      });
    }
    final rawSettings = json['settings'];
    final settings = rawSettings is Map
        ? DesignSettings.fromJson(rawSettings)
        : const DesignSettings();
    // Optional electrical sub-model (v2+). Absent on a v1 file ⇒ null, no throw.
    final rawElectrical = json['electrical'];
    final electrical = rawElectrical is Map<String, dynamic>
        ? ElectricalProject.fromJson(rawElectrical)
        : null;
    // Measurement annotations (additive; absent on an older file ⇒ empty). Each
    // malformed entry is dropped rather than throwing.
    final measurements = <Measurement>[
      for (final m in (json['measurements'] as List? ?? const []))
        ?Measurement.fromJson(m),
    ];
    // Tank areas (additive; absent on an older file ⇒ empty).
    final tanks = <TankArea>[
      for (final t in (json['tanks'] as List? ?? const [])) ?TankArea.fromJson(t),
    ];
    // Room/zone areas (additive; absent on an older file ⇒ empty).
    final rooms = <RoomArea>[
      for (final r in (json['rooms'] as List? ?? const [])) ?RoomArea.fromJson(r),
    ];
    // Embedded source plans (additive; absent ⇒ empty ⇒ paths used as-is).
    final assets = <String, String>{
      for (final e in (json['assets'] as Map? ?? const {}).entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
    return ProjectDocument(
      version: version,
      projectName: project['name'] as String? ?? 'Untitled project',
      floors: floors,
      calibrations: calibrations,
      sheets: sheets,
      network: Network(nodes: nodes, edges: edges),
      viewports: viewports,
      sheetFloors: sheetFloors,
      settings: settings,
      electrical: electrical,
      measurements: measurements,
      tanks: tanks,
      rooms: rooms,
      assets: assets,
    );
  }

  factory ProjectDocument.decode(String source) {
    final Object? raw;
    try {
      raw = jsonDecode(source);
    } on FormatException catch (e) {
      throw ProjectDocumentException('File is not valid JSON: ${e.message}');
    }
    if (raw is! Map<String, dynamic>) {
      throw const ProjectDocumentException('Not an iSystem project file.');
    }
    try {
      return ProjectDocument.fromJson(raw);
    } on ProjectDocumentException {
      rethrow;
    } catch (e) {
      // Any structural/type error → a friendly, surfaceable message.
      throw ProjectDocumentException('Could not read project: $e');
    }
  }
}
