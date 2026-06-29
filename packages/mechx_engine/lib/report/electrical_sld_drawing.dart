/// Shared, pure (Flutter-free) geometry for a PROFESSIONAL electrical
/// single-line drawing — the drafter-grade content rendered identically by the
/// PDF (`electrical_pdf_export.dart`) and DXF (`electrical_dxf_export.dart`)
/// exporters. The electrical analogue of the mechanical single-line's drafter
/// chrome: instead of an anonymous box per panel, every panel is drawn as a real
/// distribution-board single-line — incomer breaker → busbar → one ROW per
/// outgoing way carrying its breaker (rating / poles / curve), cable
/// (family + cores × CSA), load name, phase and design current Ib, with feeders
/// routed down a right-hand channel to the sub-panel they supply.
///
/// The builder emits primitives in a single y-DOWN "drawing space"; each format
/// fits/flips them into its own page. Keeping ONE geometry here guarantees the
/// PDF and DXF agree and lets the layout be unit-tested without any output
/// encoding. Zero Flutter imports.
library;

import 'dart:math' as math;

import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import '../electrical/results.dart' show BreakerResult;
import '../electrical/sources.dart'
    show GeneratorModeInfo, selectGeneratorKva;
import '../geometry/building.dart' show BuildingLevels, MountingHeights;
import '../standards/puil.dart' show BreakerCurve, BreakerClass;
import '../units.dart' show ApparentPower;

/// Stroke weight buckets (mapped to real widths by each renderer).
enum SldWeight { thin, medium, thick }

/// Drafting role of a primitive — drives its COLOUR (mirroring the reference
/// drawings' cyan-normal / red-essential split). `source` is the utility / MV /
/// transformer supply chain.
enum SldRole { normal, essential, source }

/// A drawing primitive in y-down drawing space. Sealed so renderers switch
/// exhaustively over the small closed set.
sealed class SldPrim {
  const SldPrim();
}

class SldLine extends SldPrim {
  final double x1, y1, x2, y2;
  final SldWeight weight;
  final SldRole role;
  const SldLine(this.x1, this.y1, this.x2, this.y2,
      {this.weight = SldWeight.thin, this.role = SldRole.normal});
}

class SldRect extends SldPrim {
  final double x, y, w, h;
  final SldWeight weight;
  final SldRole role;
  const SldRect(this.x, this.y, this.w, this.h,
      {this.weight = SldWeight.medium, this.role = SldRole.normal});
}

class SldLabel extends SldPrim {
  final double x, y;
  final String text;
  final double size;
  final bool bold;
  final SldRole role;
  const SldLabel(this.x, this.y, this.text,
      {this.size = 9, this.bold = false, this.role = SldRole.normal});
}

/// One row of the drawing's device legend (symbol meaning).
class SldLegendEntry {
  final String code;
  final String meaning;
  const SldLegendEntry(this.code, this.meaning);
}

/// The assembled single-line: drawing-space primitives + bounds + a device
/// legend for the sheet frame (rendered page-fixed by each format).
class SldSheet {
  final List<SldPrim> prims;
  final double minX, minY, maxX, maxY;
  final List<SldLegendEntry> legend;

  /// Title-block facts (the project name + supply summary line), stamped by the
  /// renderer in page space.
  final String supplyNote;

  const SldSheet({
    required this.prims,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    required this.legend,
    required this.supplyNote,
  });

  bool get isEmpty => prims.isEmpty;
}

// ── Block geometry (drawing units) ───────────────────────────────────────────
const double _blockW = 720;
const double _headerH = 46;
const double _rowH = 20;
const double _bodyPad = 12;
const double _gapY = 46;
const double _indent = 64; // per feeder-depth level
const double _busX = 44; // bus offset inside a block
const double _brW = 15; // breaker symbol
const double _brH = 10;

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// A connected-load (DAYA) figure: `W` under 1 kW, else `kW`.
String _watts(double w) =>
    w >= 1000 ? '${_num(w / 1000)}kW' : '${_num(w)}W';

String _curveCode(BreakerCurve c) => switch (c) {
      BreakerCurve.b => 'B',
      BreakerCurve.c => 'C',
      BreakerCurve.d => 'D',
    };

String _classCode(BreakerClass c) =>
    c == BreakerClass.mccb ? 'MCCB' : 'MCB';

/// A breaker label like `MCB C16A/1P` — the curve-led form (kept for the
/// incomer sub-line + the device legend so the trip curve stays surfaced).
String breakerLabel(BreakerResult b, int poles) =>
    '${_classCode(b.deviceClass)} ${_curveCode(b.curve)}'
    '${_num(b.ratingA.amperes)}A/${poles}P';

/// A panel-SCHEDULE breaker label leading with rating + phase count, e.g.
/// `MCB 16A 1ph` / `MCCB 40A 3ph` — the real Indonesian DIAGRAM PANEL form
/// (rating + phase first; the trip curve is secondary, surfaced via the incomer
/// sub-line + legend). `poles` is the way's pole count (1 or 3). ASCII-safe
/// (`ph`, not the unicode phase glyph) so it never renders as tofu.
String breakerScheduleLabel(BreakerResult b, int poles) =>
    '${_classCode(b.deviceClass)} ${_num(b.ratingA.amperes)}A ${poles}ph';

