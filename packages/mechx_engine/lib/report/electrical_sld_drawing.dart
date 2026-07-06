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

import '../electrical/cable_family.dart'
    show cableFamilyDescription, defaultCableFamily;
import '../electrical/control/starter.dart' show StarterType;
import '../electrical/earthing.dart' show EarthingSystemInfo;
import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import '../electrical/power_oneline.dart';
import '../electrical/results.dart' show BreakerResult;
import '../electrical/sources.dart'
    show GeneratorModeInfo, selectGeneratorKva;
import '../geometry/building.dart' show BuildingLevels, MountingHeights;
import '../standards/puil.dart' show BreakerCurve, BreakerClass;
import '../units.dart' show ApparentPower;
import 'number_format.dart' show groupThousands;
import 'sld_sheet.dart';

// The drawing-primitive types (SldSheet / SldPrim / SldLine / SldRect /
// SldLabel / SldCircle / SldLegendEntry / SldWeight / SldRole) now live in the
// discipline-neutral `sld_sheet.dart`; re-exported so existing importers of this
// file (the PDF/DXF exporters, the canvas painter) keep their single import.
export 'sld_sheet.dart';

// ── Block geometry (drawing units) ───────────────────────────────────────────
// The block widened 920 -> 948 (+28) to give the DEVICE column room for the
// per-device breaking-capacity (kA, N9) + the socket-way RCD token (N10) that
// now ride the breaker cell; the columns after DEVICE all shift +28 so their
// widths are unchanged (golden rule 5: same geometry, all renderers follow).
const double _blockW = 948;
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
const double _colDevice = 116; // breaker (MCB 16A 1ph[ 16kA][ · RCD 30mA A])
const double _colPenghantar = 252; // conductor + conduit + length (NYY 4x6 · 22 m)
const double _colDaya = 474; // connected load (DAYA, W/kW)
const double _colKeterangan = 534; // load name / -> sub-panel
const double _colR = 754; // per-phase loading band (R/S/T line currents)
const double _colS = 800;
const double _colT = 846;

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// A connected-load (DAYA) figure: `W` under 1 kW, else `kW`.
String _watts(double w) =>
    w >= 1000 ? '${_num(w / 1000)}kW' : '${_num(w)}W';

/// The DAYA cell figure in the Indonesian DIAGRAM-PANEL convention: integer
/// WATT with a DOT thousands separator + ` WATT` (e.g. 4400 -> `4.400 WATT`,
/// 190 -> `190 WATT`, 52871 -> `52.871 WATT`). Rounds to the nearest watt.
String _wattsId(double w) => '${groupThousands(w)} WATT';

/// The ASCII control / starter token for a way's [StarterType] (BRI `Diagram
/// Panel` motor-control convention: DOL / VSD / star-delta). ASCII-only — never
/// the model's own `Y-D` label (the unicode would tofu in the goldens/exports).
String _starterCode(StarterType s) => switch (s) {
      StarterType.dol => 'DOL',
      StarterType.starDelta => 'star-delta',
      StarterType.reversing => 'REV',
      StarterType.softStarter => 'soft-start',
      StarterType.vfd => 'VFD',
      StarterType.ats => 'ATS',
      StarterType.pump => 'pump',
    };

String _curveCode(BreakerCurve c) => switch (c) {
      BreakerCurve.b => 'B',
      BreakerCurve.c => 'C',
      BreakerCurve.d => 'D',
    };

String _classCode(BreakerClass c) =>
    c == BreakerClass.mccb ? 'MCCB' : 'MCB';

/// A breaker label like `MCB C16A/1P` — the curve-led form (kept for the
/// incomer sub-line + the device legend so the trip curve stays surfaced).
///
/// The trip-curve letter is emitted ONLY for MCBs. A moulded-case breaker is
/// specified by frame / trip / breaking capacity, NOT by a fixed B/C/D
/// characteristic, so `MCCB C160A/4P` is not a valid designation — an MCCB reads
/// `MCCB 160A/4P` (N12).
String breakerLabel(BreakerResult b, int poles) {
  final curve =
      b.deviceClass == BreakerClass.mccb ? '' : _curveCode(b.curve);
  return '${_classCode(b.deviceClass)} $curve'
      '${_num(b.ratingA.amperes)}A/${poles}P';
}

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

/// The protective-earth conductor token in the BRI DIAGRAM PANEL convention
/// (EL1004 DXF): an insulated single-core **NYA** for small earths, **BC** (bare
/// copper) for large ones — the DXF uses `+ NYA <csa> mm2` up to ~10 mm2 and
/// `+ BC <csa> mm2` from ~16 mm2 (so the protective conductor reads as a real
/// cable, not a generic `+ E`). // VERIFY — drawing convention, not a clause.
String _earthConductor(double peCsaMm2) {
  final family = peCsaMm2 >= 16 ? 'BC' : 'NYA';
  return ' + $family ${_num(peCsaMm2)} mm2';
}

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

/// A cable label like `NYM 3x2.5` — the family from the circuit's explicit
/// [ElectricalCircuit.cableType] when set, else the conventional default for its
/// load kind ([defaultCableFamily]: NYM for final circuits, NYY otherwise) so a
/// drawing always names a real cable construction, never the bare conductor
/// material. Cores = 3 for 1-phase L+N+E, 5 for 3-phase 3L+N+E.
String cableLabel(ElectricalCircuit? circuit, double csaMm2, bool threePhase) {
  final family = resolvedCableFamily(circuit);
  final cores = threePhase ? 5 : 3;
  return '$family ${cores}x${_num(csaMm2)}';
}

/// The cable family a circuit's label/legend should show: its explicit
/// `cableType` when set, else the convention default for its load kind.
String resolvedCableFamily(ElectricalCircuit? circuit) =>
    (circuit?.cableType != null && circuit!.cableType!.isNotEmpty)
        ? circuit.cableType!
        : defaultCableFamily(circuit?.loadKind);

