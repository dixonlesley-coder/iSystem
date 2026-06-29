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
import '../standards/puil.dart' show BreakerCurve, BreakerClass;

/// Stroke weight buckets (mapped to real widths by each renderer).
enum SldWeight { thin, medium, thick }

/// A drawing primitive in y-down drawing space. Sealed so renderers switch
/// exhaustively over the small closed set.
sealed class SldPrim {
  const SldPrim();
}

class SldLine extends SldPrim {
  final double x1, y1, x2, y2;
  final SldWeight weight;
  const SldLine(this.x1, this.y1, this.x2, this.y2,
      {this.weight = SldWeight.thin});
}

class SldRect extends SldPrim {
  final double x, y, w, h;
  final SldWeight weight;
  const SldRect(this.x, this.y, this.w, this.h,
      {this.weight = SldWeight.medium});
}

class SldLabel extends SldPrim {
  final double x, y;
  final String text;
  final double size;
  final bool bold;
  const SldLabel(this.x, this.y, this.text,
      {this.size = 9, this.bold = false});
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

String _curveCode(BreakerCurve c) => switch (c) {
      BreakerCurve.b => 'B',
      BreakerCurve.c => 'C',
      BreakerCurve.d => 'D',
    };

String _classCode(BreakerClass c) =>
    c == BreakerClass.mccb ? 'MCCB' : 'MCB';

/// A breaker label like `MCB C16A/1P`.
String breakerLabel(BreakerResult b, int poles) =>
    '${_classCode(b.deviceClass)} ${_curveCode(b.curve)}'
    '${_num(b.ratingA.amperes)}A/${poles}P';

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
    final blockX = (depth[id] ?? 0) * _indent;
    final blockY = cursorY;
    final blockH = _headerH + math.max(1, ways) * _rowH + _bodyPad;
    boxTop[id] = (x: blockX, y: blockY);
    boxBottom[id] = blockY + blockH;

    // Outer block.
    prims.add(SldRect(blockX, blockY, _blockW, blockH));

    // Header: name [tag] + the incomer / system / bus sub-line.
    final tag = (p.tag != null && p.tag!.isNotEmpty) ? '  [${p.tag}]' : '';
    prims.add(SldLabel(blockX + 8, blockY + 16, '${p.name}$tag',
        size: 13, bold: true));
    final v = model?.voltage.volts ?? (p.system.isThreePhase ? 400 : 230);
    prims.add(SldLabel(
        blockX + 8,
        blockY + 32,
        'Incomer ${breakerLabel(p.incomer.breaker, p.incomer.poles)}  '
        '${p.system.label}  ${_num(v)}V  '
        'bus ${_num(p.busbar.csaMm2)}mm2  '
        'demand ${_num(p.demandCurrent.amperes)}A',
        size: 8));
    usedCurves.add(p.incomer.breaker.curve);
    usedClasses.add(p.incomer.breaker.deviceClass);

    // Header / body divider (full width) for a clean schedule look.
    final busTop = blockY + _headerH;
    prims.add(SldLine(blockX, busTop, blockX + _blockW, busTop));
    // Busbar (two parallel verticals so it reads as a bar).
    final busBot = blockY + blockH - 6;
    final bx = blockX + _busX;
    prims.add(SldLine(bx, busTop, bx, busBot, weight: SldWeight.thick));
    prims.add(SldLine(bx + 4, busTop, bx + 4, busBot, weight: SldWeight.thick));
    // Incomer breaker straddling the divider at the bus top (the topmost device
    // on the bus; named verbatim by the header sub-line "Incomer ...").
    prims.add(SldRect(bx + 2 - _brW / 2, busTop - _brH / 2, _brW, _brH));

    // One row per way.
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
      final txt = '$wayNo  ${breakerLabel(c.breaker, poles)}  '
          '${cableLabel(circuit, c.cable.csaMm2, c.threePhase)}  '
          '${c.name}  ${c.phase.label}  Ib ${_num(c.designCurrent.amperes)}A'
          '$dest$vd';
      prims.add(SldLabel(bx + 50, rowY + 3, txt, size: 8.5));

      if (feeds != null) {
        feederFrom[feeds] = (x: blockX + _blockW, y: rowY);
      }
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
