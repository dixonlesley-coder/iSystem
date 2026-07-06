/// Bill-of-Materials aggregator — collapses a sized [Network] into grouped
/// pipe/duct quantities (total length + segment count) per service, kind
/// (run vs riser), nominal size, and material (so PPR and PVC price apart).
///
/// Pure Dart, zero Flutter imports.
library;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/riser_tags.dart'
    show riserServiceCode, riserTags;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/units.dart';

/// One row in the bill of materials.
///
/// Groups all edges that share the same [service], [kind], [diameterMm]
/// (the nominal diameter rounded to the nearest millimetre), [material], and —
/// for a rectangular duct — its [widthMm]×[heightMm]. Splitting by material
/// means PPR and PVC (or PU and BJLS duct) price on separate lines, as a
/// takeoff requires.
class BomLine {
  final ServiceType service;
  final EdgeKind kind;
  final int diameterMm;
  final Length totalLength;
  final int segmentCount;

  /// The material CODE this line prices under (PPR / PVC / CI / HDPE / BS / GI
  /// for pipes, PU / BJLS for ducts) — from the edge's chosen product, else the
  /// conventional service default (see [bomMaterialFor]). Empty only for a
  /// hand-built line that omitted it (the real [buildBom] path always sets it).
  final String material;

  /// The stable ELEMENT TAG that traces this line back to the plan, riser
  /// single-line and calc report (N13). A RISER row carries its per-service
  /// stack tag(s) from [riserTags] (`CW-R1`, or `CW-R1/CW-R2` when several
  /// distinct stacks share this size+material line); a RUN row carries
  /// `<code>-F<n>` (service code + 1-based floor) when the BOM is grouped by
  /// floor, else the bare service code. Empty only for a hand-built line that
  /// omitted it (the real [buildBom] path always sets it). Kept CSV/Markdown
  /// safe — the multi-stack join uses `/`, never a comma or pipe.
  final String tag;

  /// Rectangular-duct dimensions (mm), rounded — non-null only for a rect duct.
  /// Round ducts / pipes leave both null and are sized by [diameterMm].
  final int? widthMm;
  final int? heightMm;

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
    this.material = '',
    this.tag = '',
    this.widthMm,
    this.heightMm,
    this.floorIndex,
  });

  /// The set-wide size notation (N18): a rectangular duct as `W x H` (mm), a
  /// round air duct as `Ø<mm>`, a pipe as `DN<mm>` — the ONE notation the report
  /// BOM table and fittings table share, so one duct never prints four ways.
  String get sizeLabel {
    if (widthMm != null && heightMm != null) return '${widthMm}x$heightMm';
    return service.isAir ? 'Ø$diameterMm' : 'DN$diameterMm';
  }

  /// The CSV `nominal_size_mm` cell: the plain mm for a round duct / pipe, or
  /// `W x H` (mm) for a rectangular duct. No Ø/DN prefix — the sibling
  /// `material` column disambiguates duct from pipe for a spreadsheet consumer.
  String get csvSize =>
      (widthMm != null && heightMm != null) ? '${widthMm}x$heightMm' : '$diameterMm';
}

/// Resolve the material CODE a BOM line prices under — the edge's chosen pipe /
/// duct product, else the conventional service default. Air services resolve the
/// duct product (PU / BJLS) via [effectiveDuctProductFor]; piped services the
/// pipe product family (PPR / PVC / CI / HDPE) or the service default (PPR for
/// supply, PVC for drainage/vent/storm, BS steel for fire, GI otherwise). Never
/// fabricated — an unset product always maps to the conventional service default.
String bomMaterialFor(NetEdge edge) {
  if (edge.service.isAir) {
    return switch (effectiveDuctProductFor(edge)) {
      DuctProduct.bjls => 'BJLS',
      DuctProduct.pu => 'PU',
    };
  }
  final p = edge.pipeProduct;
  if (p != null) {
    return switch (p) {
      PipeProduct.pprPn10 ||
      PipeProduct.pprPn16 ||
      PipeProduct.pprPn20 =>
        'PPR',
      PipeProduct.pvcAw ||
      PipeProduct.pvcD ||
      PipeProduct.pvcJis ||
      PipeProduct.acousticPvc =>
        'PVC',
      PipeProduct.castIron => 'CI',
      PipeProduct.hdpe => 'HDPE',
    };
  }
  return switch (edge.service) {
    ServiceType.coldWater || ServiceType.hotWater => 'PPR',
    ServiceType.drainage ||
    ServiceType.vent ||
    ServiceType.rainwater =>
      'PVC',
    ServiceType.fireSprinkler || ServiceType.fireHydrant => 'BS',
    _ => 'GI',
  };
}

