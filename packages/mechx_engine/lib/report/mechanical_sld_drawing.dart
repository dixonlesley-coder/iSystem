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
        planLengthLabel,
        planSewerTerminusPrims;
import 'riser_tags.dart';
import 'sld_sheet.dart';

// ── Drawing geometry (y-down drawing units) ──────────────────────────────────
/// Round 14 (drafting-visual-4) — the PUMP-SET valve train, in flow order, as
/// (glyph token, printed abbrev): suction GV · STR · FJ, the pump, then the
/// discharge FJ · CV · GV. The FLEXIBLE JOINT sits right at each pump nozzle
/// (pump > FJ > CV > GV, mirroring the suction's STR > FJ > pump) — it exists
/// to isolate pump vibration, so the check valve and the isolating gate valve
/// sit beyond it. It used to read CV · GV · FJ, putting the vibration through
/// both valves; a foreman builds the train exactly as drawn. ONE source for
/// the exported riser detail AND the live canvas painter (golden rule 5).
const List<(String, String)> kPumpSetValveTrain = [
  ('GV', 'GV'),
  ('STR', 'STR'),
  ('FJ', 'FJ'),
  ('PUMP', ''),
  ('FJ', 'FJ'),
  ('CV', 'CV'),
  ('GV', 'GV'),
];

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
const double _roofBandH = 40; // Round 21 — the ATAP datum band above the top storey
const double _roofLineInset = 8; // the roof line sits this far above the top band
const double _kFanPitchSingle = 12; // Round 21 — branch fan pitch, one service
const double _kFanPitchCombined = 4; // … a sub-lane gap on a combined sheet
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

/// Round 15 — the sideways escape (drafting-visual-2-1): horizontal steps
/// past a stack channel when the vertical escape stays on ink.
const double _kSideEscapeStep = 24;
const int _kSideEscapeSteps = 8;

/// Round 15 — how much worse a box over reserved INK (or a leader) is than
/// the same area over another label: a pipe through a tag's text makes it
/// unreadable, two touching tags merely crowd.
const double _kInkWeight = 1000;
// Minimal x nudge per coincident node so two fixtures at the same world x don't
// stack their markers/labels.
const double _kSpreadStep = 18;
// X1: half-thickness of the occupied strip a drawn pipe leg reserves, so a tag
// is never printed THROUGH the run it names (the issued riser PDF showed
// "Ground tank · 5.0 m3" struck out by its own suction pipe). A drafting
// clearance, not a standard. // VERIFY
const double _kInkHalfThickness = 2;

/// Round 17 — descender depth of a label below its baseline, as a fraction
/// of its size (Helvetica descent ≈ 0.21 em, rounded up).
const double _kDescenderFraction = 0.25;