/// A cable label like `NYM 3x2.5` (family from the circuit when set, else a
/// neutral `Cu`; cores = 3 for 1-phase L+N+E, 5 for 3-phase 3L+N+E).
String cableLabel(ElectricalCircuit? circuit, double csaMm2, bool threePhase) {
  final family = (circuit?.cableType != null && circuit!.cableType!.isNotEmpty)
      ? circuit.cableType!
      : 'Cu';
  final cores = threePhase ? 5 : 3;
  return '$family ${cores}x${_num(csaMm2)}';
}

/// Build the professional single-line for [project] / [result]. Pure geometry.
SldSheet buildElectricalSld({
  required ElectricalProject project,
  required ElectricalSystemResult result,
}) {
  final modelById = {for (final p in project.panels) p.id: p};
  final circuitById = <String, ElectricalCircuit>{
    for (final p in project.panels)
      for (final c in p.circuits) c.id: c,
  };

  // Feeder depth: a panel's depth = its parent's depth + 1 (root = 0). Parent =
  // the panel whose circuit feeds it; root-first [order] guarantees parents are
  // seen first, so a single forward pass suffices.
  final parentOf = <String, String>{};
  for (final parent in project.panels) {
    for (final c in parent.circuits) {
      final child = c.feedsPanelId;
      if (child != null) parentOf[child] = parent.id;
    }
  }
  final depth = <String, int>{};
  for (final id in result.order) {
    final p = parentOf[id];
    depth[id] = p == null ? 0 : (depth[p] ?? 0) + 1;
  }

  final prims = <SldPrim>[];
  final usedCurves = <BreakerCurve>{};
  final usedClasses = <BreakerClass>{};
  final usedFamilies = <String>{};

  // Lay panels top-to-bottom (root-first), indented by depth. Record each box +
  // each way's anchor so feeders can be routed afterward.
  final boxTop = <String, ({double x, double y})>{};
  final boxBottom = <String, double>{};
  // way feeder anchors: childPanelId -> (right edge x, row y) of the feeding way.
  final feederFrom = <String, ({double x, double y})>{};

  var cursorY = 0.0;
  for (final id in result.order) {
    final p = result.panels[id];
    if (p == null) continue;
    final model = modelById[id];
    final ways = p.circuits.length;
    // Reserved spare ways (CADANGAN) draw as extra schedule rows below the real
    // ways; a footer row carries the panel TOTAL. Both extend the block height
    // so the busbar + rows stay inside the box. 0 reserved + no footer growth ⇒
    // geometry is byte-identical to the pre-enrichment block.
    final spareWays = p.spareWaysReserved;
    final scheduleRows = math.max(1, ways) + spareWays;
    const footerH = _rowH; // the TOTAL footer line
    final blockX = (depth[id] ?? 0) * _indent;
    final blockY = cursorY;
    final blockH = _headerH + scheduleRows * _rowH + footerH + _bodyPad;
    boxTop[id] = (x: blockX, y: blockY);
    boxBottom[id] = blockY + blockH;

    // Outer block.
    prims.add(SldRect(blockX, blockY, _blockW, blockH));

    // Header: name [tag] + the incomer / system / bus sub-line. The bus make-up
    // reads "Cu bus <csa>mm2" + (when the withstand fold ran) " Icw <kA>kA".
    final tag = (p.tag != null && p.tag!.isNotEmpty) ? '  [${p.tag}]' : '';
    prims.add(SldLabel(blockX + 8, blockY + 16, '${p.name}$tag',
        size: 13, bold: true));
    final v = model?.voltage.volts ?? (p.system.isThreePhase ? 400 : 230);
    final icw = p.busbar.withstand != null
        ? '  Icw ${_num(p.busbar.withstand!.icwKa)}kA'
        : '';
    prims.add(SldLabel(
        blockX + 8,
        blockY + 32,
        'Incomer ${breakerLabel(p.incomer.breaker, p.incomer.poles)}  '
        '${p.system.label}  ${_num(v)}V  '
        'Cu bus ${_num(p.busbar.csaMm2)}mm2$icw  '
        'demand ${_num(p.demandCurrent.amperes)}A',
        size: 8));
    usedCurves.add(p.incomer.breaker.curve);
    usedClasses.add(p.incomer.breaker.deviceClass);

    // Header / body divider (full width) for a clean schedule look.
    final busTop = blockY + _headerH;
    prims.add(SldLine(blockX, busTop, blockX + _blockW, busTop));
    // Busbar (two parallel verticals so it reads as a bar). The bar runs the
    // full schedule height (real + spare ways), stopping above the TOTAL footer.
    final busBot = busTop + scheduleRows * _rowH + 6;
    final bx = blockX + _busX;
    prims.add(SldLine(bx, busTop, bx, busBot, weight: SldWeight.thick));
    prims.add(SldLine(bx + 4, busTop, bx + 4, busBot, weight: SldWeight.thick));
    // Incomer breaker straddling the divider at the bus top (the topmost device
    // on the bus; named verbatim by the header sub-line "Incomer ...").
    prims.add(SldRect(bx + 2 - _brW / 2, busTop - _brH / 2, _brW, _brH));

    // One row per way: schedule breaker (rating + phase first), cable (family +
    // cores x CSA + a separate earth when the way carries one) + load name +
    // phase + Ib + the connected DAYA (W/kW) + the feeder destination / VD flag.
    for (var i = 0; i < ways; i++) {
      final c = p.circuits[i];
      final rowY = busTop + 6 + i * _rowH + _rowH / 2;
      // Stub from bus to breaker.
      prims.add(SldLine(bx + 4, rowY, bx + 28, rowY));
      // Breaker symbol.
      prims.add(SldRect(bx + 28, rowY - _brH / 2, _brW, _brH));
      usedCurves.add(c.breaker.curve);
      usedClasses.add(c.breaker.deviceClass);
      final circuit = circuitById[c.circuitId];
      if (circuit?.cableType != null && circuit!.cableType!.isNotEmpty) {
        usedFamilies.add(circuit.cableType!);
      }
      final poles = c.threePhase ? 3 : 1;
      final wayNo = 'W${i + 1}';
      final feeds = circuit?.feedsPanelId;
      final dest = feeds != null
          ? '  ->  ${result.panels[feeds]?.name ?? feeds}'
          : '';
      final vd = c.voltageDrop.withinLimit ? '' : '  VD!';
      // Cable with the mm2 unit + a separate-earth token (BRI "NYY 4x50 + E25")
      // when the way's PE conductor CSA is known. No conduit data on the model,
      // so no conduit token is invented.
      final earth = c.grounding.peCsaMm2 > 0
          ? ' + E${_num(c.grounding.peCsaMm2)} mm2'
          : '';
      final cable =
          '${cableLabel(circuit, c.cable.csaMm2, c.threePhase)} mm2$earth';
      final daya = c.loadW > 0 ? '  ${_watts(c.loadW)}' : '';
      final txt = '$wayNo  ${breakerScheduleLabel(c.breaker, poles)}  '
          '$cable  ${c.name}  ${c.phase.label}  '
          'Ib ${_num(c.designCurrent.amperes)}A$daya$dest$vd';
      prims.add(SldLabel(bx + 50, rowY + 3, txt, size: 8.5));

      if (feeds != null) {
        feederFrom[feeds] = (x: blockX + _blockW, y: rowY);
      }
    }

    // CADANGAN (spare) ways — a stub + a labelled empty schedule row each.
    for (var s = 0; s < spareWays; s++) {
      final rowY = busTop + 6 + (ways + s) * _rowH + _rowH / 2;
      prims.add(SldLine(bx + 4, rowY, bx + 28, rowY));
      prims.add(SldLabel(bx + 50, rowY + 3, 'W${ways + s + 1}  CADANGAN (spare)',
          size: 8.5));
    }

    // TOTAL footer — the panel's diversified demand (W/kW + line current).
    final footerY = busBot + _rowH / 2 + 3;
    prims.add(SldLabel(blockX + 8, footerY,
        'TOTAL  ${_watts(p.demandW)} / ${_num(p.demandCurrent.amperes)}A',
        size: 8.5, bold: true));

    cursorY = blockY + blockH + _gapY;
  }

  // ── Bounds over the blocks (before the right-hand feeder channel) ───────────
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final t in boxTop.values) {
    minX = math.min(minX, t.x);
    minY = math.min(minY, t.y);
    maxX = math.max(maxX, t.x + _blockW);
  }
  for (final b in boxBottom.values) {
    maxY = math.max(maxY, b);
  }
  if (!minX.isFinite) {
    minX = 0;
    minY = 0;
    maxX = 1;
    maxY = 1;
  }

  // Feeders: route from the feeding way's right edge down a vertical channel to
  // the LEFT edge of the sub-panel block (orthogonal, riser-duct style).
  final channelX = maxX + 30;
  for (final entry in feederFrom.entries) {
    final child = entry.key;
    final from = entry.value;
    final dst = boxTop[child];
    if (dst == null) continue;
    final dropY = dst.y + 18; // enter a touch below the child header top
    // way right -> channel; channel down; channel -> child left.
    prims.add(SldLine(from.x, from.y, channelX, from.y, weight: SldWeight.medium));
    prims.add(SldLine(channelX, from.y, channelX, dropY, weight: SldWeight.medium));
    prims.add(SldLine(channelX, dropY, dst.x, dropY, weight: SldWeight.medium));
  }
  maxX = math.max(maxX, channelX);

  // ── Device legend (KETERANGAN) entries for the symbols actually used ────────
  final legend = <SldLegendEntry>[];
  if (usedClasses.contains(BreakerClass.mcb)) {
    legend.add(const SldLegendEntry('MCB', 'Miniature circuit breaker'));
  }
  if (usedClasses.contains(BreakerClass.mccb)) {
    legend.add(const SldLegendEntry('MCCB', 'Moulded-case circuit breaker'));
  }
  for (final cv in [BreakerCurve.b, BreakerCurve.c, BreakerCurve.d]) {
    if (usedCurves.contains(cv)) {
      legend.add(SldLegendEntry('Curve ${_curveCode(cv)}', switch (cv) {
        BreakerCurve.b => 'Resistive / lighting trip',
        BreakerCurve.c => 'General / mixed trip',
        BreakerCurve.d => 'Motor / high-inrush trip',
      }));
    }
  }
  for (final f in usedFamilies.toList()..sort()) {
    legend.add(SldLegendEntry(f, 'Cable construction'));
  }
  legend.add(const SldLegendEntry('Ib', 'Design (load) current'));
  legend.add(const SldLegendEntry('VD!', 'Voltage drop over limit'));

  final s = result.supply;
  final supplyNote =
      '${s.system.label}  ${_num(s.voltage.volts)}V  '
      'demand ${_num(s.demandW / 1000)}kW / ${_num(s.demandVa.inKilovoltAmperes)}kVA';

  return SldSheet(
    prims: prims,
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
    legend: legend,
    supplyNote: supplyNote,
  );
}

