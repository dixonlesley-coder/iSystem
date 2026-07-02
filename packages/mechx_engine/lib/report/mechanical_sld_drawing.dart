/// Pure (Flutter-free) geometry for a PROFESSIONAL mechanical riser single-line
/// — the air-bersih / drainage / air riser diagram as drafter-grade vector
/// content, rendered identically by the PDF (`sld_pdf_export.dart`) and DXF
/// (`sld_dxf_export.dart`) exporters. The mechanical analogue of
/// `electrical_sld_drawing.dart`: it emits the same neutral [SldSheet]
/// primitives so both formats agree and the layout is unit-testable without any
/// output encoding.
///
/// Floors are stacked by their TRUE elevation (§10): floor 0 at the bottom, the
/// roof at the top. Each piped run/riser carries the industry
/// `SIZE-SERVICE-MATERIAL[-FUNCTION]` tag (e.g. `50-CW-PPR-GRAVITASI`) and every
/// riser its per-service tag (`CW-R1`); each floor's distributed fixtures fan
/// out as short stubs. The KETERANGAN device legend + a supply note ride the
/// sheet frame (stamped page-fixed by each renderer). Zero Flutter imports.
library;

import 'dart:math' as math;

import '../geometry/building.dart' show BuildingLevels;
import '../network/network.dart';
import '../sizing/network_sizing.dart' show EdgeSizing;
import '../standards/pipe_products.dart' show PipeProduct;
import '../standards/sni.dart' show PlumbingFixture;
import 'riser_tags.dart';
import 'sld_sheet.dart';

// ── Drawing geometry (y-down drawing units) ──────────────────────────────────
const double _gutterW = 132; // left gutter: floor name + FFL
const double _drawW = 840; // node placement band width
const double _sidePad = 48; // inset for node x within the band
const double _bandH = 150; // per-floor band height
const double _topPad = 24;
const double _nodeBox = 12; // schematic node marker half-extent
const double _fanColW = 150; // per-floor fan-out column width (right gutter)

// ── Label-collision metrics (B5) ─────────────────────────────────────────────
// A single per-size character-advance used to size every label's collision box
// (width = chars x size x this). Pinned to the run-tag centring already used
// below (`length x 2.4` half-width at size 8 => 4.8/char = 0.6 x 8), so the
// default (uncollided) run tag stays centred exactly as before.
// VERIFY: a representative average glyph advance for the drawing font — a
// drafting collision metric, not a standard. Public so the collision unit test
// can size boxes with the SAME constant the builder uses.
const double kMechRiserLabelCharW = 0.6;
// A chosen label slot pulled more than this far (drawing units) from its default
// anchor gets a short leader line back to the element it tags.
const double _kLeaderThreshold = 14;
// Minimal x nudge per coincident node so two fixtures at the same world x don't
// stack their markers/labels.
const double _kSpreadStep = 18;

