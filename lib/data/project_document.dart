import 'dart:convert';

import 'package:flutter/widgets.dart' show Size;
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

import '../store/models/sheet.dart';

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

  const ProjectDocument({
    this.version = currentVersion,
    required this.projectName,
    required this.floors,
    required this.calibrations,
    required this.sheets,
    required this.network,
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
        'network': {
          'nodes': [
            for (final n in network.nodes)
              {
                'id': n.id,
                'sheetId': n.sheetId,
                'x': n.x,
                'y': n.y,
                'floor': n.floorIndex,
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
        ),
    ];
    final edges = [
      for (final e in net['edges'] as List)
        NetEdge(
          id: (e as Map)['id'] as String,
          fromId: e['from'] as String,
          toId: e['to'] as String,
          service: ServiceType.values.byName(e['service'] as String),
          kind: EdgeKind.values.byName(e['kind'] as String),
        ),
    ];
    return ProjectDocument(
      version: (json['version'] as num?)?.toInt() ?? currentVersion,
      projectName: project['name'] as String,
      floors: floors,
      calibrations: calibrations,
      sheets: sheets,
      network: Network(nodes: nodes, edges: edges),
    );
  }

  factory ProjectDocument.decode(String source) =>
      ProjectDocument.fromJson(jsonDecode(source) as Map<String, dynamic>);
}
