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
const double _blockW = 920;
const double _headerH = 46;
const double _rowH = 20;
const double _bodyPad = 12;
const double _gapY = 46;
const double _indent = 64; // per feeder-depth level
const double _busX = 44; // bus offset inside a block
const double _brW = 15; // breaker symbol
const double _brH = 10;

// Aligned panel-schedule COLUMNS (x offset within the block) — the real BRI
// `Diagram Panel` layout: GRUP | DEVICE | PENGHANTAR | DAYA | KETERANGAN, then
// the R / S / T per-phase loading band on the right.
const double _colGrup = 92; // way no (W1) — clears the breaker stub + symbol
const double _colDevice = 116; // breaker (MCB 16A 1ph)
const double _colPenghantar = 224; // conductor + conduit (NYY 4x6 + E6 · PVC 25)
const double _colDaya = 446; // connected load (DAYA, W/kW)
const double _colKeterangan = 506; // load name / -> sub-panel
const double _colR = 726; // per-phase loading band (R/S/T line currents)
const double _colS = 772;
const double _colT = 818;

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

/// The per-phase (R / S / T) loading strings for a way carrying line current
/// [ib]: a single-phase way loads only its assigned line; a three-phase way
/// loads all three (balanced). Empty string = no load on that line.
(String, String, String) _phaseLoading(PhaseAssignment phase, String ib) =>
    switch (phase) {
      PhaseAssignment.l1 => (ib, '', ''),
      PhaseAssignment.l2 => ('', ib, ''),
      PhaseAssignment.l3 => ('', '', ib),
      PhaseAssignment.threePhase => (ib, ib, ib),
    };

