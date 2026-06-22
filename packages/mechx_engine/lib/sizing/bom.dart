/// Bill-of-Materials aggregator — collapses a sized [Network] into grouped
/// pipe/duct quantities (total length + segment count) per service, kind
/// (run vs riser), and nominal diameter.
///
/// Pure Dart, zero Flutter imports.
library;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';

/// One row in the bill of materials.
///
/// Groups all edges that share the same [service], [kind], and [diameterMm]
/// (the nominal diameter rounded to the nearest millimetre).
class BomLine {
  final ServiceType service;
  final EdgeKind kind;
  final int diameterMm;
  final Length totalLength;
  final int segmentCount;

  const BomLine({
    required this.service,
    required this.kind,
    required this.diameterMm,
    required this.totalLength,
    required this.segmentCount,
  });
}

/// Aggregates [net] + [sizing] into a bill of materials.
///
/// For every edge that appears in [sizing]:
/// - The group key is `(edge.service, edge.kind,
///   sizing.diameter.inMillimeters.round())`.
/// - [edgeLength] is called (via the calibration/building context) to
///   measure the physical length, which is accumulated into [BomLine.totalLength].
/// - [BomLine.segmentCount] counts how many individual edges fall in the group.
///
/// Edges absent from [sizing] are silently skipped (unsized / ignored segments).
///
/// Returns lines sorted by:
///   1. [ServiceType] index (enum declaration order),
///   2. [EdgeKind] index (run before riser),
///   3. [BomLine.diameterMm] ascending.
List<BomLine> buildBom({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required Map<String, ScaleCalibration> calibrationBySheet,
  required BuildingLevels building,
}) {
  // Accumulator: key → (totalMeters, segmentCount).
  final acc = <({ServiceType service, EdgeKind kind, int diameterMm}),
      ({double meters, int count})>{};

  for (final edge in net.edges) {
    final es = sizing[edge.id];
    if (es == null) continue;

    final diameterMm = es.diameter.inMillimeters.round();
    final key = (service: edge.service, kind: edge.kind, diameterMm: diameterMm);

    final len = edgeLength(
      edge,
      net,
      calibrationBySheet: calibrationBySheet,
      building: building,
    );

    final prev = acc[key];
    acc[key] = prev == null
        ? (meters: len.meters, count: 1)
        : (meters: prev.meters + len.meters, count: prev.count + 1);
  }

  final lines = [
    for (final entry in acc.entries)
      BomLine(
        service: entry.key.service,
        kind: entry.key.kind,
        diameterMm: entry.key.diameterMm,
        totalLength: Length(entry.value.meters),
        segmentCount: entry.value.count,
      ),
  ];

  lines.sort((a, b) {
    final svc = a.service.index.compareTo(b.service.index);
    if (svc != 0) return svc;
    final knd = a.kind.index.compareTo(b.kind.index);
    if (knd != 0) return knd;
    return a.diameterMm.compareTo(b.diameterMm);
  });

  return lines;
}

/// Convenience: sums [BomLine.totalLength] for all lines belonging to [service].
Length totalLengthForService(List<BomLine> bom, ServiceType service) {
  var meters = 0.0;
  for (final line in bom) {
    if (line.service == service) meters += line.totalLength.meters;
  }
  return Length(meters);
}