/// Standard metering CT primary ratings (A) — the IEC 61869-2 / 60044-1
/// preferred-value series. The metering CT primary is the smallest standard
/// rating at or above the panel demand (line) current, over a 5 A secondary.
/// // VERIFY — the preferred-value ladder + the metering accuracy class are a
/// representative selection, not a specific SNI/PUIL clause.
const List<int> _ctPrimaryLadder = [
  5, 10, 15, 20, 25, 30, 40, 50, 60, 75, 100, 125, 150, 200, 250, 300, 400, //
  500, 600, 750, 800, 1000, 1250, 1500, 1600, 2000, 2500, 3000, 4000, 5000, //
  6300,
];

/// The metering-CT label for a board carrying [demandA] line current:
/// `CT <primary>/5A cl.1` — the smallest standard primary at or above the demand
/// current, 5 A secondary, class 1 metering accuracy. Clamps to the top of the
/// ladder for very large demands (never fabricates a non-standard ratio). N11.
String _ctLabel(double demandA) {
  var primary = _ctPrimaryLadder.last;
  for (final p in _ctPrimaryLadder) {
    if (p >= demandA) {
      primary = p;
      break;
    }
  }
  return 'CT $primary/5A cl.1';
}

/// Resolve the per-device breaking-capacity figure (Icu, kA) to print on a
/// panel's incomer sub-line + every DEVICE cell (N9): (1) the explicit
/// [icuByPanelId] map — the fault study's CHOSEN standard Icu rating — when it
/// carries this panel; else (2) the busbar-withstand prospective fault at this
/// bus (present whenever the Fold-1 withstand ran — the app + dev tool default
/// 16 kA); else (3) the project-wide origin fault level. Returns null when NONE
/// is known (⇒ no kA appended, byte-identical). A device must be selected so its
/// Icu >= the prospective fault at the bus (IEC 60947-2 / 60898-1) — // VERIFY
/// (device-selection rule, not an SNI/PUIL clause) — so the figure reads as the
/// minimum breaking capacity whether it is the chosen rating or the raw fault.
double? _panelIcuKa(
  String panelId,
  ElectricalPanelResult p,
  ElectricalProject project,
  Map<String, double>? icuByPanelId,
) {
  final mapped = icuByPanelId?[panelId];
  if (mapped != null) return mapped;
  final w = p.busbar.withstand?.faultKa;
  if (w != null && w > 0) return w;
  final origin = project.originFaultLevelA;
  if (origin != null && origin.amperes > 0) return origin.amperes / 1000;
  return null;
}