/// A PVC conduit size (mm) derived from the conductor — a ~40 % fill general-
/// practice estimate (// VERIFY, NOT an SNI clause; the model carries no conduit
/// field). Returns null for large feeders (beyond the conduit range — they run
/// on tray / cable-ladder, so no conduit token). A 3-phase run (5-core) bumps up
/// one trade size for the extra cores.
int? _conduitMm(double csaMm2, bool threePhase) {
  final base = csaMm2 <= 4
      ? 20
      : csaMm2 <= 10
          ? 25
          : csaMm2 <= 16
              ? 32
              : csaMm2 <= 35
                  ? 40
                  : csaMm2 <= 70
                      ? 50
                      : 0;
  if (base == 0) return null;
  if (!threePhase || base >= 50) return base;
  return switch (base) { 20 => 25, 25 => 32, 32 => 40, 40 => 50, _ => base };
}

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
///
/// When [onlyPanelId] is set, emit JUST that one panel's board schedule
/// (re-origined to (0,0), no feeder channel, bounds tightened to the block) —
/// the per-panel DETAIL filter the interactive canvas paints as its deep-zoom
/// LOD. Null ⇒ the full multi-panel single-line (byte-identical to before).
SldSheet buildElectricalSld({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  String? onlyPanelId,
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

  // Single-panel filter: lay only the requested panel, at depth 0 (origin).
  final order = onlyPanelId == null
      ? result.order
      : [for (final id in result.order) if (id == onlyPanelId) id];

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
  for (final id in order) {
    final p = result.panels[id];
    if (p == null) continue;
    final model = modelById[id];
    final ways = p.circuits.length;
    // Reserved spare ways (CADANGAN) draw as extra schedule rows below the real
    // ways; a footer row carries the panel TOTAL. Both extend the block height
    // so the busbar + rows stay inside the box. 0 reserved + no footer growth ⇒
    // geometry is byte-identical to the pre-enrichment block.
    final spareWays = p.spareWaysReserved;
    final bodyRows = math.max(1, ways) + spareWays;
    const footerH = _rowH; // the TOTAL footer line
    // Full single-line: indent by feeder depth. Single-panel detail filter:
    // re-origin to x=0 so the block frames cleanly in a panel rect.
    final blockX = onlyPanelId != null ? 0.0 : (depth[id] ?? 0) * _indent;
    final blockY = cursorY;
    // +1 row for the column-header band (GRUP / PENGHANTAR / DAYA / R-S-T).
    final blockH = _headerH + (1 + bodyRows) * _rowH + footerH + _bodyPad;
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

    // Incomer METERING cluster (top-right of the header) — V / A / Hz meters +
    // a CT note, the BRI `Diagram Panel` convention. Only on 3-phase boards
    // (single-phase final boards carry no metering). Boxed letters read as the
    // meter symbols without a new primitive.
    if (p.system.isThreePhase) {
      var mx = blockX + _blockW - 196;
      const my = 12.0; // within the header band
      for (final m in const ['V', 'A', 'Hz']) {
        prims.add(SldRect(mx, blockY + my, 18, 18));
        prims.add(SldLabel(mx + 4, blockY + my + 13, m, size: 8));
        mx += 30;
      }
      prims.add(SldLabel(mx + 4, blockY + my + 13, 'CT', size: 8));
    }

    // Header / body divider (full width) for a clean schedule look.
    final busTop = blockY + _headerH;
    prims.add(SldLine(blockX, busTop, blockX + _blockW, busTop));
    // Busbar (two parallel verticals so it reads as a bar). The bar runs the
    // full body (column-header row + real + spare ways), stopping above TOTAL.
    final busBot = busTop + (1 + bodyRows) * _rowH + 6;
    final bx = blockX + _busX;
    prims.add(SldLine(bx, busTop, bx, busBot, weight: SldWeight.thick));
    prims.add(SldLine(bx + 4, busTop, bx + 4, busBot, weight: SldWeight.thick));
    // Incomer breaker straddling the divider at the bus top (the topmost device
    // on the bus; named verbatim by the header sub-line "Incomer ...").
    prims.add(SldRect(bx + 2 - _brW / 2, busTop - _brH / 2, _brW, _brH));

    // Column-header band (slot 0): the BRI `Diagram Panel` table columns.
    final headY = busTop + 6 + _rowH / 2 + 3;
    void colHead(double x, String t) =>
        prims.add(SldLabel(blockX + x, headY, t, size: 7, bold: true));
    colHead(_colGrup, 'GRUP');
    colHead(_colDevice, 'DEVICE');
    colHead(_colPenghantar, 'PENGHANTAR');
    colHead(_colDaya, 'DAYA');
    colHead(_colKeterangan, 'KETERANGAN');
    colHead(_colR, 'R');
    colHead(_colS, 'S');
    colHead(_colT, 'T');
    // Underline under the column-header row.
    prims.add(SldLine(bx + 4, busTop + _rowH, blockX + _blockW - 8,
        busTop + _rowH));

    // One ROW per way, in ALIGNED columns: GRUP (way no) | DEVICE (breaker,
    // rating + phase first) | PENGHANTAR (cable family + cores x CSA + separate
    // earth) | DAYA (connected W/kW) | KETERANGAN (load name / -> sub-panel) |
    // R/S/T (the line current on the way's phase(s) — the phase-loading band).
    const rowSize = 7.5;
    for (var i = 0; i < ways; i++) {
      final c = p.circuits[i];
      final slot = 1 + i; // +1 for the column-header row
      final rowY = busTop + 6 + slot * _rowH + _rowH / 2;
      // Stub from bus to breaker + the breaker symbol.
      prims.add(SldLine(bx + 4, rowY, bx + 28, rowY));
      prims.add(SldRect(bx + 28, rowY - _brH / 2, _brW, _brH));
      usedCurves.add(c.breaker.curve);
      usedClasses.add(c.breaker.deviceClass);
      final circuit = circuitById[c.circuitId];
      if (circuit?.cableType != null && circuit!.cableType!.isNotEmpty) {
        usedFamilies.add(circuit.cableType!);
      }
      final poles = c.threePhase ? 3 : 1;
      final feeds = circuit?.feedsPanelId;
      final keterangan = feeds != null
          ? '-> ${result.panels[feeds]?.name ?? feeds}'
          : c.name;
      final vd = c.voltageDrop.withinLimit ? '' : '  VD!';
      final earth = c.grounding.peCsaMm2 > 0
          ? ' + E${_num(c.grounding.peCsaMm2)} mm2'
          : '';
      final conduitMm = _conduitMm(c.cable.csaMm2, c.threePhase);
      final conduit = conduitMm != null ? ' · PVC ${conduitMm}mm' : '';
      final cable =
          '${cableLabel(circuit, c.cable.csaMm2, c.threePhase)} mm2$earth$conduit';
      final daya = c.loadW > 0 ? _watts(c.loadW) : '-';
      final ib = _num(c.designCurrent.amperes);
      prims.add(SldLabel(blockX + _colGrup, rowY + 3, 'W${i + 1}', size: rowSize));
      prims.add(SldLabel(blockX + _colDevice, rowY + 3,
          breakerScheduleLabel(c.breaker, poles), size: rowSize));
      prims.add(SldLabel(blockX + _colPenghantar, rowY + 3, cable, size: rowSize));
      prims.add(SldLabel(blockX + _colDaya, rowY + 3, daya, size: rowSize));
      prims.add(SldLabel(
          blockX + _colKeterangan, rowY + 3, '$keterangan$vd', size: rowSize));
      // R/S/T loading band — the line current under the way's phase(s).
      final (r, s, t) = _phaseLoading(c.phase, ib);
      if (r.isNotEmpty) {
        prims.add(SldLabel(blockX + _colR, rowY + 3, r, size: rowSize));
      }
      if (s.isNotEmpty) {
        prims.add(SldLabel(blockX + _colS, rowY + 3, s, size: rowSize));
      }
      if (t.isNotEmpty) {
        prims.add(SldLabel(blockX + _colT, rowY + 3, t, size: rowSize));
      }
      if (feeds != null) {
        feederFrom[feeds] = (x: blockX + _blockW, y: rowY);
      }
    }

    // CADANGAN (spare) ways — a stub + a GRUP no + a KETERANGAN label each.
    for (var s = 0; s < spareWays; s++) {
      final slot = 1 + ways + s;
      final rowY = busTop + 6 + slot * _rowH + _rowH / 2;
      prims.add(SldLine(bx + 4, rowY, bx + 28, rowY));
      prims.add(
          SldLabel(blockX + _colGrup, rowY + 3, 'W${ways + s + 1}', size: rowSize));
      prims.add(SldLabel(
          blockX + _colKeterangan, rowY + 3, 'CADANGAN (spare)', size: rowSize));
    }

    // TOTAL footer — the panel's diversified demand (W/kW + line current) + the
    // per-phase R/S/T line-current totals (the phase balance).
    final footerY = busBot + _rowH / 2 + 3;
    prims.add(SldLabel(blockX + 8, footerY,
        'TOTAL  ${_watts(p.demandW)} / ${_num(p.demandCurrent.amperes)}A',
        size: 8.5, bold: true));
    if (p.system.isThreePhase) {
      final pb = p.phaseBalance;
      prims.add(SldLabel(blockX + _colR, footerY, _num(pb.l1),
          size: rowSize, bold: true));
      prims.add(SldLabel(blockX + _colS, footerY, _num(pb.l2),
          size: rowSize, bold: true));
      prims.add(SldLabel(blockX + _colT, footerY, _num(pb.l3),
          size: rowSize, bold: true));
    }

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
  // the LEFT edge of the sub-panel block (orthogonal, riser-duct style). Skipped
  // for the single-panel detail filter (its sub-panels aren't laid out here) so
  // the block frames tightly.
  if (onlyPanelId == null) {
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
  }

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

/// The DETAIL board schedule for ONE panel ([panelId]), re-origined to (0,0)
/// with no feeder channel — the geometry the interactive single-line canvas
/// paints as its deep-zoom LOD (`SldSheetPainter`), the SAME primitives the
/// PDF/DXF export draws. A thin alias over `buildElectricalSld(onlyPanelId:)`.
/// When [panelId] is absent from the result the sheet is empty (no block).
SldSheet buildElectricalPanelDetail({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  required String panelId,
}) =>
    buildElectricalSld(project: project, result: result, onlyPanelId: panelId);

/// The utility SOURCE-SPINE only (PLN MV -> [MV main] -> TRANSFORMER -> LV main,
/// + optional GENSET / CAPACITOR BANK), as a standalone `SldSheet` for painting
/// a read-only spine strip ABOVE the root panel on the interactive single-line
/// canvas — ONE source-spine geometry shared with the overview / riser / export
/// (the `_buildSourceSpine` body). `isEmpty` is true when there is no demand AND
/// no sources / dual-tx / explicit transformer, so a bare project shows nothing
/// new on the canvas (the existing PLN head stays).
SldSheet buildElectricalSourceSpine({
  required ElectricalProject project,
  required ElectricalSystemResult result,
}) {
  final hasSource = project.sources != null ||
      project.dualTransformer ||
      project.transformerKva != null ||
      project.capacitorBankKvar != null;
  final hasDemand = result.supply.demandVa.inKilovoltAmperes > 0;
  if (!hasSource && !hasDemand) {
    return const SldSheet(
      prims: [],
      minX: 0,
      minY: 0,
      maxX: 1,
      maxY: 1,
      legend: [],
      supplyNote: '',
    );
  }

  final spine = _buildSourceSpine(project, result, _ovW);
  // Bounds over the spine prims (it extends right for the GENSET / CAPACITOR
  // side nodes and down to the LV main).
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
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
  if (!minX.isFinite) {
    minX = 0;
    minY = 0;
    maxX = 1;
    maxY = 1;
  }

  return SldSheet(
    prims: spine.prims,
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
    legend: const [SldLegendEntry('Source', 'Utility / MV supply chain')],
    supplyNote: '',
  );
}

// ── ZOOMED-OUT building single-line (the whole distribution hierarchy) ───────

/// Compact-node geometry for the overview / riser.
const double _ovW = 168;
const double _ovH = 46;
const double _ovHGap = 26;
const double _ovTierH = 120;

/// Assumed building power factor for the per-panel compact-node kVA sub-line —
/// mirrors `compute.dart`'s `assumedBuildingPf` but inlined to keep this pure
/// drawing file free of the compute dependency. A representative estimate, NOT
/// an SNI/PUIL clause. // VERIFY
const double _assumedPanelPf = 0.85;

/// Resolve, per CHILD panel id, the PARENT'S feeding circuit (project model, for
/// the cable family) + its sized [ElectricalCircuitResult] (for the cable CSA +
/// breaker). Used to label each feeder run with its real cable + breaker. A
/// child whose feeding circuit or sized result can't be resolved is absent ⇒ its
/// feeder is left UNLABELLED (never fabricated). Shared by the overview + riser.
(Map<String, ElectricalCircuit>, Map<String, ElectricalCircuitResult>)
    _feederLabelLookups(
  ElectricalProject project,
  ElectricalSystemResult result,
  Map<String, String> parentOf,
) {
  final feederCircuitOf = <String, ElectricalCircuit>{};
  for (final parent in project.panels) {
    for (final c in parent.circuits) {
      final child = c.feedsPanelId;
      if (child != null && result.panels.containsKey(child)) {
        feederCircuitOf[child] = c;
      }
    }
  }
  final feederResultOf = <String, ElectricalCircuitResult>{};
  feederCircuitOf.forEach((child, circ) {
    final par = parentOf[child];
    final pr = par == null ? null : result.panels[par];
    if (pr == null) return;
    for (final cr in pr.circuits) {
      if (cr.circuitId == circ.id) {
        feederResultOf[child] = cr;
        break;
      }
    }
  });
  return (feederCircuitOf, feederResultOf);
}

/// The feeder cable + breaker annotation for a resolvable feeder, e.g.
/// `NYY 4x50 mm2 · MCCB 250A 3ph`. Null when the child's feeding circuit or its
/// sized result is unresolved (⇒ omit the label rather than guess). ASCII-safe
/// (the bundled middle dot is allowed).
String? _feederConnLabel(
  Map<String, ElectricalCircuit> feederCircuitOf,
  Map<String, ElectricalCircuitResult> feederResultOf,
  String child,
) {
  final cr = feederResultOf[child];
  final circ = feederCircuitOf[child];
  if (cr == null || circ == null) return null;
  final poles = cr.threePhase ? 3 : 1;
  return '${cableLabel(circ, cr.cable.csaMm2, cr.threePhase)} mm2 · '
      '${breakerScheduleLabel(cr.breaker, poles)}';
}

/// The compact-node sub-line: `<In>A <poles>P · <kW>kW / <kVA>kVA` (the panel's
/// incomer rating + diversified demand in both kW and kVA). Shared by the
/// overview + riser so they read identically. ASCII-safe.
String _compactNodeSubLine(ElectricalPanelResult p) =>
    '${_num(p.incomer.breaker.ratingA.amperes)}A ${p.incomer.poles}P · '
    '${_num(p.demandW / 1000)}kW / '
    '${_num(p.demandW / _assumedPanelPf / 1000)}kVA';

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

/// The set of ESSENTIAL panel ids — a panel is essential when it is on the
/// genset-backed (emergency) supply (its explicit [ElectricalPanel.essential]
/// flag), when its name marks it emergency (EMERGENCY / ESSENTIAL / DARURAT), or
/// when its parent is essential (the property propagates DOWN the emergency
/// sub-tree). A single life-safety WAY does NOT make a whole board essential.
/// Shared by the overview + riser so their colour split is derived identically.
/// `result.order` is root-first ⇒ a parent is decided before its children.
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

  // Whole-spine kVA: an EXPLICIT transformer rating wins; else the smallest
  // standard rating covering the building demand VA (genset ladder, // VERIFY).
  // Blank when neither is known.
  final txKva = project.transformerKva?.inKilovoltAmperes ??
      (demandVa.inKilovoltAmperes > 0
          ? selectGeneratorKva(demandVa).inKilovoltAmperes
          : 0.0);
  final txLabel = txKva > 0 ? 'TRANSFORMER ${_num(txKva)} kVA' : 'TRANSFORMER';

  // The vertical spine, top -> bottom. MV main is drawn only for a dual-tx /
  // sources / explicit-transformer project (else the PLN node feeds the LV main
  // directly).
  final hasMv = project.dualTransformer ||
      project.sources != null ||
      project.transformerKva != null;
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
  // CAPACITOR BANK: drawn when a real bank is specified (kvar set) OR — kept as
  // the historic proxy — whenever any distributed sources exist. The real field
  // labels its kvar verbatim; the proxy stays the generic "PF correction".
  if (project.capacitorBankKvar != null || project.sources != null) {
    final cy = lvMidY + 8;
    final kvar = project.capacitorBankKvar;
    final capSub =
        (kvar != null && kvar > 0) ? '${_num(kvar)} kvar' : 'PF correction';
    prims.add(SldRect(sideX, cy, _ovW, _ovH, role: SldRole.source));
    prims.add(SldLabel(sideX + 7, cy + 17, 'CAPACITOR BANK',
        size: 8.5, bold: true, role: SldRole.source));
    prims.add(SldLabel(sideX + 7, cy + 33, capSub,
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
/// A panel is ESSENTIAL (drawn red) when it is on the genset-backed (emergency)
/// supply (its explicit [ElectricalPanel.essential] flag), when its name marks
/// it emergency, or when its parent is essential (the property propagates down
/// the emergency sub-tree). A single life-safety way does NOT make a board
/// essential.
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
  final (feederCircuitOf, feederResultOf) =
      _feederLabelLookups(project, result, parentOf);
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
      // Feeder annotation (cable + breaker) on the mid horizontal segment, just
      // above the line; omitted when the parent feeding circuit can't resolve.
      final lbl = _feederConnLabel(feederCircuitOf, feederResultOf, child);
      if (lbl != null) {
        prims.add(SldLabel(math.min(ax, zx) + 4, midY - 4, lbl,
            size: 6.5, role: role));
      }
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
    prims.add(SldLabel(x + 7, y + 33, _compactNodeSubLine(p),
        size: 7.5, role: role));
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
const double _riserBandH = 150;
const double _riserPanelGap = 24;

/// Per-floor branch fan-out: how many outgoing LOAD ways a riser panel shows as
/// labelled stubs before collapsing the remainder to a `+N more` summary, the
/// pitch of each stub row, and the reserved column height that the floor grid
/// line clears (so the densest board never overruns the next band).
const int kRiserFanMax = 4;
const double _fanRowH = 11;
const double _fanColH = (kRiserFanMax + 1) * _fanRowH + 6;

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
  final (feederCircuitOf, feederResultOf) =
      _feederLabelLookups(project, result, parentOf);
  // The circuit ids that are FEEDERS (supply a sub-panel) — excluded from a
  // panel's per-floor load-way fan-out (a feeder is drawn as a riser branch,
  // not a hanging stub).
  final feederCircuitIds = <String>{
    for (final p in project.panels)
      for (final c in p.circuits)
        if (c.feedsPanelId != null) c.id
  };

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
    // Feeder annotation (cable + breaker) along the horizontal branch into the
    // child, just above the line; omitted when the feeding circuit can't resolve.
    final lbl = _feederConnLabel(feederCircuitOf, feederResultOf, child);
    if (lbl != null) {
      prims.add(SldLabel(math.min(cxx, channelX) + 6, cyy - 4, lbl,
          size: 6.5, role: role));
    }
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
    // The hairline sits below the densest board's fan-out column so a board's
    // load-way stubs never cross into the next floor band.
    final gridY = y + _ovH + _fanColH + _riserPanelGap / 2;
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
    prims.add(SldLabel(x + 7, y + 33, _compactNodeSubLine(p),
        size: 7.5, role: role));

    // Per-floor branch fan-out: the panel's NON-FEEDER outgoing load ways as a
    // compact column of short labelled stubs below the box — the real riser
    // convention (what each board distributes on its floor). Capped at
    // [kRiserFanMax]; the remainder collapses to a `+N more` row (summarised,
    // never silently dropped).
    final loadWays = [
      for (final cr in p.circuits)
        if (!feederCircuitIds.contains(cr.circuitId)) cr
    ];
    final shown = loadWays.length > kRiserFanMax
        ? loadWays.sublist(0, kRiserFanMax)
        : loadWays;
    var row = 0;
    for (final cr in shown) {
      final sy = y + _ovH + 4 + row * _fanRowH;
      prims.add(SldLine(x + 8, sy, x + 22, sy, weight: SldWeight.thin, role: role));
      final nm = cr.name.length > 14 ? cr.name.substring(0, 14) : cr.name;
      final ph = cr.threePhase ? ' 3ph' : '';
      prims.add(SldLabel(x + 26, sy + 3,
          '$nm ${_num(cr.breaker.ratingA.amperes)}A$ph',
          size: 6, role: role));
      row++;
    }
    if (loadWays.length > kRiserFanMax) {
      final more = loadWays.length - kRiserFanMax;
      final sy = y + _ovH + 4 + row * _fanRowH;
      prims.add(SldLine(x + 8, sy, x + 22, sy, weight: SldWeight.thin, role: role));
      prims.add(SldLabel(x + 26, sy + 3, '+$more more', size: 6, role: role));
    }
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