// ── ZOOMED-OUT building single-line (the whole distribution hierarchy) ───────

/// Compact-node geometry for the overview / riser.
const double _ovW = 168;
const double _ovH = 46;
const double _ovHGap = 26;
const double _ovTierH = 120;

/// Parent-of map over the feeder graph (childPanelId -> parentPanelId), limited
/// to children that have a result. Shared by the overview + riser layouts.
Map<String, String> _parentOf(
    ElectricalProject project, ElectricalSystemResult result) {
  final parentOf = <String, String>{};
  for (final parent in project.panels) {
    for (final c in parent.circuits) {
      final child = c.feedsPanelId;
      if (child != null && result.panels.containsKey(child)) {
        parentOf[child] = parent.id;
      }
    }
  }
  return parentOf;
}

/// The set of ESSENTIAL panel ids — a panel is essential when its name marks it
/// emergency (EMERGENCY / ESSENTIAL / DARURAT), when it carries a life-safety
/// way, or when its parent is essential (the property propagates DOWN the
/// emergency sub-tree). Shared by the overview + riser so their colour split is
/// derived identically. `result.order` is root-first ⇒ a parent is decided
/// before its children.
Set<String> _essentialIds(
    ElectricalProject project, ElectricalSystemResult result) {
  final modelById = {for (final p in project.panels) p.id: p};
  final parentOf = _parentOf(project, result);

  // A panel is ESSENTIAL (red, emergency SUPPLY) when it is on the genset-backed
  // bus — its explicit `essential` flag — or its name marks it emergency. A
  // single life-safety WAY (e.g. a fire-pump feeder) on an otherwise-normal
  // board does NOT make the whole board essential (that would wrongly paint a
  // main board + all its sub-boards red); the emergency-supply flag is the cue.
  bool ownEssential(ElectricalPanelResult p) {
    final n = p.name.toUpperCase();
    if (n.contains('EMERGENCY') ||
        n.contains('ESSENTIAL') ||
        n.contains('DARURAT')) {
      return true;
    }
    return modelById[p.panelId]?.essential ?? false;
  }

  final essential = <String>{};
  for (final id in result.order) {
    final p = result.panels[id];
    if (p == null) continue;
    final par = parentOf[id];
    if ((par != null && essential.contains(par)) || ownEssential(p)) {
      essential.add(id);
    }
  }
  return essential;
}

