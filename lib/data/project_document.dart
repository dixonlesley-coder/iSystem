import 'dart:convert';

import 'package:flutter/widgets.dart' show Offset, Size;
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

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

/// Versioned MechX project document — the on-disk format (a `.mechx` JSON file).
/// Pure (de)serialization only; callers handle file IO. A `version` header is
/// written from day one so the format can migrate.
class ProjectDocument {
  static const int currentVersion = 1;

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

  const ProjectDocument({
    this.version = currentVersion,
    required this.projectName,
    required this.floors,
    required this.calibrations,
    required this.sheets,
    required this.network,
    this.viewports = const {},
    this.sheetFloors = const {},
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
                if (n.fixture != null) 'fixture': n.fixture!.name,
                if (n.airflow != null)
                  'airflow_lps': n.airflow!.inLitersPerSecond,
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
        'Not a MechX project file (missing "project" section).',
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
          fixture: n['fixture'] == null
              ? null
              : _enumOrNull(PlumbingFixture.values, n['fixture']),
          airflow: n['airflow_lps'] == null
              ? null
              : FlowRate.litersPerSecond((n['airflow_lps'] as num).toDouble()),
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
    return ProjectDocument(
      version: version,
      projectName: project['name'] as String? ?? 'Untitled project',
      floors: floors,
      calibrations: calibrations,
      sheets: sheets,
      network: Network(nodes: nodes, edges: edges),
      viewports: viewports,
      sheetFloors: sheetFloors,
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
      throw const ProjectDocumentException('Not a MechX project file.');
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
