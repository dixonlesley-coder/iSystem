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

  /// 0-based building floor this line belongs to, when the BOM was built with
  /// `groupByFloor: true` (a RUN's floor = its from-node's floorIndex). Null for
  /// risers (they span floors) and for the default un-grouped-by-floor build.
  final int? floorIndex;

  const BomLine({
    required this.service,
    required this.kind,
    required this.diameterMm,
    required this.totalLength,
    required this.segmentCount,
    this.floorIndex,
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
/// When [groupByFloor] is true the group key gains the floor: a RUN's floor is
/// its from-node's `floorIndex` (so the same DN on two floors becomes two lines),
/// while RISERS span floors and stay ungrouped-by-floor (`floorIndex == null`) as
/// their own rows. Default false ⇒ the pre-floor grouping (every line's
/// [BomLine.floorIndex] is null), byte-identical.
///
/// Returns lines sorted by:
///   1. [ServiceType] index (enum declaration order),
///   2. [EdgeKind] index (run before riser),
///   3. [BomLine.floorIndex] ascending (null treated as -1; uniform within a
///      kind group, so the default build reduces to the pre-floor order),
///   4. [BomLine.diameterMm] ascending.
List<BomLine> buildBom({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required Map<String, ScaleCalibration> calibrationBySheet,
  required BuildingLevels building,
  bool groupByFloor = false,
}) {
  // Accumulator: key → (totalMeters, segmentCount).
  final acc = <({ServiceType service, EdgeKind kind, int diameterMm, int? floorIndex}),
      ({double meters, int count})>{};

  for (final edge in net.edges) {
    final es = sizing[edge.id];
    if (es == null) continue;

    final diameterMm = es.diameter.inMillimeters.round();
    // Runs group by their from-node floor when requested; risers span floors so
    // they always stay ungrouped-by-floor (null).
    final floorIndex = (groupByFloor && edge.kind == EdgeKind.run)
        ? net.nodeById(edge.fromId)?.floorIndex
        : null;
    final key = (
      service: edge.service,
      kind: edge.kind,
      diameterMm: diameterMm,
      floorIndex: floorIndex,
    );

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
        floorIndex: entry.key.floorIndex,
      ),
  ];

  lines.sort((a, b) {
    final svc = a.service.index.compareTo(b.service.index);
    if (svc != 0) return svc;
    final knd = a.kind.index.compareTo(b.kind.index);
    if (knd != 0) return knd;
    final flr = (a.floorIndex ?? -1).compareTo(b.floorIndex ?? -1);
    if (flr != 0) return flr;
    return a.diameterMm.compareTo(b.diameterMm);
  });

  return lines;
}

// ── Fittings ──────────────────────────────────────────────────────────────────

/// Kind of pipe/duct fitting inferred from network topology.
enum FittingType { elbow, tee, cross, reducer }

/// One grouped fittings row: count of [type] at [diameterMm] for [service].
class FittingLine {
  final ServiceType service;
  final FittingType type;
  final int diameterMm;
  final int count;

  const FittingLine({
    required this.service,
    required this.type,
    required this.diameterMm,
    required this.count,
  });
}

/// Estimate fittings from node topology + per-edge sizes. At each node, per
/// service, the count of incident SIZED edges implies a fitting:
///   2 → elbow · 3 → tee · 4 → cross · >4 → (k−2) tees.
/// A node whose incident edges have more than one diameter also adds
/// (distinctDiameters − 1) reducers. Fitting size = the largest incident
/// diameter. This is a takeoff ESTIMATE (straight in-line couplings on a
/// polyline vertex are counted as elbows).
List<FittingLine> buildFittings({
  required Network net,
  required Map<String, EdgeSizing> sizing,
}) {
  // node → service → list of incident edge diameters (mm), sized edges only.
  final byNode = <String, Map<ServiceType, List<int>>>{};
  for (final edge in net.edges) {
    final es = sizing[edge.id];
    if (es == null) continue;
    final mm = es.diameter.inMillimeters.round();
    for (final nodeId in [edge.fromId, edge.toId]) {
      (byNode[nodeId] ??= {}).putIfAbsent(edge.service, () => []).add(mm);
    }
  }

  final acc = <({ServiceType service, FittingType type, int mm}), int>{};
  void add(ServiceType s, FittingType t, int mm, int n) {
    final key = (service: s, type: t, mm: mm);
    acc[key] = (acc[key] ?? 0) + n;
  }

  byNode.forEach((_, services) {
    services.forEach((service, diameters) {
      final k = diameters.length;
      final mm = diameters.reduce((a, b) => a > b ? a : b); // largest incident
      if (k == 2) {
        add(service, FittingType.elbow, mm, 1);
      } else if (k == 3) {
        add(service, FittingType.tee, mm, 1);
      } else if (k == 4) {
        add(service, FittingType.cross, mm, 1);
      } else if (k > 4) {
        add(service, FittingType.tee, mm, k - 2);
      }
      final distinct = diameters.toSet().length;
      if (distinct > 1) add(service, FittingType.reducer, mm, distinct - 1);
    });
  });

  final lines = [
    for (final e in acc.entries)
      FittingLine(
        service: e.key.service,
        type: e.key.type,
        diameterMm: e.key.mm,
        count: e.value,
      ),
  ];
  lines.sort((a, b) {
    final svc = a.service.index.compareTo(b.service.index);
    if (svc != 0) return svc;
    final t = a.type.index.compareTo(b.type.index);
    if (t != 0) return t;
    return a.diameterMm.compareTo(b.diameterMm);
  });
  return lines;
}

/// Render [fittings] as CSV (header + one row per line).
String fittingsToCsv(List<FittingLine> fittings) {
  final buffer = StringBuffer('service,fitting,nominal_dn_mm,count\n');
  for (final f in fittings) {
    buffer
      ..write(f.service.name)
      ..write(',')
      ..write(f.type.name)
      ..write(',')
      ..write(f.diameterMm)
      ..write(',')
      ..write(f.count)
      ..write('\n');
  }
  return buffer.toString();
}

/// Convenience: sums [BomLine.totalLength] for all lines belonging to [service].
Length totalLengthForService(List<BomLine> bom, ServiceType service) {
  var meters = 0.0;
  for (final line in bom) {
    if (line.service == service) meters += line.totalLength.meters;
  }
  return Length(meters);
}

/// Render [bom] as CSV (one header row + one row per line). Lengths are in
/// metres to two decimals. Pure — the app handles the file IO.
///
/// When any line carries a [BomLine.floorIndex] (i.e. the BOM was built with
/// `groupByFloor: true`) a `floor` column is inserted — the 1-based human floor
/// number, empty for risers. When no line carries a floor (the default build)
/// the CSV is byte-identical to the pre-floor format.
String bomToCsv(List<BomLine> bom) {
  final includeFloor = bom.any((l) => l.floorIndex != null);
  final buffer = StringBuffer(includeFloor
      ? 'service,kind,floor,nominal_dn_mm,length_m,segments\n'
      : 'service,kind,nominal_dn_mm,length_m,segments\n');
  for (final line in bom) {
    buffer
      ..write(line.service.name)
      ..write(',')
      ..write(line.kind.name)
      ..write(',');
    if (includeFloor) {
      buffer
        ..write(line.floorIndex == null ? '' : (line.floorIndex! + 1))
        ..write(',');
    }
    buffer
      ..write(line.diameterMm)
      ..write(',')
      ..write(line.totalLength.meters.toStringAsFixed(2))
      ..write(',')
      ..write(line.segmentCount)
      ..write('\n');
  }
  return buffer.toString();
}
