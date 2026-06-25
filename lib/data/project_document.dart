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

  final DuctShape ductShape;
  final DuctSizingMethod ductMethod;
  final double rainfallMmPerHr;
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

  const DesignSettings({
    this.occupancy = Occupancy.private,
    this.upfeed = false,
    this.ductShape = DuctShape.round,
    this.ductMethod = DuctSizingMethod.velocity,
    this.rainfallMmPerHr = 200.0,
    this.fireHazard = FireHazardClass.ordinaryHazard1,
    this.brightness = Brightness.dark,
    this.localeCode = 'en',
    this.priceList = const {},
    this.labourRatePerHour = 150000,
    this.overheadPct = 10,
    this.contingencyPct = 5,
    this.marginPct = 15,
    this.fixtureLibrary = const [],
  });

  Map<String, dynamic> toJson() => {
        'occupancy': occupancy.name,
        'upfeed': upfeed,
        'ductShape': ductShape.name,
        'ductMethod': ductMethod.name,
        'rainfall_mmhr': rainfallMmPerHr,
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
      };

  /// Tolerant decode: every field falls back to its default on an
  /// unknown/absent value (forward/backward compatible).
  factory DesignSettings.fromJson(Map<dynamic, dynamic> json) => DesignSettings(
        occupancy:
            _enumOr(Occupancy.values, json['occupancy'], Occupancy.private),
        upfeed: json['upfeed'] == true,
        ductShape:
            _enumOr(DuctShape.values, json['ductShape'], DuctShape.round),
        ductMethod: _enumOr(
          DuctSizingMethod.values,
          json['ductMethod'],
          DuctSizingMethod.velocity,
        ),
        rainfallMmPerHr: (json['rainfall_mmhr'] as num?)?.toDouble() ?? 200.0,
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
      );

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

  /// Optional electrical sub-model (panels + earthing system). Added in v2;
  /// null for a v1 file or a project with no electrical design yet.
  final ElectricalProject? electrical;

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
  });

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
        if (electrical != null) 'electrical': electrical!.toJson(),
        'network': {
          'nodes': [
            for (final n in network.nodes)
              {
                'id': n.id,
                'sheetId': n.sheetId,
                'x': n.x,
                'y': n.y,
                'floor': n.floorIndex,
                'role': n.role.name,
                if (n.elevation != null) 'elev_m': n.elevation!.meters,
                if (n.mountHeight != null) 'mount_h_m': n.mountHeight!.meters,
                if (n.fixture != null) 'fixture': n.fixture!.name,
                if (n.airflow != null)
                  'airflow_lps': n.airflow!.inLitersPerSecond,
                if (n.customFixtureId != null)
                  'customFixtureId': n.customFixtureId,
                if (n.roofAreaM2 != null) 'roof_area_m2': n.roofAreaM2,
                if (n.component != null) 'component': n.component!.name,
                if (n.tankCapacityLitres != null)
                  'tank_l': n.tankCapacityLitres,
              },
          ],
          'edges': [
            for (final e in network.edges)
              {
                'id': e.id,
                'from': e.fromId,
                'to': e.toId,
                'service': e.service.name,
                'kind': e.kind.name,
                if (e.pipeProduct != null) 'pipe_product': e.pipeProduct!.name,
                if (e.ductProduct != null) 'duct_product': e.ductProduct!.name,
                if (e.sizeOverride != null)
                  'size_override_mm': e.sizeOverride!.inMillimeters,
              },
          ],
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
          pageIndex: (s['pageIndex'] as num).toInt(),
          sizePx: Size((s['w'] as num).toDouble(), (s['h'] as num).toDouble()),
        ),
    ];
    final net = json['network'] as Map<String, dynamic>;
    final nodes = [
      for (final n in net['nodes'] as List)
        NetNode(
          id: (n as Map)['id'] as String,
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
        ),
    ];
    final edges = [
      for (final e in net['edges'] as List)
        NetEdge(
          id: (e as Map)['id'] as String,
          fromId: e['from'] as String,
          toId: e['to'] as String,
          service:
              _enumOr(ServiceType.values, e['service'], ServiceType.coldWater),
          kind: _enumOr(EdgeKind.values, e['kind'], EdgeKind.run),
          pipeProduct: _enumOrNull(PipeProduct.values, e['pipe_product']),
          ductProduct: _enumOrNull(DuctProduct.values, e['duct_product']),
          sizeOverride: e['size_override_mm'] == null
              ? null
              : Diameter.mm((e['size_override_mm'] as num).toDouble()),
        ),
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