/// Aggregates [net] + [sizing] into a bill of materials.
///
/// For every edge that appears in [sizing]:
/// - The group key is `(edge.service, edge.kind, nominal size, material)` — the
///   nominal diameter (`sizing.diameter.inMillimeters.round()`) plus the
///   resolved [bomMaterialFor] material, plus a rectangular duct's W×H — so PPR
///   and PVC (or PU and BJLS duct) never merge onto one priced line.
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
  // Per-riser stack tags (`CW-R1` …), computed once so a riser BOM line can
  // carry the SAME identifier the plan / riser single-line draw (N13).
  final riserTagByEdge = riserTags(net, null);

  // Accumulator: key → (totalMeters, segmentCount, riser tags in the group).
  final acc = <({
    ServiceType service,
    EdgeKind kind,
    int diameterMm,
    String material,
    int? widthMm,
    int? heightMm,
    int? floorIndex
  }), ({double meters, int count, Set<String> riserTags})>{};

  for (final edge in net.edges) {
    final es = sizing[edge.id];
    if (es == null) continue;

    final diameterMm = es.diameter.inMillimeters.round();
    final material = bomMaterialFor(edge);
    // Rectangular ducts group (and print) as W×H; round ducts / pipes as their
    // nominal diameter.
    final widthMm = es.isRectangular ? es.width!.inMillimeters.round() : null;
    final heightMm = es.isRectangular ? es.height!.inMillimeters.round() : null;
    // Runs group by their from-node floor when requested; risers span floors so
    // they always stay ungrouped-by-floor (null).
    final floorIndex = (groupByFloor && edge.kind == EdgeKind.run)
        ? net.nodeById(edge.fromId)?.floorIndex
        : null;
    final key = (
      service: edge.service,
      kind: edge.kind,
      diameterMm: diameterMm,
      material: material,
      widthMm: widthMm,
      heightMm: heightMm,
      floorIndex: floorIndex,
    );

    final len = edgeLength(
      edge,
      net,
      calibrationBySheet: calibrationBySheet,
      building: building,
    );

    // N13: which riser stack tag(s) this group covers (risers only).
    final rt = edge.kind == EdgeKind.riser ? riserTagByEdge[edge.id] : null;

    final prev = acc[key];
    if (prev == null) {
      acc[key] = (
        meters: len.meters,
        count: 1,
        riserTags: {if (rt != null) rt},
      );
    } else {
      if (rt != null) prev.riserTags.add(rt);
      acc[key] = (
        meters: prev.meters + len.meters,
        count: prev.count + 1,
        riserTags: prev.riserTags,
      );
    }
  }

  // The N13 tag for a group: a riser row lists its distinct stack tag(s)
  // (sorted, `/`-joined so a multi-stack line is CSV/Markdown safe); a run row
  // is the service code plus its 1-based floor when floor-grouped (else bare).
  String tagFor(
      ({
        ServiceType service,
        EdgeKind kind,
        int diameterMm,
        String material,
        int? widthMm,
        int? heightMm,
        int? floorIndex
      }) key,
      Set<String> tags) {
    final code = riserServiceCode(key.service);
    if (key.kind == EdgeKind.riser) {
      if (tags.isEmpty) return code;
      final sorted = tags.toList()..sort();
      return sorted.join('/');
    }
    return key.floorIndex == null ? code : '$code-F${key.floorIndex! + 1}';
  }

  final lines = [
    for (final entry in acc.entries)
      BomLine(
        service: entry.key.service,
        kind: entry.key.kind,
        diameterMm: entry.key.diameterMm,
        material: entry.key.material,
        tag: tagFor(entry.key, entry.value.riserTags),
        widthMm: entry.key.widthMm,
        heightMm: entry.key.heightMm,
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
    final dia = a.diameterMm.compareTo(b.diameterMm);
    if (dia != 0) return dia;
    final mat = a.material.compareTo(b.material);
    if (mat != 0) return mat;
    final w = (a.widthMm ?? -1).compareTo(b.widthMm ?? -1);
    if (w != 0) return w;
    return (a.heightMm ?? -1).compareTo(b.heightMm ?? -1);
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

/// Render [fittings] as CSV (header + one row per line). The size column is the
/// neutral `nominal_size_mm` (matching [bomToCsv]) — an air-duct fitting and a
/// pipe fitting both quote a nominal mm; the report FITTINGS table carries the
/// Ø/DN notation.
String fittingsToCsv(List<FittingLine> fittings) {
  final buffer = StringBuffer('service,fitting,nominal_size_mm,count\n');
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
/// BREAKING CSV CHANGE (N14): the size column is now the neutral
/// `nominal_size_mm` (was `nominal_dn_mm`, which implied a pipe DN and read a
/// round duct as pipe), and a `material` column is inserted — PPR / PVC / CI /
/// HDPE / BS for pipe, PU / BJLS for duct — so a takeoff can price the run and
/// tell duct from pipe. A rectangular duct's size cell is `W x H` (mm).
///
/// N13: a `tag` column (right after `kind`) carries the stable element tag —
/// the riser stack tag (`CW-R1`) for a riser row, `<code>-F<n>` (or the bare
/// service code, ungrouped) for a run — so a CSV takeoff line traces back to
/// the same run/riser on the plan, riser single-line and calc report.
///
/// When any line carries a [BomLine.floorIndex] (i.e. the BOM was built with
/// `groupByFloor: true`) a `floor` column is inserted — the 1-based human floor
/// number, empty for risers.
String bomToCsv(List<BomLine> bom) {
  final includeFloor = bom.any((l) => l.floorIndex != null);
  final buffer = StringBuffer(includeFloor
      ? 'service,kind,tag,floor,nominal_size_mm,material,length_m,segments\n'
      : 'service,kind,tag,nominal_size_mm,material,length_m,segments\n');
  for (final line in bom) {
    buffer
      ..write(line.service.name)
      ..write(',')
      ..write(line.kind.name)
      ..write(',')
      ..write(line.tag)
      ..write(',');
    if (includeFloor) {
      buffer
        ..write(line.floorIndex == null ? '' : (line.floorIndex! + 1))
        ..write(',');
    }
    buffer
      ..write(line.csvSize)
      ..write(',')
      ..write(line.material)
      ..write(',')
      ..write(line.totalLength.meters.toStringAsFixed(2))
      ..write(',')
      ..write(line.segmentCount)
      ..write('\n');
  }
  return buffer.toString();
}