/// Build the mechanical riser single-line as an [SldSheet] for [network].
///
/// [sizing] maps edgeId → its sized record (for the `SIZE-SERVICE-MATERIAL` tag;
/// an edge with no sizing falls back to a service-only tag). [building] supplies
/// the true floor elevations for the FFL gutter labels (degrades to `Level n`
/// when absent). [focus] filters to a single service (null ⇒ the combined view).
/// [downfeed] is the feed strategy (drives the GRAVITASI/BOOSTER/TRANSFER
/// function suffix). [projectName] + [tanksNote] feed the title-block supply
/// line. Pure — no clock, no IO.
SldSheet buildMechanicalRiserSld({
  required Network network,
  Map<String, EdgeSizing> sizing = const {},
  BuildingLevels? building,
  ServiceType? focus,
  bool downfeed = false,
  String supplyNote = '',
}) {
  final prims = <SldPrim>[];

  // Visible node ids under the focus filter (endpoints of focused-service edges).
  final Set<String>? visible = _focusedNodeIds(network, focus);
  bool nodeVisible(NetNode n) => visible == null || visible.contains(n.id);

  final nodes = network.nodes.where(nodeVisible).toList(growable: false);
  if (nodes.isEmpty) {
    return SldSheet(
      prims: const [],
      minX: 0,
      minY: 0,
      maxX: _gutterW + _drawW,
      maxY: _topPad + _bandH,
      legend: _fittingLegend(network, focus),
      supplyNote: supplyNote,
    );
  }

  // Floor range: every building level when known, else the node floor span.
  final floorsPresent = nodes.map((n) => n.floorIndex).toSet();
  final int loFloor;
  final int hiFloor;
  if (building != null && building.levelCount > 0) {
    loFloor = 0;
    hiFloor = building.levelCount - 1;
  } else {
    loFloor = floorsPresent.reduce(math.min);
    hiFloor = floorsPresent.reduce(math.max);
  }
  final bandCount = (hiFloor - loFloor + 1).clamp(1, 999);

  // Band centre y for a floor index — highest floor at the TOP.
  double bandTop(int floorIndex) =>
      _topPad + (hiFloor - floorIndex) * _bandH;
  double bandCentreY(int floorIndex) => bandTop(floorIndex) + _bandH / 2;

  // Map a node's x into the placement band [_gutterW+pad, _gutterW+drawW-pad].
  final xs = nodes.map((n) => n.x).toList()..sort();
  final minNodeX = xs.first;
  final maxNodeX = xs.last;
  final span = (maxNodeX - minNodeX).abs();
  double placeX(double x) {
    if (span < 1e-6) return _gutterW + _drawW / 2;
    final t = (x - minNodeX) / span;
    return _gutterW + _sidePad + t * (_drawW - 2 * _sidePad);
  }

  Offset posOf(NetNode n) => Offset(placeX(n.x), bandCentreY(n.floorIndex));

  final posById = <String, Offset>{
    for (final n in nodes) n.id: posOf(n),
  };

  // ── Spread coincident node positions minimally in x (B5) ─────────────────────
  // Two fixtures at the same world x land on the same band point and stack their
  // markers/labels; nudge each such group apart in x, centred on the shared
  // point, deterministically (by node id).
  final coincident = <String, List<NetNode>>{};
  for (final n in nodes) {
    final p = posById[n.id]!;
    (coincident['${n.floorIndex}:${p.dx.round()}'] ??= <NetNode>[]).add(n);
  }
  for (final group in coincident.values) {
    if (group.length < 2) continue;
    group.sort((a, b) => a.id.compareTo(b.id));
    final baseX = posById[group.first.id]!.dx;
    for (var i = 0; i < group.length; i++) {
      final dx = (i - (group.length - 1) / 2) * _kSpreadStep;
      final p = posById[group[i].id]!;
      posById[group[i].id] = Offset(baseX + dx, p.dy);
    }
  }

  // The greedy label placer tracks every emitted label rect and diverts a
  // colliding tag along an offset ladder, adding a leader when pulled far off
  // its anchor (B5). Fixed labels (gutter, fan-out) are reserved FIRST so the
  // movable band tags divert around them.
  final placer = _LabelPlacer(prims);

  // ── Floor bands: a baseline hairline + the FFL gutter label ─────────────────
  // Datum baselines stay THIN so a pipe run/riser (medium, below) reads as
  // distinct ink from the floor line (B4).
  for (var f = loFloor; f <= hiFloor; f++) {
    final top = bandTop(f);
    final yBase = top + _bandH - 1;
    prims.add(SldLine(_gutterW, yBase, _gutterW + _drawW, yBase,
        weight: SldWeight.thin));
    final name = (building != null && f < building.levelCount)
        ? building.floors[f].name
        : 'Level ${f + 1}';
    placer.reserve(SldLabel(8, top + 18, name, size: 10, bold: true));
    if (building != null && f < building.levelCount) {
      final ffl = building.elevationOf(f).meters;
      placer.reserve(SldLabel(
          8, top + 32, 'FFL +${ffl.toStringAsFixed(2)}',
          size: 8, role: SldRole.source));
    }
  }

  // ── Per-floor branch fan-out: the fixtures each floor distributes ───────────
  // Reserved (fixed right-column stubs) before the movable band tags.
  final fanOuts = floorFanOuts(network,
      visibleNodeIds: visible, labelOf: (n) => _nodeLabel(n) ?? 'Fixture');
  const fanX = _gutterW + _drawW + 12;
  for (final fo in fanOuts) {
    if (fo.floorIndex < loFloor || fo.floorIndex > hiFloor) continue;
    var y = bandTop(fo.floorIndex) + 18;
    placer.reserve(SldLabel(fanX, y, 'BRANCHES', size: 7, bold: true));
    for (final lbl in fo.labels) {
      y += 12;
      placer.reserve(SldLabel(fanX + 6, y, lbl, size: 7));
    }
    if (fo.overflow > 0) {
      y += 12;
      placer.reserve(SldLabel(fanX + 6, y, '+${fo.overflow} more', size: 7,
          role: SldRole.source));
    }
  }

  // ── Edges: runs + risers with the SIZE-SERVICE-MATERIAL[-FUNCTION] tag ───────
  // B4: every pipe run/riser is MEDIUM weight (vs the thin datum), carries its
  // service code as the CAD layer, and the vent service draws DASHED.
  final tags = riserTags(network, focus);
  for (final e in network.edges) {
    if (focus != null && e.service != focus) continue;
    final a = posById[e.fromId];
    final b = posById[e.toId];
    if (a == null || b == null) continue;
    final role = _edgeRole(network, e);
    final layer = riserServiceCode(e.service);
    final dashed = e.service == ServiceType.vent;
    // Orthogonal L-route: horizontal at the from-y, then vertical to the to-y.
    prims.add(SldLine(a.dx, a.dy, b.dx, a.dy,
        weight: SldWeight.medium, role: role, layer: layer, dashed: dashed));
    if ((b.dy - a.dy).abs() > 0.5) {
      prims.add(SldLine(b.dx, a.dy, b.dx, b.dy,
          weight: SldWeight.medium, role: role, layer: layer, dashed: dashed));
    }

    final fn = riserFunctionFor(network, e, downfeed: downfeed);
    final tag = _pipeTag(sizing[e.id], e, function: fn);
    if (e.kind == EdgeKind.riser) {
      // Tag + riser id beside the vertical leg.
      final midY = (a.dy + b.dy) / 2;
      placer.place(b.dx + 6, midY, tag,
          size: 8,
          role: role,
          anchorX: b.dx,
          anchorY: midY,
          candidates: _riserLadder(tag));
      final rt = tags[e.id];
      if (rt != null) {
        placer.place(b.dx + 6, midY + 12, rt,
            size: 8,
            bold: true,
            role: role,
            anchorX: b.dx,
            anchorY: midY + 12,
            candidates: _riserLadder(rt));
      }
    } else {
      // Tag centred above the horizontal mid.
      final midX = (a.dx + b.dx) / 2;
      placer.place(midX - _labelWidth(tag, 8) / 2, a.dy - 6, tag,
          size: 8,
          role: role,
          anchorX: midX,
          anchorY: a.dy,
          candidates: _runLadder(tag));
    }
  }

  // ── Nodes: a schematic marker + the component / fixture label ───────────────
  for (final n in nodes) {
    final p = posById[n.id]!;
    final role = _nodeRole(n);
    if (n.role == NodeRole.fixture) {
      // A drop terminal — a small open circle.
      prims.add(SldCircle(p.dx, p.dy, _nodeBox / 2, role: role));
    } else {
      prims.add(SldRect(p.dx - _nodeBox / 2, p.dy - _nodeBox / 2, _nodeBox,
          _nodeBox, weight: SldWeight.thin, role: role));
    }
    final label = _nodeLabel(n);
    if (label != null) {
      placer.place(p.dx + _nodeBox / 2 + 4, p.dy + 3, label,
          size: 8,
          role: role,
          anchorX: p.dx,
          anchorY: p.dy,
          candidates: _nodeLadder(label));
    }
  }

  // ── Bounds ──────────────────────────────────────────────────────────────────
  const maxX = _gutterW + _drawW + _fanColW;
  final maxY = _topPad + bandCount * _bandH + 12;
  return SldSheet(
    prims: prims,
    minX: 0,
    minY: 0,
    maxX: maxX,
    maxY: maxY,
    legend: _fittingLegend(network, focus),
    supplyNote: supplyNote,
  );
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Node ids kept when one system is focused — endpoints of that service's edges
/// (null ⇒ no filtering ⇒ the combined view). Mirrors the painter's filter.
Set<String>? _focusedNodeIds(Network network, ServiceType? focus) {
  if (focus == null) return null;
  final ids = <String>{};
  for (final e in network.edges) {
    if (e.service == focus) {
      ids
        ..add(e.fromId)
        ..add(e.toId);
    }
  }
  return ids;
}

/// The industry pipe tag `SIZE-SERVICE-MATERIAL[-FUNCTION]`; an air duct reads
/// `O<mm>` (ASCII, no Ø). A null sizing falls back to a service-only tag.
String _pipeTag(EdgeSizing? s, NetEdge edge, {RiserFunction? function}) {
  final code = riserServiceCode(edge.service);
  if (s == null) return code;
  final mm = s.diameter.inMillimeters.round();
  if (s.service.regime == FlowRegime.air) return 'O$mm';
  final base = '$mm-$code-${_pipeMaterialCode(edge.pipeProduct, edge.service)}';
  return function != null ? '$base-${function.code}' : base;
}

/// Pipe material code — the edge's chosen product, else the conventional default
/// for the service (clean/hot water ⇒ PPR, drainage/vent/storm ⇒ PVC, fire ⇒
/// black steel). Mirrors the painter's `_pipeMaterialCode`.
String _pipeMaterialCode(PipeProduct? p, ServiceType s) {
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
  return switch (s) {
    ServiceType.coldWater || ServiceType.hotWater => 'PPR',
    ServiceType.drainage ||
    ServiceType.vent ||
    ServiceType.rainwater =>
      'PVC',
    ServiceType.fireSprinkler || ServiceType.fireHydrant => 'BS',
    _ => 'GI',
  };
}

String? _nodeLabel(NetNode node) {
  final c = node.component;
  if (c != null) return c.label;
  final f = node.fixture;
  if (f != null) return _fixtureLabel(f);
  return null;
}

String _fixtureLabel(PlumbingFixture f) => switch (f) {
      PlumbingFixture.waterClosetFlushValve ||
      PlumbingFixture.waterClosetFlushTank =>
        'WC',
      PlumbingFixture.urinalFlushTank => 'Urinal',
      PlumbingFixture.lavatory => 'Lavatory',
      PlumbingFixture.shower => 'Shower',
      PlumbingFixture.bathtub => 'Bathtub',
      PlumbingFixture.kitchenSink => 'Sink',
      PlumbingFixture.hoseBibb => 'Hose bibb',
    };

/// Plant / supply head (tanks, pumps) reads as the `source` role colour; an
/// ordinary node is `normal`.
SldRole _nodeRole(NetNode n) {
  switch (n.component) {
    case NodeComponent.roofTank:
    case NodeComponent.groundTank:
    case NodeComponent.pump:
    case NodeComponent.boosterSet:
      return SldRole.source;
    default:
      return SldRole.normal;
  }
}

/// A run/riser touching plant (tank/pump) is drawn in the `source` colour so the
/// supply spine reads clearly; everything else is `normal`.
SldRole _edgeRole(Network net, NetEdge e) {
  final a = net.nodeById(e.fromId);
  final b = net.nodeById(e.toId);
  bool plant(NetNode? n) =>
      n != null &&
      (n.component == NodeComponent.roofTank ||
          n.component == NodeComponent.groundTank ||
          n.component == NodeComponent.pump ||
          n.component == NodeComponent.boosterSet);
  return plant(a) || plant(b) ? SldRole.source : SldRole.normal;
}

/// The KETERANGAN device legend — the reference fitting glossary plus the
/// service codes actually present on the (focused) network. Mirrors the
/// schematic painter's on-canvas legend so the export carries the same key.
List<SldLegendEntry> _fittingLegend(Network network, ServiceType? focus) {
  final out = <SldLegendEntry>[];
  // Service codes present (the focus, or every service that has an edge).
  final services = <ServiceType>{
    for (final e in network.edges)
      if (focus == null || e.service == focus) e.service,
  };
  for (final s in ServiceType.values) {
    if (services.contains(s)) {
      out.add(SldLegendEntry(riserServiceCode(s), _serviceMeaning(s)));
    }
  }
  // Reference fitting glossary (general drawing convention).
  out
    ..add(const SldLegendEntry('GV', 'Gate valve'))
    ..add(const SldLegendEntry('CV', 'Check valve'))
    ..add(const SldLegendEntry('STR', 'Strainer'))
    ..add(const SldLegendEntry('PRV', 'Pressure reducing valve'))
    ..add(const SldLegendEntry('WM', 'Water meter'))
    ..add(const SldLegendEntry('AAV', 'Auto air vent'))
    ..add(const SldLegendEntry('FJ', 'Flexible joint'));
  return out;
}

String _serviceMeaning(ServiceType s) => switch (s) {
      ServiceType.coldWater => 'Air bersih (cold water)',
      ServiceType.hotWater => 'Hot water',
      ServiceType.drainage => 'Drainage',
      ServiceType.vent => 'Vent',
      ServiceType.rainwater => 'Rainwater / storm',
      ServiceType.duct => 'Supply air',
      ServiceType.returnAir => 'Return air',
      ServiceType.exhaust => 'Exhaust air',
      ServiceType.fireSprinkler => 'Sprinkler',
      ServiceType.fireHydrant => 'Hydrant',
    };

// ── Label collision avoidance (B5) ───────────────────────────────────────────

/// A label's collision box width — a single per-size character advance times the
/// text length (see [_kLabelCharW]).
double _labelWidth(String text, double size) =>
    text.length * size * kMechRiserLabelCharW;

/// An axis-aligned label box in drawing space (baseline at [maxY], the text
/// rising to [minY]).
class _LabelRect {
  final double minX, minY, maxX, maxY;
  const _LabelRect(this.minX, this.minY, this.maxX, this.maxY);

  /// Overlap AREA with [o] (0 when disjoint) — used to pick the least-bad slot.
  double overlap(_LabelRect o) {
    final dx = math.min(maxX, o.maxX) - math.max(minX, o.minX);
    final dy = math.min(maxY, o.maxY) - math.max(minY, o.minY);
    return (dx <= 0 || dy <= 0) ? 0 : dx * dy;
  }
}

/// Greedy label placer: tracks every emitted label's box and, for a movable
/// tag, walks an offset ladder until it clears all placed boxes — falling back
/// to the LEAST-overlapping slot (a tag is the drawing's content: never dropped)
/// and adding a thin leader when the chosen slot is pulled far off its anchor.
/// Appends its output straight into the shared prim list. Deterministic given a
/// stable emission order.
class _LabelPlacer {
  final List<SldPrim> prims;
  final List<_LabelRect> _placed = <_LabelRect>[];
  _LabelPlacer(this.prims);

  _LabelRect _rectFor(double x, double y, String text, double size) =>
      _LabelRect(x, y - size, x + _labelWidth(text, size), y);

  /// Emit a FIXED-position label (gutter / fan-out) and record its box so
  /// movable tags divert around it.
  void reserve(SldLabel label) {
    _placed.add(_rectFor(label.x, label.y, label.text, label.size));
    prims.add(label);
  }

  /// Place a MOVABLE tag at its default ([defaultX], [defaultY]) trying the
  /// [candidates] offsets (candidates[0] == the default) in order; the first
  /// slot clearing every placed box wins, else the least-overlapping. A slot
  /// displaced more than [_kLeaderThreshold] from the default gets a thin leader
  /// from ([anchorX], [anchorY]) — the element the tag names — to the label.
  void place(
    double defaultX,
    double defaultY,
    String text, {
    double size = 8,
    bool bold = false,
    SldRole role = SldRole.normal,
    required double anchorX,
    required double anchorY,
    List<Offset> candidates = const [Offset(0, 0)],
  }) {
    Offset best = candidates.isEmpty ? const Offset(0, 0) : candidates.first;
    var bestOverlap = double.infinity;
    for (final c in candidates) {
      final r = _rectFor(defaultX + c.dx, defaultY + c.dy, text, size);
      var total = 0.0;
      for (final p in _placed) {
        total += p.overlap(r);
      }
      if (total <= 0) {
        best = c;
        bestOverlap = 0;
        break;
      }
      if (total < bestOverlap) {
        bestOverlap = total;
        best = c;
      }
    }
    final lx = defaultX + best.dx;
    final ly = defaultY + best.dy;
    _placed.add(_rectFor(lx, ly, text, size));
    // A tag pulled well off its default anchor gets a leader so its element
    // stays legible.
    if (math.sqrt(best.dx * best.dx + best.dy * best.dy) > _kLeaderThreshold) {
      prims.add(SldLine(anchorX, anchorY, lx, ly,
          weight: SldWeight.thin, role: role));
    }
    prims.add(SldLabel(lx, ly, text, size: size, bold: bold, role: role));
  }
}

/// Offset ladder for a RUN tag (default centred above the run): try below the
/// run, then shift along it, then the diagonal slots. // VERIFY: a drafting
/// declutter heuristic, not a standard.
List<Offset> _runLadder(String text) {
  final w = _labelWidth(text, 8);
  return [
    const Offset(0, 0), // default: above the run
    const Offset(0, 18), // below the run
    Offset(w * 0.6, 0), // shift right, above
    Offset(-w * 0.6, 0), // shift left, above
    Offset(w * 0.6, 18), // right, below
    Offset(-w * 0.6, 18), // left, below
  ];
}

/// Offset ladder for a RISER tag/id (default right of the vertical leg): try the
/// LEFT of the riser, then up/down, then the diagonal slots.
List<Offset> _riserLadder(String text) {
  final w = _labelWidth(text, 8);
  return [
    const Offset(0, 0), // default: right of the leg
    Offset(-(w + 12), 0), // left of the riser
    const Offset(0, 16), // down, right
    const Offset(0, -16), // up, right
    Offset(-(w + 12), 16), // left + down
    Offset(-(w + 12), -16), // left + up
  ];
}

/// Offset ladder for a NODE label (default right of the marker): try below,
/// above, then the LEFT of the node.
List<Offset> _nodeLadder(String text) {
  final w = _labelWidth(text, 8);
  return [
    const Offset(0, 0), // default: right of the marker
    const Offset(0, 12), // below
    const Offset(0, -12), // above
    Offset(-(w + _nodeBox + 8), 0), // left of the node
    const Offset(0, 24), // further below
    const Offset(0, -24), // further above
  ];
}

/// Minimal y-down 2-vector (the engine has no Flutter `Offset`).
class Offset {
  final double dx, dy;
  const Offset(this.dx, this.dy);
}