/// Synthesize the utility source spine drawn ABOVE the panel tree (overview) or
/// the top floor band (riser): PLN MV STATION -> (MV main, when a dual-tx /
/// sources project) -> TRANSFORMER <kVA> -> PANEL UTAMA TEGANGAN RENDAH (LV
/// main), with an optional GENSET UNIT + CAPACITOR BANK hanging off the LV bus.
/// All nodes are `SldRole.source`. Returns the prims, the spine HEIGHT (to push
/// the tree/floors down by), and the feed anchor (the LV-main bus bottom-centre)
/// the roots connect up to.
///
/// Sizing is DERIVED from existing sizers only (no invented physics): the
/// transformer + genset kVA snap to the genset ladder (`selectGeneratorKva`)
/// against the building demand VA — all `// VERIFY`.
({List<SldPrim> prims, double height, double feedX, double feedY})
    _buildSourceSpine(
  ElectricalProject project,
  ElectricalSystemResult result,
  double centreX,
) {
  final prims = <SldPrim>[];
  final nodeX = centreX - _ovW / 2;
  final demandVa = result.supply.demandVa;

  // Whole-spine kVA: the smallest standard rating covering the building demand
  // VA (genset ladder, // VERIFY). Blank when there is no demand.
  final txKva = demandVa.inKilovoltAmperes > 0
      ? selectGeneratorKva(demandVa).inKilovoltAmperes
      : 0.0;
  final txLabel = txKva > 0 ? 'TRANSFORMER ${_num(txKva)} kVA' : 'TRANSFORMER';

  // The vertical spine, top -> bottom. MV main is drawn only for a dual-tx /
  // sources project (else the PLN node feeds the LV main directly).
  final hasMv = project.dualTransformer || project.sources != null;
  final spine = <({String name, String? sub})>[
    (name: 'PLN MV STATION', sub: null),
    if (hasMv) (name: 'PANEL UTAMA TEGANGAN MENENGAH', sub: 'MV main'),
    (name: txLabel, sub: null),
    (name: 'PANEL UTAMA TEGANGAN RENDAH', sub: 'LV main'),
  ];

  var y = 0.0;
  double? prevCx, prevBottom;
  for (final node in spine) {
    prims.add(SldRect(nodeX, y, _ovW, _ovH, role: SldRole.source));
    prims.add(SldLabel(nodeX + 7, y + 17, node.name,
        size: node.name.length > 22 ? 8 : 9.5,
        bold: true,
        role: SldRole.source));
    if (node.sub != null) {
      prims.add(SldLabel(nodeX + 7, y + 33, node.sub!,
          size: 7.5, role: SldRole.source));
    }
    // Vertical connector from the previous node's bottom into this one's top.
    if (prevCx != null && prevBottom != null) {
      prims.add(SldLine(prevCx, prevBottom, centreX, y,
          weight: SldWeight.medium, role: SldRole.source));
    }
    prevCx = centreX;
    prevBottom = y + _ovH;
    y += _ovH + _ovHGap;
  }
  final lvBottom = y - _ovHGap; // bottom of the LV-main node

  // GENSET + CAPACITOR BANK hang off the LV-main bus to the right.
  final lvMidY = lvBottom - _ovH / 2;
  final sideX = nodeX + _ovW + 60;
  if (project.sources?.generator != null) {
    final gen = project.sources!.generator!;
    final backupVa = ApparentPower(demandVa.voltAmperes * gen.backupFraction);
    final genKva = (gen.kva ?? selectGeneratorKva(backupVa)).inKilovoltAmperes;
    final gy = lvMidY - _ovH - 8;
    prims.add(SldRect(sideX, gy, _ovW, _ovH, role: SldRole.source));
    prims.add(SldLabel(sideX + 7, gy + 17, 'GENSET UNIT ${_num(genKva)} kVA',
        size: 8.5, bold: true, role: SldRole.source));
    prims.add(SldLabel(sideX + 7, gy + 33, gen.mode.label,
        size: 7.5, role: SldRole.source));
    prims.add(SldLine(nodeX + _ovW, gy + _ovH / 2, sideX, gy + _ovH / 2,
        weight: SldWeight.medium, role: SldRole.source));
  }
  if (project.sources != null) {
    final cy = lvMidY + 8;
    prims.add(SldRect(sideX, cy, _ovW, _ovH, role: SldRole.source));
    prims.add(SldLabel(sideX + 7, cy + 17, 'CAPACITOR BANK',
        size: 8.5, bold: true, role: SldRole.source));
    prims.add(SldLabel(sideX + 7, cy + 33, 'PF correction',
        size: 7.5, role: SldRole.source));
    prims.add(SldLine(nodeX + _ovW, cy + _ovH / 2, sideX, cy + _ovH / 2,
        weight: SldWeight.medium, role: SldRole.source));
  }

  return (prims: prims, height: lvBottom, feedX: centreX, feedY: lvBottom);
}

