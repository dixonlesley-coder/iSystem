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
import '../units.dart' show Length;
import 'plan_symbols.dart'
    show
        planComponentPrims,
        planFixturePrims,
        planFlexibleJointPrims,
        planSewerTerminusPrims;
import 'riser_tags.dart';
import 'sld_sheet.dart';

// ── Drawing geometry (y-down drawing units) ──────────────────────────────────
const double _gutterW = 132; // left gutter: floor name + FFL
const double _drawW = 840; // node placement band width
const double _sidePad = 48; // inset for node x within the band
const double _bandH = 150; // per-floor band height
const double _topPad = 24;
const double _nodeBox = 12; // schematic node marker half-extent
const double _symbolSize = 20; // equipment glyph box (matches the canvas)
const double _fanColW = 150; // per-floor fan-out column width (right gutter)

// ── B1 detail-callout / notes geometry (drawn only when supplied) ────────────
const double _calloutW = 170; // valve-assembly reference detail box width
const double _calloutH = 64; // valve-assembly reference detail box height
const double _calloutGlyph = 15; // glyph box inside a callout row
const double _plantW = 240; // pump-set plant detail box width (holds the train)
const double _plantH = 150; // pump-set plant detail box height (roof + train)
const double _notesW = 240; // KETERANGAN system-notes block width
const double _notesLineH = 11; // per-note line pitch

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
// When the ladder finds no CLEAR slot (two short branch tags share a midpoint),
// the placer escapes further out in these steps until it clears, then leaders
// back — so tags never fuse into one unreadable token (N3). VERIFY: a drafting
// declutter heuristic, not a standard.
const double _kEscapeStep = 12;
const int _kEscapeSteps = 6;
// Minimal x nudge per coincident node so two fixtures at the same world x don't
// stack their markers/labels.
const double _kSpreadStep = 18;