/// Build the professional single-line for [project] / [result]. Pure geometry.
///
/// When [onlyPanelId] is set, emit JUST that one panel's board schedule
/// (re-origined to (0,0), no feeder channel, bounds tightened to the block) —
/// the per-panel DETAIL filter the interactive canvas paints as its deep-zoom
/// LOD. Null ⇒ the full multi-panel single-line (byte-identical to before).
///
/// [breakerIcuKaByPanelId] maps a panel id → the prospective-fault-derived
/// breaking capacity (Icu, kA) at that board (the app feeds it from the fault
/// study — see the class doc). When a panel resolves a kA it is appended
/// (` <n>kA`, integer when whole else one decimal) to that panel's INCOMER
/// sub-line breaker notation AND to each way's DEVICE cell (a way's required Icu
/// equals the prospective fault at its board, so one figure applies to all its
/// devices). Null / empty / a missing panel ⇒ NOTHING appended (byte-identical);
/// the kA is NEVER fabricated here.
SldSheet buildElectricalSld({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  String? onlyPanelId,
  Map<String, double>? breakerIcuKaByPanelId,
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
  // Whether any device carried a breaking capacity (N9) / any board drew a
  // metering cluster (N11) — drives the matching KETERANGAN legend entries.
  var anyIcuKa = false;
  var anyMetering = false;

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
    // Breaking-capacity (Icu, kA) suffix for this board's devices — appended to
    // the incomer sub-line + every way's DEVICE cell. Resolves the fault study's
    // chosen Icu rating when mapped, else the busbar-withstand prospective fault
    // at the bus, else the project origin fault level (N9); empty (⇒ byte-
    // identical) only when NONE of those is known — never fabricated.
    final icuKa = _panelIcuKa(id, p, project, breakerIcuKaByPanelId);
    final kaSuffix = icuKa != null ? ' ${_num(icuKa)}kA' : '';
    if (icuKa != null) anyIcuKa = true;
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
        'Incomer ${breakerLabel(p.incomer.breaker, p.incomer.poles)}$kaSuffix  '
        '${p.system.label}  ${_num(v)}V  '
        'Cu bus ${_num(p.busbar.csaMm2)}mm2$icw  '
        'demand ${_num(p.demandCurrent.amperes)}A',
        size: 8));
    // The trip-curve legend is about MCB characteristics only — an MCCB carries
    // no B/C/D curve (N12), so don't seed a curve legend entry from one.
    if (p.incomer.breaker.deviceClass != BreakerClass.mccb) {
      usedCurves.add(p.incomer.breaker.curve);
    }
    usedClasses.add(p.incomer.breaker.deviceClass);

    // Incomer METERING cluster (top-right of the header) — V / A / Hz meters +
    // a CT note, the BRI `Diagram Panel` convention. Only on 3-phase boards
    // (single-phase final boards carry no metering). The meters draw as CIRCLE
    // symbols (the DXF convention), each with a centred letter.
    if (p.system.isThreePhase) {
      anyMetering = true;
      var mx = blockX + _blockW - 220;
      const my = 12.0; // within the header band
      const mr = 9.0; // meter circle radius (fits the old 18px slot)
      for (final m in const ['V', 'A', 'Hz']) {
        final cx = mx + mr, cy = blockY + my + mr;
        prims.add(SldCircle(cx, cy, mr));
        prims.add(SldLabel(cx - m.length * 2.0, cy + 3, m, size: 7));
        mx += 30;
      }
      // The metering CT ratio (N11): the next standard primary above the panel
      // demand current over a 5 A secondary + the metering accuracy class,
      // e.g. `CT 200/5A cl.1` — replaces the bare `CT` glyph.
      prims.add(SldLabel(
          mx + 4, blockY + my + 13, _ctLabel(p.demandCurrent.amperes),
          size: 8));
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
    // Ruled table verticals — the BRI `Diagram Panel` schedule is a fully
    // ruled grid, not whitespace-aligned text. One thin separator a few px
    // left of each column, spanning the header band + every body row.
    for (final colX in const [
      _colDevice,
      _colPenghantar,
      _colDaya,
      _colKeterangan,
      _colR,
      _colS,
      _colT,
    ]) {
      prims.add(SldLine(blockX + colX - 6, busTop, blockX + colX - 6, busBot));
    }

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
      // Only an MCB carries a B/C/D trip curve in the legend (N12).
      if (c.breaker.deviceClass != BreakerClass.mccb) {
        usedCurves.add(c.breaker.curve);
      }
      usedClasses.add(c.breaker.deviceClass);
      final circuit = circuitById[c.circuitId];
      // Surface the cable family actually drawn (the explicit type, else the
      // convention default) so the KETERANGAN legend matches the rows.
      usedFamilies.add(resolvedCableFamily(circuit));
      final poles = c.threePhase ? 3 : 1;
      final feeds = circuit?.feedsPanelId;
      final keterangan = feeds != null
          ? '-> ${result.panels[feeds]?.name ?? feeds}'
          : c.name;
      final vd = c.voltageDrop.withinLimit ? '' : '  VD!';
      final earth = c.grounding.peCsaMm2 > 0
          ? _earthConductor(c.grounding.peCsaMm2)
          : '';
      final conduitMm = _conduitMm(c.cable.csaMm2, c.threePhase);
      final conduit = conduitMm != null ? ' · PVC ${conduitMm}mm' : '';
      // The run LENGTH the solve already used for this way (geo-derived when
      // placed, else the manual circuit length) — the cable-takeoff figure that
      // also drove the printed Vdrop (N8). Printed ONLY when a real length
      // exists (never fabricated); the ` m` suffix disambiguates it from the
      // `mm` conduit token.
      final length = c.lengthM > 0 ? ' · ${_num(c.lengthM)} m' : '';
      final cable =
          '${cableLabel(circuit, c.cable.csaMm2, c.threePhase)} mm2$earth$conduit$length';
      // DAYA in WATT (integer, dot thousands separator); a feeder (loadW 0) → '-'.
      final daya = c.loadW > 0 ? _wattsId(c.loadW) : '-';
      // DEVICE: breaker label + the motor-control / starter token (DOL / VSD /
      // star-delta) APPENDED only when the way carries a real starterType —
      // most final lighting/socket ways have none, so the cell stays bare.
      final starter = circuit?.starterType;
      // The RCD / RCBO protection token (N10) — the SAME `RcdSpec` the calc
      // report prints (schedule + report agree), appended only when the way
      // actually carries an RCD (most sockets / TT finals). e.g. `RCD 30mA A`.
      final rcd = c.rcd.required
          ? ' · RCD ${c.rcd.ratingMa}mA'
              '${c.rcd.type != null ? ' ${c.rcd.type!.name.toUpperCase()}' : ''}'
          : '';
      // The breaker cell leads with rating + phase, then the Icu suffix (when
      // fed), then the control / starter token, then the RCD token — so the kA
      // reads as part of the breaker spec, ahead of the control / RCD notes.
      final breakerCell = '${breakerScheduleLabel(c.breaker, poles)}$kaSuffix';
      final device = '$breakerCell'
          '${starter != null ? ' · ${_starterCode(starter)}' : ''}'
          '$rcd';
      final ib = _num(c.designCurrent.amperes);
      prims.add(SldLabel(blockX + _colGrup, rowY + 3, 'W${i + 1}', size: rowSize));
      prims.add(SldLabel(blockX + _colDevice, rowY + 3, device, size: rowSize));
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

    // Ruled table horizontals — one thin rule under every way/spare row (the
    // last coincides with the bus bottom, doubling as the TOTAL divider).
    for (var slot = 1; slot <= bodyRows; slot++) {
      final ruleY = busTop + 6 + (slot + 1) * _rowH;
      prims.add(SldLine(bx + 4, ruleY, blockX + _blockW - 8, ruleY));
    }

    // TOTAL footer — the panel's diversified demand (W/kW + line current) + the
    // per-phase R/S/T line-current totals (the phase balance). H7: a 3-phase
    // board also carries its already-computed phase-IMBALANCE percentage
    // (`ElectricalPanelResult.imbalancePercent`, the same figure the Markdown
    // calc report prints per panel) — never recomputed here, and only appended
    // when the board is genuinely 3-phase (a single-phase board's imbalance is
    // always 0/meaningless — `p.system.isThreePhase` gates it) and the value is
    // a real number (`isFinite` — the engine's own balancer never produces
    // NaN/Infinity, but the drawing layer never trusts that silently).
    final imbalance = p.system.isThreePhase && p.imbalancePercent.isFinite
        ? '  ·  imbalance ${_num(p.imbalancePercent)}%'
        : '';
    final footerY = busBot + _rowH / 2 + 3;
    prims.add(SldLabel(blockX + 8, footerY,
        'TOTAL  ${_watts(p.demandW)} / ${_num(p.demandCurrent.amperes)}A$imbalance',
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
    // N24: each family carries its OWN construction description (voltage / use),
    // never the ambiguous shared "Cable construction" against NYY and NYM alike.
    legend.add(SldLegendEntry(f, cableFamilyDescription(f)));
  }
  legend.add(const SldLegendEntry('Ib', 'Design (load) current'));
  legend.add(const SldLegendEntry('VD!', 'Voltage drop over limit'));
  // The breaking-capacity + metering conventions, listed only when they were
  // actually drawn on a device / board (N9 / N11) — the kA source may be the
  // chosen device Icu or the prospective fault, so the note states the
  // selection rule the two share (Icu >= fault). // VERIFY.
  if (anyIcuKa) {
    legend.add(const SldLegendEntry(
        'kA', 'Breaking capacity Icu (>= prospective fault at bus)'));
  }
  if (anyMetering) {
    legend
      ..add(const SldLegendEntry('V / A / Hz', 'Panel metering instruments'))
      ..add(const SldLegendEntry('CT', 'Metering current transformer (x/5A)'));
  }

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
  Map<String, double>? breakerIcuKaByPanelId,
}) =>
    buildElectricalSld(
      project: project,
      result: result,
      onlyPanelId: panelId,
      breakerIcuKaByPanelId: breakerIcuKaByPanelId,
    );