/// Build the ZOOMED-OUT building single-line: every panel as a COMPACT node
/// (name + incomer rating + demand), tiered top-down by feeder depth and wired
/// parent→child, with the normal / essential colour split of a real riser
/// single-line. The detail (per-way breakers/cables) lives in
/// [buildElectricalSld]; this is the overview companion.
///
/// A panel is ESSENTIAL (drawn red) when its name marks it emergency, when it
/// carries a life-safety way, or when its parent is essential (the property
/// propagates down the emergency sub-tree).
///
/// When [sourceChain] is true, a PLN MV -> (MV main) -> TRANSFORMER -> LV main
/// source spine (+ optional GENSET / CAPACITOR BANK) is PREPENDED above the
/// panel tree (all `SldRole.source`) and the LV main feeds each root. Default
/// false ⇒ the overview is byte-identical to before.
SldSheet buildElectricalOverview({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  bool sourceChain = false,
}) {
  // children map over the feeder graph; parent + essential via shared helpers.
  final parentOf = _parentOf(project, result);
  final children = <String, List<String>>{};
  for (final entry in parentOf.entries) {
    (children[entry.value] ??= []).add(entry.key);
  }
  // Preserve result.order within each parent's child list (was insertion order
  // over the feeder graph; root-first order is a faithful proxy).
  final essential = _essentialIds(project, result);

  // ── Tree layout: x by leaf order (in-order), y by depth ─────────────────────
  final depth = <String, int>{};
  for (final id in result.order) {
    final par = parentOf[id];
    depth[id] = par == null ? 0 : (depth[par] ?? 0) + 1;
  }
  final roots = [
    for (final id in result.order) if (!parentOf.containsKey(id)) id
  ];
  final cx = <String, double>{};
  var nextLeafX = 0.0;
  const pitch = _ovW + _ovHGap;

  void place(String id) {
    final kids = children[id] ?? const [];
    if (kids.isEmpty) {
      cx[id] = nextLeafX;
      nextLeafX += pitch;
      return;
    }
    for (final k in kids) {
      place(k);
    }
    cx[id] = (cx[kids.first]! + cx[kids.last]!) / 2; // centre over children
  }

  for (final r in roots) {
    place(r);
  }

  final prims = <SldPrim>[];

  // ── Optional source spine, prepended above the tree ─────────────────────────
  var sourceOffsetY = 0.0;
  ({List<SldPrim> prims, double height, double feedX, double feedY})? spine;
  if (sourceChain) {
    // Centre the spine over the placed-tree x-extent (fall back to the node
    // width when empty).
    var cMinX = double.infinity, cMaxX = -double.infinity;
    for (final x in cx.values) {
      cMinX = math.min(cMinX, x);
      cMaxX = math.max(cMaxX, x + _ovW);
    }
    if (!cMinX.isFinite) {
      cMinX = 0;
      cMaxX = _ovW;
    }
    final centreX = (cMinX + cMaxX) / 2;
    spine = _buildSourceSpine(project, result, centreX);
    sourceOffsetY = spine.height + _ovTierH; // push the tree below the LV main
    prims.addAll(spine.prims);
  }

  double nodeY(String id) => (depth[id] ?? 0) * _ovTierH + sourceOffsetY;

  // Source -> each root: drop from the LV-main bus bottom into the root top.
  if (spine != null) {
    for (final r in roots) {
      if (!cx.containsKey(r)) continue;
      final zx = cx[r]! + _ovW / 2;
      final zy = nodeY(r);
      final role = essential.contains(r) ? SldRole.essential : SldRole.source;
      final midY = (spine.feedY + zy) / 2;
      prims.add(SldLine(spine.feedX, spine.feedY, spine.feedX, midY,
          weight: SldWeight.medium, role: SldRole.source));
      prims.add(SldLine(spine.feedX, midY, zx, midY,
          weight: SldWeight.medium, role: role));
      prims.add(SldLine(zx, midY, zx, zy, weight: SldWeight.medium, role: role));
    }
  }

  // Feeders parent→child: drop from parent bottom, orthogonal, into child top.
  for (final entry in children.entries) {
    final ax = cx[entry.key]! + _ovW / 2;
    final ay = nodeY(entry.key) + _ovH;
    for (final child in entry.value) {
      if (!cx.containsKey(child)) continue;
      final zx = cx[child]! + _ovW / 2;
      final zy = nodeY(child);
      final role =
          essential.contains(child) ? SldRole.essential : SldRole.normal;
      final midY = (ay + zy) / 2;
      prims.add(SldLine(ax, ay, ax, midY, weight: SldWeight.medium, role: role));
      prims.add(SldLine(ax, midY, zx, midY, weight: SldWeight.medium, role: role));
      prims.add(SldLine(zx, midY, zx, zy, weight: SldWeight.medium, role: role));
    }
  }

  // Compact panel nodes.
  for (final id in result.order) {
    final p = result.panels[id];
    if (p == null || !cx.containsKey(id)) continue;
    final x = cx[id]!;
    final y = nodeY(id);
    final role = essential.contains(id) ? SldRole.essential : SldRole.normal;
    prims.add(SldRect(x, y, _ovW, _ovH, role: role));
    final tag = (p.tag != null && p.tag!.isNotEmpty) ? '  [${p.tag}]' : '';
    prims.add(SldLabel(x + 7, y + 17, '${p.name}$tag',
        size: 10, bold: true, role: role));
    prims.add(SldLabel(
        x + 7,
        y + 33,
        '${_num(p.incomer.breaker.ratingA.amperes)}A ${p.incomer.poles}P  '
        '${_num(p.demandW / 1000)}kW',
        size: 7.5,
        role: role));
  }

  // ── Bounds ─────────────────────────────────────────────────────────────────
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final id in result.order) {
    if (!cx.containsKey(id)) continue;
    final x = cx[id]!;
    final y = nodeY(id);
    minX = math.min(minX, x);
    minY = math.min(minY, y);
    maxX = math.max(maxX, x + _ovW);
    maxY = math.max(maxY, y + _ovH);
  }
  // Expand the bounds over the prepended source spine (it sits above + may
  // extend right via the GENSET / CAPACITOR side nodes).
  if (spine != null) {
    for (final pr in spine.prims) {
      switch (pr) {
        case SldRect():
          minX = math.min(minX, pr.x);
          minY = math.min(minY, pr.y);
          maxX = math.max(maxX, pr.x + pr.w);
          maxY = math.max(maxY, pr.y + pr.h);
        case SldLine():
          minX = math.min(minX, math.min(pr.x1, pr.x2));
          minY = math.min(minY, math.min(pr.y1, pr.y2));
          maxX = math.max(maxX, math.max(pr.x1, pr.x2));
          maxY = math.max(maxY, math.max(pr.y1, pr.y2));
        case SldLabel():
          minX = math.min(minX, pr.x);
          minY = math.min(minY, pr.y);
      }
    }
  }
  if (!minX.isFinite) {
    minX = 0;
    minY = 0;
    maxX = 1;
    maxY = 1;
  }

  final s = result.supply;
  final supplyNote = '${s.system.label}  ${_num(s.voltage.volts)}V  '
      'demand ${_num(s.demandW / 1000)}kW / '
      '${_num(s.demandVa.inKilovoltAmperes)}kVA';

  return SldSheet(
    prims: prims,
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
    legend: [
      const SldLegendEntry('Normal', 'Normal supply'),
      const SldLegendEntry('Essential', 'Essential / emergency supply'),
      if (sourceChain) const SldLegendEntry('Source', 'Utility / MV supply chain'),
    ],
    supplyNote: supplyNote,
  );
}

