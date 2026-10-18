/// Bill-of-Materials aggregator — collapses a sized [Network] into grouped
/// pipe/duct quantities (total length + segment count) per service, kind
/// (run vs riser), nominal size, and material (so PPR and PVC price apart).
///
/// Pure Dart, zero Flutter imports.
library;

import 'dart:math' as math;

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

  /// I5 — true when this line's size came from a MANUAL override on at least one
  /// of its edges ([NetEdge.sizeOverride]) rather than purely from the auto-sizer
  /// (SNI-driven). Surfaced as a `*` marker in the CSV + report BOM rows (with a
  /// "* manually sized" footnote) so a reviewer/auditor can see from the
  /// deliverable alone that a human overrode a code-derived size. Defaults false
  /// ⇒ an all-auto BOM is byte-identical.
  final bool manual;

  /// Rectangular-duct dimensions (mm), rounded — non-null only for a rect duct.
  /// Round ducts / pipes leave both null and are sized by [diameterMm].
  final int? widthMm;
  final int? heightMm;

  /// 0-based building floor this line belongs to, when the BOM was built with
  /// `groupByFloor: true` (a RUN's floor = its from-node's floorIndex). Null for
  /// risers (they span floors) and for the default un-grouped-by-floor build.
  final int? floorIndex;

  /// Round 21 (bom-quote-2) — how many of this line's [segmentCount] edges are
  /// RUNS on an UNCALIBRATED sheet: they add a segment but contribute 0 m to
  /// [totalLength] (`edgeLength` cannot measure them), so the metres — and
  /// any quantity / price read off them — are UNDERSTATED. The app's
  /// 'unmeasured' marker, the mechanical cost line and the quotation read
  /// `unmeasuredSegments > 0`, never only an all-zero total. Default 0.
  final int unmeasuredSegments;

  const BomLine({
    required this.service,
    required this.kind,
    required this.diameterMm,
    required this.totalLength,
    required this.segmentCount,
    this.material = '',
    this.tag = '',
    this.manual = false,
    this.widthMm,
    this.heightMm,
    this.floorIndex,
    this.unmeasuredSegments = 0,
  });

  /// True when at least one edge of this line could not be measured.
  bool get hasUnmeasured => unmeasuredSegments > 0;

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
  // The project's mounting heights — the SAME value the solve passes to
  // `autoSizeNetwork`, so a riser's BOM length equals its solved length
  // (audit water-drainage-8). Default = the engine default ⇒ byte-identical.
  MountingHeights mounting = const MountingHeights(),
}) {
  // Per-riser stack tags (`CW-R1` …), computed once so a riser BOM line can
  // carry the SAME identifier the plan / riser single-line draw (N13).
  final riserTagByEdge = riserTags(net, null);

  // Accumulator: key → (totalMeters, segmentCount, riser tags, manual flag).
  final acc = <({
    ServiceType service,
    EdgeKind kind,
    int diameterMm,
    String material,
    int? widthMm,
    int? heightMm,
    int? floorIndex
  }), ({
    double meters,
    int count,
    Set<String> riserTags,
    bool manual,
    int unmeasured
  })>{};

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
      mounting: mounting,
    );

    // N13: which riser stack tag(s) this group covers (risers only).
    final rt = edge.kind == EdgeKind.riser ? riserTagByEdge[edge.id] : null;
    // I5: a line is "manual" when any of its edges carried a size override.
    final manual = edge.sizeOverride != null;
    // Round 21 — a RUN on an uncalibrated sheet measures 0 m (a riser's
    // length is the elevation delta, always measurable).
    final from = net.nodeById(edge.fromId);
    final unmeasured = edge.kind == EdgeKind.run &&
            (from == null || calibrationBySheet[from.sheetId] == null)
        ? 1
        : 0;

    final prev = acc[key];
    if (prev == null) {
      acc[key] = (
        meters: len.meters,
        count: 1,
        riserTags: {if (rt != null) rt},
        manual: manual,
        unmeasured: unmeasured,
      );
    } else {
      if (rt != null) prev.riserTags.add(rt);
      acc[key] = (
        meters: prev.meters + len.meters,
        count: prev.count + 1,
        riserTags: prev.riserTags,
        manual: prev.manual || manual,
        unmeasured: prev.unmeasured + unmeasured,
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
        manual: entry.value.manual,
        widthMm: entry.key.widthMm,
        heightMm: entry.key.heightMm,
        totalLength: Length(entry.value.meters),
        segmentCount: entry.value.count,
        floorIndex: entry.key.floorIndex,
        unmeasuredSegments: entry.value.unmeasured,
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

/// One grouped fittings row: count of [type] at [diameterMm] for [service],
/// in [material] (the [bomMaterialFor] code of the largest incident edge —
/// a PPR and a PVC fitting price and joint apart; '' = unknown / hand-built).
class FittingLine {
  final ServiceType service;
  final FittingType type;
  final int diameterMm;
  final int count;
  final String material;

  /// Round 21 (bom-quote-6) — a RECTANGULAR duct fitting's W×H (mm, the
  /// largest incident duct's); null for a round duct / pipe. [diameterMm] is
  /// then only the circular equivalent (kept for ordering), never printed or
  /// keyed: a `Ø457` elbow is not a purchasable size.
  final int? widthMm;
  final int? heightMm;

  const FittingLine({
    required this.service,
    required this.type,
    required this.diameterMm,
    required this.count,
    this.material = '',
    this.widthMm,
    this.heightMm,
  });

  /// The set-wide size notation (N18), shared with [BomLine.sizeLabel]:
  /// `W x H` for a rectangular duct, `Ø<mm>` round duct, `DN<mm>` pipe.
  String get sizeLabel {
    if (widthMm != null && heightMm != null) return '${widthMm}x$heightMm';
    return service.isAir ? 'Ø$diameterMm' : 'DN$diameterMm';
  }

  /// The CSV size cell: `WxH` for a rectangular duct, else the plain mm.
  String get csvSize => (widthMm != null && heightMm != null)
      ? '${widthMm}x$heightMm'
      : '$diameterMm';
}

/// Cosine below which two runs meeting at a vertex count as a straight
/// pass-through (opposite directions within ≈ 12°) — the same threshold
/// `buildPipeChains` uses to merge a continuous pipe through a vertex.
const double _kPassThroughCos = -0.978;

/// Estimate fittings from node topology + per-edge sizes. At each node, per
/// service, the count of incident SIZED edges implies a fitting:
///   2 → elbow · 3 → tee · 4 → cross · >4 → (k−2) tees.
/// A two-edge node is an elbow ONLY when the line actually turns: two
/// collinear runs (a straight pass-through vertex, e.g. a multi-click run or a
/// split segment) and two risers (a continuous vertical stack) count NO elbow —
/// the cut plan already places those couplings (audit r8: every straight
/// vertex used to be counted and priced as an elbow). A riser meeting a run is
/// an elbow. A node whose incident edges have more than one diameter also adds
/// (distinctDiameters − 1) reducers. Fitting size = the largest incident
/// diameter; fitting material = that edge's [bomMaterialFor] code.
List<FittingLine> buildFittings({
  required Network net,
  required Map<String, EdgeSizing> sizing,
}) {
  // node → service → incident (diameter mm, edge), sized edges only.
  final byNode = <String, Map<ServiceType, List<(int, NetEdge)>>>{};
  // Round 21 — each sized edge's printed size: W×H for a rectangular duct
  // (its `diameter` is only the circular equivalent), else the round mm.
  final rectOf = <String, (int, int)>{};
  for (final edge in net.edges) {
    final es = sizing[edge.id];
    if (es == null) continue;
    final mm = es.diameter.inMillimeters.round();
    if (es.isRectangular) {
      rectOf[edge.id] = (
        es.width!.inMillimeters.round(),
        es.height!.inMillimeters.round()
      );
    }
    for (final nodeId in [edge.fromId, edge.toId]) {
      (byNode[nodeId] ??= {})
          .putIfAbsent(edge.service, () => [])
          .add((mm, edge));
    }
  }
  String sizeKey((int, NetEdge) e) {
    final r = rectOf[e.$2.id];
    return r == null ? '${e.$1}' : '${r.$1}x${r.$2}';
  }

  // Round 21 (bom-quote-3) — an INLINE fixture-role terminal (a sprinkler
  // head / hydrant box / diffuser on a straight branch) sits on a reducing
  // TEE outlet, not a plain pass-through.
  bool inlineTerminal(String nodeId) {
    final c = net.nodeById(nodeId)?.component;
    return c != null &&
        c.role == NodeRole.fixture &&
        c != NodeComponent.cleanout &&
        c != NodeComponent.airVent &&
        c != NodeComponent.fireExtinguisher;
  }

  // Unit plan direction from [nodeId] toward [edge]'s far end, or null when
  // degenerate (coincident endpoints).
  ({double dx, double dy})? dirFrom(String nodeId, NetEdge edge) {
    final here = net.nodeById(nodeId);
    final far = net.nodeById(edge.fromId == nodeId ? edge.toId : edge.fromId);
    if (here == null || far == null) return null;
    final dx = far.x - here.x, dy = far.y - here.y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len <= 1e-9) return null;
    return (dx: dx / len, dy: dy / len);
  }

  bool isPassThrough(String nodeId, NetEdge a, NetEdge b) {
    if (a.kind == EdgeKind.riser && b.kind == EdgeKind.riser) return true;
    if (a.kind != EdgeKind.run || b.kind != EdgeKind.run) return false;
    final da = dirFrom(nodeId, a), db = dirFrom(nodeId, b);
    if (da == null || db == null) return false;
    return da.dx * db.dx + da.dy * db.dy <= _kPassThroughCos;
  }

  final acc = <({
    ServiceType service,
    FittingType type,
    int mm,
    String mat,
    int? w,
    int? h
  }), int>{};
  void add(ServiceType s, FittingType t, int mm, String mat, int n,
      (int, int)? rect) {
    final key =
        (service: s, type: t, mm: mm, mat: mat, w: rect?.$1, h: rect?.$2);
    acc[key] = (acc[key] ?? 0) + n;
  }

  byNode.forEach((nodeId, services) {
    services.forEach((service, incident) {
      final k = incident.length;
      // Largest incident diameter; its edge sets the material (ties → the
      // alphabetically-first code, deterministic).
      var best = incident.first;
      for (final e in incident.skip(1)) {
        if (e.$1 > best.$1 ||
            (e.$1 == best.$1 &&
                bomMaterialFor(e.$2).compareTo(bomMaterialFor(best.$2)) < 0)) {
          best = e;
        }
      }
      final mm = best.$1;
      final mat = bomMaterialFor(best.$2);
      final rect = rectOf[best.$2.id];
      if (k == 2) {
        if (inlineTerminal(nodeId)) {
          add(service, FittingType.tee, mm, mat, 1, rect);
        } else if (!isPassThrough(nodeId, incident[0].$2, incident[1].$2)) {
          add(service, FittingType.elbow, mm, mat, 1, rect);
        }
      } else if (k == 3) {
        add(service, FittingType.tee, mm, mat, 1, rect);
      } else if (k == 4) {
        add(service, FittingType.cross, mm, mat, 1, rect);
      } else if (k > 4) {
        add(service, FittingType.tee, mm, mat, k - 2, rect);
      }
      // Round 21 — distinct by the PRINTED size (a 600x300 -> 500x350
      // transition is a transition even at one equivalent diameter).
      final distinct = incident.map(sizeKey).toSet().length;
      if (distinct > 1) {
        add(service, FittingType.reducer, mm, mat, distinct - 1, rect);
      }
    });
  });

  final lines = [
    for (final e in acc.entries)
      FittingLine(
        service: e.key.service,
        type: e.key.type,
        diameterMm: e.key.mm,
        count: e.value,
        material: e.key.mat,
        widthMm: e.key.w,
        heightMm: e.key.h,
      ),
  ];
  lines.sort((a, b) {
    final svc = a.service.index.compareTo(b.service.index);
    if (svc != 0) return svc;
    final t = a.type.index.compareTo(b.type.index);
    if (t != 0) return t;
    final d = a.diameterMm.compareTo(b.diameterMm);
    if (d != 0) return d;
    final m = a.material.compareTo(b.material);
    if (m != 0) return m;
    final w = (a.widthMm ?? -1).compareTo(b.widthMm ?? -1);
    if (w != 0) return w;
    return (a.heightMm ?? -1).compareTo(b.heightMm ?? -1);
  });
  return lines;
}

/// Render [fittings] as CSV (header + one row per line). The size column is the
/// neutral `nominal_size_mm` (matching [bomToCsv]) — an air-duct fitting and a
/// pipe fitting both quote a nominal mm, a rectangular duct fitting its `WxH`;
/// the report FITTINGS table carries the Ø/DN notation. Round 21 — a
/// `material` column, so a PPR and a PVC DN50 tee are two DISTINCT rows.
String fittingsToCsv(List<FittingLine> fittings) {
  final buffer =
      StringBuffer('service,fitting,nominal_size_mm,material,count\n');
  for (final f in fittings) {
    buffer
      ..write(f.service.name)
      ..write(',')
      ..write(f.type.name)
      ..write(',')
      ..write(f.csvSize)
      ..write(',')
      ..write(f.material)
      ..write(',')
      ..write(f.count)
      ..write('\n');
  }
  return buffer.toString();
}

// ── Drawn components (valves, heads, terminals, drains, dampers) ─────────────

/// Round 21 (bom-quote-3) — the drawn COMPONENTS a take-off buys per piece:
/// valves, strainers, meters, air vents, drains / cleanouts, taps, sprinkler
/// heads, hydrant boxes / hose reels / FDCs / extinguishers, diffusers /
/// grilles, dampers and VAV boxes. Plant (pumps, tanks, boosters, AHU / FCU,
/// fans, AC units) is scheduled EQUIPMENT and the riser marker is not a part,
/// so neither is listed here.
const Set<NodeComponent> kTakeoffComponents = {
  NodeComponent.gateValve,
  NodeComponent.checkValve,
  NodeComponent.prv,
  NodeComponent.balancingValve,
  NodeComponent.strainer,
  NodeComponent.waterMeter,
  NodeComponent.airVent,
  NodeComponent.expansionTank,
  NodeComponent.roofDrain,
  NodeComponent.floorDrain,
  NodeComponent.cleanout,
  NodeComponent.waterOutlet,
  NodeComponent.sprinklerHead,
  NodeComponent.fireExtinguisher,
  NodeComponent.hydrantBox,
  NodeComponent.hoseReel,
  NodeComponent.fireDeptConnection,
  NodeComponent.supplyDiffuser,
  NodeComponent.returnGrille,
  NodeComponent.exhaustGrille,
  NodeComponent.linearDiffuser,
  NodeComponent.volumeDamper,
  NodeComponent.fireDamper,
  NodeComponent.motorizedDamper,
  NodeComponent.vavBox,
};

/// The service an UNPIPED component belongs to (an auto-placed diffuser not
/// yet ducted is still bought) — its conventional service.
ServiceType _componentDefaultService(NodeComponent c) => switch (c) {
      NodeComponent.supplyDiffuser ||
      NodeComponent.linearDiffuser ||
      NodeComponent.vavBox ||
      NodeComponent.volumeDamper ||
      NodeComponent.fireDamper ||
      NodeComponent.motorizedDamper =>
        ServiceType.duct,
      NodeComponent.returnGrille => ServiceType.returnAir,
      NodeComponent.exhaustGrille => ServiceType.exhaust,
      NodeComponent.sprinklerHead => ServiceType.fireSprinkler,
      NodeComponent.hydrantBox ||
      NodeComponent.hoseReel ||
      NodeComponent.fireDeptConnection ||
      NodeComponent.fireExtinguisher =>
        ServiceType.fireHydrant,
      NodeComponent.roofDrain => ServiceType.rainwater,
      NodeComponent.floorDrain ||
      NodeComponent.cleanout =>
        ServiceType.drainage,
      _ => ServiceType.coldWater,
    };

/// One grouped drawn-component row: [count] × [component] on [service] at
/// [sizeLabel] (a valve / head / drain at its largest incident `DN<mm>`, an
/// air terminal at its chosen face `W x H`, else its largest incident duct;
/// '' when nothing sizes it).
class ComponentLine {
  final ServiceType service;
  final NodeComponent component;
  final String sizeLabel;
  final int count;

  const ComponentLine({
    required this.service,
    required this.component,
    required this.sizeLabel,
    required this.count,
  });
}

/// Round 21 (bom-quote-3) — the per-piece take-off of every drawn component
/// in [kTakeoffComponents], grouped by (service, component, size). Service =
/// the component's incident edge service (lowest enum index when several),
/// else its conventional service. Pure; sorted by service, component, size.
List<ComponentLine> buildComponentTakeoff({
  required Network net,
  required Map<String, EdgeSizing> sizing,
}) {
  final acc = <(ServiceType, NodeComponent, String), int>{};
  for (final n in net.nodes) {
    final c = n.component;
    if (c == null || !kTakeoffComponents.contains(c)) continue;
    final incident = net.edgesAt(n.id).toList()
      ..sort((a, b) => a.service.index.compareTo(b.service.index));
    final service =
        incident.isEmpty ? _componentDefaultService(c) : incident.first.service;
    var size = '';
    final fw = n.faceWidthMm, fh = n.faceHeightMm;
    if (fw != null && fh != null && fw > 0 && fh > 0) {
      size = '${fw.round()}x${fh.round()}';
    } else {
      EdgeSizing? best;
      for (final e in incident) {
        final es = sizing[e.id];
        if (es == null) continue;
        if (best == null ||
            es.diameter.inMillimeters > best.diameter.inMillimeters) {
          best = es;
        }
      }
      if (best != null) {
        size = best.isRectangular
            ? '${best.width!.inMillimeters.round()}x'
                '${best.height!.inMillimeters.round()}'
            : service.isAir
                ? 'Ø${best.diameter.inMillimeters.round()}'
                : 'DN${best.diameter.inMillimeters.round()}';
      }
    }
    final key = (service, c, size);
    acc[key] = (acc[key] ?? 0) + 1;
  }
  final lines = [
    for (final e in acc.entries)
      ComponentLine(
          service: e.key.$1,
          component: e.key.$2,
          sizeLabel: e.key.$3,
          count: e.value),
  ]..sort((a, b) {
      final s = a.service.index.compareTo(b.service.index);
      if (s != 0) return s;
      final c = a.component.index.compareTo(b.component.index);
      if (c != 0) return c;
      return a.sizeLabel.compareTo(b.sizeLabel);
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
///
/// I5: when any line is a MANUAL override ([BomLine.manual]) a trailing `manual`
/// column is inserted, carrying `*` for an overridden line (empty otherwise), so
/// a takeoff can tell an engineer-forced size from a code-derived one. Both
/// columns are conditional, so an all-auto / un-floored BOM stays byte-identical.
String bomToCsv(List<BomLine> bom) {
  final includeFloor = bom.any((l) => l.floorIndex != null);
  final includeManual = bom.any((l) => l.manual);
  final header = StringBuffer('service,kind,tag,');
  if (includeFloor) header.write('floor,');
  header.write('nominal_size_mm,material,length_m,segments');
  if (includeManual) header.write(',manual');
  header.write('\n');
  final buffer = StringBuffer(header.toString());
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
      ..write(line.segmentCount);
    if (includeManual) {
      buffer
        ..write(',')
        ..write(line.manual ? '*' : '');
    }
    buffer.write('\n');
  }
  return buffer.toString();
}