/// The utility SOURCE-SPINE only (PLN MV -> [MV main] -> TRANSFORMER -> LV main,
/// + optional GENSET / CAPACITOR BANK), as a standalone `SldSheet` for painting
/// a read-only spine strip ABOVE the root panel on the interactive single-line
/// canvas — ONE source-spine geometry shared with the overview / riser / export
/// (the `_buildSourceSpine` body). `isEmpty` is true when there is no demand AND
/// no sources / dual-tx / explicit transformer, so a bare project shows nothing
/// new on the canvas (the existing PLN head stays).
/// [horizontal] lays the chain out LEFT-TO-RIGHT (PLN -> MV -> transformer -> LV
/// main, genset/capacitor dropping BELOW the LV bus) for the left-to-right
/// interactive single-line canvas — the source sits to the LEFT of the root
/// board and flows right into it. The default vertical layout is used by the
/// top-down overview + the floor-stacked riser.
SldSheet buildElectricalSourceSpine({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  bool horizontal = false,
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

  final spine = horizontal
      ? _buildSourceSpineH(project, result)
      : _buildSourceSpine(project, result, _ovW);
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
      case SldCircle():
        minX = math.min(minX, pr.cx - pr.r);
        minY = math.min(minY, pr.cy - pr.r);
        maxX = math.max(maxX, pr.cx + pr.r);
        maxY = math.max(maxY, pr.cy + pr.r);
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
    // The spine always draws the system-earthing mark (the earth symbol was
    // drawn ⇒ the 'Earth' legend entry is included).
    legend: const [
      SldLegendEntry('Source', 'Utility / MV supply chain'),
      SldLegendEntry('Earth', 'System earthing point'),
    ],
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

/// The feeder cable + breaker (+ run length) annotation for a resolvable feeder,
/// e.g. `NYY 4x50 mm2 · MCCB 250A 3ph · 24 m`. The LENGTH (N8) is the run the
/// solve already used for the feeder (geo-derived when placed, else the manual
/// length) — appended only when a real length exists, never fabricated. Null
/// when the child's feeding circuit or its sized result is unresolved (⇒ omit
/// the label rather than guess). ASCII-safe (the bundled middle dot is allowed).
String? _feederConnLabel(
  Map<String, ElectricalCircuit> feederCircuitOf,
  Map<String, ElectricalCircuitResult> feederResultOf,
  String child,
) {
  final cr = feederResultOf[child];
  final circ = feederCircuitOf[child];
  if (cr == null || circ == null) return null;
  final poles = cr.threePhase ? 3 : 1;
  final length = cr.lengthM > 0 ? ' · ${_num(cr.lengthM)} m' : '';
  return '${cableLabel(circ, cr.cable.csaMm2, cr.threePhase)} mm2 · '
      '${breakerScheduleLabel(cr.breaker, poles)}$length';
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
/// Shared by the overview + riser so their colour split is derived identically,
/// and PUBLIC so the interactive single-line canvas colours essential boards the
/// same red. `result.order` is root-first ⇒ a parent is decided before children.
Set<String> essentialPanelIds(
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

// ── Source-chain schematic SYMBOLS (IEC 60617) ───────────────────────────────
// The utility incoming is a real single-line, not a row of boxes: the
// transformer is the two-winding double circle, the genset a circle-G, the
// capacitor bank the two-plate symbol, the utility a supply circle, and a main
// switchboard a busbar. Each emits sealed [SldPrim]s so the PDF / DXF / canvas
// renderers draw them identically (golden rule 5).

/// A DELTA (triangle, pointing up) winding mark inside a circle at ([cx],[cy]).
void _emitDelta(List<SldPrim> out, double cx, double cy, double r,
    SldRole role) {
  final s = r * 0.62;
  final ax = cx, ay = cy - s; // apex
  final bx = cx - s * 0.87, by = cy + s * 0.5;
  final dx = cx + s * 0.87, dy = cy + s * 0.5;
  out
    ..add(SldLine(ax, ay, bx, by, role: role))
    ..add(SldLine(bx, by, dx, dy, role: role))
    ..add(SldLine(dx, dy, ax, ay, role: role));
}

/// A WYE (star, three legs at 90/210/330°) winding mark inside a circle.
void _emitWye(List<SldPrim> out, double cx, double cy, double r, SldRole role) {
  final s = r * 0.62;
  out
    ..add(SldLine(cx, cy, cx, cy - s, role: role)) // up
    ..add(SldLine(cx, cy, cx - s * 0.87, cy + s * 0.5, role: role)) // down-left
    ..add(SldLine(cx, cy, cx + s * 0.87, cy + s * 0.5, role: role)); // down-right
}

/// Two-winding TRANSFORMER at the two given circle centres (primary = circle 1
/// with a DELTA winding, secondary = circle 2 with a WYE — the Dyn vector group
/// the project transformers use). The spine connectors enter as the leads.
void _emitTransformerPair(List<SldPrim> out, double c1x, double c1y, double c2x,
    double c2y, double r, SldRole role) {
  out
    ..add(SldCircle(c1x, c1y, r, weight: SldWeight.medium, role: role))
    ..add(SldCircle(c2x, c2y, r, weight: SldWeight.medium, role: role));
  _emitDelta(out, c1x, c1y, r, role);
  _emitWye(out, c2x, c2y, r, role);
}

/// Two-winding TRANSFORMER, circles STACKED vertically (primary above), centred
/// on [cx] within the slot [topY..topY+h] — for the vertical overview/riser spine.
void _emitTransformer(
    List<SldPrim> out, double cx, double topY, double h, SldRole role) {
  final r = (h * 0.28).clamp(8.0, 13.0);
  _emitTransformerPair(
      out, cx, topY + h / 2 - r * 0.65, cx, topY + h / 2 + r * 0.65, r, role);
}

/// Utility / MV-incoming BOWTIE (two triangles meeting at a point) — the
/// isolator/incoming symbol on the far left of the DXF, centred at ([cx],[cy]).
void _emitBowtie(List<SldPrim> out, double cx, double cy, double r,
    SldRole role) {
  final t = r * 0.9;
  // Left triangle (apex at centre), right triangle (apex at centre).
  out
    ..add(SldLine(cx - r, cy - t, cx - r, cy + t, weight: SldWeight.medium,
        role: role))
    ..add(SldLine(cx - r, cy - t, cx, cy, role: role))
    ..add(SldLine(cx - r, cy + t, cx, cy, role: role))
    ..add(SldLine(cx + r, cy - t, cx + r, cy + t, weight: SldWeight.medium,
        role: role))
    ..add(SldLine(cx + r, cy - t, cx, cy, role: role))
    ..add(SldLine(cx + r, cy + t, cx, cy, role: role));
}

/// A small labelled PANEL BOX (MVMDP / LVMDP) centred on the baseline — the DXF
/// draws each distribution board as a rectangle, not a busbar.
void _emitPanelBox(List<SldPrim> out, double cx, double cy, double w, double h,
    String label, SldRole role) {
  out.add(SldRect(cx - w / 2, cy - h / 2, w, h, role: role));
  out.add(SldLabel(cx - w / 2 + 5, cy + 3, label,
      size: 8, bold: true, role: role));
}

/// GENERATOR (genset): a circle with a centred "G".
void _emitGenerator(List<SldPrim> out, double cx, double cy, double r,
    SldRole role) {
  out.add(SldCircle(cx, cy, r, weight: SldWeight.medium, role: role));
  out.add(SldLabel(cx - 3.5, cy + 4, 'G', size: 11, bold: true, role: role));
}

/// The IEC 60617 EARTH mark: a short vertical drop lead into three SHORTENING
/// horizontal bars (widest at the top), centred on [cx] with the drop starting
/// at [topY]. Pure [SldLine] prims (no new SldPrim subtype) so the PDF / DXF /
/// canvas renderers draw it identically (golden rule 5).
void _emitEarth(List<SldPrim> out, double cx, double topY, SldRole role) {
  const drop = 9.0; // vertical lead into the bars
  const halfWidths = [8.0, 5.0, 2.0]; // bars narrow toward the bottom
  const barGap = 3.0;
  final barY = topY + drop;
  out.add(SldLine(cx, topY, cx, barY, weight: SldWeight.medium, role: role));
  for (var i = 0; i < halfWidths.length; i++) {
    final y = barY + i * barGap;
    out.add(SldLine(cx - halfWidths[i], y, cx + halfWidths[i], y, role: role));
  }
}

/// CAPACITOR: two parallel plates with leads, centred on ([cx],[cy]).
void _emitCapacitor(List<SldPrim> out, double cx, double cy, SldRole role) {
  const pw = 9.0; // half plate width
  out.add(SldLine(cx - pw, cy - 3, cx + pw, cy - 3,
      weight: SldWeight.medium, role: role));
  out.add(SldLine(cx - pw, cy + 3, cx + pw, cy + 3,
      weight: SldWeight.medium, role: role));
  out.add(SldLine(cx, cy - 11, cx, cy - 3, role: role)); // top lead
  out.add(SldLine(cx, cy + 3, cx, cy + 11, role: role)); // bottom lead
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
  // Each spine element carries its SYMBOL kind so it draws as a real single-line
  // device, not a labelled box.
  final spine = <({String name, String? sub, String kind})>[
    (name: 'PLN MV STATION', sub: null, kind: 'supply'),
    if (hasMv)
      (name: 'PANEL UTAMA TEGANGAN MENENGAH', sub: 'MV main', kind: 'bus'),
    (name: txLabel, sub: null, kind: 'transformer'),
    (name: 'PANEL UTAMA TEGANGAN RENDAH', sub: 'LV main', kind: 'bus'),
  ];

  const role = SldRole.source;
  var y = 0.0;
  double? prevBottom;
  for (final node in spine) {
    final midY = y + _ovH / 2;
    // The vertical riser leg from the previous element's bottom into this one.
    if (prevBottom != null) {
      prims.add(SldLine(centreX, prevBottom, centreX, y,
          weight: SldWeight.medium, role: role));
    }
    switch (node.kind) {
      case 'transformer':
        _emitTransformer(prims, centreX, y, _ovH, role);
        // kVA label to the RIGHT of the windings.
        prims.add(SldLabel(centreX + 22, midY + 3, node.name,
            size: 8.5, bold: true, role: role));
      case 'supply':
        // The MV incoming isolator (bowtie).
        _emitBowtie(prims, centreX, midY, 11, role);
        prims.add(SldLabel(centreX + 22, midY + 3, node.name,
            size: 8.5, bold: true, role: role));
      case 'bus':
      default:
        // A distribution board: a labelled BOX (the DXF convention), with the
        // tier sub below it.
        _emitPanelBox(prims, centreX, midY, _ovW, _ovH - 8, node.name, role);
        if (node.sub != null) {
          prims.add(SldLabel(nodeX, y + _ovH + 1, node.sub!,
              size: 7.5, role: role));
        }
    }
    prevBottom = y + _ovH;
    y += _ovH + _ovHGap;
  }
  final lvBottom = y - _ovHGap; // bottom of the LV-main bus band

  // GENSET + CAPACITOR BANK hang off the LV-main bus to the right.
  final lvMidY = lvBottom - _ovH / 2;
  final sideX = nodeX + _ovW + 60;
  if (project.sources?.generator != null) {
    final gen = project.sources!.generator!;
    final backupVa = ApparentPower(demandVa.voltAmperes * gen.backupFraction);
    final genKva = (gen.kva ?? selectGeneratorKva(backupVa)).inKilovoltAmperes;
    final gy = lvMidY - _ovH - 8;
    final gcy = gy + _ovH / 2;
    _emitGenerator(prims, sideX + 14, gcy, 13, SldRole.source);
    prims.add(SldLabel(sideX + 34, gcy - 2, 'GENSET ${_num(genKva)} kVA',
        size: 8.5, bold: true, role: SldRole.source));
    prims.add(SldLabel(sideX + 34, gcy + 12, gen.mode.label,
        size: 7.5, role: SldRole.source));
    prims.add(SldLine(nodeX + _ovW, gcy, sideX + 1, gcy,
        weight: SldWeight.medium, role: SldRole.source));
  }
  // CAPACITOR BANK: drawn when a real bank is specified (kvar set) OR — kept as
  // the historic proxy — whenever any distributed sources exist. The real field
  // labels its kvar verbatim; the proxy stays the generic "PF correction".
  if (project.capacitorBankKvar != null || project.sources != null) {
    final cy = lvMidY + 8 + _ovH / 2;
    final kvar = project.capacitorBankKvar;
    final capSub =
        (kvar != null && kvar > 0) ? '${_num(kvar)} kvar' : 'PF correction';
    _emitCapacitor(prims, sideX + 14, cy, SldRole.source);
    prims.add(SldLabel(sideX + 34, cy - 2, 'CAPACITOR BANK',
        size: 8.5, bold: true, role: SldRole.source));
    prims.add(SldLabel(sideX + 34, cy + 12, capSub,
        size: 7.5, role: SldRole.source));
    prims.add(SldLine(nodeX + _ovW, cy, sideX + 14, cy,
        weight: SldWeight.medium, role: SldRole.source));
  }

  // System-earthing mark at the LV-main / transformer-secondary — the IEC earth
  // symbol hung to the LEFT of the LV-main bus (the genset / capacitor take the
  // right side), labelled with the installation earthing-system designation.
  final earthX = nodeX - 34;
  prims.add(SldLine(nodeX, lvMidY, earthX, lvMidY,
      weight: SldWeight.medium, role: SldRole.source));
  _emitEarth(prims, earthX, lvMidY, SldRole.source);
  prims.add(SldLabel(earthX - 16, lvMidY + 30, project.earthingSystem.label,
      size: 7.5, bold: true, role: SldRole.source));

  return (prims: prims, height: lvBottom, feedX: centreX, feedY: lvBottom);
}

/// HORIZONTAL (left-to-right) source chain for the interactive single-line
/// canvas: PLN supply -> [MV bus] -> two-winding transformer -> LV-main bus,
/// flowing rightward, with the GENSET / CAPACITOR BANK dropping BELOW the LV bus
/// (so they never collide with the root board placed to the right). The feed
/// anchor is the LV-main board (at the baseline) — the root board connects to
/// it. Uses the compact Indonesian board codes (PLN / MVMDP / LVMDP) since a
/// horizontal chain has no room for the full names; the transformer is the
/// Δ-Y (DyN) two-winding symbol, panels are boxes — matching the EL10011003 DXF.
({List<SldPrim> prims, double height, double feedX, double feedY})
    _buildSourceSpineH(
  ElectricalProject project,
  ElectricalSystemResult result,
) {
  final prims = <SldPrim>[];
  const role = SldRole.source;
  final demandVa = result.supply.demandVa;
  final txKva = project.transformerKva?.inKilovoltAmperes ??
      (demandVa.inKilovoltAmperes > 0
          ? selectGeneratorKva(demandVa).inKilovoltAmperes
          : 0.0);
  final txLabel = txKva > 0 ? 'TRAFO ${_num(txKva)} kVA' : 'TRAFO';
  final hasMv = project.dualTransformer ||
      project.sources != null ||
      project.transformerKva != null;
  final chain = <({String name, String kind})>[
    (name: 'PLN', kind: 'supply'),
    if (hasMv) (name: 'MVMDP', kind: 'bus'),
    (name: txLabel, kind: 'transformer'),
    (name: 'LVMDP', kind: 'bus'),
  ];

  const pitchX = 132.0;
  const yMid = 0.0;
  const boxW = 58.0, boxH = 24.0;
  var x = 0.0;
  double? prevCx;
  double? txSecondaryX; // the transformer-secondary x (for the earthing mark)
  for (final node in chain) {
    if (prevCx != null) {
      prims.add(SldLine(prevCx, yMid, x, yMid,
          weight: SldWeight.medium, role: role));
    }
    switch (node.kind) {
      case 'transformer':
        const r = 11.0;
        _emitTransformerPair(
            prims, x - r * 0.62, yMid, x + r * 0.62, yMid, r, role);
        txSecondaryX = x + r * 0.62;
        prims.add(SldLabel(x - 30, yMid + 28, node.name,
            size: 8, bold: true, role: role));
      case 'supply':
        // MV incoming isolator (bowtie), with the PLN label below.
        _emitBowtie(prims, x, yMid, 11, role);
        prims.add(SldLabel(x - 10, yMid + 26, node.name,
            size: 8.5, bold: true, role: role));
      case 'bus':
      default:
        // A distribution board as a labelled BOX (DXF convention).
        _emitPanelBox(prims, x, yMid, boxW, boxH, node.name, role);
    }
    prevCx = x;
    x += pitchX;
  }
  final lvX = x - pitchX; // the LV-main board (feed-out to the root)

  // GENSET + CAPACITOR drop BELOW the LV bus, STACKED vertically on the bus x
  // with their labels to the RIGHT (clear of the root board, no label overlap).
  final hasGen = project.sources?.generator != null;
  if (hasGen) {
    final gen = project.sources!.generator!;
    final backupVa = ApparentPower(demandVa.voltAmperes * gen.backupFraction);
    final genKva = (gen.kva ?? selectGeneratorKva(backupVa)).inKilovoltAmperes;
    const gcy = yMid + 64;
    prims.add(SldLine(lvX, yMid + 17, lvX, gcy - 13,
        weight: SldWeight.medium, role: role));
    _emitGenerator(prims, lvX, gcy, 13, role);
    // Labels to the LEFT (ending left of the bus x) so they stay clear of the
    // root board placed to the right.
    prims.add(SldLabel(lvX - 104, gcy - 1, 'GENSET ${_num(genKva)} kVA',
        size: 7.5, bold: true, role: role));
    prims.add(SldLabel(lvX - 104, gcy + 11, gen.mode.label, size: 7, role: role));
  }
  if (project.capacitorBankKvar != null || project.sources != null) {
    final kvar = project.capacitorBankKvar;
    final capSub =
        (kvar != null && kvar > 0) ? '${_num(kvar)} kvar' : 'PF correction';
    final ccy = hasGen ? yMid + 122 : yMid + 64;
    final dropFrom = hasGen ? yMid + 77 : yMid + 17;
    prims.add(SldLine(lvX, dropFrom, lvX, ccy - 11,
        weight: SldWeight.medium, role: role));
    _emitCapacitor(prims, lvX, ccy, role);
    prims.add(SldLabel(lvX - 96, ccy + 2, 'CAP $capSub',
        size: 7.5, bold: true, role: role));
  }

  // System-earthing mark at the transformer secondary — the IEC earth symbol
  // dropping BELOW the secondary winding (clear of the genset / capacitor that
  // hang under the LV bus to the right), labelled with the installation
  // earthing-system designation. Placed at the transformer only when one is
  // drawn (it always is, so this mirrors the vertical spine).
  if (txSecondaryX != null) {
    const eTop = yMid + 40; // below the TRAFO label at yMid+28
    prims.add(SldLine(txSecondaryX, yMid + 11, txSecondaryX, eTop,
        weight: SldWeight.medium, role: role));
    _emitEarth(prims, txSecondaryX, eTop, role);
    prims.add(SldLabel(txSecondaryX + 12, eTop + 8, project.earthingSystem.label,
        size: 7, bold: true, role: role));
  }

  return (prims: prims, height: yMid, feedX: lvX, feedY: yMid);
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
  final essential = essentialPanelIds(project, result);

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
        case SldCircle():
          minX = math.min(minX, pr.cx - pr.r);
          minY = math.min(minY, pr.cy - pr.r);
          maxX = math.max(maxX, pr.cx + pr.r);
          maxY = math.max(maxY, pr.cy + pr.r);
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
      // The source spine draws the system-earthing mark, so surface it too.
      if (sourceChain) const SldLegendEntry('Earth', 'System earthing point'),
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

/// Truncate a fan-out circuit NAME to [maxLen] characters total (the same
/// on-canvas width budget the old bare `substring(0, 14)` used), but cut on a
/// word boundary and append an ASCII ellipsis when the name is shortened —
/// never a bare mid-word chop like the old 'Lighting groun' / 'Power socke'.
/// Falls back to a hard cut (still budgeted so the total stays <= [maxLen])
/// only when no reasonable word boundary exists (e.g. one long unbroken
/// token). (H5)
String _fanOutLabel(String name, {int maxLen = 14}) {
  if (name.length <= maxLen) return name;
  const ellipsis = '...';
  final budget = maxLen - ellipsis.length;
  if (budget <= 0) return name.substring(0, maxLen);
  final lastSpace = name.lastIndexOf(' ', budget);
  // Only honour the word boundary when it keeps a meaningful chunk of the
  // name (else a boundary right at the start would truncate harder than a
  // plain hard cut for no readability gain).
  final cut = lastSpace >= (budget * 0.4).floor() ? lastSpace : budget;
  return '${name.substring(0, cut).trimRight()}$ellipsis';
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
  final essential = essentialPanelIds(project, result);
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
      final nm = _fanOutLabel(cr.name);
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
      case SldCircle():
        minY = math.min(minY, pr.cy - pr.r);
        maxY = math.max(maxY, pr.cy + pr.r);
        maxX = math.max(maxX, pr.cx + pr.r);
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
      // The source spine draws the system-earthing mark, so surface it too.
      if (sourceChain) const SldLegendEntry('Earth', 'System earthing point'),
    ],
    supplyNote: supplyNote,
  );
}

// ── Hybrid POWER one-line (C7) ───────────────────────────────────────────────

/// Node footprint + tier geometry for the power one-line.
const double _polW = 172;
const double _polH = 44;
const double _polSymR = 14; // generator / utility symbol radius
const double _polGapX = 44; // horizontal gap between siblings in a tier
const double _polTierH = 120; // vertical pitch between tiers

/// The label (name + optional sub) beside a SYMBOL node (utility / generator),
/// placed to the right of the glyph so all content stays inside the footprint.
void _polSymLabel(
    List<SldPrim> out, double x, double cy, PowerNode n, SldRole role) {
  out.add(SldLabel(x, cy - 3, n.label, size: 9, bold: true, role: role));
  if (n.sub != null && n.sub!.isNotEmpty) {
    out.add(SldLabel(x, cy + 9, n.sub!, size: 7, role: role));
  }
}

/// Build the hybrid power one-line ([PowerOneLine]) as an [SldSheet] on the
/// shared drawing pipeline (C7) — the fourth electrical output, now rendered
/// identically by the PDF + DXF exporters via their prebuilt-`sheet` params
/// (replacing the old centre-to-centre wireframe grid).
///
/// Nodes are laid out top-down in longest-path TIERS from the supply roots
/// (utility / generator / PV / battery) and wired edge-to-edge with the same
/// orthogonal 3-segment feeder routing the overview uses. Source equipment
/// reuses the IEC symbol emitters — the utility a BOWTIE, a generator the
/// G-in-a-circle — and every other node (buses, inverters, PV/battery, main
/// panel) is a labelled board box. Every SUPPLY node carries `SldRole.source`;
/// only the main panel (the load side) is `normal`, so a renderer's role-colour
/// split reads the supply chain as one.
SldSheet buildPowerOneLineSheet(PowerOneLine oneLine) {
  final nodes = oneLine.nodes;
  final byId = {for (final n in nodes) n.id: n};

  // Longest-path tier from the roots (a node with no incoming edge). The model
  // is a DAG by construction; a per-node iteration cap guards any accidental
  // cycle so relaxation always terminates.
  final tier = <String, int>{for (final n in nodes) n.id: 0};
  for (var pass = 0; pass < nodes.length; pass++) {
    var changed = false;
    for (final e in oneLine.edges) {
      if (!byId.containsKey(e.from) || !byId.containsKey(e.to)) continue;
      final want = tier[e.from]! + 1;
      if (want > tier[e.to]!) {
        tier[e.to] = want;
        changed = true;
      }
    }
    if (!changed) break;
  }

  // Group node ids by tier (insertion order preserved for stable packing).
  final maxTier = tier.values.isEmpty ? 0 : tier.values.reduce(math.max);
  final byTier = <int, List<String>>{};
  for (final n in nodes) {
    (byTier[tier[n.id]!] ??= []).add(n.id);
  }

  // Place: x by index within the tier, y by tier (top-left of each footprint).
  final pos = <String, ({double x, double y})>{};
  for (var t = 0; t <= maxTier; t++) {
    final row = byTier[t] ?? const [];
    for (var i = 0; i < row.length; i++) {
      pos[row[i]] = (x: i * (_polW + _polGapX), y: t * _polTierH);
    }
  }

  final prims = <SldPrim>[];

  // Edges first (under the node graphics): the overview orthogonal 3-segment
  // route — source bottom-centre down to a mid line, across, then down into the
  // target top-centre. The role follows the TARGET: the run into the main panel
  // (the load side) is normal, everything else is a supply run.
  for (final e in oneLine.edges) {
    final a = pos[e.from];
    final z = pos[e.to];
    if (a == null || z == null) continue;
    final role = byId[e.to]!.kind == PowerNodeKind.mainPanel
        ? SldRole.normal
        : SldRole.source;
    final ax = a.x + _polW / 2;
    final ay = a.y + _polH;
    final zx = z.x + _polW / 2;
    final zy = z.y;
    final midY = (ay + zy) / 2;
    prims
      ..add(SldLine(ax, ay, ax, midY, weight: SldWeight.medium, role: role))
      ..add(SldLine(ax, midY, zx, midY, weight: SldWeight.medium, role: role))
      ..add(SldLine(zx, midY, zx, zy, weight: SldWeight.medium, role: role));
    if (e.label != null && e.label!.isNotEmpty) {
      prims.add(SldLabel(math.min(ax, zx) + 4, midY - 4, e.label!,
          size: 6.5, role: role));
    }
  }

  // Nodes: source symbols reuse the IEC emitters; every other node is a box.
  for (final n in nodes) {
    final at = pos[n.id]!;
    final role =
        n.kind == PowerNodeKind.mainPanel ? SldRole.normal : SldRole.source;
    final cx = at.x + _polW / 2;
    final cy = at.y + _polH / 2;
    switch (n.kind) {
      case PowerNodeKind.utility:
        final symX = at.x + _polSymR + 8;
        _emitBowtie(prims, symX, cy, _polSymR, role);
        _polSymLabel(prims, symX + _polSymR + 12, cy, n, role);
      case PowerNodeKind.generator:
        final symX = at.x + _polSymR + 8;
        _emitGenerator(prims, symX, cy, _polSymR, role);
        _polSymLabel(prims, symX + _polSymR + 12, cy, n, role);
      default:
        _emitPanelBox(prims, cx, cy, _polW, _polH, n.label, role);
        if (n.sub != null && n.sub!.isNotEmpty) {
          prims.add(SldLabel(at.x + 5, at.y + _polH + 11, n.sub!,
              size: 7, role: role));
        }
    }
  }

  // ── Bounds ─────────────────────────────────────────────────────────────────
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final pr in prims) {
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
        maxY = math.max(maxY, pr.y);
      case SldCircle():
        minX = math.min(minX, pr.cx - pr.r);
        minY = math.min(minY, pr.cy - pr.r);
        maxX = math.max(maxX, pr.cx + pr.r);
        maxY = math.max(maxY, pr.cy + pr.r);
    }
  }
  if (!minX.isFinite) {
    minX = 0;
    minY = 0;
    maxX = 1;
    maxY = 1;
  }

  // Supply note lists the present sources, honestly (no invented content).
  final present = <String>[
    if (oneLine.nodeOfKind(PowerNodeKind.utility) != null) 'PLN utility',
    if (oneLine.nodeOfKind(PowerNodeKind.generator) != null) 'genset',
    if (oneLine.nodeOfKind(PowerNodeKind.pv) != null) 'PV',
    if (oneLine.nodeOfKind(PowerNodeKind.battery) != null) 'battery',
  ];
  final supplyNote =
      'Power one-line - ${present.isEmpty ? 'no sources' : present.join(' / ')}';

  return SldSheet(
    prims: prims,
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
    legend: const [
      SldLegendEntry('Source', 'Supply source / equipment'),
      SldLegendEntry('G', 'Standby generator (genset)'),
      SldLegendEntry('Board', 'Distribution board / bus'),
    ],
    supplyNote: supplyNote,
  );
}