// ── FLOOR-BY-FLOOR electrical riser (panels by building level) ───────────────

/// Gutter + band geometry for the riser.
const double _riserGutterW = 150;
const double _riserBandH = 130;
const double _riserPanelGap = 24;

/// Format a true elevation (m) as an FFL tag like `+12.50` / `-3.00`.
String _ffl(double meters) {
  final s = meters.abs().toStringAsFixed(2);
  return meters < 0 ? '-$s' : '+$s';
}

/// Build the FLOOR-BY-FLOOR electrical riser: every panel placed on its building
/// FLOOR (by true elevation — highest floor at the TOP of the y-down sheet),
/// laid left-to-right within its floor band; feeders draw as a vertical riser in
/// a right-hand channel + horizontal branches into each panel; a left GUTTER
/// column carries each floor's name + FFL elevation and a hairline grid line.
///
/// Floor assignment precedence: (1) `panel.layoutPos.floorIndex` when set and in
/// range; (2) ELSE feeder-depth tier (root at the highest tier); (3) clamp any
/// out-of-range index. When [building] is null / has no levels it degrades to
/// pure feeder-depth TIERS (gutter shows `Tier n`, no elevation) — never throws.
///
/// When [sourceChain] is true a PLN/MV/transformer/LV-main source spine is
/// prepended ABOVE the top floor band. [mounting] is accepted for signature
/// parity with the mechanical riser; it is unused here.
SldSheet buildElectricalRiser({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  BuildingLevels? building,
  MountingHeights mounting = const MountingHeights(),
  bool sourceChain = false,
}) {
  final parentOf = _parentOf(project, result);
  final essential = _essentialIds(project, result);
  final panelModelById = {for (final p in project.panels) p.id: p};

  // Feeder depth per panel (root = 0). result.order is root-first.
  final depth = <String, int>{};
  for (final id in result.order) {
    final par = parentOf[id];
    depth[id] = par == null ? 0 : (depth[par] ?? 0) + 1;
  }
  final maxDepth =
      depth.values.isEmpty ? 0 : depth.values.reduce(math.max);

  final hasFloors = building != null && building.levelCount > 0;
  final levelCount = hasFloors ? building.levelCount : (maxDepth + 1);

  // Floor index per panel (0 = lowest). With real floors: the panel's
  // layoutPos.floorIndex (clamped), else a depth-derived tier (root highest).
  // In tier mode: the depth tier itself, root at the top band.
  int floorOf(String id) {
    if (hasFloors) {
      final lp = panelModelById[id]?.layoutPos;
      if (lp != null) {
        return lp.floorIndex.clamp(0, levelCount - 1);
      }
      // Unplaced ⇒ a depth tier, root at the TOP floor, descending by depth.
      final d = depth[id] ?? 0;
      return (levelCount - 1 - d).clamp(0, levelCount - 1);
    }
    // No floors ⇒ tier mode: root (depth 0) at the top band (highest index).
    final d = depth[id] ?? 0;
    return (levelCount - 1 - d).clamp(0, levelCount - 1);
  }

  // Elevation→y: the highest floor maps to the smallest y. With a degenerate
  // (zero-span) building use a fixed band height so we never divide by zero.
  final topIndex = levelCount - 1;
  double bandY(int floorIndex) =>
      (topIndex - floorIndex) * _riserBandH;

  // ── Optional source spine above the top band ────────────────────────────────
  final prims = <SldPrim>[];
  var contentOffsetY = 0.0;
  ({List<SldPrim> prims, double height, double feedX, double feedY})? spine;
  if (sourceChain) {
    spine = _buildSourceSpine(project, result, _riserGutterW + 2 * _ovW);
    contentOffsetY = spine.height + _ovTierH;
    prims.addAll(spine.prims);
  }

  // ── Place panels left-to-right within their floor band ──────────────────────
  // Group by floor, ordered by result.order (root-first) for stable packing.
  final byFloor = <int, List<String>>{};
  for (final id in result.order) {
    if (!result.panels.containsKey(id)) continue;
    (byFloor[floorOf(id)] ??= []).add(id);
  }

  final panelX = <String, double>{};
  final panelY = <String, double>{};
  const panelPitch = _ovW + _riserPanelGap;
  var sheetMaxX = _riserGutterW + _ovW;
  for (final entry in byFloor.entries) {
    final y = bandY(entry.key) + contentOffsetY;
    var x = _riserGutterW + _riserPanelGap;
    for (final id in entry.value) {
      panelX[id] = x;
      panelY[id] = y;
      x += panelPitch;
    }
    sheetMaxX = math.max(sheetMaxX, x);
  }

  // ── Feeders: vertical riser in a right-hand channel + horizontal branches ───
  final channelX = sheetMaxX + 40;
  for (final entry in parentOf.entries) {
    final child = entry.key;
    final parent = entry.value;
    if (!panelX.containsKey(child) || !panelX.containsKey(parent)) continue;
    final role =
        essential.contains(child) ? SldRole.essential : SldRole.normal;
    final px = panelX[parent]! + _ovW; // parent right edge
    final py = panelY[parent]! + _ovH / 2;
    final cxx = panelX[child]! + _ovW; // child right edge
    final cyy = panelY[child]! + _ovH / 2;
    // parent right -> channel; channel vertical riser (length ∝ elevation
    // delta); channel -> child right.
    prims.add(SldLine(px, py, channelX, py, weight: SldWeight.medium, role: role));
    prims.add(SldLine(channelX, py, channelX, cyy,
        weight: SldWeight.medium, role: role));
    prims.add(SldLine(channelX, cyy, cxx, cyy,
        weight: SldWeight.medium, role: role));
  }
  sheetMaxX = math.max(sheetMaxX, channelX);

  // Source -> each root: from the LV-main bus bottom into the root panel.
  if (spine != null) {
    for (final id in result.order) {
      if (parentOf.containsKey(id) || !panelX.containsKey(id)) continue;
      final zx = panelX[id]! + _ovW / 2;
      final zy = panelY[id]!;
      final midY = (spine.feedY + zy) / 2;
      prims.add(SldLine(spine.feedX, spine.feedY, spine.feedX, midY,
          weight: SldWeight.medium, role: SldRole.source));
      prims.add(SldLine(spine.feedX, midY, zx, midY,
          weight: SldWeight.medium, role: SldRole.source));
      prims.add(SldLine(zx, midY, zx, zy,
          weight: SldWeight.medium, role: SldRole.source));
    }
  }

  // ── Floor gutter: per band, name + FFL + a hairline grid line ───────────────
  for (var i = 0; i < levelCount; i++) {
    final y = bandY(i) + contentOffsetY;
    final gridY = y + _ovH + _riserPanelGap / 2;
    prims.add(SldLine(0, gridY, sheetMaxX, gridY, weight: SldWeight.thin));
    if (hasFloors) {
      final fl = building.floors[i];
      prims.add(SldLabel(6, y + 17, fl.name.isEmpty ? 'L${i + 1}' : fl.name,
          size: 10, bold: true));
      prims.add(SldLabel(6, y + 33,
          'FFL ${_ffl(building.elevationOf(i).meters)}', size: 8));
    } else {
      // Tier-fallback gutter: Tier n, root tier at the top.
      final tier = topIndex - i; // band i is depth `tier`
      prims.add(SldLabel(6, y + 17, 'Tier ${tier + 1}', size: 10, bold: true));
    }
  }

  // ── Panel nodes (drawn last, over the grid) ─────────────────────────────────
  for (final id in result.order) {
    final p = result.panels[id];
    if (p == null || !panelX.containsKey(id)) continue;
    final x = panelX[id]!;
    final y = panelY[id]!;
    final role = essential.contains(id) ? SldRole.essential : SldRole.normal;
    prims.add(SldRect(x, y, _ovW, _ovH, role: role));
    final tag = (p.tag != null && p.tag!.isNotEmpty) ? '  [${p.tag}]' : '';
    prims.add(SldLabel(x + 7, y + 17, '${p.name}$tag',
        size: 10, bold: true, role: role));
    prims.add(SldLabel(
        x + 7,
        y + 33,
        '${_num(p.incomer.breaker.ratingA.amperes)}A ${p.incomer.poles}P  '
        '${_num(p.demandW / 1000)}kW',
        size: 7.5,
        role: role));
  }

  // ── Bounds ─────────────────────────────────────────────────────────────────
  var minX = 0.0, minY = double.infinity, maxX = sheetMaxX, maxY = -double.infinity;
  for (final pr in prims) {
    switch (pr) {
      case SldRect():
        minY = math.min(minY, pr.y);
        maxY = math.max(maxY, pr.y + pr.h);
        maxX = math.max(maxX, pr.x + pr.w);
      case SldLine():
        minY = math.min(minY, math.min(pr.y1, pr.y2));
        maxY = math.max(maxY, math.max(pr.y1, pr.y2));
        maxX = math.max(maxX, math.max(pr.x1, pr.x2));
      case SldLabel():
        minY = math.min(minY, pr.y);
    }
  }
  if (!minY.isFinite) {
    minY = 0;
    maxY = 1;
  }
  if (maxX <= minX) maxX = minX + 1;

  final s = result.supply;
  final supplyNote = '${s.system.label}  ${_num(s.voltage.volts)}V  '
      'demand ${_num(s.demandW / 1000)}kW / '
      '${_num(s.demandVa.inKilovoltAmperes)}kVA';

  return SldSheet(
    prims: prims,
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
    legend: [
      const SldLegendEntry('Normal', 'Normal supply'),
      const SldLegendEntry('Essential', 'Essential / emergency supply'),
      const SldLegendEntry('FFL', 'Finished floor level (m)'),
      if (sourceChain) const SldLegendEntry('Source', 'Utility / MV supply chain'),
    ],
    supplyNote: supplyNote,
  );
}