/// Round 16 — the solve's recorded flow direction per edge (edge id -> the
/// node its flow comes FROM, `EdgeSizing.flowFromId`), the input of the
/// flow-path FUNCTION suffix ([riserFunctionFor]). Edges the solve did not
/// orient are absent.
Map<String, String> flowFromBySizing(Map<String, EdgeSizing> sizing) => {
      for (final en in sizing.entries)
        // ignore: use_null_aware_elements
        if (en.value.flowFromId case final f?) en.key: f,
    };

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
/// [nodeTags] (drafting-7) is the stable equipment-tag map
/// (`equipmentNodeTags`) the plan exporters + the equipment schedule key on;
/// a tagged node's label leads with its tag before the role word
/// (`P-08 Pump · 2.2 kW`). Empty (the default) ⇒ byte-identical.
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
  Map<String, String> nodeTags = const {},
  Set<String> transferPumpNodeIds = const {},
  ({int lo, int hi})? floorRange,
}) {
  final prims = <SldPrim>[];
  // Round 16 — the solve's flow direction drives the FUNCTION suffix.
  final flowFromByEdge = flowFromBySizing(sizing);

  // Visible node ids under the focus filter (endpoints of focused-service edges).
  final Set<String>? visible = _focusedNodeIds(network, focus);
  bool nodeVisible(NetNode n) => visible == null || visible.contains(n.id);

  // Round 21 (riser-drafting-2-2) — a PAGE of a paginated riser draws only
  // the floors in [floorRange]; a riser crossing the page edge ends in a
  // 'LANJUT KE <floor>' match stub (below).
  bool onPage(NetNode n) =>
      floorRange == null ||
      (n.floorIndex >= floorRange.lo && n.floorIndex <= floorRange.hi);
  final allVisible = network.nodes.where(nodeVisible).toList(growable: false);
  final nodes = allVisible.where(onPage).toList(growable: false);
  if (allVisible.isEmpty) {
    return SldSheet(
      prims: const [],
      minX: 0,
      minY: 0,
      maxX: _gutterW + _drawW,
      maxY: _topPad + _bandH,
      legend: _fittingLegend(network, focus, const []),
      supplyNote: supplyNote,
    );
  }

  // Floor range: every building level when known, else the node floor span.
  final floorsPresent = allVisible.map((n) => n.floorIndex).toSet();
  final int fullLo;
  final int fullHi;
  if (building != null && building.levelCount > 0) {
    fullLo = 0;
    fullHi = building.levelCount - 1;
  } else {
    fullLo = floorsPresent.reduce(math.min);
    fullHi = floorsPresent.reduce(math.max);
  }
  final loFloor =
      floorRange == null ? fullLo : math.max(fullLo, floorRange.lo);
  final hiFloor =
      floorRange == null ? fullHi : math.min(fullHi, floorRange.hi);
  // The building's real top storey (the VTR / roof gating never reads a
  // page's own top floor).
  final topFloor = fullHi;
  final bandCount = (hiFloor - loFloor + 1).clamp(1, 999);
  // Round 21 (riser-drafting-2-7) — an ATAP (roof) datum band above the top
  // storey whenever this sheet shows it and the building is known: roof
  // tanks / roof drains park on the roof line, never inside the top floor.
  final roofBand = building != null &&
      building.levelCount > 0 &&
      hiFloor == building.levelCount - 1;
  final roofH = roofBand ? _roofBandH : 0.0;
  // The extras (plant detail, reference callouts, notes) ride the page that
  // carries the building's LOWEST floor (the last page of a set).
  final drawExtras = floorRange == null || loFloor == fullLo;

  // Band centre y for a floor index — highest floor at the TOP.
  double bandTop(int floorIndex) =>
      _topPad + roofH + (hiFloor - floorIndex) * _bandH;
  double bandCentreY(int floorIndex) => bandTop(floorIndex) + _bandH / 2;
  final roofLineY = _topPad + roofH - _roofLineInset;
  bool parksOnRoof(NetNode n) =>
      roofBand &&
      n.floorIndex == hiFloor &&
      (n.component == NodeComponent.roofTank ||
          n.component == NodeComponent.roofDrain);

  // Map a node's x into the placement band via the SHARED layout helper (B7):
  // a normalized column position in [0,1] — the SAME geometry the on-canvas Auto
  // painter uses — so a vertical riser stack reads as one column here and on the
  // preview, instead of the two surfaces jogging apart. Absent (should not
  // happen for a visible node) falls back to centred.
  final normX = riserLayoutPositions(network, focus: focus);
  double placeX(String nodeId) =>
      _gutterW + _sidePad + (normX[nodeId] ?? 0.5) * (_drawW - 2 * _sidePad);

  // Round 14 (drafting-visual-3) — each service on its own LANE within the
  // floor band (the shared [riserServiceLanes], mirrored by the canvas Auto
  // painter), so CW / HW and drainage / vent branches no longer overdraw.
  final lanes = riserServiceLanes(network, focus: focus);
  Offset posOf(NetNode n) => Offset(
      placeX(n.id),
      parksOnRoof(n)
          ? roofLineY - _symbolSize / 2
          : bandCentreY(n.floorIndex) + (lanes[n.id] ?? 0) * kRiserLanePitch);

  final posById = <String, Offset>{
    for (final n in nodes) n.id: posOf(n),
  };
  // Round 17 (drafting-visual-3-1) — each RUN on its own service lane, even
  // between multi-service nodes (D + V stack junction, CW + D fixture): the
  // horizontal leg sits at `a.dy + delta × pitch` with vertical drops into the
  // endpoints, so a vent run no longer overdraws the drainage run.
  final edgeLanes = riserEdgeLaneOffsets(network, focus: focus);
  // Round 21 (riser-drafting-2-4) — sibling runs leaving ONE node on ONE
  // lane fan out to distinct y offsets (filled below, after the B5 spread).
  final fanOff = <String, double>{};
  double runY(NetEdge e, Offset a) =>
      a.dy + (edgeLanes[e.id] ?? 0) * kRiserLanePitch + (fanOff[e.id] ?? 0);

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

  // ── Round 21 (riser-drafting-2-4) — branch fan-out from one header ─────────
  // Runs out of one node on the same lane were collinear (WC / lavatory /
  // shower overprinting as one line with three tags). Each sibling run now
  // gets its own offset — ordered as the fixtures are spread (far-end x, then
  // id), the first on the lane itself — away from the band centre. A
  // single-service sheet has the whole band, a combined one only a sub-lane
  // gap so a fan never lands on a neighbouring service lane.
  final siblings = <String, List<NetEdge>>{};
  for (final e in network.edges) {
    if (e.kind != EdgeKind.run) continue;
    if (focus != null && e.service != focus) continue;
    if (posById[e.fromId] == null || posById[e.toId] == null) continue;
    final lane = edgeLanes[e.id] ?? 0;
    (siblings['${e.fromId}|${e.service.index}|$lane'] ??= <NetEdge>[]).add(e);
  }
  final singleService = focus != null ||
      network.edges.map((e) => e.service).toSet().length < 2;
  final fanPitch = singleService ? _kFanPitchSingle : _kFanPitchCombined;
  // Each fan group is (the shared header node, its runs); the far end of a
  // run is the endpoint that is NOT the header.
  final fanGroups = <(String, List<NetEdge>)>[];
  for (final entry in siblings.entries) {
    if (entry.value.length < 2) continue;
    fanGroups.add((entry.key.split('|').first, entry.value));
  }
  // Round 21 review — runs drawn INTO the header (fixture -> header, the
  // header as `toId`) were never grouped and stayed collinear. Every run not
  // already fanned above is registered under BOTH its ends, keyed by the
  // shared node + service + lane + the SIDE (left / right) its far end lies
  // on — a series chain (A -> B -> C, far ends on opposite sides of B) never
  // groups — and joins the to-end group when that group has siblings, else
  // the from-end group.
  final fanned = {for (final g in fanGroups) ...g.$2.map((e) => e.id)};
  String endKey(NetEdge e, String nodeId) {
    final other = nodeId == e.fromId ? e.toId : e.fromId;
    final side = posById[other]!.dx < posById[nodeId]!.dx ? 'L' : 'R';
    return '$nodeId|${e.service.index}|${edgeLanes[e.id] ?? 0}|$side';
  }

  final byEnd = <String, List<NetEdge>>{};
  final loose = <NetEdge>[
    for (final group in siblings.values)
      for (final e in group)
        if (!fanned.contains(e.id)) e,
  ];
  for (final e in loose) {
    (byEnd[endKey(e, e.fromId)] ??= <NetEdge>[]).add(e);
    (byEnd[endKey(e, e.toId)] ??= <NetEdge>[]).add(e);
  }
  final headerGroups = <String, List<NetEdge>>{};
  for (final e in loose) {
    final toKey = endKey(e, e.toId);
    final fromKey = endKey(e, e.fromId);
    final key = byEnd[toKey]!.length >= 2
        ? toKey
        : byEnd[fromKey]!.length >= 2
            ? fromKey
            : null;
    if (key != null) (headerGroups[key] ??= <NetEdge>[]).add(e);
  }
  final headerKeys = headerGroups.keys.toList()..sort();
  for (final k in headerKeys) {
    final group = headerGroups[k]!;
    if (group.length < 2) continue;
    fanGroups.add((k.split('|').first, group));
  }
  for (final (header, group) in fanGroups) {
    double farX(NetEdge e) =>
        posById[e.fromId == header ? e.toId : e.fromId]!.dx;
    group.sort((x, y) {
      final d = farX(x).compareTo(farX(y));
      return d != 0 ? d : x.id.compareTo(y.id);
    });
    final lane = riserServiceLane(group.first.service);
    final dir = lane < 0 ? -1.0 : 1.0;
    for (var i = 1; i < group.length; i++) {
      fanOff[group[i].id] = dir * i * fanPitch;
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
  // Round 21 (riser-drafting-2-7) — the ATAP datum line + its elevation.
  if (roofBand) {
    prims.add(SldLine(_gutterW, roofLineY, _gutterW + _drawW, roofLineY,
        weight: SldWeight.thin, dashed: true));
    placer.reserveLine(_gutterW, roofLineY, _gutterW + _drawW, roofLineY);
    placer.reserve(SldLabel(8, roofLineY - 10, 'ATAP', size: 10, bold: true));
    placer.reserve(SldLabel(8, roofLineY + 4,
        fflLabel(building.roofElevation.meters),
        size: 8, role: SldRole.source));
  }
  for (var f = loFloor; f <= hiFloor; f++) {
    final top = bandTop(f);
    final yBase = top + _bandH - 1;
    prims.add(SldLine(_gutterW, yBase, _gutterW + _drawW, yBase,
        weight: SldWeight.thin));
    // X1: the floor datum is ink too — a riser tag whose mid-point lands on the
    // band line used to print straight through it.
    placer.reserveLine(_gutterW, yBase, _gutterW + _drawW, yBase);
    final name = (building != null && f < building.levelCount)
        ? building.floors[f].name
        : 'Level ${f + 1}';
    placer.reserve(SldLabel(8, top + 18, name, size: 10, bold: true));
    if (building != null && f < building.levelCount) {
      final ffl = building.elevationOf(f).meters;
      placer.reserve(
          SldLabel(8, top + 32, fflLabel(ffl), size: 8, role: SldRole.source));
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
    final colTop = y - 7;
    var colRight = fanX + _labelWidth('BRANCHES', 7);
    placer.reserve(SldLabel(fanX, y, 'BRANCHES', size: 7, bold: true));
    // N7: enumerate EVERY fixture the floor serves, grouped per type with a
    // count (`WC x3`) — no `+N more` truncation. A count of 1 stays bare.
    for (final g in fo.groups) {
      y += 12;
      final row = g.count > 1 ? '${g.label} x${g.count}' : g.label;
      placer.reserve(SldLabel(fanX + 6, y, row, size: 7));
      colRight = math.max(colRight, fanX + 6 + _labelWidth(row, 7));
    }
    if (fo.groupOverflow > 0) {
      y += 12;
      final more = '+${fo.groupOverflow} types';
      placer.reserve(SldLabel(fanX + 6, y, more, size: 7, role: SldRole.source));
      colRight = math.max(colRight, fanX + 6 + _labelWidth(more, 7));
    }
    // Round 17 — the whole column (+ a 2-unit margin, descenders included) is
    // a hard obstacle: no leader may cross it to a tag parked beyond.
    placer.reserveHardBox(fanX - 2, colTop - 2, colRight + 2,
        y + _kDescenderFraction * 7 + 2);
  }

  // ── Extras geometry (plant detail / reference callouts / notes) ─────────────
  // Computed HERE (it depends only on the network + focus + band count) so the
  // label placer can reserve those blocks before it places any movable tag;
  // the blocks themselves are still EMITTED further down, unchanged.
  const contentMaxX = _gutterW + _drawW + _fanColW;
  final extrasTop = _topPad + roofH + bandCount * _bandH + 12.0;
  bool hasComponent(NodeComponent c) =>
      network.nodes.any((n) => n.component == c);
  final waterFocus = focus == null ||
      focus == ServiceType.coldWater ||
      focus == ServiceType.hotWater;
  // G4: the drainage/vent/rainwater view earns the SAME reference-detail
  // treatment the clean-water view gets.
  final drainageFocus = focus == null ||
      focus == ServiceType.drainage ||
      focus == ServiceType.vent ||
      focus == ServiceType.rainwater;
  final plantWillDraw = detailCallouts &&
      drawExtras &&
      waterFocus &&
      (hasComponent(NodeComponent.roofTank) ||
          hasComponent(NodeComponent.groundTank) ||
          hasComponent(NodeComponent.pump) ||
          hasComponent(NodeComponent.boosterSet));
  final detailBoxes = !detailCallouts || !drawExtras
      ? const <(String, List<(NodeComponent?, String)>)>[]
      : <(String, List<(NodeComponent?, String)>)>[
          if (waterFocus && hasComponent(NodeComponent.waterMeter))
            (
              'DETAIL WATER METER',
              const [
                (NodeComponent.gateValve, 'GV'),
                (NodeComponent.waterMeter, 'WM'),
                (NodeComponent.gateValve, 'GV'),
                // Round 15 (drafting-visual-2-6) — a UNION, drawn as its own
                // mark (null component), never a fourth gate-valve bow-tie.
                (null, 'U'),
              ]
            ),
          if (waterFocus && hasComponent(NodeComponent.prv))
            (
              'DETAIL PRV SET',
              const [
                (NodeComponent.gateValve, 'GV'),
                (NodeComponent.strainer, 'STR'),
                (NodeComponent.prv, 'PRV'),
                (NodeComponent.gateValve, 'GV'),
              ]
            ),
          // G4: DETAIL FLOOR DRAIN (FD trap + CO) — only when one is drawn.
          if (drainageFocus && hasComponent(NodeComponent.floorDrain))
            (
              'DETAIL FLOOR DRAIN',
              const [
                (NodeComponent.floorDrain, 'FD'),
                (NodeComponent.cleanout, 'CO'),
              ]
            ),
          // G4: DETAIL VTR — only when a vent riser actually reaches the roof.
          if (drainageFocus &&
              ventTopTerminalIds(network, topFloor: topFloor).isNotEmpty)
            (
              'DETAIL VTR',
              const [
                (NodeComponent.airVent, 'VTR'),
              ]
            ),
        ];
  final showNotes = notes.isNotEmpty && drawExtras;
  final notesH = !showNotes ? 0.0 : 20 + notes.length * _notesLineH + 6;
  // Round 21 (riser-drafting-2-5) — the reference callout row and the
  // KETERANGAN block share the strip below the bands: the row is centred in
  // the drawing band but never runs past the notes' left edge (minus a gap);
  // if it still cannot fit (or would start inside the gutter) the notes stack
  // BELOW the callouts instead. One geometry for reserve + emit.
  final calloutTotalW = detailBoxes.isEmpty
      ? 0.0
      : detailBoxes.length * _calloutW + (detailBoxes.length - 1) * 16;
  const notesLeft = contentMaxX - _notesW;
  var calloutX0 = _gutterW + (_drawW - calloutTotalW) / 2;
  var notesTop = extrasTop;
  if (detailBoxes.isNotEmpty &&
      showNotes &&
      calloutX0 + calloutTotalW > notesLeft - 16) {
    final shifted = notesLeft - 16 - calloutTotalW;
    if (shifted >= _gutterW) {
      calloutX0 = shifted;
    } else {
      notesTop = extrasTop + _calloutH + 12;
    }
  }

  // ── X1: seed the occupied list with the sheet's non-label INK ───────────────
  // The placer used to know only about other LABELS, so a tag could still be
  // struck through by the pipe it names, printed over an equipment glyph, or
  // land on top of the right-margin PUMP-SET / reference-detail / KETERANGAN
  // blocks (all of which are emitted later in the prim list). Reserving those
  // regions FIRST — the electrical `_RiserLabelPlacer` idiom: per-size
  // char-advance boxes, a bounded nudge ladder, leaders, never a dropped tag —
  // makes the movable tags divert around them. Nothing is emitted here, so the
  // prim order (and any sheet whose tags already sat clear) is unchanged.
  for (final n in nodes) {
    final p = posById[n.id]!;
    final half = (n.component != null ? _symbolSize : _nodeBox) / 2;
    placer.reserveBox(p.dx - half, p.dy - half, p.dx + half, p.dy + half);
  }
  for (final e in network.edges) {
    if (focus != null && e.service != focus) continue;
    final a = posById[e.fromId];
    final b = posById[e.toId];
    if (a == null || b == null) continue;
    final y = runY(e, a);
    if ((y - a.dy).abs() > 0.5) placer.reserveLine(a.dx, a.dy, a.dx, y);
    if ((b.dx - a.dx).abs() >= 0.5) placer.reserveLine(a.dx, y, b.dx, y);
    if ((b.dy - y).abs() > 0.5) {
      placer.reserveLine(b.dx, y, b.dx, b.dy);
    }
  }
  if (plantWillDraw) {
    placer.reserveBox(contentMaxX + 12, _topPad, contentMaxX + 12 + _plantW,
        _topPad + _plantDetailH(network));
  }
  if (detailBoxes.isNotEmpty) {
    var bx = calloutX0;
    for (var i = 0; i < detailBoxes.length; i++) {
      placer.reserveBox(bx, extrasTop, bx + _calloutW, extrasTop + _calloutH);
      bx += _calloutW + 16;
    }
  }
  if (notesH > 0) {
    placer.reserveBox(notesLeft, notesTop, contentMaxX, notesTop + notesH);
  }

  // ── B2 STACK DETAIL: cleanouts, the vent tee, VTR terminations ──────────────
  // Data-gated on the DRAWN network (positions exist only for focus-visible
  // nodes, so a filtered system omits the other system's marks). Reserved
  // before the movable band tags so they divert around these fixed marks.
  if (focus == null || focus == ServiceType.vent) {
    // A vent riser reaching the TOP floor terminates through the roof: a short
    // dashed stub above the band + the 'VTR' code.
    for (final id in ventTopTerminalIds(network, topFloor: topFloor)) {
      final p = posById[id];
      if (p == null) continue;
      final stubTop = roofBand ? roofLineY - 10 : bandTop(hiFloor) - 10;
      prims.add(SldLine(p.dx, p.dy, p.dx, stubTop,
          weight: SldWeight.medium,
          layer: riserServiceCode(ServiceType.vent),
          dashed: true));
      // Roof-penetration cap tick.
      prims.add(SldLine(p.dx - 4, stubTop, p.dx + 4, stubTop,
          weight: SldWeight.medium, layer: riserServiceCode(ServiceType.vent)));
      // Round 10 (mech-drawing-props-6) — the stub + cap are ink a top-floor
      // band tag must divert around, not print through.
      placer
        ..reserveLine(p.dx, p.dy, p.dx, stubTop)
        ..reserveLine(p.dx - 4, stubTop, p.dx + 4, stubTop);
      placer
          .reserve(SldLabel(p.dx + 6, stubTop + 6, 'VTR', size: 7, bold: true));
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
      // Round 15 — the terminus glyph is ink a node tag must not print over.
      placer.reserveBox(p.dx - _symbolSize / 2, gy - _symbolSize / 2,
          p.dx + _symbolSize / 2, gy + _symbolSize / 2);
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

  // ── Round 21 (riser-drafting-2-2) — page-edge MATCH stubs ───────────────────
  // A riser whose far end sits on another page of a paginated set runs to the
  // page's band edge and names the floor it continues to.
  //
  // Round 22 (regression-riser-page-break-drops-tags) — the riser's
  // SIZE-SERVICE-MATERIAL tag + its riser id ride the page holding the
  // riser's LOWER end (exactly one page, so the set carries every tag once),
  // and a riser whose span strictly contains this page's floors is drawn as a
  // full-height PASS-THROUGH with its pipe tag and a LANJUT label at both
  // page edges — never absent from an intermediate page.
  final tags = riserTags(network, focus);
  if (floorRange != null) {
    final byId = {for (final n in allVisible) n.id: n};
    final topEdgeY = bandTop(hiFloor) + 2;
    final bottomEdgeY = bandTop(loFloor) + _bandH - 2;
    String floorName(int f) => (building != null && f < building.levelCount)
        ? building.floors[f].name
        : 'Level ${f + 1}';
    void lanjut(double x, double edgeY, bool up, int floor) {
      final text = 'LANJUT KE ${floorName(floor)}';
      placer.place(x + 6, up ? edgeY + 9 : edgeY - 3, text,
          size: 8,
          bold: true,
          anchorX: x,
          anchorY: edgeY,
          candidates: _riserLadder(text));
    }

    void riserTagAt(NetEdge e, double x, double y1, double y2,
        {required bool withId}) {
      final role = _edgeRole(network, e);
      final fn = riserFunctionFor(network, e,
          downfeed: downfeed, flowFrom: flowFromByEdge);
      final tag = _pipeTag(sizing[e.id], e,
          function: fn, length: edgeLengths[e.id]);
      final midY = math.min(y1, y2) + (y1 - y2).abs() / 4;
      placer.place(x + 6, midY, tag,
          size: 8,
          role: role,
          anchorX: x,
          anchorY: midY,
          candidates: _riserLadder(tag));
      final rt = withId ? tags[e.id] : null;
      if (rt != null) {
        placer.place(x + 6, midY + 12, rt,
            size: 8,
            bold: true,
            role: role,
            anchorX: x,
            anchorY: midY + 12,
            candidates: _riserLadder(rt));
      }
    }

    for (final e in network.edges) {
      if (focus != null && e.service != focus) continue;
      final a = posById[e.fromId];
      final b = posById[e.toId];
      final layer = riserServiceCode(e.service);
      if (a == null && b == null) {
        // A pass-through: both ends visible on OTHER pages, one above and one
        // below this page's floor range.
        final na = byId[e.fromId];
        final nb = byId[e.toId];
        if (na == null || nb == null) continue;
        final lo = math.min(na.floorIndex, nb.floorIndex);
        final hi = math.max(na.floorIndex, nb.floorIndex);
        if (!(lo < loFloor && hi > hiFloor)) continue;
        final lower = na.floorIndex <= nb.floorIndex ? na : nb;
        final upper = identical(lower, na) ? nb : na;
        final x = placeX(lower.id);
        prims.add(SldLine(x, bottomEdgeY, x, topEdgeY,
            weight: SldWeight.medium,
            role: _edgeRole(network, e),
            layer: layer,
            dashed: e.service == ServiceType.vent));
        placer.reserveLine(x, bottomEdgeY, x, topEdgeY);
        lanjut(x, topEdgeY, true, upper.floorIndex);
        lanjut(x, bottomEdgeY, false, lower.floorIndex);
        riserTagAt(e, x, topEdgeY, bottomEdgeY, withId: false);
        continue;
      }
      if (a == null || b == null) {
        final here = a ?? b!;
        final farNode = byId[a == null ? e.fromId : e.toId];
        if (farNode == null) continue;
        final up = farNode.floorIndex > hiFloor;
        final edgeY = up ? topEdgeY : bottomEdgeY;
        prims.add(SldLine(here.dx, here.dy, here.dx, edgeY,
            weight: SldWeight.medium,
            role: _edgeRole(network, e),
            layer: layer,
            dashed: e.service == ServiceType.vent));
        placer.reserveLine(here.dx, here.dy, here.dx, edgeY);
        lanjut(here.dx, edgeY, up, farNode.floorIndex);
        // The lower end's page carries the tag + riser id.
        if (up) riserTagAt(e, here.dx, here.dy, edgeY, withId: true);
      }
    }
  }

  // ── Edges: runs + risers with the SIZE-SERVICE-MATERIAL[-FUNCTION] tag ───────
  // B4: every pipe run/riser is MEDIUM weight (vs the thin datum), carries its
  // service code as the CAD layer, and the vent service draws DASHED.
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
    // Round 10 (mech-drawing-props-7) — a purely vertical riser has no
    // horizontal leg: skip it rather than emit a zero-length LINE.
    // Round 17 — the run leg on the edge's own service lane (a drop at the
    // from-x first when the from node sits on another lane).
    final y = runY(e, a);
    if ((y - a.dy).abs() > 0.5) {
      prims.add(SldLine(a.dx, a.dy, a.dx, y,
          weight: SldWeight.medium, role: role, layer: layer, dashed: dashed));
    }
    if ((b.dx - a.dx).abs() >= 0.5) {
      prims.add(SldLine(a.dx, y, b.dx, y,
          weight: SldWeight.medium, role: role, layer: layer, dashed: dashed));
    }
    if ((b.dy - y).abs() > 0.5) {
      prims.add(SldLine(b.dx, y, b.dx, b.dy,
          weight: SldWeight.medium, role: role, layer: layer, dashed: dashed));
    }

    // B1 flow chevron — only where the solve confidently recorded the
    // direction (EdgeSizing.flowFromId); null ⇒ nothing (byte-identical).
    final flowFrom = sz?.flowFromId;
    if (flowFrom == e.fromId || (flowFrom != null && flowFrom == e.toId)) {
      _addFlowChevron(prims, Offset(a.dx, y), b,
          reversed: flowFrom == e.toId, role: role, layer: layer);
    }

    final fn = riserFunctionFor(network, e,
        downfeed: downfeed, flowFrom: flowFromByEdge);
    final tag = _pipeTag(sz, e, function: fn, length: edgeLengths[e.id]);
    if (e.kind == EdgeKind.riser) {
      // Tag + riser id beside the vertical leg. Round 10
      // (mech-drawing-props-7) — the default slot sits INSIDE the upper
      // floor's band, a quarter band below its node: nodes sit at band
      // centres, so the old mid-point of two adjacent floors landed exactly on
      // the reserved floor datum and EVERY riser tag walked the ladder to a
      // leader.
      final midY = math.min(a.dy, b.dy) + _bandH / 4;
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
      placer.place(midX - _labelWidth(tag, 8) / 2, y - 6, tag,
          size: 8,
          role: role,
          anchorX: midX,
          anchorY: y,
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
      prims.addAll(_withRole(
          planFixturePrims(cx: p.dx, cy: p.dy, size: _nodeBox), role));
      labelInset = _nodeBox / 2;
    } else {
      prims.add(SldRect(
          p.dx - _nodeBox / 2, p.dy - _nodeBox / 2, _nodeBox, _nodeBox,
          weight: SldWeight.thin, role: role));
      labelInset = _nodeBox / 2;
    }
    // drafting-7: a scheduled unit LEADS with its stable equipment TAG (the
    // same `equipmentNodeTags` number the plan + schedule carry) ahead of its
    // descriptive word, so the riser cross-references them without losing
    // what the unit is (`TK-01 Roof tank · 5 m3`, `P-02 Pump · 2.2 kW`).
    final tagged = nodeTags[n.id];
    final word = _nodeLabel(n);
    final base = (tagged != null && tagged.isNotEmpty)
        ? (word == null ? tagged : '$tagged $word')
        : word;
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
  var maxX = contentMaxX;
  var extrasBottom = extrasTop;

  if (detailCallouts && drawExtras) {
    if (waterFocus &&
        _emitPlantDetail(prims, network, contentMaxX + 12, _topPad,
            equipmentDetailByNodeId: equipmentDetailByNodeId,
            downfeed: downfeed,
            transferPumpNodeIds: transferPumpNodeIds)) {
      maxX = contentMaxX + 12 + _plantW;
    }
    // Reference detail callouts, bottom-centre of the band — each drawn ONLY
    // when the network actually carries the assembly's key device (G7/G4,
    // mirroring the plant detail's has()-gating): the WATER METER / PRV SET
    // (clean water), the FLOOR DRAIN / VTR (drainage/vent). A project without a
    // device shows neither box (honesty — no boilerplate detail masquerading as
    // an as-designed assembly). The present boxes are centred as a group so a
    // lone detail still reads balanced; the combined view shows every applicable
    // box in one row. (The rects were computed + reserved above.)
    if (detailBoxes.isNotEmpty) {
      var bx = calloutX0;
      for (final (title, items) in detailBoxes) {
        _emitDetailBox(prims, bx, extrasTop, title, items);
        bx += _calloutW + 16;
      }
      extrasBottom = math.max(extrasBottom, extrasTop + _calloutH);
    }
  }
  if (showNotes) {
    // The KETERANGAN system-notes block, bottom-RIGHT (the renderers stamp the
    // page-fixed title block below/beside it in page space).
    const left = notesLeft;
    prims
        .add(SldRect(left, notesTop, _notesW, notesH, weight: SldWeight.thin));
    prims.add(
        SldLabel(left + 6, notesTop + 12, 'KETERANGAN', size: 7, bold: true));
    var y = notesTop + 24.0;
    for (final line in notes) {
      prims.add(SldLabel(left + 6, y, line, size: 7));
      y += _notesLineH;
    }
    extrasBottom = math.max(extrasBottom, notesTop + notesH);
  }

  // ── Bounds ──────────────────────────────────────────────────────────────────
  final maxY = extrasBottom == extrasTop ? extrasTop : extrasBottom + 12;
  return SldSheet(
    prims: prims,
    minX: 0,
    minY: 0,
    maxX: maxX,
    maxY: maxY,
    legend: _fittingLegend(network, focus, prims),
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

/// The industry pipe tag `SIZE-SERVICE-MATERIAL[-FUNCTION][ - x.x m]`; a round
/// air duct reads `O<mm>` (ASCII), a rectangular one `<W>x<H>`. A null sizing falls back to a service-only
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
      // A rectangular duct prints its real W x H — its `diameter` is only the
      // circular EQUIVALENT (network_sizing), a round size that does not exist
      // on site. Mirrors the plan exporters' `_sizeLabel` and the BOM.
      tag = s.isRectangular
          ? '${s.width!.inMillimeters.round()}x${s.height!.inMillimeters.round()}'
          : '\u00D8$mm'; // R5: real Ø (PDF WinAnsi 0xD8 / DXF %%c)
    } else {
      final base =
          '$mm-$code-${_pipeMaterialCode(edge.pipeProduct, edge.service)}';
      tag = function != null ? '$base-${function.code}' : base;
    }
  }
  if (length != null && length.meters > 0) {
    tag = '$tag - ${planLengthLabel(length)}';
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
    ServiceType.drainage || ServiceType.vent || ServiceType.rainwater => 'PVC',
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

/// The riser drawing's own ABBREVIATIONS, keyed only when a label on the sheet
/// actually uses them (drafting-8). Drafting-office vocabulary, not engineering
/// values, so no `// VERIFY`. Listed in the order the legend prints them.
const List<(String, String)> _kRiserTagGlossary = [
  // Line codes beyond the service codes.
  ('HWR', 'Hot water return (sirkulasi), dashed'),
  // Pipe MATERIAL codes (the third token of a SIZE-SERVICE-MATERIAL tag).
  ('PPR', 'Pipa PPR (polypropylene random)'),
  ('PVC', 'Pipa PVC'),
  ('CI', 'Pipa besi tuang (cast iron)'),
  ('HDPE', 'Pipa HDPE'),
  ('BS', 'Pipa baja hitam (black steel)'),
  ('GI', 'Pipa baja galvanis (galvanised iron)'),
  // Riser FUNCTION codes (the tag suffix).
  ('GRAVITASI', 'Gravity feed from the roof tank'),
  ('BOOSTER', 'Booster-pumped supply'),
  ('TRANSFER', 'Transfer pumping, ground tank to roof tank'),
  // Fittings, valves and terminals drawn with a code.
  ('GV', 'Gate valve'),
  ('U', 'Union'),
  ('CV', 'Check valve'),
  ('STR', 'Strainer'),
  ('PRV', 'Pressure reducing valve'),
  ('WM', 'Water meter'),
  ('AAV', 'Auto air vent'),
  ('FJ', 'Flexible joint'),
  ('FD', 'Floor drain'),
  ('CO', 'Cleanout'),
  ('VTR', 'Vent through roof'),
];

/// The KETERANGAN device legend, built from what the sheet DRAWS (drafting-8):
/// the service codes present on the (focused) network, then each abbreviation
/// of [_kRiserTagGlossary] that some label on the sheet uses (a pipe tag's
/// material and function codes, the HWR return, the fitting codes of the
/// detail callouts…), then a riser-tag key when riser ids (`CW-R1`) are drawn.
/// A code the sheet never prints is not keyed, and nothing it prints is left
/// unexplained.
List<SldLegendEntry> _fittingLegend(
    Network network, ServiceType? focus, List<SldPrim> prims) {
  final out = <SldLegendEntry>[];
  // Service codes present (the focus, or every service that has an edge).
  final services = <ServiceType>{
    for (final e in network.edges)
      if (focus == null || e.service == focus) e.service,
  };
  // Every token any label prints (split on spaces, hyphens, the middle dot and
  // brackets — a tag `32-CW-PPR-BOOSTER - 4.0 m` yields CW / PPR / BOOSTER).
  final tokens = <String>{
    for (final p in prims)
      if (p is SldLabel) ...p.text.split(RegExp(r'[\s\-\u00B7/()]+')),
  };
  // Round 10 (mech-drawing-props-8) — a service code is keyed only when some
  // label actually PRINTS it (air tags print `Ø300` / `WxH`, no code, so an
  // air service with no `SA-R1` riser id earns no key).
  for (final s in ServiceType.values) {
    if (services.contains(s) && tokens.contains(riserServiceCode(s))) {
      out.add(SldLegendEntry(riserServiceCode(s), _serviceMeaning(s)));
    }
  }
  final keyed = {for (final e in out) e.code};
  for (final (code, meaning) in _kRiserTagGlossary) {
    if (tokens.contains(code) && keyed.add(code)) {
      out.add(SldLegendEntry(code, meaning));
    }
  }
  // A riser id (`CW-R1`) keys with the first one the sheet prints.
  final riserId = RegExp(r'^[A-Z]+-R\d+$');
  for (final p in prims) {
    if (p is SldLabel && riserId.hasMatch(p.text)) {
      out.add(SldLegendEntry(p.text, 'Riser tag: service code + riser no.'));
      break;
    }
  }
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
    List<(NodeComponent?, String)> items) {
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
    if (component == null) {
      prims.addAll(unionMarkPrims(cx: cx, cy: cy, size: _calloutGlyph));
    } else {
      prims.addAll(
          planComponentPrims(component, cx: cx, cy: cy, size: _calloutGlyph));
    }
    prims.add(SldLabel(
        cx - _labelWidth(abbrev, 7) / 2, cy + _calloutGlyph / 2 + 10, abbrev,
        size: 7));
  }
}

/// Round 15 (drafting-visual-2-6) — the pipe UNION mark: two short parallel
/// bars ACROSS the run (the drafting convention for a union / coupling), pure
/// [SldLine] prims so PDF / DXF / canvas draw it alike. Never a valve glyph.
List<SldPrim> unionMarkPrims(
    {required double cx, required double cy, required double size}) {
  final half = size * 0.38;
  const dx = 2.0;
  return [
    SldLine(cx - dx, cy - half, cx - dx, cy + half, weight: SldWeight.medium),
    SldLine(cx + dx, cy - half, cx + dx, cy + half, weight: SldWeight.medium),
  ];
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
  Set<String> transferPumpNodeIds = const {},
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

  prims.add(SldRect(left, top, _plantW, _plantDetailH(network),
      weight: SldWeight.thin));
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
      // Round 21 (riser-drafting-2-3) — GRAVITASI names the tank's gravity
      // OUTLET to the building, drawn as its OWN stub off the tank's left side
      // (out, then down) with the word beside it at the box edge — never on
      // the pump-to-tank leg at cx (that leg is the TRANSFER / booster
      // discharge, and it used to strike through the word).
      final outY = y + glyph / 2;
      final stubX = left + 24;
      prims
        ..add(SldLine(cx - glyph / 2, outY, stubX, outY,
            weight: SldWeight.thin, role: SldRole.source))
        ..add(SldLine(stubX, outY, stubX, y + glyph + 2,
            weight: SldWeight.thin, role: SldRole.source))
        ..add(SldLabel(left + 6, y + glyph + 12, 'GRAVITASI',
            size: 7, bold: true, role: SldRole.source));
    }
    roofBottom = y + glyph;
    y += glyph + 26;
  }

  // Round 21 (riser-drafting-2-7) — the GROUND TANK and its real capacity:
  // the H-101 pump-set detail shows the GWT -> pump -> (RT) chain.
  void groundTankRow(double gx, double gy) {
    prims.addAll(_withRole(
        planComponentPrims(NodeComponent.groundTank,
            cx: gx, cy: gy + glyph / 2, size: glyph),
        SldRole.source));
    final m3 = detailOf(NodeComponent.groundTank);
    prims.add(SldLabel(gx + glyph / 2 + 8, gy + glyph / 2 + 3,
        m3 != null ? 'GROUND TANK $m3' : 'GROUND TANK',
        size: 7, role: SldRole.source));
  }

  // ── PUMP row with the suction / discharge VALVE TRAIN (G3) ───────────────────
  // The pump sits centred, flanked by its real isolation / backflow train — the
  // suction leg (GV · STR · FJ) to the left, the discharge leg (FJ · CV · GV) to
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
    const train = kPumpSetValveTrain;
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
        prims.add(SldLabel(
            gx - _labelWidth(abbrev, 7) / 2, trainCy + gl / 2 + 10, abbrev,
            size: 7, role: SldRole.source));
      }
    }
    // Duty caption(s) + the pump-leg function label, centred below the train.
    // Round 17 (report-recompute-2-transfer-pump-drawn-as-booster) — ONE
    // caption per drawn mover from the per-node duty map, a transfer pump
    // (ground tank -> roof tank) captioned 'TRANSFER PUMP', never 'BOOSTER'.
    var capY = trainCy + gl / 2 + 24;
    for (final cap in plantMoverCaptions(network,
        detailByNodeId: equipmentDetailByNodeId,
        transferPumpNodeIds: transferPumpNodeIds)) {
      prims.add(SldLabel(cx - _labelWidth(cap, 7) / 2, capY, cap,
          size: 7, role: SldRole.source));
      capY += 12;
    }
    // TRANSFER (ground -> roof lift) only when BOTH tanks exist (the legend's
    // own definition, and riserFunctionFor's rule — Round 12 printed-parity-3:
    // an upfeed ground-tank booster was labelled TRANSFER); else BOOSTER
    // (pump-up) on upfeed. Mirrors the canvas leg labels.
    final leg = hasGround && hasRoof
        ? 'TRANSFER'
        : (!downfeed ? 'BOOSTER' : null);
    if (leg != null) {
      prims.add(SldLabel(cx - _labelWidth(leg, 7) / 2, capY, leg,
          size: 7, bold: true, role: SldRole.source));
      capY += 12;
    }
    if (hasGround) {
      // The suction leg drops from the train's inlet end to the tank below
      // the captions (left of them, so it crosses no text).
      final inletX = firstCx - gl / 2;
      final gy = capY - 2;
      prims.add(SldLine(inletX, trainCy, inletX, gy,
          weight: SldWeight.thin, role: SldRole.source));
      groundTankRow(inletX, gy);
    }
  } else if (hasGround) {
    groundTankRow(cx, y);
  }
  return true;
}

/// The drawn domestic-water MOVERS (pump / booster set nodes on a cold-water
/// edge — never the fire pump or the HW circulator) the plant detail captions,
/// in a deterministic id order.
List<NetNode> _plantMovers(Network network) => [
      for (final n in network.nodes)
        if ((n.component == NodeComponent.pump ||
                n.component == NodeComponent.boosterSet) &&
            network
                .edgesAt(n.id)
                .any((e) => e.service == ServiceType.coldWater))
          n,
    ]..sort((a, b) => a.id.compareTo(b.id));

/// Round 17 (report-recompute-2-transfer-pump-drawn-as-booster) — the
/// pump-set detail's duty CAPTIONS, ONE per drawn domestic-water mover from
/// the per-node duty map ([detailByNodeId], the `riserEquipmentDetails` both
/// the canvas and the export read): `TRANSFER PUMP <kW>` for a node in
/// [transferPumpNodeIds] (ground tank -> roof tank), `BOOSTER PUMP <kW>`
/// otherwise. No piped mover (a dropped, unconnected pump) ⇒ one bare
/// `BOOSTER PUMP` caption with the first pump's datum. Shared by the export
/// and the canvas Auto painter (golden rule 5) so the two never disagree.
List<String> plantMoverCaptions(
  Network network, {
  required Map<String, String> detailByNodeId,
  Set<String> transferPumpNodeIds = const {},
}) {
  final movers = _plantMovers(network);
  if (movers.isEmpty) {
    String? kw;
    for (final c in [NodeComponent.boosterSet, NodeComponent.pump]) {
      for (final n in network.nodes) {
        if (n.component != c) continue;
        kw ??= detailByNodeId[n.id];
      }
      if (kw != null || network.nodes.any((n) => n.component == c)) break;
    }
    return [kw != null ? 'BOOSTER PUMP $kw' : 'BOOSTER PUMP'];
  }
  return [
    for (final m in movers)
      () {
        final kw = detailByNodeId[m.id];
        final noun = transferPumpNodeIds.contains(m.id)
            ? 'TRANSFER PUMP'
            : 'BOOSTER PUMP';
        return kw != null ? '$noun $kw' : noun;
      }(),
  ];
}

/// The plant-detail box height: [_plantH], grown one caption row per mover
/// beyond the second (Round 17 — one duty caption per mover).
///
/// Round 21 — plus one tank row when a ground tank sits below the pump train.
double _plantDetailH(Network network) {
  bool has(NodeComponent c) => network.nodes.any((n) => n.component == c);
  final groundBelowTrain = has(NodeComponent.groundTank) &&
      (has(NodeComponent.pump) || has(NodeComponent.boosterSet));
  return _plantH +
      math.max(0, _plantMovers(network).length - 2) * 12.0 +
      (groundBelowTrain ? 36.0 : 0.0);
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
      'CV' => planComponentPrims(NodeComponent.checkValve,
          cx: cx, cy: cy, size: size),
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
          e.service == ServiceType.drainage && (e.fromId == id || e.toId == id))
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
    // Round 10 — the return leg + loop turn are ink tags divert around.
    placer
      ..reserveLine(legX, yTop, legX, yBot)
      ..reserveLine(b.dx, yTop, legX, yTop);
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
    const half = (_nodeBox + 4) / 2;
    placer.reserveBox(px - half, lp.dy - half, px + half, lp.dy + half);
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

  /// Boxes of LABELS already on the sheet (fixed + placed movable tags).
  final List<_LabelRect> _labels = <_LabelRect>[];

  /// Boxes of reserved INK — pipe legs, equipment glyphs, bordered blocks.
  final List<_LabelRect> _ink = <_LabelRect>[];

  /// Leader segments already drawn (x1, y1, x2, y2) — Round 15: reserved so a
  /// later tag never lands on an earlier leader.
  final List<(double, double, double, double)> _leaders = [];

  /// Round 17 (drafting-visual-3-6) — HARD obstacles a leader may never cross
  /// (the per-floor BRANCHES fan-out column): a tag parked on the far side of
  /// the column used to run its leader through the fan-out text.
  final List<_LabelRect> _hard = <_LabelRect>[];
  _LabelPlacer(this.prims);

  /// A label's box: cap height above the baseline PLUS a descender allowance
  /// of [_kDescenderFraction] × size below it (Round 17 — a leader skimming
  /// 0.3 units under a baseline used to pass 'clear' through the descenders
  /// of 'Lavatory').
  _LabelRect _rectFor(double x, double y, String text, double size) =>
      _LabelRect(x, y - size, x + _labelWidth(text, size),
          y + _kDescenderFraction * size);

  /// Record a region no leader may cross (see [_hard]); also ink for labels.
  void reserveHardBox(double minX, double minY, double maxX, double maxY) {
    if (maxX <= minX || maxY <= minY) return;
    _hard.add(_LabelRect(minX, minY, maxX, maxY));
  }

  /// Round 15 (drafting-visual-2-1) — the COST of a label box at ([x], [y]):
  /// its overlap with other labels, plus [_kInkWeight] × its overlap with
  /// reserved ink and with drawn leaders, plus the same weight when the
  /// leader it would need (from ([anchorX], [anchorY])) would strike through
  /// a placed label. A tag over ink (a pipe through its text) is far worse
  /// than two tags touching, so the least-cost fallback never prefers it.
  double _costAt(double x, double y, String text, double size,
      {required double anchorX,
      required double anchorY,
      required bool withLeader}) {
    final r = _rectFor(x, y, text, size);
    var total = 0.0;
    for (final p in _labels) {
      total += p.overlap(r);
    }
    for (final p in _ink) {
      total += _kInkWeight * p.overlap(r);
    }
    for (final (x1, y1, x2, y2) in _leaders) {
      if (_segmentHitsRect(x1, y1, x2, y2, r)) total += _kInkWeight * size;
    }
    for (final p in _hard) {
      total += _kInkWeight * p.overlap(r);
    }
    if (withLeader) {
      final (ex, ey) = _leaderEnd(r, anchorX, anchorY);
      for (final p in _labels) {
        if (_segmentHitsRect(anchorX, anchorY, ex, ey, p)) {
          total += _kInkWeight * size;
        }
      }
      // A leader through a hard obstacle is never acceptable: a cost no
      // ordinary overlap can reach, so any other slot wins.
      for (final p in _hard) {
        if (_segmentHitsRect(anchorX, anchorY, ex, ey, p)) total += 1e9;
      }
    }
    return total;
  }

  /// Round 20 (drafting-visual-4-2) — the SECONDARY cost of the leader a slot
  /// at ([x], [y]) would need: how far it runs ALONG a reserved pipe strip
  /// (beyond the strip's own thickness — the square exit), plus a text height
  /// for every OTHER glyph box it strikes (the anchor's own box is exempt:
  /// every leader leaves it). A tag's leader once ran from the third supply
  /// diffuser back along its duct, through two diffuser glyphs and the AHU,
  /// to a slot left of the plant — reading as a duct stub. This tier only
  /// ORDERS slots whose primary [_costAt] is equal (a clear slot with a
  /// square leader beats a clear slot with a collinear one, and the search
  /// keeps going past a collinear 'clear' slot); it never trades a label
  /// collision for a straighter leader.
  double _leaderInkCost(double x, double y, String text, double size,
      {required double anchorX, required double anchorY}) {
    final r = _rectFor(x, y, text, size);
    final (ex, ey) = _leaderEnd(r, anchorX, anchorY);
    var total = 0.0;
    for (final p in _ink) {
      final len = _segmentClipLength(anchorX, anchorY, ex, ey, p);
      if (len <= 0) continue;
      final strip = (p.maxX - p.minX) <= 2 * _kInkHalfThickness + 0.01 ||
          (p.maxY - p.minY) <= 2 * _kInkHalfThickness + 0.01;
      if (strip) {
        final along = len - 2 * _kInkHalfThickness;
        if (along > 0) total += along;
        continue;
      }
      final containsAnchor = anchorX >= p.minX &&
          anchorX <= p.maxX &&
          anchorY >= p.minY &&
          anchorY <= p.maxY;
      if (!containsAnchor) total += size;
    }
    return total;
  }

  /// Emit a FIXED-position label (gutter / fan-out) and record its box so
  /// movable tags divert around it.
  void reserve(SldLabel label) {
    _labels.add(_rectFor(label.x, label.y, label.text, label.size));
    prims.add(label);
  }

  /// Record an occupied REGION that is not a label — an equipment glyph, a pipe
  /// run, or a bordered detail/notes block — WITHOUT emitting anything (X1). The
  /// owning prims are still drawn at their own place in the list, so the prim
  /// ORDER is unchanged; only a tag that would have printed over the region
  /// moves. Zero-area regions are ignored.
  void reserveBox(double minX, double minY, double maxX, double maxY) {
    if (maxX <= minX || maxY <= minY) return;
    _ink.add(_LabelRect(minX, minY, maxX, maxY));
  }

  /// Record a drawn LINE as a thin occupied strip so a label is never struck
  /// through by the pipe / leg it sits on (X1). Only axis-aligned segments are
  /// seeded — every run/riser leg of the L-route is one.
  void reserveLine(double x1, double y1, double x2, double y2) {
    reserveBox(
        math.min(x1, x2) - _kInkHalfThickness,
        math.min(y1, y2) - _kInkHalfThickness,
        math.max(x1, x2) + _kInkHalfThickness,
        math.max(y1, y2) + _kInkHalfThickness);
  }

  /// Place a MOVABLE tag at its default ([defaultX], [defaultY]) trying the
  /// [candidates] offsets (candidates[0] == the default) in order; the first
  /// slot clearing every placed box wins, else the least-costly. When NO
  /// ladder slot clears — two short branch tags sharing a midpoint (N3) — the
  /// placer ESCAPES further out (growing vertical steps, down then up) and,
  /// Round 15, then SIDEWAYS past the stack channel, until it clears, so tags
  /// never overprint into one fused token nor print through a pipe. A tag is
  /// the drawing's content and is never dropped: if even the escape can't
  /// fully clear, the least-costly slot is used. Any slot displaced more than
  /// [_kLeaderThreshold] from the default — or that could not be fully
  /// cleared — gets a thin leader from ([anchorX], [anchorY]), the element the
  /// tag names, to the NEAREST point of the label's box (so it never runs
  /// through its own text), and that leader is reserved.
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
    bool needsLeader(Offset c) =>
        math.sqrt(c.dx * c.dx + c.dy * c.dy) > _kLeaderThreshold;
    double cost(Offset c) => _costAt(
        defaultX + c.dx, defaultY + c.dy, text, size,
        anchorX: anchorX, anchorY: anchorY, withLeader: needsLeader(c));
    // Round 20 — the leader-along-ink tier (0 when no leader is drawn).
    double leaderCost(Offset c) => needsLeader(c)
        ? _leaderInkCost(defaultX + c.dx, defaultY + c.dy, text, size,
            anchorX: anchorX, anchorY: anchorY)
        : 0;
    Offset best = candidates.isEmpty ? const Offset(0, 0) : candidates.first;
    var bestCost = double.infinity;
    var bestLeader = double.infinity;
    var cleared = false;
    void consider(Offset c) {
      if (cleared) return;
      final total = cost(c);
      // Only a slot that is at least as clear as the best so far pays for
      // its leader check (the tier orders equal-primary slots).
      if (total > bestCost) return;
      final lead = leaderCost(c);
      if (total < bestCost || lead < bestLeader) {
        bestCost = total;
        bestLeader = lead;
        best = c;
      }
      if (total <= 0 && lead <= 0) cleared = true;
    }

    for (final c in candidates) {
      consider(c);
      if (cleared) break;
    }
    // No ladder slot cleared → escape vertically (down then up, growing) from
    // the least-bad column until a clear slot appears.
    //
    // Round 20 (drafting-visual-4-2) — each step also tries the tag CENTRED
    // over its anchor, so its leader leaves the run square (perpendicular)
    // instead of running back along the pipe to a slot beside it.
    if (!cleared) {
      final baseDx = best.dx;
      final centredDx =
          (anchorX - defaultX) - _labelWidth(text, size) / 2;
      for (var k = 1; k <= _kEscapeSteps && !cleared; k++) {
        for (final dx in [baseDx, centredDx]) {
          for (final dy in [_kEscapeStep * k, -_kEscapeStep * k]) {
            consider(Offset(dx, dy));
            if (cleared) break;
          }
          if (cleared) break;
        }
      }
    }
    // Round 15 — still on ink or another tag: widen SIDEWAYS (right, then
    // left, growing), at the default row and a few rows either side.
    if (!cleared) {
      final w = _labelWidth(text, size);
      for (var k = 1; k <= _kSideEscapeSteps && !cleared; k++) {
        for (final dx in [_kSideEscapeStep * k, -_kSideEscapeStep * k - w]) {
          for (final dy in const [0.0, _kEscapeStep, -_kEscapeStep,
              2 * _kEscapeStep, -2 * _kEscapeStep]) {
            consider(Offset(dx, dy));
            if (cleared) break;
          }
          if (cleared) break;
        }
      }
    }
    final lx = defaultX + best.dx;
    final ly = defaultY + best.dy;
    final rect = _rectFor(lx, ly, text, size);
    _labels.add(rect);
    // A tag pulled well off its default anchor — or one that could not be fully
    // cleared — gets a leader so its element stays legible / unfused.
    if (!cleared || needsLeader(best)) {
      final (ex, ey) = _leaderEnd(rect, anchorX, anchorY);
      if (ex != anchorX || ey != anchorY) {
        prims.add(SldLine(anchorX, anchorY, ex, ey,
            weight: SldWeight.thin, role: role));
        _leaders.add((anchorX, anchorY, ex, ey));
      }
    }
    prims.add(SldLabel(lx, ly, text, size: size, bold: bold, role: role));
  }
}