/// Build the mechanical riser single-line as an [SldSheet] for [network].
///
/// [sizing] maps edgeId → its sized record (for the `SIZE-SERVICE-MATERIAL` tag;
/// an edge with no sizing falls back to a service-only tag, and its
/// `flowFromId` — when the solve confidently knows the direction — draws a
/// small flow chevron on the run). [building] supplies
/// the true floor elevations for the FFL gutter labels (degrades to `Level n`
/// when absent). [focus] filters to a single service (null ⇒ the combined view).
/// [downfeed] is the feed strategy (drives the GRAVITASI/BOOSTER/TRANSFER
/// function suffix). [projectName] + [tanksNote] feed the title-block supply
/// line.
///
/// B1 export-parity extras — every one OPTIONAL, defaulting empty/off so the
/// existing output is BYTE-IDENTICAL when the app supplies nothing:
///   • [equipmentDetailByNodeId] — a per-node capacity/duty suffix (e.g.
///     `237 m3` / `5.5 kW`, from [equipmentDetail]) appended to the node label
///     as `Roof tank · 237 m3`;
///   • [notes] — real project echoes rendered as a bordered KETERANGAN block
///     bottom-right (above where the renderers stamp the title block);
///   • [detailCallouts] — the H101 reference details on the clean-water focus:
///     DETAIL WATER METER (GV·WM·GV·U) — only when a waterMeter node exists —
///     and DETAIL PRV SET (GV·STR·PRV·GV) — only when a prv node exists (G7) —
///     bottom-centre, and the PUMP-SET plant detail (roof-tank glyph +
///     capacity, booster glyph + duty, GRAVITASI/TRANSFER/BOOSTER leg labels)
///     in a right margin column — the plant detail drawn ONLY when the network
///     actually carries the relevant plant nodes, its capacity/duty text only
///     when [equipmentDetailByNodeId] supplies it (absent data ⇒ omitted).
/// [hotWaterRecirc] (G2) is the app-supplied signal that the engine's hot-water
/// RECIRCULATION loop exists (the `hotWaterRecircProvider` result is non-null).
/// When true — and the network carries hot-water RISERS — each hot-water supply
/// riser gains a thinner DASHED return riser alongside it (the `HWR` return
/// leg), a down-chevron for the recirculation flow direction, and a recirc-pump
/// glyph at the loop base. Default false / no hot-water risers ⇒ nothing drawn
/// (byte-identical); the return leg is never fabricated without the signal.
/// Pure — no clock, no IO.
///
/// [edgeLengths] (N6) is the SAME §10 length-per-edge map the plan export
/// consumes — a riser carries its true elevation delta, a run its calibrated
/// pixel length. When supplied, each pipe run/riser tag gains a ` - x.x m`
/// suffix so the riser sheet is a take-off / prefab source (an edge with no
/// entry, or the default EMPTY map, appends nothing ⇒ byte-identical).
SldSheet buildMechanicalRiserSld({
  required Network network,
  Map<String, EdgeSizing> sizing = const {},
  BuildingLevels? building,
  ServiceType? focus,
  bool downfeed = false,
  String supplyNote = '',
  Map<String, String> equipmentDetailByNodeId = const {},
  Map<String, Length> edgeLengths = const {},
  List<String> notes = const [],
  bool detailCallouts = false,
  bool hotWaterRecirc = false,
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

  // Map a node's x into the placement band via the SHARED layout helper (B7):
  // a normalized column position in [0,1] — the SAME geometry the on-canvas Auto
  // painter uses — so a vertical riser stack reads as one column here and on the
  // preview, instead of the two surfaces jogging apart. Absent (should not
  // happen for a visible node) falls back to centred.
  final normX = riserLayoutPositions(network, focus: focus);
  double placeX(String nodeId) =>
      _gutterW + _sidePad + (normX[nodeId] ?? 0.5) * (_drawW - 2 * _sidePad);

  Offset posOf(NetNode n) => Offset(placeX(n.id), bandCentreY(n.floorIndex));

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
          8, top + 32, fflLabel(ffl),
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
    // N7: enumerate EVERY fixture the floor serves, grouped per type with a
    // count (`WC x3`) — no `+N more` truncation. A count of 1 stays bare.
    for (final g in fo.groups) {
      y += 12;
      final row = g.count > 1 ? '${g.label} x${g.count}' : g.label;
      placer.reserve(SldLabel(fanX + 6, y, row, size: 7));
    }
    if (fo.groupOverflow > 0) {
      y += 12;
      placer.reserve(SldLabel(fanX + 6, y, '+${fo.groupOverflow} types',
          size: 7, role: SldRole.source));
    }
  }

  // ── B2 STACK DETAIL: cleanouts, the vent tee, VTR terminations ──────────────
  // Data-gated on the DRAWN network (positions exist only for focus-visible
  // nodes, so a filtered system omits the other system's marks). Reserved
  // before the movable band tags so they divert around these fixed marks.
  if (focus == null || focus == ServiceType.vent) {
    // A vent riser reaching the TOP floor terminates through the roof: a short
    // dashed stub above the band + the 'VTR' code.
    for (final id in ventTopTerminalIds(network, topFloor: hiFloor)) {
      final p = posById[id];
      if (p == null) continue;
      final stubTop = bandTop(hiFloor) - 10;
      prims.add(SldLine(p.dx, p.dy, p.dx, stubTop,
          weight: SldWeight.medium,
          layer: riserServiceCode(ServiceType.vent),
          dashed: true));
      // Roof-penetration cap tick.
      prims.add(SldLine(p.dx - 4, stubTop, p.dx + 4, stubTop,
          weight: SldWeight.medium,
          layer: riserServiceCode(ServiceType.vent)));
      placer.reserve(SldLabel(p.dx + 6, stubTop + 6, 'VTR', size: 7, bold: true));
    }
  }
  if (focus == null ||
      focus == ServiceType.vent ||
      focus == ServiceType.drainage) {
    // The drawn vent-to-soil tee: a short bar across the shared junction.
    for (final id in ventSoilTeeNodeIds(network)) {
      final p = posById[id];
      if (p == null) continue;
      prims.add(SldLine(p.dx - 9, p.dy, p.dx + 9, p.dy,
          weight: SldWeight.medium,
          layer: riserServiceCode(ServiceType.drainage)));
    }
  }
  if (focus == null || focus == ServiceType.drainage) {
    // 'CO' code beside each cleanout that serves a drainage stack base — only
    // cleanouts the engineer actually drew (a missing one is an ADVISORY in the
    // Review panel, never fabricated here).
    for (final id in cleanoutAtStackBaseIds(network)) {
      final p = posById[id];
      if (p == null) continue;
      placer.reserve(SldLabel(
          p.dx - _symbolSize / 2 - 2, p.dy - _symbolSize / 2 - 4, 'CO',
          size: 7, bold: true));
    }
  }
  // ── G4 DRAINAGE TERMINUS: the exit to the disposal system ───────────────────
  // The network's drainage EXIT (the lowest stack base / main outlet) carries a
  // terminus glyph + a 'KE SALURAN PEMBUANGAN' label — the point where the
  // soil/waste leaves the building. HONESTY: the model has NO septic/STP/sewer
  // component, so the destination is NEVER invented ('KE STP' / 'KE RIOL KOTA'
  // are not claimed); the generic disposal label is used. (When a septic/STP
  // NodeComponent is later added, specialise the label from the exit node's
  // component — the drainage exit is where such a component would sit.)
  if (focus == null ||
      focus == ServiceType.drainage ||
      focus == ServiceType.rainwater) {
    final exitId = _drainageExitNodeId(network);
    final p = exitId == null ? null : posById[exitId];
    if (p != null) {
      final gy = p.dy + _symbolSize;
      prims.addAll(planSewerTerminusPrims(cx: p.dx, cy: gy, size: _symbolSize));
      placer.reserve(SldLabel(
          p.dx + _symbolSize / 2 + 4, gy + 3, 'KE SALURAN PEMBUANGAN',
          size: 7, bold: true));
    }
  }

  // ── G2 HOT-WATER RECIRCULATION return leg (data-gated) ───────────────────────
  // When the app signals a live recirc loop, draw the return riser(s) alongside
  // the hot-water supply riser(s): a thinner dashed 'HWR' leg + a down chevron
  // (return flow) + a recirc-pump glyph at the loop base. No signal / no hot
  // water riser ⇒ nothing drawn (byte-identical).
  if (hotWaterRecirc) {
    _emitHotWaterReturn(prims, network, posById, placer, focus);
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
    final sz = sizing[e.id];
    // Orthogonal L-route: horizontal at the from-y, then vertical to the to-y.
    prims.add(SldLine(a.dx, a.dy, b.dx, a.dy,
        weight: SldWeight.medium, role: role, layer: layer, dashed: dashed));
    if ((b.dy - a.dy).abs() > 0.5) {
      prims.add(SldLine(b.dx, a.dy, b.dx, b.dy,
          weight: SldWeight.medium, role: role, layer: layer, dashed: dashed));
    }

    // B1 flow chevron — only where the solve confidently recorded the
    // direction (EdgeSizing.flowFromId); null ⇒ nothing (byte-identical).
    final flowFrom = sz?.flowFromId;
    if (flowFrom == e.fromId || (flowFrom != null && flowFrom == e.toId)) {
      _addFlowChevron(prims, a, b,
          reversed: flowFrom == e.toId, role: role, layer: layer);
    }

    final fn = riserFunctionFor(network, e, downfeed: downfeed);
    final tag = _pipeTag(sz, e, function: fn, length: edgeLengths[e.id]);
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

  // ── Nodes: the schematic symbol + the component / fixture label ─────────────
  // B1: a node with a component draws its REAL equipment glyph (the shared
  // plan-symbol library — one geometry with the plan exports), a fixture its
  // drop-triangle terminal; only a plain junction keeps the anonymous box.
  for (final n in nodes) {
    final p = posById[n.id]!;
    final role = _nodeRole(n);
    final c = n.component;
    final double labelInset;
    if (c != null) {
      prims.addAll(_withRole(
          planComponentPrims(c, cx: p.dx, cy: p.dy, size: _symbolSize), role));
      labelInset = _symbolSize / 2;
    } else if (n.role == NodeRole.fixture) {
      // A fixture drop terminal — the down-triangle marker.
      prims.addAll(
          _withRole(planFixturePrims(cx: p.dx, cy: p.dy, size: _nodeBox), role));
      labelInset = _nodeBox / 2;
    } else {
      prims.add(SldRect(p.dx - _nodeBox / 2, p.dy - _nodeBox / 2, _nodeBox,
          _nodeBox, weight: SldWeight.thin, role: role));
      labelInset = _nodeBox / 2;
    }
    final base = _nodeLabel(n);
    if (base != null) {
      // B1 equipment-detail suffix (capacity / duty) — only when the app
      // supplied a real datum for this node.
      final detail = equipmentDetailByNodeId[n.id];
      final label = detail == null ? base : '$base · $detail';
      placer.place(p.dx + labelInset + 4, p.dy + 3, label,
          size: 8,
          role: role,
          anchorX: p.dx,
          anchorY: p.dy,
          candidates: _nodeLadder(label));
    }
  }

  // ── B1 detail callouts + system-notes block (drawn only when supplied) ──────
  // The callouts sit in a strip BELOW the floor bands (clear of every band tag)
  // and the plant detail in a right margin column, so the placer never has to
  // divert around them; the bounds grow to include whatever was drawn.
  const contentMaxX = _gutterW + _drawW + _fanColW;
  var maxX = contentMaxX;
  final extrasTop = _topPad + bandCount * _bandH + 12.0;
  var extrasBottom = extrasTop;

  final waterFocus = focus == null ||
      focus == ServiceType.coldWater ||
      focus == ServiceType.hotWater;
  // G4: the drainage/vent/rainwater view earns the SAME reference-detail
  // treatment the clean-water view gets.
  final drainageFocus = focus == null ||
      focus == ServiceType.drainage ||
      focus == ServiceType.vent ||
      focus == ServiceType.rainwater;
  if (detailCallouts) {
    bool has(NodeComponent c) => network.nodes.any((n) => n.component == c);
    if (waterFocus &&
        _emitPlantDetail(prims, network, contentMaxX + 12, _topPad,
            equipmentDetailByNodeId: equipmentDetailByNodeId,
            downfeed: downfeed)) {
      maxX = contentMaxX + 12 + _plantW;
    }
    // Reference detail callouts, bottom-centre of the band — each drawn ONLY
    // when the network actually carries the assembly's key device (G7/G4,
    // mirroring the plant detail's has()-gating): the WATER METER / PRV SET
    // (clean water), the FLOOR DRAIN / VTR (drainage/vent). A project without a
    // device shows neither box (honesty — no boilerplate detail masquerading as
    // an as-designed assembly). The present boxes are centred as a group so a
    // lone detail still reads balanced; the combined view shows every applicable
    // box in one row.
    final detailBoxes = <(String, List<(NodeComponent, String)>)>[
      if (waterFocus && has(NodeComponent.waterMeter))
        ('DETAIL WATER METER', const [
          (NodeComponent.gateValve, 'GV'),
          (NodeComponent.waterMeter, 'WM'),
          (NodeComponent.gateValve, 'GV'),
          (NodeComponent.gateValve, 'U'),
        ]),
      if (waterFocus && has(NodeComponent.prv))
        ('DETAIL PRV SET', const [
          (NodeComponent.gateValve, 'GV'),
          (NodeComponent.strainer, 'STR'),
          (NodeComponent.prv, 'PRV'),
          (NodeComponent.gateValve, 'GV'),
        ]),
      // G4: DETAIL FLOOR DRAIN (FD trap + CO) — only when a floor drain is drawn.
      if (drainageFocus && has(NodeComponent.floorDrain))
        ('DETAIL FLOOR DRAIN', const [
          (NodeComponent.floorDrain, 'FD'),
          (NodeComponent.cleanout, 'CO'),
        ]),
      // G4: DETAIL VTR (vent-through-roof termination) — only when a vent riser
      // actually reaches the roof (never fabricated).
      if (drainageFocus &&
          ventTopTerminalIds(network, topFloor: hiFloor).isNotEmpty)
        ('DETAIL VTR', const [
          (NodeComponent.airVent, 'VTR'),
        ]),
    ];
    if (detailBoxes.isNotEmpty) {
      final totalW =
          detailBoxes.length * _calloutW + (detailBoxes.length - 1) * 16;
      var bx = _gutterW + (_drawW - totalW) / 2;
      for (final (title, items) in detailBoxes) {
        _emitDetailBox(prims, bx, extrasTop, title, items);
        bx += _calloutW + 16;
      }
      extrasBottom = math.max(extrasBottom, extrasTop + _calloutH);
    }
  }
  if (notes.isNotEmpty) {
    // The KETERANGAN system-notes block, bottom-RIGHT (the renderers stamp the
    // page-fixed title block below/beside it in page space).
    final noteH = 20 + notes.length * _notesLineH + 6;
    const left = contentMaxX - _notesW;
    prims.add(SldRect(left, extrasTop, _notesW, noteH, weight: SldWeight.thin));
    prims.add(SldLabel(left + 6, extrasTop + 12, 'KETERANGAN',
        size: 7, bold: true));
    var y = extrasTop + 24.0;
    for (final line in notes) {
      prims.add(SldLabel(left + 6, y, line, size: 7));
      y += _notesLineH;
    }
    extrasBottom = math.max(extrasBottom, extrasTop + noteH);
  }

  // ── Bounds ──────────────────────────────────────────────────────────────────
  final maxY = extrasBottom == extrasTop ? extrasTop : extrasBottom + 12;
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

/// The industry pipe tag `SIZE-SERVICE-MATERIAL[-FUNCTION][ - x.x m]`; an air
/// duct reads `O<mm>` (ASCII, no Ø). A null sizing falls back to a service-only
/// tag. [length] (N6), when non-null and positive, appends the run/riser length
/// as ` - x.x m` (a §10 metre figure — take-off / prefab data); null ⇒ no
/// suffix.
String _pipeTag(EdgeSizing? s, NetEdge edge,
    {RiserFunction? function, Length? length}) {
  final code = riserServiceCode(edge.service);
  String tag;
  if (s == null) {
    tag = code;
  } else {
    final mm = s.diameter.inMillimeters.round();
    if (s.service.regime == FlowRegime.air) {
      tag = 'O$mm';
    } else {
      final base = '$mm-$code-${_pipeMaterialCode(edge.pipeProduct, edge.service)}';
      tag = function != null ? '$base-${function.code}' : base;
    }
  }
  if (length != null && length.meters > 0) {
    tag = '$tag - ${length.meters.toStringAsFixed(1)} m';
  }
  return tag;
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
      // B2: the Indonesian sheet-language meanings, matching the air-bersih
      // entry (Diagram Air Kotor drawing convention).
      ServiceType.drainage => 'Air kotor & bekas (drainage)',
      ServiceType.vent => 'Ven (vent)',
      ServiceType.rainwater => 'Air hujan (rainwater / storm)',
      ServiceType.duct => 'Supply air',
      ServiceType.returnAir => 'Return air',
      ServiceType.exhaust => 'Exhaust air',
      ServiceType.fireSprinkler => 'Sprinkler',
      ServiceType.fireHydrant => 'Hydrant',
    };

/// Re-colour a symbol-library prim list with [role] (the plan-symbol library
/// emits geometry-only prims; the riser drawing owns the plant/source split).
/// Normal role passes the list through untouched.
List<SldPrim> _withRole(List<SldPrim> prims, SldRole role) {
  if (role == SldRole.normal) return prims;
  return [
    for (final p in prims)
      switch (p) {
        final SldLine l => SldLine(l.x1, l.y1, l.x2, l.y2,
            weight: l.weight, role: role, layer: l.layer, dashed: l.dashed),
        final SldRect r =>
          SldRect(r.x, r.y, r.w, r.h, weight: r.weight, role: role),
        final SldCircle c =>
          SldCircle(c.cx, c.cy, c.r, weight: c.weight, role: role),
        final SldLabel lb => SldLabel(lb.x, lb.y, lb.text,
            size: lb.size, bold: lb.bold, role: role),
      },
  ];
}

/// A small 3-line flow chevron (two arrowhead legs + a short shaft) on the
/// edge's L-route, pointing WITH the solved flow. The chevron rides the longer
/// leg (horizontal preferred) at its 2/3 point measured from the flow's start
/// of that leg. [reversed] flips the direction (flow enters at the edge's `to`
/// endpoint). Read-only drawing of the solve's own orientation — never a guess.
void _addFlowChevron(
  List<SldPrim> prims,
  Offset a,
  Offset b, {
  required bool reversed,
  required SldRole role,
  String? layer,
}) {
  // L-route legs: horizontal a→corner at y=a.dy, vertical corner→b at x=b.dx.
  final hLen = (b.dx - a.dx).abs();
  final vLen = (b.dy - a.dy).abs();
  if (hLen < 24 && vLen < 24) return; // too short to carry a readable chevron
  final double px, py, ux, uy;
  if (hLen >= vLen) {
    // Along the horizontal leg, 2/3 from the flow's entry end.
    final startX = reversed ? b.dx : a.dx;
    final endX = reversed ? a.dx : b.dx;
    px = startX + (endX - startX) * (2 / 3);
    py = a.dy;
    ux = endX >= startX ? 1 : -1;
    uy = 0;
  } else {
    // Along the vertical leg, 2/3 from the flow's entry end.
    final startY = reversed ? b.dy : a.dy;
    final endY = reversed ? a.dy : b.dy;
    px = b.dx;
    py = startY + (endY - startY) * (2 / 3);
    ux = 0;
    uy = endY >= startY ? 1 : -1;
  }
  // Perpendicular unit.
  final wx = -uy, wy = ux;
  const legBack = 7.0, halfSpread = 3.5, shaft = 8.0;
  final tipX = px + ux * 4, tipY = py + uy * 4;
  prims
    ..add(SldLine(tipX - ux * shaft, tipY - uy * shaft, tipX, tipY,
        weight: SldWeight.thin, role: role, layer: layer))
    ..add(SldLine(tipX, tipY, tipX - ux * legBack + wx * halfSpread,
        tipY - uy * legBack + wy * halfSpread,
        weight: SldWeight.thin, role: role, layer: layer))
    ..add(SldLine(tipX, tipY, tipX - ux * legBack - wx * halfSpread,
        tipY - uy * legBack - wy * halfSpread,
        weight: SldWeight.thin, role: role, layer: layer));
}

// ── B1 detail callouts (export analogues of the canvas H101 details) ─────────

/// One bordered DETAIL box with a title + a left→right row of valve/meter
/// glyphs joined by a run line, each with its ASCII abbrev beneath — the export
/// analogue of the canvas `_drawDetailGlyphRow`. A generic REFERENCE assembly
/// (the abbrev names the real device; no claim about a specific drawn valve).
void _emitDetailBox(List<SldPrim> prims, double left, double top, String title,
    List<(NodeComponent, String)> items) {
  prims.add(SldRect(left, top, _calloutW, _calloutH, weight: SldWeight.thin));
  prims.add(SldLabel(left + 6, top + 12, title, size: 7, bold: true));
  const gap = 36.0;
  final cy = top + 34.0;
  final firstCx = left + 18.0;
  final lastCx = firstCx + (items.length - 1) * gap;
  // The connecting run line spans the first and last glyph centres.
  prims.add(SldLine(
      firstCx - _calloutGlyph / 2, cy, lastCx + _calloutGlyph / 2, cy,
      weight: SldWeight.thin));
  for (var i = 0; i < items.length; i++) {
    final (component, abbrev) = items[i];
    final cx = firstCx + i * gap;
    prims.addAll(
        planComponentPrims(component, cx: cx, cy: cy, size: _calloutGlyph));
    prims.add(SldLabel(cx - _labelWidth(abbrev, 7) / 2,
        cy + _calloutGlyph / 2 + 10, abbrev, size: 7));
  }
}

/// The PUMP-SET / ROOF-TANK plant detail (H101 top-right convention), emitted
/// in a right margin column: a roof-tank glyph + its real capacity, a
/// booster-pump glyph + its real duty, a connecting leg and the GRAVITASI /
/// TRANSFER / BOOSTER leg labels. Drawn ONLY when [network] actually carries a
/// roof-tank / ground-tank / pump / booster set (returns false ⇒ nothing
/// emitted); the capacity/duty text appears only when [equipmentDetailByNodeId]
/// supplies it (honesty: absent data ⇒ omitted). Mirrors the canvas
/// `_paintPlantDetail`.
bool _emitPlantDetail(
  List<SldPrim> prims,
  Network network,
  double left,
  double top, {
  required Map<String, String> equipmentDetailByNodeId,
  required bool downfeed,
}) {
  bool has(NodeComponent c) => network.nodes.any((n) => n.component == c);
  String? detailOf(NodeComponent c) {
    for (final n in network.nodes) {
      if (n.component != c) continue;
      final d = equipmentDetailByNodeId[n.id];
      if (d != null) return d;
    }
    return null;
  }

  final hasRoof = has(NodeComponent.roofTank);
  final hasGround = has(NodeComponent.groundTank);
  final hasPump = has(NodeComponent.pump) || has(NodeComponent.boosterSet);
  if (!hasRoof && !hasGround && !hasPump) return false;

  prims.add(SldRect(left, top, _plantW, _plantH, weight: SldWeight.thin));
  prims.add(
      SldLabel(left + 6, top + 12, 'PUMP-SET DETAIL', size: 7, bold: true));

  final cx = left + _plantW / 2;
  const glyph = 20.0;
  var y = top + 24.0;

  // ── ROOF TANK row (centred) with its real capacity + GRAVITASI leg label ─────
  double? roofBottom;
  if (hasRoof) {
    prims.addAll(_withRole(
        planComponentPrims(NodeComponent.roofTank,
            cx: cx, cy: y + glyph / 2, size: glyph),
        SldRole.source));
    final m3 = detailOf(NodeComponent.roofTank);
    prims.add(SldLabel(cx + glyph / 2 + 8, y + glyph / 2 + 3,
        m3 != null ? 'ROOF TANK $m3' : 'ROOF TANK',
        size: 7, role: SldRole.source));
    if (downfeed) {
      prims.add(SldLabel(cx - glyph / 2 - 2, y + glyph + 10, 'GRAVITASI',
          size: 7, bold: true, role: SldRole.source));
    }
    roofBottom = y + glyph;
    y += glyph + 26;
  }

  // ── PUMP row with the suction / discharge VALVE TRAIN (G3) ───────────────────
  // The pump sits centred, flanked by its real isolation / backflow train — the
  // suction leg (GV · STR · FJ) to the left, the discharge leg (CV · GV · FJ) to
  // the right — the most safety-critical assembly on an air-bersih riser, drawn
  // instead of a bare pump icon. Glyphs reuse the plan-symbol + flexible-joint
  // libraries; the abbrevs already sit in the KETERANGAN legend.
  if (hasPump) {
    final pumpC = has(NodeComponent.boosterSet)
        ? NodeComponent.boosterSet
        : NodeComponent.pump;
    final trainCy = y + glyph / 2;
    // Connecting leg down from the roof tank to the pump train.
    if (roofBottom != null) {
      prims.add(SldLine(cx, roofBottom, cx, trainCy - glyph / 2,
          weight: SldWeight.thin, role: SldRole.source));
    }
    const train = <(String, String)>[
      ('GV', 'GV'),
      ('STR', 'STR'),
      ('FJ', 'FJ'),
      ('PUMP', ''),
      ('CV', 'CV'),
      ('GV', 'GV'),
      ('FJ', 'FJ'),
    ];
    const gap = 30.0;
    const gl = 15.0;
    final firstCx = cx - (train.length - 1) / 2 * gap;
    // The connecting run line through the whole train.
    prims.add(SldLine(firstCx - gl / 2, trainCy,
        firstCx + (train.length - 1) * gap + gl / 2, trainCy,
        weight: SldWeight.thin, role: SldRole.source));
    for (var i = 0; i < train.length; i++) {
      final (token, abbrev) = train[i];
      final gx = firstCx + i * gap;
      final gp = token == 'PUMP'
          ? planComponentPrims(pumpC, cx: gx, cy: trainCy, size: gl + 4)
          : _pumpTrainGlyphPrims(token, gx, trainCy, gl);
      prims.addAll(_withRole(gp, SldRole.source));
      if (abbrev.isNotEmpty) {
        prims.add(SldLabel(gx - _labelWidth(abbrev, 7) / 2,
            trainCy + gl / 2 + 10, abbrev,
            size: 7, role: SldRole.source));
      }
    }
    // Duty caption + the pump-leg function label, centred below the train.
    final kw = detailOf(pumpC);
    final cap = kw != null ? 'BOOSTER PUMP $kw' : 'BOOSTER PUMP';
    prims.add(SldLabel(cx - _labelWidth(cap, 7) / 2, trainCy + gl / 2 + 24, cap,
        size: 7, role: SldRole.source));
    // TRANSFER (ground -> roof lift) when a ground tank exists; else BOOSTER
    // (pump-up) on upfeed. Mirrors the canvas leg labels.
    final leg = hasGround ? 'TRANSFER' : (!downfeed ? 'BOOSTER' : null);
    if (leg != null) {
      prims.add(SldLabel(cx - _labelWidth(leg, 7) / 2, trainCy + gl / 2 + 36,
          leg,
          size: 7, bold: true, role: SldRole.source));
    }
  }
  return true;
}

/// The glyph for one device in the pump-set valve TRAIN (G3): GV / STR / CV
/// reuse the plan-symbol library; FJ (flexible joint) is a standalone glyph.
/// Returns geometry-only prims centred on ([cx], [cy]); an unknown token ⇒
/// empty (never fabricates a device).
List<SldPrim> _pumpTrainGlyphPrims(
        String token, double cx, double cy, double size) =>
    switch (token) {
      'GV' =>
        planComponentPrims(NodeComponent.gateValve, cx: cx, cy: cy, size: size),
      'STR' =>
        planComponentPrims(NodeComponent.strainer, cx: cx, cy: cy, size: size),
      'CV' =>
        planComponentPrims(NodeComponent.checkValve, cx: cx, cy: cy, size: size),
      'FJ' => planFlexibleJointPrims(cx: cx, cy: cy, size: size),
      _ => const [],
    };

/// The network's DRAINAGE EXIT node id (G4) — the point where the soil/waste
/// leaves the building. It is the lowest drainage-connected node, PREFERRING a
/// genuine outlet (a plain main/plant, not a fixture or a cleanout branch) and,
/// among equals, a leaf. Null when the network carries no drainage. Pure
/// bookkeeping — never fabricates a node.
String? _drainageExitNodeId(Network net) {
  final touching = <String>{};
  for (final e in net.edges) {
    if (e.service != ServiceType.drainage) continue;
    touching
      ..add(e.fromId)
      ..add(e.toId);
  }
  final nodes = <NetNode>[
    for (final id in touching)
      if (net.nodeById(id) != null) net.nodeById(id)!,
  ];
  if (nodes.isEmpty) return null;
  int drainDegree(String id) => net.edges
      .where((e) =>
          e.service == ServiceType.drainage &&
          (e.fromId == id || e.toId == id))
      .length;
  bool poorExit(NetNode n) =>
      n.role == NodeRole.fixture || n.component == NodeComponent.cleanout;
  nodes.sort((a, b) {
    final byFloor = a.floorIndex.compareTo(b.floorIndex); // lowest floor first
    if (byFloor != 0) return byFloor;
    final byExit = (poorExit(a) ? 1 : 0).compareTo(poorExit(b) ? 1 : 0);
    if (byExit != 0) return byExit; // a real outlet before a fixture/cleanout
    final byDeg = drainDegree(a.id).compareTo(drainDegree(b.id)); // leaf first
    if (byDeg != 0) return byDeg;
    final byX = a.x.compareTo(b.x);
    return byX != 0 ? byX : a.id.compareTo(b.id);
  });
  return nodes.first.id;
}

/// G2: draw the HOT-WATER RECIRCULATION return leg(s) alongside the hot-water
/// supply riser(s) — a thinner DASHED `HWR` return riser, a down chevron (the
/// recirculation flow returning to the heater), and a recirc-pump glyph at the
/// loop base. Emits nothing when the focus hides hot water or the network has no
/// hot-water riser. Appends into [prims]; labels route through [placer].
void _emitHotWaterReturn(List<SldPrim> prims, Network network,
    Map<String, Offset> posById, _LabelPlacer placer, ServiceType? focus) {
  if (!(focus == null || focus == ServiceType.hotWater)) return;
  final layer = riserServiceCode(ServiceType.hotWater); // 'HW'
  const off = 12.0;
  final hwRisers = <NetEdge>[
    for (final e in network.edges)
      if (e.service == ServiceType.hotWater &&
          e.kind == EdgeKind.riser &&
          posById[e.fromId] != null &&
          posById[e.toId] != null)
        e,
  ];
  if (hwRisers.isEmpty) return;
  for (final e in hwRisers) {
    final a = posById[e.fromId]!;
    final b = posById[e.toId]!;
    final legX = b.dx + off;
    final yTop = math.min(a.dy, b.dy);
    final yBot = math.max(a.dy, b.dy);
    // The parallel return riser — THINNER + DASHED (a hot-water return).
    prims.add(SldLine(legX, yTop, legX, yBot,
        weight: SldWeight.thin, layer: layer, dashed: true));
    // The loop turn: tie the return top back to the supply riser leg.
    prims.add(SldLine(b.dx, yTop, legX, yTop,
        weight: SldWeight.thin, layer: layer, dashed: true));
    // A down chevron: recirculation flow returns to the heater.
    final midY = (yTop + yBot) / 2;
    prims
      ..add(SldLine(legX - 4, midY - 4, legX, midY,
          weight: SldWeight.thin, layer: layer))
      ..add(SldLine(legX + 4, midY - 4, legX, midY,
          weight: SldWeight.thin, layer: layer));
    placer.place(legX + 5, midY, 'HWR',
        size: 7,
        bold: true,
        anchorX: legX,
        anchorY: midY,
        candidates: _riserLadder('HWR'));
  }
  // The recirc pump glyph at the loop base — the lowest hot-water node.
  NetNode? lowest;
  for (final e in hwRisers) {
    for (final id in [e.fromId, e.toId]) {
      final n = network.nodeById(id);
      if (n == null) continue;
      if (lowest == null || n.floorIndex < lowest.floorIndex) lowest = n;
    }
  }
  final lp = lowest == null ? null : posById[lowest.id];
  if (lp != null) {
    final px = lp.dx + off;
    prims.addAll(planComponentPrims(NodeComponent.pump,
        cx: px, cy: lp.dy, size: _nodeBox + 4));
    placer.place(px + (_nodeBox + 4) / 2 + 4, lp.dy + 3, 'HWR PUMP',
        size: 7,
        anchorX: px,
        anchorY: lp.dy,
        candidates: _nodeLadder('HWR PUMP'));
  }
}

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

  /// Total overlap AREA of a label box at ([x], [y]) against every placed box.
  double _overlapAt(double x, double y, String text, double size) {
    final r = _rectFor(x, y, text, size);
    var total = 0.0;
    for (final p in _placed) {
      total += p.overlap(r);
    }
    return total;
  }

  /// Emit a FIXED-position label (gutter / fan-out) and record its box so
  /// movable tags divert around it.
  void reserve(SldLabel label) {
    _placed.add(_rectFor(label.x, label.y, label.text, label.size));
    prims.add(label);
  }

  /// Place a MOVABLE tag at its default ([defaultX], [defaultY]) trying the
  /// [candidates] offsets (candidates[0] == the default) in order; the first
  /// slot clearing every placed box wins, else the least-overlapping. When NO
  /// ladder slot clears — two short branch tags sharing a midpoint (N3) — the
  /// placer ESCAPES further out (growing vertical steps, down then up) until it
  /// clears, so tags never overprint into one fused token. A tag is the
  /// drawing's content and is never dropped: if even the escape can't fully
  /// clear, the least-overlapping escape slot is used. Any slot displaced more
  /// than [_kLeaderThreshold] from the default — or that could not be fully
  /// cleared — gets a thin leader from ([anchorX], [anchorY]), the element the
  /// tag names, to the label.
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
    var cleared = false;
    for (final c in candidates) {
      final total = _overlapAt(defaultX + c.dx, defaultY + c.dy, text, size);
      if (total <= 0) {
        best = c;
        bestOverlap = 0;
        cleared = true;
        break;
      }
      if (total < bestOverlap) {
        bestOverlap = total;
        best = c;
      }
    }
    // No ladder slot cleared → escape vertically (down then up, growing) from
    // the least-bad column until a clear slot appears.
    if (!cleared) {
      final baseDx = best.dx;
      for (var k = 1; k <= _kEscapeSteps && !cleared; k++) {
        for (final dy in [_kEscapeStep * k, -_kEscapeStep * k]) {
          final total = _overlapAt(defaultX + baseDx, defaultY + dy, text, size);
          if (total < bestOverlap) {
            bestOverlap = total;
            best = Offset(baseDx, dy);
          }
          if (total <= 0) {
            cleared = true;
            break;
          }
        }
      }
    }
    final lx = defaultX + best.dx;
    final ly = defaultY + best.dy;
    _placed.add(_rectFor(lx, ly, text, size));
    // A tag pulled well off its default anchor — or one that could not be fully
    // cleared — gets a leader so its element stays legible / unfused.
    if (!cleared ||
        math.sqrt(best.dx * best.dx + best.dy * best.dy) > _kLeaderThreshold) {
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