/// Round 15 — where a leader from ([ax], [ay]) lands on label box [r]: the
/// NEAREST point of the box (the anchor clamped into it). The box is convex,
/// so the leader never crosses its own text. X1's near-end rule falls out:
/// an anchor beside the tag lands on that end.
(double, double) _leaderEnd(_LabelRect r, double ax, double ay) =>
    (ax.clamp(r.minX, r.maxX).toDouble(), ay.clamp(r.minY, r.maxY).toDouble());

/// Round 15 — does segment (x1,y1)-(x2,y2) pass through the open interior of
/// [r] (Liang–Barsky; touching an edge does not count)?
/// Round 20 — the LENGTH of segment (x1, y1)-(x2, y2) inside [r] (0 when it
/// misses), by the same Liang–Barsky clip as [_segmentHitsRect] (no inset).
double _segmentClipLength(
    double x1, double y1, double x2, double y2, _LabelRect r) {
  var t0 = 0.0, t1 = 1.0;
  final dx = x2 - x1, dy = y2 - y1;
  for (final (p, q) in [
    (-dx, x1 - r.minX),
    (dx, r.maxX - x1),
    (-dy, y1 - r.minY),
    (dy, r.maxY - y1),
  ]) {
    if (p == 0) {
      if (q < 0) return 0;
    } else {
      final t = q / p;
      if (p < 0) {
        if (t > t1) return 0;
        if (t > t0) t0 = t;
      } else {
        if (t < t0) return 0;
        if (t < t1) t1 = t;
      }
    }
  }
  if (t0 >= t1) return 0;
  return (t1 - t0) * math.sqrt(dx * dx + dy * dy);
}

bool _segmentHitsRect(
    double x1, double y1, double x2, double y2, _LabelRect r) {
  const inset = 0.5;
  final minX = r.minX + inset, maxX = r.maxX - inset;
  final minY = r.minY + inset, maxY = r.maxY - inset;
  if (minX >= maxX || minY >= maxY) return false;
  var t0 = 0.0, t1 = 1.0;
  final dx = x2 - x1, dy = y2 - y1;
  for (final (p, q) in [
    (-dx, x1 - minX),
    (dx, maxX - x1),
    (-dy, y1 - minY),
    (dy, maxY - y1),
  ]) {
    if (p == 0) {
      if (q < 0) return false;
    } else {
      final t = q / p;
      if (p < 0) {
        if (t > t1) return false;
        if (t > t0) t0 = t;
      } else {
        if (t < t0) return false;
        if (t < t1) t1 = t;
      }
    }
  }
  return t0 < t1;
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
