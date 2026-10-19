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
import '../electrical/containment.dart'
    show ConduitSpec, conduitFillSingle, sizeConduit;
import '../electrical/control/starter.dart' show StarterType;
import '../electrical/earthing.dart'
    show EarthingSystemInfo, groupedConductorMakeup;
import '../electrical/genset_backup.dart'
    show gensetBackupDemandVa, gensetBackupDemandW, isEssentialByName;
import '../electrical/load_kind.dart' show LoadKind;
import '../electrical/metering.dart' show MeteringKind, meterFor;
import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import '../electrical/power_oneline.dart';
import '../electrical/results.dart' show BreakerResult;
import '../electrical/sources.dart'
    show
        BatteryChemistryInfo,
        GeneratorModeInfo,
        kGeneratorPf,
        selectGeneratorUnits,
        GeneratorSource,
        sizeGenerator,
        sizeBattery;
import '../electrical/supply_design.dart' show serviceTransformer;
import '../geometry/building.dart' show BuildingLevels, MountingHeights;
import '../standards/puil.dart'
    show BreakerCurve, BreakerClass, BreakerClassCode;
import '../units.dart' show ApparentPower, Current, Length, Power;
import 'drawing_chrome.dart' show helveticaTextWidth;
import 'number_format.dart' show groupThousands, signedElevationText;
import 'plan_symbols.dart' show planLengthLabel;
import 'sld_sheet.dart';

// The drawing-primitive types (SldSheet / SldPrim / SldLine / SldRect /
// SldLabel / SldCircle / SldLegendEntry / SldWeight / SldRole) now live in the
// discipline-neutral `sld_sheet.dart`; re-exported so existing importers of this
// file (the PDF/DXF exporters, the canvas painter) keep their single import.
export '../electrical/panel_results.dart'
    show kIncomerOverRangeToken, incomerOverRangeSuffix;
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
// Round 14 (drafting-visual-8) — 89, not 92: the bold 7-pt 'GRUP' head is
// 2.889 em = 20.2 wide, so at 92 it ran to 112.2, past the DEVICE rule at
// _colDevice - 6 = 110 (the rule struck through its 'P'). At 89 it ends at
// 109.2, and the row breaker symbol (bx + 28 .. + _brW = 87) still clears it.
const double _colGrup = 89; // way no (W1) — clears the breaker stub + symbol
const double _colDevice = 116; // breaker (MCB 16A 1ph[ 16kA][ · RCD 30mA A])
const double _colPenghantar =
    252; // conductor + conduit + length (NYY 4x6 · 22 m)
const double _colDaya = 474; // connected load (DAYA, W/kW)
const double _colKeterangan = 534; // load name / -> sub-panel
// The R / S / T per-phase loading band: THREE EQUAL ruled cells spanning from
// the band's left divider to the grid's right edge (where the row rules stop).
// Equal thirds matter — the three cells hold the same kind of figure, so an
// odd one out (the T cell used to run to the grid edge at twice the width of
// R and S) throws the whole band off its own column heads.
const double _phaseBandL = 748; // divider left of the R cell
const double _phaseBandR = _blockW - 8; // grid right edge (row-rule end)
const double _phaseCellW = (_phaseBandR - _phaseBandL) / 3;
const double _cellRL = _phaseBandL, _cellRR = _phaseBandL + _phaseCellW;
const double _cellSL = _cellRR, _cellSR = _phaseBandL + 2 * _phaseCellW;
const double _cellTL = _cellSR, _cellTR = _phaseBandR;

/// CENTRE a short numeric figure in a ruled cell. Every text column is
/// left-anchored (the BRI `Diagram Panel` convention for prose cells), but the
/// R/S/T phase-loading band is a run of narrow ruled BOXES — a left-anchored
/// current figure hugs its divider and reads as mis-set. Centring is done here
/// with build-time arithmetic (estimated glyph advance ~0.5 em, within a pixel
/// for these short digit strings) so the ONE geometry stays authoritative and
/// every renderer (canvas / PDF / DXF) agrees — no renderer re-measures text.
double _centredInCell(double leftX, double rightX, String text, double size) =>
    (leftX + rightX) / 2 - text.length * size * 0.25;

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// Round 20 (drafting-visual-4-7) — a CURRENT figure in a ruled schedule
/// column (the R/S/T cells, the TOTAL phase totals, the header / TOTAL
/// demand currents): ONE fixed 0.1 A precision, so '13.0' sits beside '14.8'
/// instead of a bare '13' that reads as a differently rounded quantity.
String _amps(double v) => v.toStringAsFixed(1);

/// Round 20 (drafting-visual-4-4) — whether any primitive is drawn in the
/// ESSENTIAL role: the overview / riser legend keys 'Essential' only when the
/// sheet shows an essential board or feeder.
bool _anyEssentialPrim(List<SldPrim> prims) => prims.any((p) => switch (p) {
      SldLine(:final role) => role == SldRole.essential,
      SldRect(:final role) => role == SldRole.essential,
      SldLabel(:final role) => role == SldRole.essential,
      SldCircle(:final role) => role == SldRole.essential,
    });

/// A connected-load (DAYA) figure: `W` under 1 kW, else `kW`.
String _watts(double w) => w >= 1000 ? '${_num(w / 1000)}kW' : '${_num(w)}W';

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

/// The KETERANGAN meaning of a [_starterCode] token (drafting-8).
String _starterMeaning(StarterType s) => switch (s) {
      StarterType.dol => 'Direct-on-line starter',
      StarterType.starDelta => 'Star-delta starter',
      StarterType.reversing => 'Reversing starter',
      StarterType.softStarter => 'Soft starter',
      StarterType.vfd => 'Variable-frequency drive',
      StarterType.ats => 'Automatic transfer switch',
      StarterType.pump => 'Pump control panel',
    };

String _curveCode(BreakerCurve c) => switch (c) {
      BreakerCurve.b => 'B',
      BreakerCurve.c => 'C',
      BreakerCurve.d => 'D',
    };

String _classCode(BreakerClass c) => c.code;

/// A breaker label like `MCB C16A/1P` — the curve-led form (kept for the
/// incomer sub-line + the device legend so the trip curve stays surfaced).
///
/// The trip-curve letter is emitted ONLY for MCBs. A moulded-case breaker is
/// specified by frame / trip / breaking capacity, NOT by a fixed B/C/D
/// characteristic, so `MCCB C160A/4P` is not a valid designation — an MCCB reads
/// `MCCB 160A/4P` (N12).
String breakerLabel(BreakerResult b, int poles) {
  final curve = b.deviceClass.hasTripCurve ? _curveCode(b.curve) : '';
  return '${_classCode(b.deviceClass)} $curve'
      '${_num(b.ratingA.amperes)}A/${poles}P';
}

/// A panel-SCHEDULE breaker label leading with rating + phase count, e.g.
/// `MCB 16A 1ph` / `MCCB 40A 3ph` — the real Indonesian DIAGRAM PANEL form
/// (rating + phase first; the trip curve is secondary, surfaced via the incomer
/// sub-line + legend). `poles` is the way's pole count (1 or 3). ASCII-safe
/// (`ph`, not the unicode phase glyph) so it never renders as tofu.
///
/// E8b: a SINGLE-PHASE FEEDER leaving a three-phase board is specified by its
/// POLE count, not its phase count — the device is a 2-pole (L + N) breaker, the
/// same `2P` the overview node already prints. [twoPole] switches that one case
/// to `MCCB 80A 2P`; every ordinary single-phase FINAL way keeps `1ph`.
String breakerScheduleLabel(BreakerResult b, int poles,
        {bool twoPole = false}) =>
    '${_classCode(b.deviceClass)} ${_num(b.ratingA.amperes)}A '
    '${twoPole ? '2P' : '${poles}ph'}';

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
/// on tray / cable-ladder; the schedule then prints an explicit `tray` route
/// token instead, H6). A 3-phase run (5-core) bumps up one trade size for the
/// extra cores.
///
/// E2/E8c: the CSA ladder alone could name a PHYSICALLY IMPOSSIBLE conduit (a
/// 5×70 mm² run does not go into 50 mm), so the ladder pick is now checked
/// against the containment module's OWN geometry — `sizeConduit` (estimated
/// cable OD vs the standard bores at the `conduitFillSingle` limit), imported,
/// not re-derived — and RAISED to whatever that fill check demands. The result
/// is therefore never smaller than the ladder (so a run whose ladder pick
/// already satisfies the fill stays byte-identical) and never smaller than the
/// physics. When the cable does not fit the largest standard conduit at all,
/// null is returned ⇒ the row prints `tray`, agreeing with the containment
/// study instead of contradicting it.
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
  final ladder = (!threePhase || base >= 50)
      ? base
      : switch (base) { 20 => 25, 25 => 32, 32 => 40, 40 => 50, _ => base };
  final fill = _conduitFromSpec(sizeConduit(csaMm2, threePhase ? 5 : 3));
  // No standard conduit holds the cable ⇒ tray (never a fabricated size).
  if (fill == null) return null;
  return math.max(ladder, fill);
}

/// The conduit trade size (mm) a containment [ConduitSpec] actually issues, or
/// null when even the largest standard conduit is over the single-cable fill
/// limit (⇒ the run is a tray/ladder run, not a conduit run). Shared by the
/// fill-aware fallback above and the study-fed token below so the two can never
/// disagree about what "no conduit" means.
int? _conduitFromSpec(ConduitSpec spec) =>
    spec.fillPct > conduitFillSingle * 100 ? null : spec.conduitSizeMm.round();

/// A cable label like `NYM 3x2.5` — the family from the circuit's explicit
/// [ElectricalCircuit.cableType] when set, else the conventional default for its
/// load kind ([defaultCableFamily]: NYM for final circuits, NYY otherwise) so a
/// drawing always names a real cable construction, never the bare conductor
/// material.
///
/// G5 — [cores] is the REAL conductor count the sizing already resolved
/// (`ElectricalCircuitResult.grounding.cores` = live cores + neutral (when the
/// circuit has one) + PE), so a 3-phase way with NO neutral (a motor: 3L+PE)
/// labels `4x`, one with a neutral `5x`, and a 1-phase way `3x` (L+N+PE) — the
/// same count the containment study sizes the conduit from
/// (`cableOuterDiameterMm(csa, grounding.cores)`), so the label can no longer
/// contradict the containment basis printed beside it.
///
/// Null [cores] keeps the drawing convention (3 for 1-phase, 5 for 3-phase) for
/// callers with no sized grounding to hand ⇒ byte-identical.
///
/// CONVENTION: this label is the earth-IN-the-cable form. Where the drawing
/// prints the protective earth as a SEPARATE conductor (`+ NYA/BC <csa> mm2`,
/// the BRI schedule convention), callers go through [_cableSpecWithEarth],
/// which passes `cores - 1` so the PE is never specified twice.
///
/// Round 19 (electrical-parity-2-cable-makeup-label-vs-bom) — the conductor
/// MAKE-UP, not just the count: `sizeGrounding` reduces the PE (and may reduce
/// the neutral) once the phase conductor exceeds 16 mm², and the BOM orders
/// that make-up (`NYY 4×35 + 16 mm²`). Passing the solved [peCsaMm2] /
/// [neutralCsaMm2] groups equal conductors exactly as `sizeGrounding` does,
/// ASCII-safe: `NYY 4x35+16` (never `5x35` — that is 19 mm² of copper per
/// metre the take-off does not buy, and a PE the ADS check never saw). Absent
/// or equal to the phase section ⇒ `NYY 5x16` (byte-identical).
String cableLabel(ElectricalCircuit? circuit, double csaMm2, bool threePhase,
    {int? cores, double? peCsaMm2, double? neutralCsaMm2}) {
  final family = resolvedCableFamily(circuit);
  final n = (cores != null && cores > 0) ? cores : (threePhase ? 5 : 3);
  final live = threePhase ? 3 : 1;
  final hasPe = peCsaMm2 != null && peCsaMm2 > 0;
  final hasNeutral = n - live - (hasPe ? 1 : 0) >= 1;
  final pe = hasPe ? peCsaMm2 : csaMm2;
  final neutral =
      (neutralCsaMm2 != null && neutralCsaMm2 > 0) ? neutralCsaMm2 : csaMm2;
  final conductors = <double>[
    for (var i = 0; i < live; i++) csaMm2,
    if (hasNeutral) neutral,
    if (hasPe) pe,
  ];
  if (conductors.length != n || conductors.every((c) => c == csaMm2)) {
    return '$family ${n}x${_num(csaMm2)}';
  }
  final makeup =
      groupedConductorMakeup(conductors, _num, times: 'x', separator: '+');
  return '$family $makeup';
}

/// Round 19 (electrical-parity-2-board-demand-current-undiversified) — a
/// board's demand CURRENT as printed beside its diversified kW: a diversified
/// board prints the diversified worst-phase current (the basis its feeder is
/// judged on) and labels the undiversified sizing current
/// (`15.8A div (max ph 17.5A undiv)`); a board with no diversity prints the
/// one figure exactly as before (`17.5A`).
String _boardDemandCurrent(ElectricalPanelResult p) {
  final undiv = _amps(p.demandCurrent.amperes);
  if (!p.isDiversified) return '${_amps(p.demandCurrent.amperes)}A';
  final div = _amps(p.diversifiedDemandCurrent.amperes);
  return '${div}A div (max ph ${undiv}A undiv)';
}

/// The full PENGHANTAR conductor label WITH its unit and parallel-run count:
/// `NYY 5x16 mm2` for a single cable, `2x(NYY 5x185 mm2)` when the sizer
/// paralleled [runs] cables per phase ([CableResult.runsPerPhase]). A paralleled
/// way pulls N complete cables (and the containment issues N conduits), so a
/// label naming ONE cable under-states the take-off by N. [cores] is
/// `grounding.cores` — live + neutral + PE, i.e. the PE travels INSIDE the
/// cable, exactly as the earthing model sizes it and the BOM procures it — so
/// no separate earth conductor is appended (that would specify the PE twice,
/// audit 2026-10 reports-2 / drafting-1). The ONE notation the board schedule,
/// the overview/riser feeder labels, the live canvas feeder label and the
/// inspector all print, so the formats can never disagree with the take-off.
/// Null / <= 1 [runs] ⇒ exactly `${cableLabel(...)} mm2` (byte-identical).
String cableRunLabel(ElectricalCircuit? circuit, double csaMm2, bool threePhase,
    {int? cores, int? runs, double? peCsaMm2, double? neutralCsaMm2}) {
  final single =
      '${cableLabel(circuit, csaMm2, threePhase, cores: cores, peCsaMm2: peCsaMm2, neutralCsaMm2: neutralCsaMm2)} mm2';
  return (runs != null && runs > 1) ? '${runs}x($single)' : single;
}

/// The cable family a circuit's label/legend should show: its explicit
/// `cableType` when set, else the convention default for its load kind.
String resolvedCableFamily(ElectricalCircuit? circuit) =>
    (circuit?.cableType != null && circuit!.cableType!.isNotEmpty)
        ? circuit.cableType!
        : defaultCableFamily(circuit?.loadKind);

/// The board's METERING token on the schedule header (N11, Round 15
/// elec-props-3-ct-token-two-ladders): driven by the ONE metering spec the
/// advanced study prints ([meterFor] — its CT primary ladder, its revenue
/// accuracy class, its direct-metering limit), so the schedule and the study
/// can never name two different CT ratios / classes for the same board:
/// `CT <ratio>A cl.<class>` when CT-operated, else `kWh direct`.
String _ctLabel(double meteringA) {
  final spec = meterFor(Current(meteringA));
  if (spec.metering == MeteringKind.direct) return 'kWh direct';
  return 'CT ${spec.ctRatio}A cl.${spec.ctClass}';
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
///
/// [breakerKaByCircuitId] (E1) maps a CIRCUIT id → that way's OWN device
/// breaking capacity (the fault study's `fault.circuits[id].breakerKa`, snapped
/// to the ladder of the way's own device class). A panel map is one figure for
/// the whole board — the INCOMER's frame ladder — so a board with an MCCB
/// incomer stamped `16kA` on its MCB ways, a rating no MCB is built to. When
/// this map carries the way, it WINS for that way's DEVICE cell; the panel map
/// stays the fallback (and still drives the INCOMER sub-line), so an existing
/// caller that passes only the panel map is byte-identical.
///
/// [containmentByCircuitId] (E2/E8c) maps a CIRCUIT id → the containment
/// study's own `ConduitSpec` for that run. When present, the PENGHANTAR cell
/// prints the STUDY's conduit trade size (or `tray` when the cable exceeds the
/// largest standard conduit at the study's fill limit) instead of the local CSA
/// ladder, so the schedule and the containment take-off can never contradict
/// each other on the same run. Absent ⇒ the (now fill-aware) ladder.
SldSheet buildElectricalSld({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  String? onlyPanelId,
  Map<String, double>? breakerIcuKaByPanelId,
  Map<String, double>? breakerKaByCircuitId,
  Map<String, ConduitSpec>? containmentByCircuitId,
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
      : [
          for (final id in result.order)
            if (id == onlyPanelId) id
        ];

  final prims = <SldPrim>[];
  final usedCurves = <BreakerCurve>{};
  final usedClasses = <BreakerClass>{};
  final usedFamilies = <String>{};
  // Whether any device carried a breaking capacity (N9) / any board drew a
  // metering cluster (N11) — drives the matching KETERANGAN legend entries.
  var anyIcuKa = false;
  var anyMetering = false;
  // drafting-8: the row tokens actually printed (starter / RCD / conduit /
  // tray), so the KETERANGAN keys every abbreviation the schedule uses.
  final usedStarters = <StarterType>{};
  var anyRcd = false;
  var anyConduit = false;
  var anyTray = false;

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
        'Incomer ${breakerLabel(p.incomer.breaker, p.incomer.poles)}$kaSuffix'
        '${incomerOverRangeSuffix(p.incomer)}  '
        '${p.system.label}  ${_num(v)}V  '
        'Cu bus ${_num(p.busbar.csaMm2)}mm2$icw  '
        'demand ${_boardDemandCurrent(p)}',
        size: 8));
    // The trip-curve legend is about MCB characteristics only — an MCCB carries
    // no B/C/D curve (N12), so don't seed a curve legend entry from one.
    if (p.incomer.breaker.deviceClass.hasTripCurve) {
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
      // The metering CT ratio (N11): the next standard primary above the
      // board's METERING current over a 5 A secondary + the metering accuracy
      // class, e.g. `CT 200/5A cl.1` — replaces the bare `CT` glyph. Round 14:
      // the metering current is the larger of the demand and the current the
      // incomer/busbar were sized for (`meteringCurrent`), so a daya-floored
      // entrance board never prints a CT that saturates at subscribed load.
      prims.add(SldLabel(
          mx + 4, blockY + my + 13, _ctLabel(p.meteringCurrent.amperes),
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

    // Column-header band (slot 0): the BRI `Diagram Panel` table columns. The
    // R / S / T headers carry their PHASE role so every renderer colours the
    // three phase columns apart (red / yellow / blue — see [SldRole]).
    //
    // Round 20 (drafting-visual-4-8) — the heads sit with the SAME clearance
    // over their rule as every body row's figures (baseline 7 above the
    // rule): the old busTop + 19 put the 7-pt caps 1 unit above the
    // underline at busTop + 20, so they read as underlined text on it.
    final headY = busTop + _rowH - 7;
    void colHead(double x, String t, {SldRole role = SldRole.normal}) => prims
        .add(SldLabel(blockX + x, headY, t, size: 7, bold: true, role: role));
    colHead(_colGrup, 'GRUP');
    colHead(_colDevice, 'DEVICE');
    colHead(_colPenghantar, 'PENGHANTAR');
    colHead(_colDaya, 'DAYA');
    colHead(_colKeterangan, 'KETERANGAN');
    // The R/S/T heads sit centred over their ruled cells, like the figures.
    colHead(_centredInCell(_cellRL, _cellRR, 'R', 7), 'R',
        role: SldRole.phaseR);
    colHead(_centredInCell(_cellSL, _cellSR, 'S', 7), 'S',
        role: SldRole.phaseS);
    colHead(_centredInCell(_cellTL, _cellTR, 'T', 7), 'T',
        role: SldRole.phaseT);
    // Underline under the column-header row.
    prims.add(
        SldLine(bx + 4, busTop + _rowH, blockX + _blockW - 8, busTop + _rowH));
    // Ruled table verticals — the BRI `Diagram Panel` schedule is a fully
    // ruled grid, not whitespace-aligned text. A thin separator 6 px left of
    // each PROSE column, then the phase band's own equal-cell dividers,
    // spanning the header band + every body row.
    for (final ruleX in const [
      _colDevice - 6,
      _colPenghantar - 6,
      _colDaya - 6,
      _colKeterangan - 6,
      _cellRL,
      _cellSL,
      _cellTL,
    ]) {
      prims.add(SldLine(blockX + ruleX, busTop, blockX + ruleX, busBot));
    }

    // One ROW per way, in ALIGNED columns: GRUP (way no) | DEVICE (breaker,
    // rating + phase first) | PENGHANTAR (cable family + cores x CSA — the core
    // count INCLUDES the PE core, so no separate earth conductor is added) | DAYA (connected W/kW) | KETERANGAN (load name / -> sub-panel) |
    // R/S/T (the line current on the way's phase(s) — the phase-loading band).
    const rowSize = 7.5;
    for (var i = 0; i < ways; i++) {
      final c = p.circuits[i];
      final slot = 1 + i; // +1 for the column-header row
      final rowY = busTop + 6 + slot * _rowH + _rowH / 2;
      // Stub from bus to breaker + the breaker symbol.
      prims.add(SldLine(bx + 4, rowY, bx + 28, rowY));
      prims.add(SldRect(bx + 28, rowY - _brH / 2, _brW, _brH));
      // Round 20 (drafting-visual-4-4) — a way's schedule label prints NO
      // curve letter (rating + phase first), so its curve is not keyed; only
      // the incomer sub-line's curve (added where it is printed) is.
      usedClasses.add(c.breaker.deviceClass);
      final circuit = circuitById[c.circuitId];
      // Surface the cable family actually drawn (the explicit type, else the
      // convention default) so the KETERANGAN legend matches the rows.
      usedFamilies.add(resolvedCableFamily(circuit));
      final poles = c.threePhase ? 3 : 1;
      final feeds = circuit?.feedsPanelId;
      final keterangan =
          feeds != null ? '-> ${result.panels[feeds]?.name ?? feeds}' : c.name;
      // G5 — FIRE-DUTY PROTECTION reaches the deliverable. A life-safety
      // motor/pump way is protected differently under fire duty (locked-rotor
      // rated, overload trip disabled / alarm-only); the engine has no data for
      // that controller and will not fabricate one, so the schedule the panel
      // builder works from carries the SPEC token instead. Gated on exactly the
      // condition behind `compute.dart`'s `fire-pump-protection` INFO note
      // (`lifeSafety && motorLike`), so the note and the sheet can never
      // disagree; any other way is byte-identical.
      // VERIFY — notAnSniClause: NFPA 20 fire-pump controller practice.
      final fireDuty = circuit != null &&
              circuit.lifeSafety &&
              (circuit.loadKind == LoadKind.motor ||
                  circuit.loadKind == LoadKind.pump)
          ? ' · no-OL trip (fire)'
          : '';
      // `VD!` on the SAME gate as compute.dart's warnings: the way's OWN drop
      // over its limit, OR (a final way, never a feeder — a feeder's cumulative
      // is the sub-bus drop its downstream ways already carry) the CUMULATIVE
      // drop from the origin over the limit (`cumulative-voltage-drop-exceeded`).
      // The schedule must never call a way fine that the calc report fails.
      final vd =
          voltageDropOverLimit(c, isFeeder: feeds != null) ? '  VD!' : '';
      // E2: the containment STUDY's own result for this run wins when supplied
      // (one containment source for the schedule + the take-off); else the
      // fill-aware ladder. Both return null for a cable no standard conduit
      // holds ⇒ `tray`.
      final studySpec = containmentByCircuitId?[c.circuitId];
      final conduitMm = studySpec != null
          ? _conduitFromSpec(studySpec)
          : _conduitMm(c.cable.csaMm2, c.threePhase);
      // H6: a way whose conductor exceeds the conduit range runs on cable tray /
      // ladder, not in conduit — print an explicit `tray` route token so EVERY
      // row states a route method (the code's own convention; never a silent
      // blank next to neighbours that show `· PVC NNmm`).
      // // VERIFY — a drawing convention (the model carries no containment field).
      // A way sized as N parallel runs lays N cables, each in its own conduit
      // (the containment study's `CircuitConduit.count`) ⇒ `· 2x PVC 50mm`, so
      // the token can never under-count the conduits to procure. A single run
      // keeps the bare token (byte-identical).
      final runs = (c.cable.runsPerPhase ?? 1) > 1 ? c.cable.runsPerPhase! : 1;
      final conduitCount = runs > 1 ? '${runs}x ' : '';
      final conduit = conduitMm != null
          ? ' · ${conduitCount}PVC ${conduitMm}mm'
          : ' · tray';
      if (conduitMm != null) {
        anyConduit = true;
      } else {
        anyTray = true;
      }
      // The run LENGTH the solve already used for this way (geo-derived when
      // placed, else the manual circuit length) — the cable-takeoff figure that
      // also drove the printed Vdrop (N8). Printed ONLY when a real length
      // exists (never fabricated); the ` m` suffix disambiguates it from the
      // `mm` conduit token.
      final length =
          c.lengthM > 0 ? ' · ${planLengthLabel(Length(c.lengthM))}' : '';
      final cable =
          '${cableRunLabel(circuit, c.cable.csaMm2, c.threePhase, cores: c.grounding.cores, runs: c.cable.runsPerPhase, peCsaMm2: c.grounding.peCsaMm2, neutralCsaMm2: c.grounding.neutralCsaMm2)}'
          '$conduit$length';
      // DAYA in WATT (integer, dot thousands separator); a feeder (loadW 0) → '-'.
      // Round 19 — a capacitor way's loadW is its REACTIVE rating, so it prints
      // in kvar, never as WATT.
      final isCapacitor = c.loadKind == LoadKind.capacitor;
      final kvar = isCapacitor ? (circuit?.loadW ?? c.loadW) : 0.0;
      final daya = isCapacitor && kvar > 0
          ? '${_num(kvar / 1000)} kvar'
          // Round 25 — the CONNECTED daya (before the demand factor); the
          // TOTAL footer carries the diversified demand.
          : (c.connectedWOrLoad > 0 && !isCapacitor
              ? _wattsId(c.connectedWOrLoad)
              : '-');
      // DEVICE: breaker label + the motor-control / starter token (DOL / VSD /
      // star-delta) APPENDED only when the way carries a real starterType —
      // most final lighting/socket ways have none, so the cell stays bare.
      final starter = circuit?.starterType;
      if (starter != null) usedStarters.add(starter);
      if (c.rcd.required) anyRcd = true;
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
      // E1: a per-CIRCUIT kA (the way's OWN device ladder) wins over the
      // board-wide figure; absent ⇒ the panel figure, exactly as before.
      final wayKa = breakerKaByCircuitId?[c.circuitId] ?? icuKa;
      final wayKaSuffix = wayKa != null ? ' ${_num(wayKa)}kA' : '';
      if (wayKa != null) anyIcuKa = true;
      // E8b: a single-phase FEEDER on a three-phase board is a 2-pole device.
      final feederTwoPole =
          feeds != null && !c.threePhase && p.system.isThreePhase;
      final breakerCell =
          '${breakerScheduleLabel(c.breaker, poles, twoPole: feederTwoPole)}'
          '$wayKaSuffix';
      final device = '$breakerCell'
          '${starter != null ? ' · ${_starterCode(starter)}' : ''}'
          '$rcd';
      // Round 19 (electrical-parity-2-capacitor-feeder-zero-current) — a
      // capacitor way, or a feeder whose only current is a downstream bank
      // (bank-off balance basis ⇒ design current 0), prints the current its
      // conductor REALLY carries when the bank is switched in (the run
      // current the calc report's Ib prints), marked `cap`: excluded from the
      // TOTAL phase balance (bank-off governs), but never a 0 | 0 | 0 under a
      // 2x240 mm2 feeder.
      //
      // Round 20 — gated on the WAY being a capacitor, or a feeder whose fed
      // board carries a capacitor floor; a zero design current alone (a
      // standby pump at demand factor 0) is NOT a capacitor and prints its
      // own (zero) design current.
      final fedHasCapacitor = feeds != null &&
          (result.panels[feeds]?.capacitorCurrentA ?? 0) > 1e-9;
      final capacitorCurrent = isCapacitor ||
          (fedHasCapacitor &&
              c.designCurrent.amperes <= 1e-9 &&
              c.runCurrentA.amperes > 1e-9);
      final ib = capacitorCurrent
          ? '${_amps(c.runCurrentA.amperes)} cap'
          : _amps(c.designCurrent.amperes);
      prims.add(
          SldLabel(blockX + _colGrup, rowY + 3, 'W${i + 1}', size: rowSize));
      prims.add(SldLabel(blockX + _colDevice, rowY + 3, device, size: rowSize));
      prims.add(
          SldLabel(blockX + _colPenghantar, rowY + 3, cable, size: rowSize));
      prims.add(SldLabel(blockX + _colDaya, rowY + 3, daya, size: rowSize));
      prims.add(SldLabel(
          blockX + _colKeterangan, rowY + 3, '$keterangan$fireDuty$vd',
          size: rowSize));
      // R/S/T loading band — the line current under the way's phase(s), each
      // cell carrying its phase role so the loading reads by colour at a glance.
      final (r, s, t) = _phaseLoading(c.phase, ib);
      if (r.isNotEmpty) {
        prims.add(SldLabel(
            blockX + _centredInCell(_cellRL, _cellRR, r, rowSize), rowY + 3, r,
            size: rowSize, role: SldRole.phaseR));
      }
      if (s.isNotEmpty) {
        prims.add(SldLabel(
            blockX + _centredInCell(_cellSL, _cellSR, s, rowSize), rowY + 3, s,
            size: rowSize, role: SldRole.phaseS));
      }
      if (t.isNotEmpty) {
        prims.add(SldLabel(
            blockX + _centredInCell(_cellTL, _cellTR, t, rowSize), rowY + 3, t,
            size: rowSize, role: SldRole.phaseT));
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
      prims.add(SldLabel(blockX + _colGrup, rowY + 3, 'W${ways + s + 1}',
          size: rowSize));
      prims.add(SldLabel(blockX + _colKeterangan, rowY + 3, 'CADANGAN (spare)',
          size: rowSize));
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
        'TOTAL  ${_watts(p.demandW)} / ${_boardDemandCurrent(p)}$imbalance',
        size: 8.5, bold: true));
    if (p.system.isThreePhase) {
      final pb = p.phaseBalance;
      final l1 = _amps(pb.l1), l2 = _amps(pb.l2), l3 = _amps(pb.l3);
      prims.add(SldLabel(
          blockX + _centredInCell(_cellRL, _cellRR, l1, rowSize), footerY, l1,
          size: rowSize, bold: true, role: SldRole.phaseR));
      prims.add(SldLabel(
          blockX + _centredInCell(_cellSL, _cellSR, l2, rowSize), footerY, l2,
          size: rowSize, bold: true, role: SldRole.phaseS));
      prims.add(SldLabel(
          blockX + _centredInCell(_cellTL, _cellTR, l3, rowSize), footerY, l3,
          size: rowSize, bold: true, role: SldRole.phaseT));
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
  // the RIGHT edge of the sub-panel block (orthogonal, riser-duct style). Skipped
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
      // way right -> channel; channel down; channel -> child RIGHT edge.
      // Round 14 (drafting-visual-2) — the channel runs to the right of every
      // block, so the last leg stops at the child's RIGHT edge: it used to run
      // on to the LEFT edge, striking straight through the sub-panel's name +
      // header text at title height.
      prims.add(
          SldLine(from.x, from.y, channelX, from.y, weight: SldWeight.medium));
      prims.add(
          SldLine(channelX, from.y, channelX, dropY, weight: SldWeight.medium));
      prims.add(SldLine(channelX, dropY, dst.x + _blockW, dropY,
          weight: SldWeight.medium));
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
  if (usedClasses.contains(BreakerClass.acb)) {
    legend.add(const SldLegendEntry('ACB', 'Air circuit breaker'));
  }
  for (final cv in [BreakerCurve.b, BreakerCurve.c, BreakerCurve.d]) {
    if (usedCurves.contains(cv)) {
      legend.add(SldLegendEntry(
          'Curve ${_curveCode(cv)}',
          switch (cv) {
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
  // Round 20 (drafting-visual-4-4) — the remaining keys follow the PRINTED
  // text, never the data behind it: no 'Ib' (the R/S/T cells print bare
  // figures), 'VD!' only when a row printed it, 'CT' only when a board's
  // meter token is CT-operated (a 'kWh direct' board needs no CT key), and
  // the 'div' / 'undiv' + 'cap' abbreviations the header / TOTAL / cells
  // print are keyed whenever they appear.
  final printed = [
    for (final pr in prims)
      if (pr is SldLabel) pr.text,
  ];
  bool printedMatch(RegExp re) => printed.any(re.hasMatch);
  if (printedMatch(RegExp(r'(^|\s)VD!'))) {
    legend.add(const SldLegendEntry('VD!', 'Voltage drop over limit'));
  }
  if (printedMatch(RegExp(r'\bundiv\b'))) {
    legend.add(const SldLegendEntry('div / undiv',
        'Demand current with / without the board diversity factor'));
  }
  if (printedMatch(RegExp(r'\d cap$'))) {
    legend.add(const SldLegendEntry(
        'cap', 'Capacitor-bank current (excluded from the TOTAL balance)'));
  }
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
        .add(const SldLegendEntry('V / A / Hz', 'Panel metering instruments'));
    if (printedMatch(RegExp(r'^CT '))) {
      legend.add(
          const SldLegendEntry('CT', 'Metering current transformer (x/5A)'));
    }
  }
  // drafting-8: every remaining row abbreviation, keyed only when printed.
  if (anyRcd) {
    legend.add(const SldLegendEntry(
        'RCD', 'Residual current device (rated mA, RCD type)'));
  }
  if (anyConduit) {
    legend.add(const SldLegendEntry('PVC', 'PVC conduit, outer diameter mm'));
  }
  if (anyTray) {
    legend.add(const SldLegendEntry('tray', 'Run on cable tray / ladder'));
  }
  for (final st in StarterType.values) {
    if (usedStarters.contains(st)) {
      legend.add(SldLegendEntry(_starterCode(st), _starterMeaning(st)));
    }
  }
  // A separately-run earth conductor family (`NYA` / `BC`) when any label
  // prints one that is not already keyed as a way's cable family.
  final rowTokens = <String>{
    for (final pr in prims)
      if (pr is SldLabel) ...pr.text.split(RegExp(r'[\s\u00B7/+()]+')),
  };
  for (final f in const ['NYA', 'BC']) {
    if (rowTokens.contains(f) && !usedFamilies.contains(f)) {
      legend.add(SldLegendEntry(f, cableFamilyDescription(f)));
    }
  }

  final s = result.supply;
  final supplyNote = '${s.system.label}  ${_num(s.voltage.volts)}V  '
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
  Map<String, double>? breakerKaByCircuitId,
  Map<String, ConduitSpec>? containmentByCircuitId,
}) =>
    buildElectricalSld(
      project: project,
      result: result,
      onlyPanelId: panelId,
      breakerIcuKaByPanelId: breakerIcuKaByPanelId,
      breakerKaByCircuitId: breakerKaByCircuitId,
      containmentByCircuitId: containmentByCircuitId,
    );

/// The utility SOURCE-SPINE only, as a standalone `SldSheet` for painting a
/// read-only spine strip beside the root panel on the interactive single-line
/// canvas — ONE source-spine geometry shared with the overview / riser /
/// export (the `_buildSourceSpine` body). On a DECLARED MV service (explicit
/// transformer kVA or dual-tx) the chain is PLN MV -> MV main -> TRANSFORMER
/// -> LV main; on an LV (TR) direct service it is the SUPPLY HEAD only — no
/// fabricated substation. Optional GENSET / CAPACITOR / SOLAR / BATTERY hang
/// off either. `isEmpty` is true when there is no demand AND no
/// sources / service fields, so a bare project shows nothing new on the
/// canvas (the existing PLN head stays).
/// [horizontal] lays the chain out LEFT-TO-RIGHT (PLN -> MV -> transformer -> LV
/// main, genset/capacitor dropping BELOW the LV bus) for the left-to-right
/// interactive single-line canvas — the source sits to the LEFT of the root
/// board and flows right into it. The default vertical layout is used by the
/// top-down overview + the floor-stacked riser.
/// Round 14 — a CAPACITOR BANK node is drawn on a source spine only when the
/// project specifies a real bank (`capacitorBankKvar > 0`): a declared genset or
/// solar array no longer implies one (honesty by construction).
bool _hasCapacitorBank(ElectricalProject project) =>
    (project.capacitorBankKvar ?? 0) > 0;

SldSheet buildElectricalSourceSpine({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  bool horizontal = false,
}) {
  final hasSource = project.sources != null ||
      project.dualTransformer ||
      project.transformerKva != null ||
      _hasCapacitorBank(project) ||
      project.supplyKind != SupplyKind.pln ||
      project.supplyCapacityVa != null;
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
      SldLegendEntry('Source', 'Utility supply chain'),
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

/// Text size of an OVERVIEW feeder annotation (the size it has always been
/// drawn at) — shared with the collision pass so the boxes match the ink.
const double _ovFeederLabelSize = 6.5;

/// Vertical pitch + budget of the overview's feeder-annotation stagger ladder.
const double _kOvLabelStackH = 9;
const int _kOvStackSlots = 10;

/// Clearance between a BELOW-line overview annotation's glyph top and the
/// branch line it hangs under (drawing units).
const double _kOvBelowClearance = 2.5;

/// The escape ladder for one overview feeder annotation whose default anchor
/// [def] collides: stagger vertically about the default (down, then up,
/// growing) — the tag stays over its own mid segment and never drifts into a
/// neighbouring tier. // VERIFY: a drafting declutter heuristic, not a standard.
///
/// [def] sits 4 units ABOVE the shared mid horizontal (baseline `midY − 4`), so
/// that line is at `def.y + 4`. A below-line slot must hang its whole glyph box
/// (`baseline − size .. baseline`) UNDER the line, else the branch strikes
/// through the text: the first below slot's baseline is therefore
/// `midY + size + clearance` = `def.y + 4 + 6.5 + 2.5` = `midY + 9` (the old
/// `midY + 5` put the box at `[midY − 1.5, midY + 5]`, straddling the line).
/// Further below slots step down by the stack pitch; the above slots stack up
/// from the default by the same pitch.
List<(double, double)> _ovLabelLadder((double, double) def) {
  const firstBelow = 4 + _ovFeederLabelSize + _kOvBelowClearance;
  return [
    def,
    for (var k = 0; k < _kOvStackSlots; k++)
      (
        def.$1,
        k.isEven
            ? def.$2 + firstBelow + (k ~/ 2) * _kOvLabelStackH
            : def.$2 - ((k + 1) ~/ 2) * _kOvLabelStackH,
      ),
  ];
}

/// Assumed building power factor — only the FALLBACK for a panel result with
/// no recorded per-board VA ([ElectricalPanelResult.demandVa]); mirrors
/// `compute.dart`'s `assumedBuildingPf` but inlined to keep this pure drawing
/// file free of the compute dependency. A representative estimate, NOT an
/// SNI/PUIL clause. // VERIFY
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
/// e.g. `NYY 4x50 mm2 · MCCB 250A 3ph · 24.0 m`. The LENGTH (N8) is the run the
/// solve already used for the feeder (geo-derived when placed, else the manual
/// length) — appended only when a real length exists, never fabricated. Null
/// when the child's feeding circuit or its sized result is unresolved (⇒ omit
/// the label rather than guess). ASCII-safe (the bundled middle dot is allowed).
/// [parentThreePhase] marks a single-phase feeder leaving a THREE-phase board:
/// its device is a 2-pole (L + N) breaker, so the token reads `2P` (E8b) — the
/// same convention the compact overview node already prints. A single-phase
/// feeder from a single-phase board is unchanged.
String? _feederConnLabel(
  Map<String, ElectricalCircuit> feederCircuitOf,
  Map<String, ElectricalCircuitResult> feederResultOf,
  String child, {
  bool parentThreePhase = false,
}) {
  final cr = feederResultOf[child];
  final circ = feederCircuitOf[child];
  if (cr == null || circ == null) return null;
  final poles = cr.threePhase ? 3 : 1;
  final length =
      cr.lengthM > 0 ? ' · ${planLengthLabel(Length(cr.lengthM))}' : '';
  final twoPole = parentThreePhase && !cr.threePhase;
  return '${cableRunLabel(circ, cr.cable.csaMm2, cr.threePhase, cores: cr.grounding.cores, runs: cr.cable.runsPerPhase, peCsaMm2: cr.grounding.peCsaMm2, neutralCsaMm2: cr.grounding.neutralCsaMm2)} · '
      '${breakerScheduleLabel(cr.breaker, poles, twoPole: twoPole)}$length';
}

/// True when [child]'s PARENT board is three-phase (so a single-phase feeder to
/// it is a 2-pole device — see [_feederConnLabel]). Shared by the overview + the
/// riser so both read identically.
bool _parentIsThreePhase(
  Map<String, String> parentOf,
  ElectricalSystemResult result,
  String child,
) {
  final par = parentOf[child];
  final pr = par == null ? null : result.panels[par];
  return pr?.system.isThreePhase ?? false;
}

/// The compact-node sub-line: `<In>A <poles>P · <kW>kW / <kVA>kVA` (the panel's
/// incomer rating + diversified demand in both kW and kVA). Shared by the
/// overview + riser so they read identically. ASCII-safe.
///
/// Round 15 (drafting-visual-2-3) — the kVA is the board's OWN per-circuit VA
/// (the basis `computeSystem` sums into the supply note), so a single-root
/// sheet prints ONE apparent power for one demand (the node used W / 0.85 =
/// 44.9 kVA beside a 44.1 kVA supply note). The flat PF is the fallback only.
String _compactNodeSubLine(ElectricalPanelResult p, {ElectricalPanel? model}) {
  // Round 23 (elec-drafting-2-5) — a saturated incomer says so on the node.
  final head = '${_num(p.incomer.breaker.ratingA.amperes)}A '
      '${p.incomer.poles}P${incomerOverRangeSuffix(p.incomer, withNeeds: false)}';
  // Round 23 (elec-drafting-2-7) — a capacitor-only board carries no real
  // power (Round 11): print its bank rating, never '0kW / 0kVA'. The bank's
  // kvar is the MODEL way's rating (the solved way carries 0 W by design).
  var kvar = 0.0;
  for (final c in model?.circuits ?? const <ElectricalCircuit>[]) {
    if (c.loadKind == LoadKind.capacitor) kvar += c.loadW;
  }
  if (p.demandW <= 0 && kvar > 0) {
    return '$head · ${_num(kvar / 1000)} kvar';
  }
  return '$head · ${_num(p.demandW / 1000)}kW / '
      '${_num(p.demandVaOrEstimate(fallbackPf: _assumedPanelPf) / 1000)}kVA';
}


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
    if (isEssentialByName(p.name)) return true;
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
void _emitDelta(
    List<SldPrim> out, double cx, double cy, double r, SldRole role) {
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
    ..add(
        SldLine(cx, cy, cx + s * 0.87, cy + s * 0.5, role: role)); // down-right
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
///
/// Round 17 (drafting-visual-3-3) — [vertical] draws the bowtie ALONG a
/// vertical conductor (apexes meeting on the Y axis, bars horizontal at
/// `cy ± r`), so on the vertical source spine the isolator sits IN SERIES
/// with the riser lead instead of across it.
void _emitBowtie(
    List<SldPrim> out, double cx, double cy, double r, SldRole role,
    {bool vertical = false}) {
  final t = r * 0.9;
  if (vertical) {
    out
      ..add(SldLine(cx - t, cy - r, cx + t, cy - r,
          weight: SldWeight.medium, role: role))
      ..add(SldLine(cx - t, cy - r, cx, cy, role: role))
      ..add(SldLine(cx + t, cy - r, cx, cy, role: role))
      ..add(SldLine(cx - t, cy + r, cx + t, cy + r,
          weight: SldWeight.medium, role: role))
      ..add(SldLine(cx - t, cy + r, cx, cy, role: role))
      ..add(SldLine(cx + t, cy + r, cx, cy, role: role));
    return;
  }
  // Left triangle (apex at centre), right triangle (apex at centre).
  out
    ..add(SldLine(cx - r, cy - t, cx - r, cy + t,
        weight: SldWeight.medium, role: role))
    ..add(SldLine(cx - r, cy - t, cx, cy, role: role))
    ..add(SldLine(cx - r, cy + t, cx, cy, role: role))
    ..add(SldLine(cx + r, cy - t, cx + r, cy + t,
        weight: SldWeight.medium, role: role))
    ..add(SldLine(cx + r, cy - t, cx, cy, role: role))
    ..add(SldLine(cx + r, cy + t, cx, cy, role: role));
}

/// A small labelled PANEL BOX (MVMDP / LVMDP) centred on the baseline — the DXF
/// draws each distribution board as a rectangle, not a busbar.
///
/// Round 15 (drafting-visual-2-7) — a label that would not clear the box once
/// the plot fit grows it to the minimum plotted size (allowance
/// [_kPanelBoxLabelGrowth] over the 8-unit size, bold ≈ [_kBoldWidthFactor] ×
/// Helvetica) WRAPS onto two centred lines at the space nearest its middle
/// ('PANEL UTAMA' / 'TEGANGAN MENENGAH') instead of running into the right
/// border. A label that fits keeps the original left-anchored single line.
void _emitPanelBox(List<SldPrim> out, double cx, double cy, double w, double h,
    String label, SldRole role) {
  const pad = 5.0;
  out.add(SldRect(cx - w / 2, cy - h / 2, w, h, role: role));
  double grownW(String s) =>
      helveticaTextWidth(s, 8) * _kBoldWidthFactor * _kPanelBoxLabelGrowth;
  final spaces = [
    for (var i = 0; i < label.length; i++)
      if (label[i] == ' ') i,
  ];
  if (grownW(label) <= w - 2 * pad || spaces.isEmpty || h < 24) {
    out.add(SldLabel(cx - w / 2 + pad, cy + 3, label,
        size: 8, bold: true, role: role));
    return;
  }
  final mid = label.length / 2;
  final cut =
      spaces.reduce((a, b) => (a - mid).abs() <= (b - mid).abs() ? a : b);
  final lines = [label.substring(0, cut), label.substring(cut + 1)];
  for (var i = 0; i < 2; i++) {
    final lw = helveticaTextWidth(lines[i], 8) * _kBoldWidthFactor;
    out.add(SldLabel(cx - lw / 2, cy - 2 + i * 10, lines[i],
        size: 8, bold: true, role: role));
  }
}

/// Helvetica-Bold is ~10 % wider than the regular AFM widths
/// [helveticaTextWidth] measures. // drafting estimate, not a standard value.
const double _kBoldWidthFactor = 1.1;

/// Allowance for the plot fit growing an 8-unit label to the minimum plotted
/// size (8 → ~8.5 on an A3 riser; 25 % covers the denser sheets).
const double _kPanelBoxLabelGrowth = 1.25;

/// GENERATOR (genset): a circle with a centred "G".
void _emitGenerator(
    List<SldPrim> out, double cx, double cy, double r, SldRole role) {
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

/// BATTERY (IEC 60617): a long/short plate PAIR (the classic cell) doubled to
/// mark a bank, with leads — pure [SldLine] prims so every renderer draws it
/// identically (golden rule 5). Centred on ([cx],[cy]).
void _emitBattery(List<SldPrim> out, double cx, double cy, SldRole role) {
  const long = 9.0, short = 4.0; // half plate widths
  // Two cells: long/short, long/short, 4 px pitch, centred on cy.
  const ys = [-6.0, -2.0, 2.0, 6.0];
  for (var i = 0; i < ys.length; i++) {
    final half = i.isEven ? long : short;
    out.add(SldLine(cx - half, cy + ys[i], cx + half, cy + ys[i],
        weight: i.isEven ? SldWeight.medium : SldWeight.thin, role: role));
  }
  out.add(SldLine(cx, cy - 13, cx, cy - 6, role: role)); // top lead
  out.add(SldLine(cx, cy + 6, cx, cy + 13, role: role)); // bottom lead
}

/// SOLAR PV ARRAY: a small cell rectangle with its two internal division lines
/// (the panel-grid convention) + a lead — pure prims, no new subtype.
void _emitPvArray(List<SldPrim> out, double cx, double cy, SldRole role) {
  const w = 22.0, h = 14.0;
  final x = cx - w / 2, y = cy - h / 2;
  out.add(SldRect(x, y, w, h, role: role));
  out.add(SldLine(x + w / 3, y, x + w / 3, y + h, role: role));
  out.add(SldLine(x + 2 * w / 3, y, x + 2 * w / 3, y + h, role: role));
  out.add(SldLine(cx, y - 7, cx, y, role: role)); // top lead
}

/// True when the project's service is a DECLARED medium-voltage (TM)
/// connection with a customer substation — an explicit transformer rating or
/// the dual-transformer flag. Everything else is a low-voltage (TR) direct
/// service: PLN metering at 220/380 V with NO customer MV station, no
/// customer transformer and no separate utility-side LV main, so the spine
/// must never fabricate them (a house on a 33 kVA daya tersambung has no
/// TRAFO to draw). Distributed sources (genset / solar / battery /
/// capacitor) do NOT imply an MV service — they hang off the LV side of
/// whichever service exists.
bool _isMvService(ElectricalProject project) =>
    project.transformerKva != null || project.dualTransformer;

/// The SUPPLY-head node name for the project's primary supply kind, with the
/// declared connection capacity appended when set (`PLN MV STATION 197 kVA` /
/// compact `PLN 197 kVA`). PLN with no capacity keeps today's exact labels ⇒
/// byte-identical defaults. [mv] marks a declared MV service — only then is
/// the PLN head an "MV STATION"; an LV direct service reads plain `PLN`.
String _supplyHeadLabel(ElectricalProject project,
    {required bool compact, bool mv = true}) {
  final cap = project.supplyCapacityVa == null
      ? ''
      : ' ${_num(project.supplyCapacityVa!.inKilovoltAmperes)} kVA';
  return switch (project.supplyKind) {
    SupplyKind.pln => compact || !mv ? 'PLN$cap' : 'PLN MV STATION$cap',
    SupplyKind.generator => compact ? 'GENSET$cap' : 'GENSET SUPPLY$cap',
    SupplyKind.solar => compact ? 'PV$cap' : 'SOLAR PV SUPPLY$cap',
  };
}

/// `backs NN% of load` — the declared/sized genset kVA against the building
/// demand kVA, capped at 100 (an oversized set still backs the whole load, it
/// does not back 250% of it). Null when there is no demand or no rating — no
/// honest ratio to print, so nothing is printed.
/// A genset-ladder kVA figure that NEVER saturates silently (audit r8-5):
/// below the top rung it is the single standard rating (`500`); above it,
/// `n x 2500` paralleled sets. [totalKva] is the paralleled capacity (what the
/// coverage % compares), [text] the printable figure (no unit). An explicit
/// [forced] rating is printed verbatim as one set.
({double totalKva, String text}) _ladderKva(ApparentPower required,
    {ApparentPower? forced}) {
  if (forced != null) {
    final k = forced.inKilovoltAmperes;
    return (totalKva: k, text: _num(k));
  }
  final sel = selectGeneratorUnits(required);
  final unit = sel.unitKva.inKilovoltAmperes;
  return (
    totalKva: unit * sel.units,
    text: sel.units > 1 ? '${sel.units} x ${_num(unit)}' : _num(unit),
  );
}

/// Round 16 — the transformer figure for the drawings: [serviceTransformer]
/// (`n x <kVA>` when the study needs several units).
({double totalKva, String text})? _transformerFig(
    ElectricalProject project, ApparentPower demandVa) {
  final t = serviceTransformer(project, demandVa);
  if (t == null) return null;
  return (
    totalKva: t.kva * t.units,
    text: t.units > 1 ? '${t.units} x ${_num(t.kva)}' : _num(t.kva),
  );
}

/// The GENSET figure for the drawings, sized in ONE place (Round 12,
/// report-recompute-genset-prime-kva-mismatch): [sizeGenerator] — the same
/// call the report's power one-line makes — so a PRIME-mode set carries its
/// 1.25× continuous-duty uplift on every drawing too (the drawings used to
/// snap the bare backup demand: 82 kVA drawn vs 100 kVA reported). A forced
/// nameplate is printed verbatim.
///
/// Round 16 — sized on the backup kW as well ([backupW]): a set delivers
/// only 0.8 × its kVA in kW, so a load above cos φ 0.8 is kW-limited.
({double totalKva, String text}) _gensetKva(
    ApparentPower backupVa, GeneratorSource gen, Power backupW) {
  if (gen.kva != null) return _ladderKva(backupVa, forced: gen.kva);
  final r = sizeGenerator(backupVa, mode: gen.mode, backupPower: backupW);
  final unit = r.ratingKva.inKilovoltAmperes;
  return (
    totalKva: unit * r.units,
    text: r.units > 1 ? '${r.units} x ${_num(unit)}' : _num(unit),
  );
}

///
/// Round 16 — the coverage is the LESSER of the kVA ratio and the kW ratio
/// (the set's kW rating = 0.8 × kVA against the demand W): a 100 kVA / 80 kW
/// set does not back 100 % of a 90 kW load. [demandW] ≤ 0 ⇒ the kVA ratio
/// alone (byte-identical).
String? _gensetBackupPctLabel(
    double genKva, ApparentPower demandVa, double demandW) {
  final demandKva = demandVa.inKilovoltAmperes;
  if (demandKva <= 0 || genKva <= 0) return null;
  var ratio = genKva / demandKva;
  if (demandW > 0) {
    ratio = math.min(ratio, genKva * kGeneratorPf / (demandW / 1000));
  }
  final pct = math.min(100.0, ratio * 100).round();
  return 'backs $pct% of load';
}

/// The BATTERY node labels: headline (+ sized bank kWh when the demand gives an
/// honest critical load — the SAME `sizeBattery` basis the power one-line uses)
/// and the chemistry/autonomy sub-line. Zero demand ⇒ headline stays 'BATTERY'
/// (a bank size derived from nothing would be fabricated).
///
/// Round 16 — the critical load is the REAL demand W ([demandW]) when known
/// (the same basis the power one-line now sizes on), not demandVa × 0.8.
(String, String) _batteryNodeLabels(
    ElectricalProject project, ApparentPower demandVa, double demandW) {
  final batt = project.sources!.battery!;
  var head = 'BATTERY';
  if (demandVa.voltAmperes > 0) {
    final sized = sizeBattery(
      Power(demandW > 0 ? demandW : demandVa.voltAmperes * kGeneratorPf),
      autonomyHours: batt.autonomyHours,
      chemistry: batt.chemistry,
    );
    head = 'BATTERY ${_num(sized.installedKwh.inKilowattHours)} kWh';
  }
  final sub =
      '${batt.chemistry.label} · ${_num(batt.autonomyHours)} h autonomy';
  return (head, sub);
}

/// The SOLAR PV node labels: headline with the installed array kWp (input
/// arithmetic: panels × Wp) and the panel-count sub-line.
(String, String) _solarNodeLabels(ElectricalProject project) {
  final solar = project.sources!.solar!;
  final kwp = solar.panels * solar.panelWp / 1000;
  return (
    'SOLAR PV ${_num(kwp)} kWp',
    '${solar.panels} x ${solar.panelWp} Wp',
  );
}

/// Round 10 (elec-drawing-props-1) — how far below a side-source node's
/// centre its drawing reaches: the sub-label baseline at +12 plus its 7.5 pt
/// descent (~1.6), which also clears every side glyph's half-height (≤ 13).
const double _sideNodeBottom = 14;

/// Synthesize the utility source spine drawn ABOVE the panel tree (overview) or
/// the top floor band (riser). On a DECLARED MV service (`_isMvService`):
/// PLN MV STATION -> PANEL UTAMA TEGANGAN MENENGAH -> TRANSFORMER <kVA> ->
/// PANEL UTAMA TEGANGAN RENDAH, with optional GENSET / CAPACITOR / SOLAR /
/// BATTERY hanging off the LV bus. On an LV (TR) direct service — the default
/// — the chain is the SUPPLY HEAD ONLY (no fabricated substation): the side
/// sources drop from a short right-hand trunk off the head, and the earthing
/// mark hangs at the service entrance. All nodes are `SldRole.source`.
/// Returns the prims, the spine HEIGHT (to push the tree/floors down by), and
/// the feed anchor (the bottom-centre of the last chain node) the roots
/// connect up to.
///
/// Sizing is DERIVED from existing sizers only (no invented physics): on an
/// MV service with no explicit rating (dual-tx), the transformer + genset kVA
/// snap to the genset ladder (`selectGeneratorUnits` — `n x 2500` past the
/// top rung, never a silent saturation) against the building demand VA — all
/// `// VERIFY`.
({List<SldPrim> prims, double height, double feedX, double feedY})
    _buildSourceSpine(
  ElectricalProject project,
  ElectricalSystemResult result,
  double centreX,
) {
  final prims = <SldPrim>[];
  final nodeX = centreX - _ovW / 2;
  final demandVa = result.supply.demandVa;
  final isMv = _isMvService(project);

  // MV-chain transformer kVA — Round 16: the SAME [serviceTransformer] the
  // study and the schedule use (declared rating, else the dual-tx study pick
  // on the transformer ladder). Blank when neither is known.
  final txFig = _transformerFig(project, demandVa);
  final txLabel = (txFig != null && txFig.totalKva > 0)
      ? 'TRANSFORMER ${txFig.text} kVA'
      : 'TRANSFORMER';

  // The vertical spine, top -> bottom. The MV station chain exists ONLY on a
  // declared MV service — an LV direct service is just its supply head.
  // Each spine element carries its SYMBOL kind so it draws as a real
  // single-line device, not a labelled box.
  final spine = <({String name, String? sub, String kind})>[
    (
      name: _supplyHeadLabel(project, compact: false, mv: isMv),
      sub: null,
      kind: 'supply'
    ),
    if (isMv) ...[
      (name: 'PANEL UTAMA TEGANGAN MENENGAH', sub: 'MV main', kind: 'bus'),
      (name: txLabel, sub: null, kind: 'transformer'),
      (name: 'PANEL UTAMA TEGANGAN RENDAH', sub: 'LV main', kind: 'bus'),
    ],
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
        // The incoming isolator (bowtie). On an LV head-only chain the label
        // moves ABOVE the symbol — the side-source trunk leaves at mid-height
        // to the right, exactly where the MV label used to sit.
        _emitBowtie(prims, centreX, midY, 11, role, vertical: true);
        // The outgoing lead from the isolator's lower bar down to the band
        // bottom, where the next riser leg / root feeder picks up — the
        // symbol no longer floats 13 units above its conductor.
        prims.add(SldLine(centreX, midY + 11, centreX, y + _ovH,
            weight: SldWeight.medium, role: role));
        prims.add(SldLabel(centreX + 22, isMv ? midY + 3 : midY - 14, node.name,
            size: 8.5, bold: true, role: role));
      case 'bus':
      default:
        // A distribution board: a labelled BOX (the DXF convention), with the
        // tier sub below it.
        _emitPanelBox(prims, centreX, midY, _ovW, _ovH - 8, node.name, role);
        if (node.sub != null) {
          // drafting-9: baseline 7 below the band so the caption's capitals
          // clear the box's bottom edge (at y + _ovH - 4) even after the plot
          // fit grows the caption to the minimum plotted size.
          prims.add(
              SldLabel(nodeX, y + _ovH + 7, node.sub!, size: 7.5, role: role));
        }
    }
    prevBottom = y + _ovH;
    y += _ovH + _ovHGap;
  }
  final lvBottom = y - _ovHGap; // bottom of the last chain band

  final lvMidY = lvBottom - _ovH / 2;
  final sideX = nodeX + _ovW + 60;
  var stackBottom = lvBottom;
  if (isMv) {
    // MV: GENSET + CAPACITOR BANK hang off the LV-main bus to the right
    // (historic coordinates — declared-MV projects are byte-identical).
    if (project.sources?.generator != null) {
      final gen = project.sources!.generator!;
      final backupVa = gensetBackupDemandVa(project, result);
      final genFig =
          _gensetKva(backupVa, gen, gensetBackupDemandW(project, result));
      final genKva = genFig.totalKva;
      final gy = lvMidY - _ovH - 8;
      final gcy = gy + _ovH / 2;
      _emitGenerator(prims, sideX + 14, gcy, 13, SldRole.source);
      prims.add(SldLabel(sideX + 34, gcy - 2, 'GENSET ${genFig.text} kVA',
          size: 8.5, bold: true, role: SldRole.source));
      prims.add(SldLabel(sideX + 34, gcy + 12, gen.mode.label,
          size: 7.5, role: SldRole.source));
      // What fraction of the building's diversified demand this set can carry —
      // the honest coverage figure (capped at 100%), printed only when a demand
      // exists to compare against.
      final pct =
          _gensetBackupPctLabel(genKva, demandVa, result.supply.demandW);
      if (pct != null) {
        prims.add(SldLabel(sideX + 34, gcy + 24, pct,
            size: 7.5, role: SldRole.source));
      }
      prims.add(SldLine(nodeX + _ovW, gcy, sideX + 1, gcy,
          weight: SldWeight.medium, role: SldRole.source));
    }
    // CAPACITOR BANK: drawn ONLY when a real bank is specified (kvar > 0).
    // Round 14 (elec-building-sim-5) — the historic "any distributed source ⇒
    // a generic PF-correction bank" proxy is gone: declaring a genset or solar
    // array added a piece of plant to the issued single-line that the design
    // never specified (and the PF study may say none is needed).
    if (_hasCapacitorBank(project)) {
      final cy = lvMidY + 8 + _ovH / 2;
      final capSub = '${_num(project.capacitorBankKvar!)} kvar';
      _emitCapacitor(prims, sideX + 14, cy, SldRole.source);
      prims.add(SldLabel(sideX + 34, cy - 2, 'CAPACITOR BANK',
          size: 8.5, bold: true, role: SldRole.source));
      prims.add(SldLabel(sideX + 34, cy + 12, capSub,
          size: 7.5, role: SldRole.source));
      prims.add(SldLine(nodeX + _ovW, cy, sideX + 14, cy,
          weight: SldWeight.medium, role: SldRole.source));
      // Round 10 (elec-drawing-props-1) — the side stack counts toward the
      // spine height (the LV-branch idiom): the sub-label baseline sits at
      // cy + 12 (+ its descent), below the glyph's ±11.
      stackBottom = math.max(stackBottom, cy + _sideNodeBottom);
    }
    // SOLAR PV array + BATTERY bank stack BELOW the capacitor slot (new side
    // nodes — absent sources leave every existing coordinate untouched).
    var sideY = lvMidY + 8 + _ovH / 2 + 54;
    if (project.sources?.solar != null) {
      final (head, sub) = _solarNodeLabels(project);
      _emitPvArray(prims, sideX + 14, sideY, SldRole.source);
      prims.add(SldLabel(sideX + 34, sideY - 2, head,
          size: 8.5, bold: true, role: SldRole.source));
      prims.add(SldLabel(sideX + 34, sideY + 12, sub,
          size: 7.5, role: SldRole.source));
      prims.add(SldLine(nodeX + _ovW, sideY, sideX + 3, sideY,
          weight: SldWeight.medium, role: SldRole.source));
      stackBottom = math.max(stackBottom, sideY + _sideNodeBottom);
      sideY += 54;
    }
    if (project.sources?.battery != null) {
      final (head, sub) =
          _batteryNodeLabels(project, demandVa, result.supply.demandW);
      _emitBattery(prims, sideX + 14, sideY, SldRole.source);
      prims.add(SldLabel(sideX + 34, sideY - 2, head,
          size: 8.5, bold: true, role: SldRole.source));
      prims.add(SldLabel(sideX + 34, sideY + 12, sub,
          size: 7.5, role: SldRole.source));
      prims.add(SldLine(nodeX + _ovW, sideY, sideX + 5, sideY,
          weight: SldWeight.medium, role: SldRole.source));
      stackBottom = math.max(stackBottom, sideY + _sideNodeBottom);
    }
  } else {
    // LV: no LV-main box to hang off — the side sources drop from a short
    // right-hand trunk at the supply head (clear of the feeder tree that
    // leaves the head's bottom-centre). Node order: genset, capacitor,
    // solar, battery; each glyph carries its top/bottom lead offsets so the
    // drop connectors meet the symbols exactly.
    final dropX = sideX + 14;
    final hasCap = _hasCapacitorBank(project);
    final anySide = project.sources?.generator != null ||
        hasCap ||
        project.sources?.solar != null ||
        project.sources?.battery != null;
    if (anySide) {
      // Round 17 — the side trunk TEES off the outgoing lead just below the
      // (now in-line) isolator, never off the symbol's flank.
      final trunkY = lvMidY + 15;
      prims.add(SldLine(centreX, trunkY, dropX, trunkY,
          weight: SldWeight.medium, role: SldRole.source));
      var prevDropBottom = trunkY;
      var cy = lvMidY + 58;
      void connectTo(double topOff, double bottomOff) {
        prims.add(SldLine(dropX, prevDropBottom, dropX, cy - topOff,
            weight: SldWeight.medium, role: SldRole.source));
        prevDropBottom = cy + bottomOff;
      }

      if (project.sources?.generator != null) {
        final gen = project.sources!.generator!;
        final backupVa = gensetBackupDemandVa(project, result);
        final genFig =
            _gensetKva(backupVa, gen, gensetBackupDemandW(project, result));
        final genKva = genFig.totalKva;
        connectTo(13, 13);
        _emitGenerator(prims, dropX, cy, 13, SldRole.source);
        prims.add(SldLabel(dropX + 20, cy - 2, 'GENSET ${genFig.text} kVA',
            size: 8.5, bold: true, role: SldRole.source));
        prims.add(SldLabel(dropX + 20, cy + 12, gen.mode.label,
            size: 7.5, role: SldRole.source));
        final pct =
            _gensetBackupPctLabel(genKva, demandVa, result.supply.demandW);
        if (pct != null) {
          prims.add(SldLabel(dropX + 20, cy + 24, pct,
              size: 7.5, role: SldRole.source));
        }
        stackBottom = cy + 13;
        cy += 58;
      }
      if (hasCap) {
        final capSub = '${_num(project.capacitorBankKvar!)} kvar';
        connectTo(11, 11);
        _emitCapacitor(prims, dropX, cy, SldRole.source);
        prims.add(SldLabel(dropX + 20, cy - 2, 'CAPACITOR BANK',
            size: 8.5, bold: true, role: SldRole.source));
        prims.add(SldLabel(dropX + 20, cy + 12, capSub,
            size: 7.5, role: SldRole.source));
        stackBottom = cy + 11;
        cy += 58;
      }
      if (project.sources?.solar != null) {
        final (head, sub) = _solarNodeLabels(project);
        connectTo(14, 7);
        _emitPvArray(prims, dropX, cy, SldRole.source);
        prims.add(SldLabel(dropX + 20, cy - 2, head,
            size: 8.5, bold: true, role: SldRole.source));
        prims.add(SldLabel(dropX + 20, cy + 12, sub,
            size: 7.5, role: SldRole.source));
        stackBottom = cy + 7;
        cy += 58;
      }
      if (project.sources?.battery != null) {
        final (head, sub) =
            _batteryNodeLabels(project, demandVa, result.supply.demandW);
        connectTo(13, 13);
        _emitBattery(prims, dropX, cy, SldRole.source);
        prims.add(SldLabel(dropX + 20, cy - 2, head,
            size: 8.5, bold: true, role: SldRole.source));
        prims.add(SldLabel(dropX + 20, cy + 12, sub,
            size: 7.5, role: SldRole.source));
        stackBottom = cy + 13;
      }
    }
  }

  // System-earthing mark — at the LV-main / transformer-secondary on an MV
  // service, at the SERVICE ENTRANCE (the supply head) on an LV one — the IEC
  // earth symbol hung to the LEFT (the side sources take the right side),
  // labelled with the installation earthing-system designation.
  final earthX = isMv ? nodeX - 34 : centreX - 60;
  prims.add(SldLine(isMv ? nodeX : centreX - 12, lvMidY, earthX, lvMidY,
      weight: SldWeight.medium, role: SldRole.source));
  _emitEarth(prims, earthX, lvMidY, SldRole.source);
  // drafting-9: the designation hangs below the earth bars, starting 40 to the
  // LEFT of the mark, so it reads under the symbol and keeps clear of the
  // board's tier caption ('LV main') to its right, with room to grow to the
  // minimum plotted size on a scaled-down sheet.
  prims.add(SldLabel(earthX - 40, lvMidY + 28, project.earthingSystem.label,
      size: 7.5, bold: true, role: SldRole.source));

  return (
    prims: prims,
    height: math.max(lvBottom, stackBottom),
    feedX: centreX,
    feedY: lvBottom
  );
}

/// HORIZONTAL (left-to-right) source chain for the interactive single-line
/// canvas. On a DECLARED MV service (`_isMvService`): PLN supply -> MVMDP ->
/// two-winding transformer -> LVMDP, flowing rightward. On an LV (TR) direct
/// service — the default — the chain is the SUPPLY HEAD ONLY with a short
/// outgoing lead (no fabricated TRAFO / MVMDP / LVMDP: a house metered at
/// 220/380 V has no customer substation to draw). The GENSET / CAPACITOR /
/// SOLAR / BATTERY drop BELOW the last chain node (so they never collide with
/// the root board placed to the right). The feed anchor is that node at the
/// baseline — the root board connects to it. Uses the compact Indonesian
/// board codes (PLN / MVMDP / LVMDP) since a horizontal chain has no room for
/// the full names; the transformer is the Δ-Y (DyN) two-winding symbol,
/// panels are boxes — matching the EL10011003 DXF.
({List<SldPrim> prims, double height, double feedX, double feedY})
    _buildSourceSpineH(
  ElectricalProject project,
  ElectricalSystemResult result,
) {
  final prims = <SldPrim>[];
  const role = SldRole.source;
  final demandVa = result.supply.demandVa;
  final isMv = _isMvService(project);
  final txFig = _transformerFig(project, demandVa);
  final txLabel = (txFig != null && txFig.totalKva > 0)
      ? 'TRAFO ${txFig.text} kVA'
      : 'TRAFO';
  final chain = <({String name, String kind})>[
    (name: _supplyHeadLabel(project, compact: true), kind: 'supply'),
    if (isMv) ...[
      (name: 'MVMDP', kind: 'bus'),
      (name: txLabel, kind: 'transformer'),
      (name: 'LVMDP', kind: 'bus'),
    ],
  ];

  const pitchX = 132.0;
  const yMid = 0.0;
  const boxW = 58.0, boxH = 24.0;
  var x = 0.0;
  double? prevCx;
  double? txSecondaryX; // the transformer-secondary x (for the earthing mark)
  for (final node in chain) {
    if (prevCx != null) {
      prims.add(
          SldLine(prevCx, yMid, x, yMid, weight: SldWeight.medium, role: role));
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
        // Incoming isolator (bowtie). On the MV chain the label sits below;
        // on the LV head-only chain it moves ABOVE the symbol — the side-
        // source drop line leaves straight down from the head, exactly where
        // the below-label used to sit.
        _emitBowtie(prims, x, yMid, 11, role);
        prims.add(SldLabel(x - 10, isMv ? yMid + 26 : yMid - 20, node.name,
            size: 8.5, bold: true, role: role));
      case 'bus':
      default:
        // A distribution board as a labelled BOX (DXF convention).
        _emitPanelBox(prims, x, yMid, boxW, boxH, node.name, role);
    }
    prevCx = x;
    x += pitchX;
  }
  final lvX = x - pitchX; // the last chain node (feed-out to the root)
  if (!isMv) {
    // A short outgoing service lead so the lone head visibly feeds the root
    // board the canvas places to the right of the chain.
    prims.add(SldLine(lvX + 12, yMid, lvX + 46, yMid,
        weight: SldWeight.medium, role: role));
  }

  // GENSET + CAPACITOR (+ SOLAR PV + BATTERY) drop BELOW the LV bus, STACKED
  // vertically on the bus x with their labels to the LEFT (clear of the root
  // board placed to the right). A running cursor keeps the historic 58-px
  // pitch, so the pre-existing genset/capacitor coordinates are unchanged and
  // the new solar/battery nodes simply extend the stack.
  final hasGen = project.sources?.generator != null;
  var nextCy = yMid + 64; // the next side-node centre y
  // Drop-line start: the LV-bus box bottom on the MV chain, the bowtie's
  // lower edge on the LV head-only chain.
  var prevBottom = isMv ? yMid + 17 : yMid + 10;
  if (hasGen) {
    final gen = project.sources!.generator!;
    final backupVa = gensetBackupDemandVa(project, result);
    final genFig =
        _gensetKva(backupVa, gen, gensetBackupDemandW(project, result));
    final genKva = genFig.totalKva;
    final gcy = nextCy;
    prims.add(SldLine(lvX, prevBottom, lvX, gcy - 13,
        weight: SldWeight.medium, role: role));
    _emitGenerator(prims, lvX, gcy, 13, role);
    prims.add(SldLabel(lvX - 104, gcy - 1, 'GENSET ${genFig.text} kVA',
        size: 7.5, bold: true, role: role));
    prims.add(
        SldLabel(lvX - 104, gcy + 11, gen.mode.label, size: 7, role: role));
    // The honest coverage figure — this set against the building's diversified
    // demand, capped at 100%; printed only when a demand exists.
    final pct = _gensetBackupPctLabel(genKva, demandVa, result.supply.demandW);
    if (pct != null) {
      prims.add(SldLabel(lvX - 104, gcy + 23, pct, size: 7, role: role));
    }
    prevBottom = gcy + 13;
    nextCy += 58;
  }
  if (_hasCapacitorBank(project)) {
    final capSub = '${_num(project.capacitorBankKvar!)} kvar';
    final ccy = nextCy;
    prims.add(SldLine(lvX, prevBottom, lvX, ccy - 11,
        weight: SldWeight.medium, role: role));
    _emitCapacitor(prims, lvX, ccy, role);
    prims.add(SldLabel(lvX - 96, ccy + 2, 'CAP $capSub',
        size: 7.5, bold: true, role: role));
    prevBottom = ccy + 11;
    nextCy += 58;
  }
  if (project.sources?.solar != null) {
    final (head, sub) = _solarNodeLabels(project);
    final scy = nextCy;
    prims.add(SldLine(lvX, prevBottom, lvX, scy - 14,
        weight: SldWeight.medium, role: role));
    _emitPvArray(prims, lvX, scy, role);
    prims.add(
        SldLabel(lvX - 104, scy - 1, head, size: 7.5, bold: true, role: role));
    prims.add(SldLabel(lvX - 104, scy + 11, sub, size: 7, role: role));
    prevBottom = scy + 7;
    nextCy += 58;
  }
  if (project.sources?.battery != null) {
    final (head, sub) =
        _batteryNodeLabels(project, demandVa, result.supply.demandW);
    final bcy = nextCy;
    prims.add(SldLine(lvX, prevBottom, lvX, bcy - 13,
        weight: SldWeight.medium, role: role));
    _emitBattery(prims, lvX, bcy, role);
    prims.add(
        SldLabel(lvX - 104, bcy - 1, head, size: 7.5, bold: true, role: role));
    prims.add(SldLabel(lvX - 104, bcy + 11, sub, size: 7, role: role));
  }

  // System-earthing mark — at the transformer secondary on an MV chain (the
  // IEC earth symbol dropping BELOW the secondary winding, clear of the
  // genset / capacitor that hang under the LV bus to the right); on the LV
  // head-only chain it hangs to the LEFT of the supply head (the service
  // entrance — the side sources take the space below). Labelled with the
  // installation earthing-system designation.
  if (txSecondaryX != null) {
    const eTop = yMid + 40; // below the TRAFO label at yMid+28
    prims.add(SldLine(txSecondaryX, yMid + 11, txSecondaryX, eTop,
        weight: SldWeight.medium, role: role));
    _emitEarth(prims, txSecondaryX, eTop, role);
    prims.add(SldLabel(
        txSecondaryX + 12, eTop + 8, project.earthingSystem.label,
        size: 7, bold: true, role: role));
  } else {
    const headX = 0.0; // the supply head is the first chain node, at x = 0
    const earthX = headX - 44;
    prims.add(const SldLine(headX - 11, yMid, earthX, yMid,
        weight: SldWeight.medium, role: role));
    _emitEarth(prims, earthX, yMid, role);
    prims.add(SldLabel(earthX - 16, yMid + 30, project.earthingSystem.label,
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
  String? subtreeRootId,
  int? maxDepth,
}) {
  // children map over the feeder graph; parent + essential via shared helpers.
  final fullParentOf = _parentOf(project, result);
  // Round 23 (elec-drafting-2-1) — an issuable PAGE of a wide distribution
  // tree: [subtreeRootId] draws only that board + its descendants (the board
  // becomes the page's root, with a 'DARI <parent>' match note above it), and
  // [maxDepth] stops the tree at that depth (a cut board carries a
  // 'LANJUT KE DIAGRAM <board>' note below it). Both null ⇒ the whole tree.
  final fullChildren = <String, List<String>>{};
  for (final entry in fullParentOf.entries) {
    (fullChildren[entry.value] ??= []).add(entry.key);
  }
  Set<String>? include;
  if (subtreeRootId != null) {
    include = <String>{};
    final stack = [subtreeRootId];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (!include.add(id)) continue;
      stack.addAll(fullChildren[id] ?? const []);
    }
  }
  if (maxDepth != null) {
    final rel = <String, int>{};
    for (final id in result.order) {
      if (include != null && !include.contains(id)) continue;
      final par = fullParentOf[id];
      rel[id] = (par == null || (include != null && !include.contains(par)))
          ? 0
          : (rel[par] ?? 0) + 1;
    }
    include = {
      for (final e in rel.entries)
        if (e.value <= maxDepth) e.key,
    };
  }
  final order = [
    for (final id in result.order)
      if (include == null || include.contains(id)) id,
  ];
  final parentOf = <String, String>{
    for (final e in fullParentOf.entries)
      if (include == null ||
          (include.contains(e.key) && include.contains(e.value)))
        e.key: e.value,
  };
  // A sub-tree page never repeats the building's source spine.
  if (subtreeRootId != null) sourceChain = false;
  final (feederCircuitOf, feederResultOf) =
      _feederLabelLookups(project, result, parentOf);
  final children = <String, List<String>>{};
  for (final entry in parentOf.entries) {
    (children[entry.value] ??= []).add(entry.key);
  }
  // Preserve order within each parent's child list (was insertion order
  // over the feeder graph; root-first order is a faithful proxy).
  final essential = essentialPanelIds(project, result);
  final panelModelById = {for (final p in project.panels) p.id: p};

  // ── Tree layout: x by leaf order (in-order), y by depth ─────────────────────
  final depth = <String, int>{};
  for (final id in order) {
    final par = parentOf[id];
    depth[id] = par == null ? 0 : (depth[par] ?? 0) + 1;
  }
  final roots = [
    for (final id in order)
      if (!parentOf.containsKey(id)) id
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
      prims
          .add(SldLine(zx, midY, zx, zy, weight: SldWeight.medium, role: role));
    }
  }

  // ── Feeder annotations: collision-resolved BEFORE anything is emitted ───────
  // X2: two feeders leaving ONE parent share the same mid-segment row, so their
  // annotations printed on top of each other. The riser's placer idiom applies
  // unchanged here: every tag keeps its DEFAULT anchor when that is clear (so a
  // single-feeder parent — and every uncollided sheet — is byte-identical), and
  // a colliding tag walks a bounded stagger ladder, leadering back to the branch
  // it names. A tag is drawing CONTENT: it is never dropped.
  final ovSlot = <String, (double, double)>{};
  final ovLabel = <String, String>{};
  final ovDefault = <String, (double, double)>{};
  final ovCleared = <String, bool>{};
  {
    final ovPlacer = _RiserLabelPlacer([
      for (final id in order)
        if (cx.containsKey(id))
          _RiserBox(cx[id]!, nodeY(id), cx[id]! + _ovW, nodeY(id) + _ovH),
    ]);
    final pending = <String>[];
    for (final entry in children.entries) {
      final ax = cx[entry.key]! + _ovW / 2;
      final ay = nodeY(entry.key) + _ovH;
      // Every sibling's drop x, so a RIGHT-hand child's tag can sit on the bus
      // segment that is its own (Round 23).
      final drops = [
        for (final k in entry.value)
          if (cx.containsKey(k)) cx[k]! + _ovW / 2,
      ];
      for (final child in entry.value) {
        if (!cx.containsKey(child)) continue;
        final lbl = _feederConnLabel(feederCircuitOf, feederResultOf, child,
            parentThreePhase: _parentIsThreePhase(parentOf, result, child));
        if (lbl == null) continue;
        final zx = cx[child]! + _ovW / 2;
        final midY = (ay + nodeY(child)) / 2;
        // Round 23 (elec-drafting-2-4) — a child LEFT of (or under) its
        // parent keeps the anchor at its own drop; a child to the RIGHT used to
        // anchor at min(ax, zx) = the PARENT's drop, so every right-hand
        // sibling's tag piled over another feeder's drop. It now ends at its
        // OWN drop, on the bus segment only it uses (from the nearest drop to
        // its left — a sibling or the parent's), never starting left of that.
        final double slotX;
        if (zx > ax + 1e-6) {
          var prev = ax;
          for (final d in drops) {
            if (d < zx - 1e-6 && d > prev) prev = d;
          }
          final w = _riserLabelWidth(lbl, _ovFeederLabelSize);
          slotX = math.max(prev + 4, zx - w - 4);
        } else {
          slotX = zx + 4;
        }
        final slot = (slotX, midY - 4);
        ovLabel[child] = lbl;
        ovDefault[child] = slot;
        ovSlot[child] = slot;
        ovCleared[child] = true;
        if (!ovPlacer.reserveIfClear(slot, lbl, _ovFeederLabelSize)) {
          pending.add(child);
        }
      }
    }
    for (final child in pending) {
      final r = ovPlacer.escape(_ovLabelLadder(ovDefault[child]!),
          ovLabel[child]!, _ovFeederLabelSize);
      ovSlot[child] = r.slot;
      ovCleared[child] = r.cleared;
    }
  }
  // The extents of any DISPLACED annotation, folded into the bounds below so an
  // escaped tag is never clipped (no displacement ⇒ the bounds are unchanged).
  var ovLabelMaxX = double.negativeInfinity;
  var ovLabelMinY = double.infinity;
  var ovLabelMaxY = double.negativeInfinity;

  // Feeders parent→child: drop from parent bottom, orthogonal, into child top.
  // Sibling feeders share the parent's drop + bus run; those shared pieces are
  // drawn ONCE (via [_mergeFeederSegments]) instead of once per child on the
  // same coordinates, where the last child's colour won (drafting-3).
  for (final entry in children.entries) {
    final ax = cx[entry.key]! + _ovW / 2;
    final ay = nodeY(entry.key) + _ovH;
    final routes = <_FeederSeg>[];
    for (final child in entry.value) {
      if (!cx.containsKey(child)) continue;
      final zx = cx[child]! + _ovW / 2;
      final zy = nodeY(child);
      final role =
          essential.contains(child) ? SldRole.essential : SldRole.normal;
      final midY = (ay + zy) / 2;
      routes
        ..add(_FeederSeg(ax, ay, ax, midY, role))
        ..add(_FeederSeg(ax, midY, zx, midY, role))
        ..add(_FeederSeg(zx, midY, zx, zy, role));
    }
    prims.addAll(_mergeFeederSegments(routes,
        parentRole: essential.contains(entry.key)
            ? SldRole.essential
            : SldRole.normal));
    for (final child in entry.value) {
      if (!cx.containsKey(child)) continue;
      final zx = cx[child]! + _ovW / 2;
      final zy = nodeY(child);
      final role =
          essential.contains(child) ? SldRole.essential : SldRole.normal;
      final midY = (ay + zy) / 2;
      // Feeder annotation (cable + breaker) on the mid horizontal segment, just
      // above the line; omitted when the parent feeding circuit can't resolve.
      final lbl = ovLabel[child];
      if (lbl != null) {
        final (lx, ly) = ovSlot[child]!;
        final def = ovDefault[child]!;
        final dx = lx - def.$1, dy = ly - def.$2;
        if (dx != 0 || dy != 0) {
          ovLabelMaxX = math.max(
              ovLabelMaxX, lx + _riserLabelWidth(lbl, _ovFeederLabelSize));
          ovLabelMinY = math.min(ovLabelMinY, ly - _ovFeederLabelSize);
          ovLabelMaxY = math.max(ovLabelMaxY, ly);
        }
        // Pulled well off its anchor — or unable to fully clear — ⇒ a thin
        // leader from the mid segment it annotates back to the tag.
        if (!(ovCleared[child] ?? true) ||
            math.sqrt(dx * dx + dy * dy) > _kRiserLeaderThreshold) {
          final bx = math.min(math.max(lx, math.min(ax, zx)), math.max(ax, zx));
          final rx = lx + _riserLabelWidth(lbl, _ovFeederLabelSize);
          prims.add(SldLine(bx, midY, rx < bx ? rx : lx, ly,
              weight: SldWeight.thin, role: role));
        }
        prims.add(SldLabel(lx, ly, lbl, size: _ovFeederLabelSize, role: role));
      }
    }
  }

  // Compact panel nodes.
  for (final id in order) {
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
        x + 7, y + 33, _compactNodeSubLine(p, model: panelModelById[id]),
        size: 7.5, role: role));
    // Page match notes (Round 23): a board whose sub-tree was cut continues
    // on its own diagram; a sub-tree page's root names the board feeding it.
    final cut = (fullChildren[id] ?? const <String>[])
        .any((k) => result.panels.containsKey(k) && !cx.containsKey(k));
    if (cut) {
      prims.add(SldLine(x + _ovW / 2, y + _ovH, x + _ovW / 2, y + _ovH + 14,
          weight: SldWeight.medium, role: role));
      prims.add(SldLabel(
          x + _ovW / 2 + 4, y + _ovH + 12, 'LANJUT KE DIAGRAM ${p.name}',
          size: _ovFeederLabelSize, role: role));
    }
    final par = fullParentOf[id];
    if (par != null && !parentOf.containsKey(id)) {
      final parName = result.panels[par]?.name ?? par;
      prims.add(SldLine(x + _ovW / 2, y - 14, x + _ovW / 2, y,
          weight: SldWeight.medium, role: role));
      prims.add(SldLabel(x + _ovW / 2 + 4, y - 6, 'DARI $parName',
          size: _ovFeederLabelSize, role: role));
    }
  }

  // ── Bounds ─────────────────────────────────────────────────────────────────
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final id in order) {
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
          // drafting-9: a label's glyphs rise ABOVE its baseline, so its top
          // (y - size) bounds the sheet, not the baseline.
          minX = math.min(minX, pr.x);
          minY = math.min(minY, pr.y - pr.size);
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
  // X2: a DISPLACED feeder annotation may reach past the tree — widen the sheet
  // so it can't be clipped (no displacement ⇒ -/+infinity ⇒ bounds unchanged).
  maxX = math.max(maxX, ovLabelMaxX);
  minY = math.min(minY, ovLabelMinY);
  maxY = math.max(maxY, ovLabelMaxY);
  // Page match notes (sub-tree / depth-cut pages only) extend the bounds.
  if (subtreeRootId != null || maxDepth != null) {
    for (final pr in prims) {
      if (pr is SldLabel &&
          (pr.text.startsWith('LANJUT KE DIAGRAM') ||
              pr.text.startsWith('DARI '))) {
        minY = math.min(minY, pr.y - pr.size - 8);
        maxY = math.max(maxY, pr.y + 2);
        maxX = math.max(maxX, pr.x + _riserLabelWidth(pr.text, pr.size));
      }
    }
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
      if (_anyEssentialPrim(prims))
        const SldLegendEntry('Essential', 'Essential / emergency supply'),
      if (sourceChain)
        const SldLegendEntry('Source', 'Utility / MV supply chain'),
      // The source spine draws the system-earthing mark, so surface it too.
      if (sourceChain) const SldLegendEntry('Earth', 'System earthing point'),
    ],
    supplyNote: supplyNote,
  );
}

// ── FLOOR-BY-FLOOR electrical riser (panels by building level) ───────────────

/// Gutter + band geometry for the riser.
const double _riserGutterW = 150;
const double _riserBandH = 167;
const double _riserPanelGap = 24;

/// How far above a band's boxes its BUS ROW runs — the clear gap between the
/// previous band's floor grid line (31 units above the boxes:
/// `_riserBandH − _ovH − _fanColH − _riserPanelGap/2` = 167 − 46 − 78 − 12)
/// and the box tops, where a feeder / supply leg that would otherwise cross a
/// board is routed instead. A drafting choice, not a standard.
const double _riserBusOffset = 12;

/// Several legs can need a band's bus row at once (a parent leg AND a child leg
/// of DIFFERENT feeders, say). Sharing one row would draw them collinear —
/// reading as one connected bus, a false topology — so every leg gets its OWN
/// TRACK in the clear gap above the boxes. Legs leaving ONE parent board share
/// that board's track (one source bus — a truthful common connection). A
/// drafting choice, not a standard.
///
/// Tracks are claimed in GEOMETRIC order — RIGHT-TO-LEFT by jog x — and the
/// offsets rise MONOTONICALLY with the claim index, so a left board's track
/// horizontal always passes ABOVE every right board's jog vertical (which
/// rises from its centre-line to its own, lower track) instead of crossing it:
/// a band draws no feeder crossing however many boards it carries.
///
/// Up to [_riserBusLegacyTracks] tracks keep the legacy rows (12 / 17 / 22 / 27
/// above the box tops ⇒ a band with ≤ 4 jogs is byte-identical). A denser band
/// spreads its n tracks evenly from [_riserBusGapBottom] up to
/// [_riserBusGapTop] (never past the hairline [_riserBusGap] above the boxes,
/// so never into the upper band's fan-out column); once that spacing would
/// drop under [_riserBusMinPitch] the band GROWS ([_riserBusTrackExtra]).
const double _riserBusTrackPitch = 5;
const int _riserBusLegacyTracks = 4;

/// The clear gap between a band's box tops and the floor-grid hairline of the
/// band above (`_riserBandH − _ovH − _fanColH − _riserPanelGap/2` = 31).
const double _riserBusGap = _riserBandH - _ovH - _fanColH - _riserPanelGap / 2;

/// Lowest / highest track offsets above the box tops for a dense band — 4
/// clear of the box edge, 2 clear of the hairline.
const double _riserBusGapBottom = 4;
const double _riserBusGapTop = _riserBusGap - 2;

/// The tightest track spacing a dense band accepts before it grows.
const double _riserBusMinPitch = 3;

/// Offset above the box tops of a band's [k]-th of [n] bus tracks, given the
/// [extra] height the band grew by. Strictly increasing in [k] for every [n].
double _riserBusTrackOffset(int k, int n, double extra) {
  if (n <= _riserBusLegacyTracks) {
    return _riserBusOffset + k * _riserBusTrackPitch;
  }
  final span = _riserBusGapTop + extra - _riserBusGapBottom;
  final pitch = math.min(_riserBusTrackPitch, span / (n - 1));
  return _riserBusGapBottom + k * pitch;
}

/// Extra height a band with [n] bus tracks needs above its boxes so its tracks
/// keep at least [_riserBusMinPitch] apart under the hairline (0 ⇒ fits).
double _riserBusTrackExtra(int n) {
  if (n <= _riserBusLegacyTracks) return 0;
  final need = _riserBusGapBottom + (n - 1) * _riserBusMinPitch;
  return need > _riserBusGapTop ? (need - _riserBusGapTop).ceilToDouble() : 0;
}

/// One feeder's two legs on the riser (child + parent edges, centre lines, and
/// whether each must jog to its band's bus track).
typedef _RiserLeg = ({
  String child,
  String parent,
  double cxx,
  double pxx,
  double pyy,
  double cyy,
  bool pJog,
  bool cJog,
});

/// Per-floor branch fan-out: how many outgoing LOAD ways a riser panel shows as
/// labelled stubs before collapsing the remainder to a `+N more` summary, the
/// pitch of each stub row, and the reserved column height that the floor grid
/// line clears (so the densest board never overruns the next band).
///
/// drafting-6: the 13-unit pitch and the 6-unit gap under the box leave room
/// for the plot fit (`sld_plot_fit.dart`) to grow each stub label to the
/// minimum plotted size on a scaled-down sheet without touching the box or the
/// next row (was an 11 pitch with a 4 gap, which boxed the labels in).
/// Round 23 (elec-drafting-2-7) — the first stub starts ONE ROW PITCH below
/// the box (a 6-unit gap left the first row's text touching every board's
/// bottom border once grown); the band grows by the same 7 units so the bus
/// gap above the boxes stays 31.
const int kRiserFanMax = 4;
const double _fanRowH = 13;
const double _fanTopGap = _fanRowH;
const double _fanColH = (kRiserFanMax + 1) * _fanRowH + _fanTopGap;

/// Drawn size of a fan-out stub label — also the font-size term in its
/// name-truncation budget (`kElectricalRiserLabelCharW * _fanLabelSize`),
/// consistent with the feeder-annotation collision boxes' own font-scaled
/// advance.
const double _fanLabelSize = 6;

/// Format a true elevation (m) as an FFL tag like `+12.50` / `-3.00`.
String _ffl(double meters) => signedElevationText(meters);

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

// ── Feeder-annotation collision avoidance (riser only) ──────────────────────
// Several boards packed into ONE floor band sit squarely under the branch a
// feeder annotation rides on, so the default anchor (just right of the child's
// box, on the branch) printed straight over a sibling board. The placer below
// keeps that DEFAULT anchor whenever it is clear — a riser whose bands hold one
// board each is unchanged — and otherwise walks an escape ladder until the tag
// clears every board box and every already-placed tag, leadering back to the
// branch it names. A tag is drawing CONTENT: it is never dropped.

/// Text size of a feeder annotation (the size the tag has always been drawn at).
const double _riserFeederLabelSize = 6.5;

/// A single per-size character advance used to size a feeder annotation's
/// collision box (width = chars x size x this).
/// VERIFY: a representative average glyph advance for the drawing font — a
/// drafting collision metric, not a standard. Public so the collision unit test
/// sizes its boxes with the SAME constant the builder uses.
const double kElectricalRiserLabelCharW = 0.6;

/// A slot pulled more than this far (drawing units) off the default anchor gets
/// a thin leader back to the branch it annotates. // VERIFY: a drafting
/// declutter heuristic, not a standard.
const double _kRiserLeaderThreshold = 14;

/// Vertical pitch of the right-of-channel annotation column and how many stacked
/// slots it offers — the escape budget for one floor band's displaced tags.
const double _kRiserLabelStackH = 10;
const int _kRiserStackSlots = 12;

/// Overlap penalty for a slot reaching into the floor-name GUTTER column, so the
/// ladder always steps past it (an area, to stay comparable with real overlaps).
const double _kRiserGutterPenalty = 1e9;

/// The collision-box width of [text] drawn at [size].
double _riserLabelWidth(String text, double size) =>
    text.length * size * kElectricalRiserLabelCharW;

/// An axis-aligned box in drawing space (a label's baseline is its [maxY], the
/// text rising to [minY]).
class _RiserBox {
  final double minX, minY, maxX, maxY;
  const _RiserBox(this.minX, this.minY, this.maxX, this.maxY);

  /// Overlap AREA with [o] (0 when disjoint) — used to rank the least-bad slot.
  double overlap(_RiserBox o) {
    final dx = math.min(maxX, o.maxX) - math.max(minX, o.minX);
    final dy = math.min(maxY, o.maxY) - math.max(minY, o.minY);
    return (dx <= 0 || dy <= 0) ? 0 : dx * dy;
  }
}

/// Greedy placer for the riser's feeder annotations: it knows every board box
/// (fixed) plus every tag it has already reserved, and hands each tag either its
/// default anchor (when clear) or the first ladder slot that clears them all —
/// else the least-overlapping one. Deterministic given a stable feeder order.
class _RiserLabelPlacer {
  final List<_RiserBox> _fixed;

  /// Left margin a slot must stay clear of (the riser's floor-name gutter).
  /// 0 ⇒ no gutter (the overview has none), so the penalty never fires.
  final double _gutterX;
  final List<_RiserBox> _placed = <_RiserBox>[];
  _RiserLabelPlacer(this._fixed, {double gutterX = 0}) : _gutterX = gutterX;

  _RiserBox _boxFor((double, double) slot, String text, double size) =>
      _RiserBox(slot.$1, slot.$2 - size, slot.$1 + _riserLabelWidth(text, size),
          slot.$2);

  /// Total overlap AREA of a tag box at [slot] against every board box and every
  /// reserved tag (plus the gutter penalty).
  double _overlapAt((double, double) slot, String text, double size) {
    final r = _boxFor(slot, text, size);
    var total = slot.$1 < _gutterX ? _kRiserGutterPenalty : 0.0;
    for (final b in _fixed) {
      total += b.overlap(r);
    }
    for (final b in _placed) {
      total += b.overlap(r);
    }
    return total;
  }

  /// Reserve [slot] when nothing collides with it; true ⇒ the tag keeps it.
  bool reserveIfClear((double, double) slot, String text, double size) {
    if (_overlapAt(slot, text, size) > 0) return false;
    _placed.add(_boxFor(slot, text, size));
    return true;
  }

  /// Walk [ladder] (default first) and reserve the first slot that clears every
  /// board box and reserved tag; when NONE clears, the least-overlapping slot is
  /// reserved anyway (a feeder spec is never dropped) and `cleared` is false so
  /// the caller always leaders it back to its branch.
  ({(double, double) slot, bool cleared}) escape(
      List<(double, double)> ladder, String text, double size) {
    var best = ladder.first;
    var bestOverlap = double.infinity;
    var cleared = false;
    for (final slot in ladder) {
      final total = _overlapAt(slot, text, size);
      if (total <= 0) {
        best = slot;
        cleared = true;
        break;
      }
      if (total < bestOverlap) {
        bestOverlap = total;
        best = slot;
      }
    }
    _placed.add(_boxFor(best, text, size));
    return (slot: best, cleared: cleared);
  }
}

/// One drawn feeder run + the annotation slot chosen for it.
class _RiserFeeder {
  final SldRole role;
  final String parent; // the feeding board's id (groups the shared trunk)
  final double px, py; // parent box right edge / its centre-line
  final double cx, cy; // child box right edge / the branch line
  final double bandRight; // rightmost board edge on the CHILD's band
  final String? label;

  /// Bus-row y of the PARENT leg when a board in the parent's band sits between
  /// the parent's right edge and the channel: the leg jogs up into the band's
  /// clear gap above the boxes instead of running THROUGH that board (which read
  /// as if the far board were on this feeder's path). Null ⇒ the straight
  /// legacy leg at [py].
  final double? parentBusY;

  /// Bus-row y of the CHILD leg when a board sits between the channel and the
  /// child's right edge (the same jog, on the child's band). Null ⇒ the
  /// straight legacy branch at [cy].
  final double? childBusY;
  (double, double) slot = (0, 0);
  bool cleared = true; // false ⇒ nothing cleared; always leadered
  _RiserFeeder({
    required this.role,
    required this.parent,
    required this.px,
    required this.py,
    required this.cx,
    required this.cy,
    required this.bandRight,
    required this.label,
    this.parentBusY,
    this.childBusY,
  });

  /// The y the branch runs at OUTSIDE the band's boxes (right of the band, up
  /// to the channel): the bus row when the child leg jogs, else [cy].
  double get branchY => childBusY ?? cy;

  /// The x where a jogged leg turns between its bus row and the box centre-line
  /// — the middle of the inter-board gap just right of the box edge [edgeX].
  static double jogX(double edgeX) => edgeX + _riserPanelGap / 2;

  /// The legacy anchor: on the branch, just right of the child's box.
  (double, double) defaultSlot(double channelX) =>
      (math.min(cx, channelX) + 6, cy - 4);

  /// Escape ladder (default first, so an un-collided tag never moves):
  ///   1. the clear span of the branch between the band's RIGHTMOST board edge
  ///      and the channel — above, then below the branch line — offered only
  ///      when the tag actually FITS inside that span;
  ///   2. a right-of-channel annotation column, stacked around the branch height
  ///      (down, then up, growing) so several tags off ONE band never fuse.
  /// Nothing is drawn beyond the channel, so (2) always clears within its slot
  /// budget for a realistic band.
  List<(double, double)> ladder(double channelX, double size) {
    final w = _riserLabelWidth(label!, size);
    final spanFits = bandRight + 8 + w <= channelX - 4;
    // A jogged branch runs at its bus row right of the band, so the clear-span
    // and annotation-column slots ride THAT line (else a tag would float beside
    // a branch segment that is no longer drawn).
    final by = branchY;
    return [
      defaultSlot(channelX),
      if (spanFits) (bandRight + 8, by - 4),
      if (spanFits) (bandRight + 8, by + 12),
      for (var k = 0; k < _kRiserStackSlots; k++)
        (
          channelX + 10,
          by - 4 + (k.isOdd ? 1 : -1) * ((k + 1) ~/ 2) * _kRiserLabelStackH,
        ),
    ];
  }
}

/// One axis-aligned feeder segment a single child's route asks for.
class _FeederSeg {
  final double x1, y1, x2, y2;
  final SldRole role;
  const _FeederSeg(this.x1, this.y1, this.x2, this.y2, this.role);
}

/// Merge ONE parent's per-child feeder routes into non-overlapping lines: every
/// axis line (a vertical at one x / a horizontal at one y) is split at all the
/// route endpoints on it, and each elementary piece is emitted once — in the
/// single role of the routes covering it, or the PARENT's role where normal and
/// essential routes share it (the parent's own outgoing bus). Adjacent pieces of
/// equal role are re-joined, so a lone child's route comes back as its exact
/// legacy three lines. Zero-length segments are dropped.
List<SldLine> _mergeFeederSegments(List<_FeederSeg> segs,
    {required SldRole parentRole}) {
  // key: ('v', x) or ('h', y) → list of (lo, hi, role)
  final lines = <(bool, double), List<(double, double, SldRole)>>{};
  for (final g in segs) {
    if (g.x1 == g.x2 && g.y1 != g.y2) {
      (lines[(true, g.x1)] ??= [])
          .add((math.min(g.y1, g.y2), math.max(g.y1, g.y2), g.role));
    } else if (g.y1 == g.y2 && g.x1 != g.x2) {
      (lines[(false, g.y1)] ??= [])
          .add((math.min(g.x1, g.x2), math.max(g.x1, g.x2), g.role));
    }
  }
  final out = <SldLine>[];
  for (final entry in lines.entries) {
    final (vertical, at) = entry.key;
    final spans = entry.value;
    final cuts = <double>{
      for (final sp in spans) ...[sp.$1, sp.$2]
    }.toList()
      ..sort();
    double? runLo;
    double runHi = 0;
    SldRole? runRole;
    void flush() {
      if (runLo == null || runRole == null) return;
      out.add(vertical
          ? SldLine(at, runLo!, at, runHi,
              weight: SldWeight.medium, role: runRole!)
          : SldLine(runLo!, at, runHi, at,
              weight: SldWeight.medium, role: runRole!));
      runLo = null;
      runRole = null;
    }

    for (var i = 0; i + 1 < cuts.length; i++) {
      final lo = cuts[i], hi = cuts[i + 1];
      final roles = {
        for (final sp in spans)
          if (sp.$1 <= lo && sp.$2 >= hi) sp.$3
      };
      if (roles.isEmpty) {
        flush();
        continue;
      }
      final role = roles.length == 1 ? roles.first : parentRole;
      if (runLo != null && runRole == role && runHi == lo) {
        runHi = hi;
      } else {
        flush();
        runLo = lo;
        runHi = hi;
        runRole = role;
      }
    }
    flush();
  }
  return out;
}

/// Build the FLOOR-BY-FLOOR electrical riser: every panel placed on its building
/// FLOOR (by true elevation — highest floor at the TOP of the y-down sheet),
/// laid left-to-right within its floor band; feeders draw as a vertical riser in
/// a right-hand channel + horizontal branches into each panel; a left GUTTER
/// column carries each floor's name + FFL elevation and a hairline grid line.
///
/// Floor assignment precedence: (1) `panel.layoutPos.floorIndex` when set and in
/// range; (2) ELSE feeder-depth tier rising from the GROUND (entrance) floor —
/// root at ground, each depth one floor up (Round 15); (3) clamp any
/// out-of-range index. When [building] is null / has no levels it degrades to
/// pure feeder-depth TIERS (gutter shows `Tier n`, no elevation) — never throws.
///
/// When [sourceChain] is true a PLN/MV/transformer/LV-main source spine is
/// drawn: ABOVE the top floor band when a root board sits on the top band,
/// else (Round 23, elec-drafting-2-6) BESIDE the highest root's band — in a
/// column left of the floor gutter, with a short lead into the root — so the
/// PLN / transformer / genset sit at the substation level next to the LV main
/// instead of at roof level with a service cable descending every storey.
/// [mounting] is accepted for signature parity with the mechanical riser; it
/// is unused here.
///
/// [floorRange] (Round 23, elec-drafting-2-1) crops the sheet to those bands
/// (an issuable PAGE of a tall riser): every feeder that leaves the page is
/// cut at the page edge with a `LANJUT KE <floor>` match stub, and the source
/// spine rides the page that carries its root band. Null ⇒ the whole riser.
///
/// Each feeder's cable/breaker annotation keeps its default anchor (on the
/// branch, just right of the child's box) whenever that is clear; when boards
/// share a band it escapes past them (see [_RiserFeeder.ladder]) and is leadered
/// back to its branch, so a tag never prints over a sibling board.
SldSheet buildElectricalRiser({
  required ElectricalProject project,
  required ElectricalSystemResult result,
  BuildingLevels? building,
  MountingHeights mounting = const MountingHeights(),
  bool sourceChain = false,
  ({int lo, int hi})? floorRange,
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
  final maxDepth = depth.values.isEmpty ? 0 : depth.values.reduce(math.max);

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
      // Round 15 (drafting-visual-2-4) — unplaced ⇒ a depth tier RISING from
      // the service-entrance (GROUND) floor: the PLN-fed root sits at the
      // entrance and each feeder depth climbs one floor (riser convention).
      // It used to land the root on the TOP floor stamped with that floor's
      // real FFL (+7.50) — a fabricated location — with Ground left empty.
      final d = depth[id] ?? 0;
      return (building.groundIndex + d).clamp(0, levelCount - 1);
    }
    // No floors ⇒ tier mode: root (depth 0) at the top band (highest index).
    final d = depth[id] ?? 0;
    return (levelCount - 1 - d).clamp(0, levelCount - 1);
  }

  // Elevation→y: the highest floor maps to the smallest y. With a degenerate
  // (zero-span) building use a fixed band height so we never divide by zero.
  final topIndex = levelCount - 1;
  // Extra height inserted ABOVE a band's boxes when its bus tracks outgrow the
  // clear gap under the hairline (see [_riserBusTrackExtra]); it shifts that
  // band and every band below it down. Empty ⇒ the fixed pitch, byte-identical.
  final bandExtra = <int, double>{};
  double bandY(int floorIndex) {
    var y = (topIndex - floorIndex) * _riserBandH;
    for (var j = floorIndex; j <= topIndex; j++) {
      y += bandExtra[j] ?? 0;
    }
    return y;
  }

  // ── Optional source spine ───────────────────────────────────────────────────
  final prims = <SldPrim>[];
  var contentOffsetY = 0.0;
  ({List<SldPrim> prims, double height, double feedX, double feedY})? spine;
  // Round 23 (elec-drafting-2-6) — when every root board sits BELOW the top
  // band the spine is drawn beside the highest root's band (placed once the
  // band positions are final, below); only a top-band root keeps it above.
  final rootIds = [
    for (final id in result.order)
      if (!parentOf.containsKey(id) && result.panels.containsKey(id)) id,
  ];
  final spineBeside = sourceChain &&
      rootIds.isNotEmpty &&
      rootIds.every((r) => floorOf(r) < topIndex);
  String? spineRoot;
  if (spineBeside) {
    for (final r in rootIds) {
      if (spineRoot == null || floorOf(r) > floorOf(spineRoot)) spineRoot = r;
    }
  }
  if (sourceChain && !spineBeside) {
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
  void placePanels() {
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
  }

  placePanels();

  // ── Feeders: vertical riser in a right-hand channel + horizontal branches ───
  final channelX = sheetMaxX + 40;
  // The rightmost board edge per band bounds the clear span of that band's
  // branches (a displaced annotation's first escape).
  final bandRightEdge = <int, double>{};
  for (final entry in byFloor.entries) {
    var right = _riserGutterW + _riserPanelGap;
    for (final id in entry.value) {
      right = math.max(right, panelX[id]! + _ovW);
    }
    bandRightEdge[entry.key] = right;
  }
  // Topology honesty: a feeder / supply segment must never run THROUGH a board
  // box it does not connect to (it would read as if that board were on its
  // path). These test an axis-aligned segment against every board's INTERIOR
  // (0.5 pt inset, so touching an edge is fine).
  bool hBlocked(double y, double xa, double xb) {
    final lo = math.min(xa, xb), hi = math.max(xa, xb);
    for (final id in panelX.keys) {
      final x0 = panelX[id]! + 0.5, x1 = panelX[id]! + _ovW - 0.5;
      final y0 = panelY[id]! + 0.5, y1 = panelY[id]! + _ovH - 0.5;
      if (y > y0 && y < y1 && lo < x1 && hi > x0) return true;
    }
    return false;
  }

  bool vBlocked(double x, double ya, double yb) {
    final lo = math.min(ya, yb), hi = math.max(ya, yb);
    for (final id in panelX.keys) {
      final x0 = panelX[id]! + 0.5, x1 = panelX[id]! + _ovW - 0.5;
      final y0 = panelY[id]! + 0.5, y1 = panelY[id]! + _ovH - 0.5;
      if (x > x0 && x < x1 && lo < y1 && hi > y0) return true;
    }
    return false;
  }

  // Does a root's source drop need the dedicated left trunk? The root sits
  // below other bands when the legacy three-leg drop at its centre column would
  // run straight through a board in between (see the drawing pass below).
  // Shared by the track pre-claim AND the drawing so the two always agree.
  bool rootNeedsTrunk(String id) {
    final sp = spine;
    if (sp == null || spineBeside) return false;
    final zx = panelX[id]! + _ovW / 2;
    final zy = panelY[id]!;
    final midY = (sp.feedY + zy) / 2;
    return vBlocked(sp.feedX, sp.feedY, midY) ||
        hBlocked(midY, sp.feedX, zx) ||
        vBlocked(zx, midY, zy);
  }

  // One record per drawn feeder, in the deterministic parent-map order. Which
  // legs must jog is decided first; their bus tracks are then claimed per band
  // in GEOMETRIC order — RIGHT-TO-LEFT by jog x (see [_riserBusTrackOffset]) —
  // so no track horizontal crosses another leg's jog vertical.
  List<_RiserLeg> buildLegs() => [
        for (final entry in parentOf.entries)
          if (panelX.containsKey(entry.key) && panelX.containsKey(entry.value))
            (
              child: entry.key,
              parent: entry.value,
              cxx: panelX[entry.key]! + _ovW, // child right edge
              pxx: panelX[entry.value]! + _ovW, // parent right edge
              pyy: panelY[entry.value]! + _ovH / 2,
              cyy: panelY[entry.key]! + _ovH / 2,
              // A board between a leg's box and the channel ⇒ that leg jogs to
              // its band's bus row (the clear gap above the boxes). One board
              // per band ⇒ nothing blocks ⇒ the straight legacy geometry,
              // byte-identical.
              pJog: hBlocked(panelY[entry.value]! + _ovH / 2,
                  panelX[entry.value]! + _ovW, channelX),
              cJog: hBlocked(panelY[entry.key]! + _ovH / 2, channelX,
                  panelX[entry.key]! + _ovW),
            ),
      ];

  // Every bus-track claim, per band, in GEOMETRIC claim order: feeder legs
  // right-to-left by jog x (legs leaving ONE parent board share its key ⇒ one
  // track), then the source rows (`top` / `s:<root>`), which ride the LEFT
  // trunk and so sort last (leftmost) — the root is the first board of its
  // band, so its row crosses no jog.
  List<({String key, int band})> buildClaims(List<_RiserLeg> legs) {
    final claims = <({String key, int band, double jx, int seq})>[];
    final claimed = <String>{};
    void claim(String key, int band, double jx) {
      if (!claimed.add(key)) return;
      claims.add((key: key, band: band, jx: jx, seq: claims.length));
    }

    for (final l in legs) {
      if (l.pJog) {
        claim('p:${l.parent}', floorOf(l.parent), _RiserFeeder.jogX(l.pxx));
      }
      if (l.cJog) {
        claim('c:${l.child}', floorOf(l.child), _RiserFeeder.jogX(l.cxx));
      }
    }
    for (final id in result.order) {
      if (parentOf.containsKey(id) || !panelX.containsKey(id)) continue;
      if (spineBeside) {
        // The beside-spine lead rides its own row above the root's boxes.
        claim('s:$id', floorOf(id), double.negativeInfinity);
        continue;
      }
      if (!rootNeedsTrunk(id)) continue;
      claim('top', topIndex, double.negativeInfinity);
      if (floorOf(id) != topIndex) {
        claim('s:$id', floorOf(id), double.negativeInfinity);
      }
    }
    claims.sort((a, b) {
      if (a.band != b.band) return a.band.compareTo(b.band);
      final byX = b.jx.compareTo(a.jx); // rightmost first
      return byX != 0 ? byX : a.seq.compareTo(b.seq);
    });
    return [for (final c in claims) (key: c.key, band: c.band)];
  }

  Map<int, int> perBand(List<({String key, int band})> claims) {
    final n = <int, int>{};
    for (final c in claims) {
      n[c.band] = (n[c.band] ?? 0) + 1;
    }
    return n;
  }

  // A band whose tracks would sit closer than [_riserBusMinPitch] in the clear
  // gap GROWS (extra height above its boxes) rather than letting a track climb
  // past the hairline into the upper band's fan-out column. Growth shifts the
  // bands below, so the legs/claims are re-derived on the final positions.
  var legs = buildLegs();
  var claims = buildClaims(legs);
  var trackCount = perBand(claims);
  for (final e in trackCount.entries) {
    final extra = _riserBusTrackExtra(e.value);
    if (extra > 0) bandExtra[e.key] = extra;
  }
  if (bandExtra.isNotEmpty) {
    placePanels();
    legs = buildLegs();
    claims = buildClaims(legs);
    trackCount = perBand(claims);
  }
  final busTrackOf = <String, double>{};
  final claimedSoFar = <int, int>{};
  for (final c in claims) {
    final k = claimedSoFar[c.band] ?? 0;
    claimedSoFar[c.band] = k + 1;
    busTrackOf[c.key] = bandY(c.band) +
        contentOffsetY -
        _riserBusTrackOffset(k, trackCount[c.band]!, bandExtra[c.band] ?? 0);
  }

  // Prims that belong to the beside-root source spine + its root leads: kept
  // WHOLE on the page that carries the spine root's band (never cropped).
  final spineGroup = <SldPrim>{};
  if (spineBeside) {
    final raw = _buildSourceSpine(project, result, 0);
    var sMaxX = -double.infinity;
    for (final pr in raw.prims) {
      sMaxX = math.max(
          sMaxX,
          switch (pr) {
            SldRect() => pr.x + pr.w,
            SldLine() => math.max(pr.x1, pr.x2),
            SldLabel() => pr.x + _riserLabelWidth(pr.text, pr.size),
            SldCircle() => pr.cx + pr.r,
          });
    }
    // The column ends 24 units left of the floor gutter; its feed point sits
    // 10 units above the spine root's own supply row.
    final rowY = busTrackOf['s:$spineRoot']!;
    final double dx = -24 - (sMaxX.isFinite ? sMaxX : 0.0);
    final dy = rowY - 10 - raw.feedY;
    final shifted = [for (final pr in raw.prims) _shiftPrim(pr, dx, dy)];
    spine = (
      prims: shifted,
      height: raw.height,
      feedX: raw.feedX + dx,
      feedY: raw.feedY + dy,
    );
    spineGroup.addAll(shifted);
    prims.addAll(shifted);
  }

  final feeders = <_RiserFeeder>[];
  for (final l in legs) {
    feeders.add(_RiserFeeder(
      role: essential.contains(l.child) ? SldRole.essential : SldRole.normal,
      parent: l.parent,
      px: l.pxx,
      py: l.pyy,
      cx: l.cxx,
      cy: l.cyy,
      bandRight: bandRightEdge[floorOf(l.child)] ?? l.cxx,
      // Feeder annotation (cable + breaker); null when the feeding circuit
      // can't resolve ⇒ that run is left unlabelled (never fabricated).
      label: _feederConnLabel(feederCircuitOf, feederResultOf, l.child,
          parentThreePhase: _parentIsThreePhase(parentOf, result, l.child)),
      parentBusY: l.pJog ? busTrackOf['p:${l.parent}'] : null,
      childBusY: l.cJog ? busTrackOf['c:${l.child}'] : null,
    ));
  }
  // Pass 1 — every annotation whose DEFAULT anchor is clear keeps it (so a riser
  // whose bands hold one board each is unchanged); pass 2 walks the escape
  // ladder for the rest, stacking them without mutual overlap.
  // Obstacles: every board box, plus every feeder's CHANNEL VERTICAL (a 1-unit
  // wide strip at channelX over the span that feeder's riser leg occupies) — a
  // long tag whose default slot runs past channelX would otherwise be struck
  // through by the riser line — plus every JOGGED leg's bus-track horizontal
  // (jog x .. channel) and its jog vertical (centre-line .. track): tracks sit
  // only 5 units apart, so a tag escaping onto one feeder's track would
  // otherwise be struck through by a NEIGHBOURING feeder's track above it.
  // (A tag never collides with its own branch: its glyph box ends 4 units
  // above the line it rides.)
  final placer = _RiserLabelPlacer([
    for (final id in panelX.keys)
      _RiserBox(
          panelX[id]!, panelY[id]!, panelX[id]! + _ovW, panelY[id]! + _ovH),
    for (final f in feeders)
      _RiserBox(channelX - 0.5, math.min(f.parentBusY ?? f.py, f.branchY),
          channelX + 0.5, math.max(f.parentBusY ?? f.py, f.branchY)),
    for (final f in feeders)
      for (final (edgeX, centreY, busY) in [
        (f.px, f.py, f.parentBusY),
        (f.cx, f.cy, f.childBusY),
      ])
        if (busY != null) ...[
          _RiserBox(_RiserFeeder.jogX(edgeX), busY - 0.5, channelX, busY + 0.5),
          _RiserBox(_RiserFeeder.jogX(edgeX) - 0.5, math.min(busY, centreY),
              _RiserFeeder.jogX(edgeX) + 0.5, math.max(busY, centreY)),
        ],
  ], gutterX: _riserGutterW);
  final needsEscape = <_RiserFeeder>[];
  for (final f in feeders) {
    if (f.label == null) continue;
    f.slot = f.defaultSlot(channelX);
    if (!placer.reserveIfClear(f.slot, f.label!, _riserFeederLabelSize)) {
      needsEscape.add(f);
    }
  }
  for (final f in needsEscape) {
    final r = placer.escape(f.ladder(channelX, _riserFeederLabelSize), f.label!,
        _riserFeederLabelSize);
    f.slot = r.slot;
    f.cleared = r.cleared;
  }
  // The right edge of the widest DISPLACED annotation — folded into the sheet
  // bounds below so an escaped tag is never clipped. Labels otherwise don't
  // drive the bounds, so a riser with no displacement keeps its exact extents.
  var displacedMaxX = double.negativeInfinity;
  // Every feeder's route (parent leg + optional jog to its bus track, the
  // channel vertical, the child branch + optional jog) is collected per PARENT
  // and merged by [_mergeFeederSegments], so a piece shared by sibling feeders
  // is drawn ONCE — never once per child on identical coordinates, where the
  // last-drawn child's colour won (a normal board's trunk printed red when its
  // essential feeder came last). A piece carried by one role keeps it; a piece
  // shared by normal AND essential feeders takes the PARENT board's role (its
  // own outgoing bus). A lone feeder comes back as its exact legacy lines.
  final segsByParent = <String, List<_FeederSeg>>{};
  for (final f in feeders) {
    final route = segsByParent[f.parent] ??= [];
    // parent right -> channel; channel vertical riser (length ∝ elevation
    // delta); channel -> child right. A leg with a board in its way jogs up
    // into its band's bus row (above the boxes) so it never crosses that board.
    final pBus = f.parentBusY;
    final double channelTopY;
    if (pBus == null) {
      route.add(_FeederSeg(f.px, f.py, channelX, f.py, f.role));
      channelTopY = f.py;
    } else {
      final jx = _RiserFeeder.jogX(f.px);
      route.add(_FeederSeg(f.px, f.py, jx, f.py, f.role));
      route.add(_FeederSeg(jx, f.py, jx, pBus, f.role));
      route.add(_FeederSeg(jx, pBus, channelX, pBus, f.role));
      channelTopY = pBus;
    }
    route.add(_FeederSeg(channelX, channelTopY, channelX, f.branchY, f.role));
    final cBus = f.childBusY;
    if (cBus == null) {
      route.add(_FeederSeg(channelX, f.cy, f.cx, f.cy, f.role));
    } else {
      final jx = _RiserFeeder.jogX(f.cx);
      route.add(_FeederSeg(channelX, cBus, jx, cBus, f.role));
      route.add(_FeederSeg(jx, cBus, jx, f.cy, f.role));
      route.add(_FeederSeg(jx, f.cy, f.cx, f.cy, f.role));
    }
    final lbl = f.label;
    if (lbl == null) continue;
    final (lx, ly) = f.slot;
    final def = f.defaultSlot(channelX);
    final dx = lx - def.$1, dy = ly - def.$2;
    if (dx != 0 || dy != 0) {
      displacedMaxX = math.max(
          displacedMaxX, lx + _riserLabelWidth(lbl, _riserFeederLabelSize));
    }
    // A tag pulled well off its anchor — or one no slot could fully clear —
    // gets a thin leader from the nearest point on ITS branch, so it still
    // reads as this feeder's spec.
    if (!f.cleared || math.sqrt(dx * dx + dy * dy) > _kRiserLeaderThreshold) {
      // The branch segment the leader lands on: the bus row (jog x .. channel)
      // for a jogged child leg, else the straight branch (child .. channel).
      final segL =
          cBus == null ? math.min(f.cx, channelX) : _RiserFeeder.jogX(f.cx);
      final segR = cBus == null ? math.max(f.cx, channelX) : channelX;
      final bx = math.min(math.max(lx, segL), segR);
      // Land the leader on the NEAR end of the text, so a tag diverted LEFT of
      // its branch is not crossed by the leader that points at it.
      final rx = lx + _riserLabelWidth(lbl, _riserFeederLabelSize);
      final endX = rx < bx ? rx : lx;
      prims.add(SldLine(bx, f.branchY, endX, ly,
          weight: SldWeight.thin, role: f.role));
    }
    prims.add(SldLabel(lx, ly, lbl, size: _riserFeederLabelSize, role: f.role));
  }
  for (final entry in segsByParent.entries) {
    prims.addAll(_mergeFeederSegments(entry.value,
        parentRole: essential.contains(entry.key)
            ? SldRole.essential
            : SldRole.normal));
  }
  sheetMaxX = math.max(sheetMaxX, channelX);

  // Source -> each root: from the LV-main bus bottom into the root panel.
  if (spine != null && spineBeside) {
    // Beside-root spine: down the spine column to the root's own supply row,
    // across (above its band's boxes), down into the root. The spine root is
    // the HIGHEST root, so every other root's lead runs down, never back up
    // through the spine column.
    for (final id in result.order) {
      if (parentOf.containsKey(id) || !panelX.containsKey(id)) continue;
      final zx = panelX[id]! + _ovW / 2;
      final zy = panelY[id]!;
      final rowY = busTrackOf['s:$id']!;
      final lead = [
        SldLine(spine.feedX, spine.feedY, spine.feedX, rowY,
            weight: SldWeight.medium, role: SldRole.source),
        SldLine(spine.feedX, rowY, zx, rowY,
            weight: SldWeight.medium, role: SldRole.source),
        SldLine(zx, rowY, zx, zy,
            weight: SldWeight.medium, role: SldRole.source),
      ];
      prims.addAll(lead);
      if (id == spineRoot) spineGroup.addAll(lead);
    }
  } else if (spine != null) {
    for (final id in result.order) {
      if (parentOf.containsKey(id) || !panelX.containsKey(id)) continue;
      final zx = panelX[id]! + _ovW / 2;
      final zy = panelY[id]!;
      final midY = (spine.feedY + zy) / 2;
      final straightBlocked = rootNeedsTrunk(id);
      if (!straightBlocked) {
        // The root sits on (or the drop clears) every band above it: the
        // legacy three-leg drop, byte-identical.
        prims.add(SldLine(spine.feedX, spine.feedY, spine.feedX, midY,
            weight: SldWeight.medium, role: SldRole.source));
        prims.add(SldLine(spine.feedX, midY, zx, midY,
            weight: SldWeight.medium, role: SldRole.source));
        prims.add(SldLine(zx, midY, zx, zy,
            weight: SldWeight.medium, role: SldRole.source));
        continue;
      }
      // A root below other bands: the drop at the root's centre column would
      // run straight through the first board of every band in between (reading
      // as if that board were on the main supply path). Route it down a
      // DEDICATED trunk in the gap left of the first column instead, along the
      // clear bus row above the top band, and enter the root from its own
      // band's bus row.
      const trunkX = _riserGutterW + _riserPanelGap / 2;
      final topRowY = busTrackOf['top']!;
      // A root on the TOP band rides the same source row (one continuous path).
      final rootRowY = floorOf(id) == topIndex ? topRowY : busTrackOf['s:$id']!;
      prims.add(SldLine(spine.feedX, spine.feedY, spine.feedX, topRowY,
          weight: SldWeight.medium, role: SldRole.source));
      prims.add(SldLine(spine.feedX, topRowY, trunkX, topRowY,
          weight: SldWeight.medium, role: SldRole.source));
      prims.add(SldLine(trunkX, topRowY, trunkX, rootRowY,
          weight: SldWeight.medium, role: SldRole.source));
      prims.add(SldLine(trunkX, rootRowY, zx, rootRowY,
          weight: SldWeight.medium, role: SldRole.source));
      prims.add(SldLine(zx, rootRowY, zx, zy,
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
      prims.add(SldLabel(
          6, y + 33, 'FFL ${_ffl(building.elevationOf(i).meters)}',
          size: 8));
    } else {
      // Tier-fallback gutter: Tier n, root tier at the top.
      final tier = topIndex - i; // band i is depth `tier`
      prims.add(SldLabel(6, y + 17, 'Tier ${tier + 1}', size: 10, bold: true));
    }
  }

  // Per-panel horizontal budget for the load-way fan-out stub labels below the
  // box: the clear space from the stub label's x to the NEXT panel's box left
  // edge in the same band (or the sheet's right margin, `sheetMaxX`, for the
  // band's last panel) — so a name only truncates as far as a neighbour
  // actually forces, never shorter than the old fixed 14 chars. `byFloor`'s
  // per-band lists are already in left-to-right x order (panels are placed by
  // walking them in that order above).
  final fanRightLimit = <String, double>{};
  for (final ids in byFloor.values) {
    for (var i = 0; i < ids.length; i++) {
      fanRightLimit[ids[i]] =
          i + 1 < ids.length ? panelX[ids[i + 1]]! : sheetMaxX;
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
        x + 7, y + 33, _compactNodeSubLine(p, model: panelModelById[id]),
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
    // The stub label starts at x+26; budget its TOTAL printed width (name +
    // the ' <rating>A[ 3ph]' suffix — the suffix is drawn too, so it must
    // count against the same box) so the label's measured width (chars x
    // size x kElectricalRiserLabelCharW, the SAME per-char advance the
    // feeder-annotation collision boxes use) never crosses the clear space to
    // the next panel/fan column. The NAME portion alone is floored at the
    // original fixed 14 chars so it's never shorter than before.
    const fanClearanceX = 10.0;
    final fanAvailX =
        (fanRightLimit[id] ?? sheetMaxX) - (x + 26) - fanClearanceX;
    const fanCharW = _fanLabelSize * kElectricalRiserLabelCharW;
    final fanTotalBudget = fanCharW <= 0 ? 14 : (fanAvailX / fanCharW).floor();
    var row = 0;
    for (final cr in shown) {
      final sy = y + _ovH + _fanTopGap + row * _fanRowH;
      prims.add(
          SldLine(x + 8, sy, x + 22, sy, weight: SldWeight.thin, role: role));
      final ph = cr.threePhase ? ' 3ph' : '';
      final suffix = ' ${_num(cr.breaker.ratingA.amperes)}A$ph';
      final fanNameBudget = math.max(14, fanTotalBudget - suffix.length);
      final nm = _fanOutLabel(cr.name, maxLen: fanNameBudget);
      prims.add(SldLabel(x + 26, sy + 3, '$nm$suffix',
          size: _fanLabelSize, role: role));
      row++;
    }
    if (loadWays.length > kRiserFanMax) {
      final more = loadWays.length - kRiserFanMax;
      final sy = y + _ovH + _fanTopGap + row * _fanRowH;
      prims.add(
          SldLine(x + 8, sy, x + 22, sy, weight: SldWeight.thin, role: role));
      prims.add(SldLabel(x + 26, sy + 3, '+$more more',
          size: _fanLabelSize, role: role));
    }
  }

  // ── Page crop (Round 23, elec-drafting-2-1) ────────────────────────────────
  if (floorRange != null) {
    final lo = floorRange.lo.clamp(0, topIndex);
    final hi = floorRange.hi.clamp(lo, topIndex);
    double gridY(int i) =>
        bandY(i) + contentOffsetY + _ovH + _fanColH + _riserPanelGap / 2;
    final top = hi >= topIndex ? double.negativeInfinity : gridY(hi + 1);
    final bottom = lo <= 0 ? double.infinity : gridY(lo);
    String floorName(int i) {
      if (hasFloors) {
        final n = building.floors[i].name;
        return n.isEmpty ? 'L${i + 1}' : n;
      }
      return 'Tier ${topIndex - i + 1}';
    }

    final keepSpine = spineRoot != null &&
        floorOf(spineRoot) >= lo &&
        floorOf(spineRoot) <= hi;
    const eps = 1e-6;
    bool inWin(double y) => y >= top - eps && y <= bottom + eps;
    final cropped = <SldPrim>[];
    final stubs = <String>{};
    void stub(double x, double y, int floor, SldRole role) {
      if (!stubs.add('${x.toStringAsFixed(2)}@${y.toStringAsFixed(2)}')) return;
      cropped.add(SldLabel(x + 3, y, 'LANJUT KE ${floorName(floor)}',
          size: _fanLabelSize, role: role));
    }

    for (final pr in prims) {
      if (spineGroup.contains(pr)) {
        if (keepSpine) cropped.add(pr);
        continue;
      }
      switch (pr) {
        case SldRect():
          if (inWin(pr.y) && inWin(pr.y + pr.h)) cropped.add(pr);
        case SldLabel():
          if (inWin(pr.y)) cropped.add(pr);
        case SldCircle():
          if (inWin(pr.cy)) cropped.add(pr);
        case SldLine():
          final ya = math.min(pr.y1, pr.y2), yb = math.max(pr.y1, pr.y2);
          if (yb < top - eps || ya > bottom + eps) continue;
          if (ya >= top - eps && yb <= bottom + eps) {
            cropped.add(pr);
            continue;
          }
          // Clip a line crossing the page edge(s).
          double xAt(double y) => (pr.y2 - pr.y1).abs() < eps
              ? pr.x1
              : pr.x1 + (pr.x2 - pr.x1) * (y - pr.y1) / (pr.y2 - pr.y1);
          final ca = math.max(ya, top), cb = math.min(yb, bottom);
          cropped.add(SldLine(xAt(ca), ca, xAt(cb), cb,
              weight: pr.weight,
              role: pr.role,
              layer: pr.layer,
              dashed: pr.dashed));
          if (ya < top - eps) {
            stub(xAt(ca), ca + _fanLabelSize + 2, hi + 1, pr.role);
          }
          if (yb > bottom + eps) stub(xAt(cb), cb - 3, lo - 1, pr.role);
      }
    }
    prims
      ..clear()
      ..addAll(cropped);
  }

  // ── Bounds ─────────────────────────────────────────────────────────────────
  var minX = 0.0,
      minY = double.infinity,
      maxX = sheetMaxX,
      maxY = -double.infinity;
  for (final pr in prims) {
    switch (pr) {
      case SldRect():
        minX = math.min(minX, pr.x);
        minY = math.min(minY, pr.y);
        maxY = math.max(maxY, pr.y + pr.h);
        maxX = math.max(maxX, pr.x + pr.w);
      case SldLine():
        minX = math.min(minX, math.min(pr.x1, pr.x2));
        minY = math.min(minY, math.min(pr.y1, pr.y2));
        maxY = math.max(maxY, math.max(pr.y1, pr.y2));
        maxX = math.max(maxX, math.max(pr.x1, pr.x2));
      case SldLabel():
        // drafting-9: the label's top (y - size), not its baseline.
        minX = math.min(minX, pr.x);
        minY = math.min(minY, pr.y - pr.size);
      case SldCircle():
        minX = math.min(minX, pr.cx - pr.r);
        minY = math.min(minY, pr.cy - pr.r);
        maxY = math.max(maxY, pr.cy + pr.r);
        maxX = math.max(maxX, pr.cx + pr.r);
    }
  }
  // A DISPLACED feeder annotation escapes past the channel — widen the sheet so
  // it can't be clipped (no displacement ⇒ -infinity ⇒ the bounds are unchanged).
  maxX = math.max(maxX, displacedMaxX);
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
      if (_anyEssentialPrim(prims))
        const SldLegendEntry('Essential', 'Essential / emergency supply'),
      const SldLegendEntry('FFL', 'Finished floor level (m)'),
      if (sourceChain)
        const SldLegendEntry('Source', 'Utility / MV supply chain'),
      // The source spine draws the system-earthing mark, so surface it too.
      if (sourceChain) const SldLegendEntry('Earth', 'System earthing point'),
    ],
    supplyNote: supplyNote,
  );
}

/// [p] translated by ([dx], [dy]) — every field else verbatim.
SldPrim _shiftPrim(SldPrim p, double dx, double dy) => switch (p) {
      SldLine() => SldLine(p.x1 + dx, p.y1 + dy, p.x2 + dx, p.y2 + dy,
          weight: p.weight, role: p.role, layer: p.layer, dashed: p.dashed),
      SldRect() =>
        SldRect(p.x + dx, p.y + dy, p.w, p.h, weight: p.weight, role: p.role),
      SldLabel() => SldLabel(p.x + dx, p.y + dy, p.text,
          size: p.size, bold: p.bold, role: p.role),
      SldCircle() =>
        SldCircle(p.cx + dx, p.cy + dy, p.r, weight: p.weight, role: p.role),
    };

/// The number of floor BANDS [buildElectricalRiser] draws for [project] —
/// the building's levels, else (no [building]) the feeder-depth tiers. The
/// page chunker ([paginatedRiserSheets]) splits on this count.
int electricalRiserBandCount(ElectricalProject project,
    ElectricalSystemResult result, BuildingLevels? building) {
  if (building != null && building.levelCount > 0) return building.levelCount;
  final parentOf = _parentOf(project, result);
  final depth = <String, int>{};
  var maxDepth = 0;
  for (final id in result.order) {
    final par = parentOf[id];
    depth[id] = par == null ? 0 : (depth[par] ?? 0) + 1;
    maxDepth = math.max(maxDepth, depth[id]!);
  }
  return maxDepth + 1;
}

// ── Hybrid POWER one-line (C7) ───────────────────────────────────────────────

/// Node footprint + tier geometry for the power one-line.
const double _polW = 172;
const double _polH = 44;
const double _polSymR = 14; // generator / utility symbol radius
const double _polGapX = 44; // horizontal gap between siblings in a tier
const double _polTierH = 120; // vertical pitch between tiers
const double _polLaneGap = 16; // pitch of the skip-tier side lanes (Round 10)
const double _polSubStrip = 14; // the strip a node's sub-label prints in
const double _polEdgeLabelSize = 6.5;

/// An axis-aligned box (left, top, right, bottom) for the one-line label placer.
typedef _PolBox = ({double l, double t, double r, double b});

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

  // Round 10 (elec-drawing-props-2) — obstacle boxes for the edge-label
  // placer: every node footprint plus the strip its sub-label prints in.
  final obstacles = <_PolBox>[
    for (final n in nodes)
      (
        l: pos[n.id]!.x,
        t: pos[n.id]!.y,
        r: pos[n.id]!.x + _polW,
        b: pos[n.id]!.y + _polH + _polSubStrip,
      ),
  ];
  final placedLabels = <_PolBox>[];
  bool clear(_PolBox bx) {
    bool hit(_PolBox o) =>
        math.min(bx.r, o.r) - math.max(bx.l, o.l) > 0 &&
        math.min(bx.b, o.b) - math.max(bx.t, o.t) > 0;
    return !obstacles.any(hit) && !placedLabels.any(hit);
  }

  _PolBox labelBox(double x, double y, double w) =>
      (l: x, t: y - _polEdgeLabelSize, r: x + w, b: y + 2);

  void placeLabel(
      String text, List<(double, double)> candidates, SldRole role) {
    final w = helveticaTextWidth(text, _polEdgeLabelSize);
    var at = candidates.first;
    for (final c in candidates) {
      if (clear(labelBox(c.$1, c.$2, w))) {
        at = c;
        break;
      }
    }
    placedLabels.add(labelBox(at.$1, at.$2, w));
    prims
        .add(SldLabel(at.$1, at.$2, text, size: _polEdgeLabelSize, role: role));
  }

  // Edges first (under the node graphics). An ADJACENT-tier edge takes the
  // overview orthogonal 3-segment route — source bottom-centre down to a mid
  // line, across, then down into the target top-centre (all inside the
  // inter-tier gap, so it never crosses a box). A SKIP-tier edge (e.g. PLN ->
  // bus past the PV-inverter tier) would run that vertical straight THROUGH
  // the intermediate tier's boxes and read as a SERIES connection, so it
  // detours through its own side LANE left of every column (Round 10). The
  // role follows the TARGET: the run into the main panel (the load side) is
  // normal, everything else is a supply run.
  //
  // Round 23 (elec-drafting-2-2) — two skip-tier sources on ONE tier (PLN and
  // the genset) used to turn into their lanes on the SAME y and draw one
  // continuous line between their drops: the utility and the standby genset
  // read as solidly tied upstream of the ATS. Each source now takes the lane
  // on ITS side of the drawing (a source right of the column centre detours
  // right), and every lane on a side gets its own turn rows, so no two edges
  // ever share a collinear segment.
  var colMinX = double.infinity, colMaxX = -double.infinity;
  for (final p in pos.values) {
    colMinX = math.min(colMinX, p.x);
    colMaxX = math.max(colMaxX, p.x + _polW);
  }
  final colMid = colMinX.isFinite ? (colMinX + colMaxX) / 2 : 0.0;
  var laneL = 0, laneR = 0;
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
    final label = (e.label != null && e.label!.isNotEmpty) ? e.label! : null;
    final skip = tier[e.to]! - tier[e.from]! > 1;
    if (!skip) {
      final midY = (ay + zy) / 2;
      prims
        ..add(SldLine(ax, ay, ax, midY, weight: SldWeight.medium, role: role))
        ..add(SldLine(ax, midY, zx, midY, weight: SldWeight.medium, role: role))
        ..add(SldLine(zx, midY, zx, zy, weight: SldWeight.medium, role: role));
      if (label != null) {
        final w = helveticaTextWidth(label, _polEdgeLabelSize);
        placeLabel(
            label,
            [
              (math.min(ax, zx) + 4, midY - 4),
              (ax + 4, midY - 4),
              (ax - 4 - w, midY - 4),
              (zx + 4, midY - 4),
              (zx - 4 - w, midY - 4),
              for (var k = 1; k <= 3; k++) ...[
                (ax + 4, midY - 4 - 9.0 * k),
                (zx + 4, midY + 9.0 * k + 4),
              ],
            ],
            role);
      }
    } else {
      final rightSide = ax > colMid;
      final k = rightSide ? ++laneR : ++laneL;
      final laneX =
          rightSide ? colMaxX + _polLaneGap * k : colMinX - _polLaneGap * k;
      // Clear of the source's sub-label; each lane on a side turns on its own
      // rows (8 units apart), so same-side lanes never run collinear.
      final y1 = ay + _polSubStrip + 6 + 8.0 * (k - 1);
      final y2 = zy - 12 - 8.0 * (k - 1);
      prims
        ..add(SldLine(ax, ay, ax, y1, weight: SldWeight.medium, role: role))
        ..add(SldLine(ax, y1, laneX, y1, weight: SldWeight.medium, role: role))
        ..add(
            SldLine(laneX, y1, laneX, y2, weight: SldWeight.medium, role: role))
        ..add(SldLine(laneX, y2, zx, y2, weight: SldWeight.medium, role: role))
        ..add(SldLine(zx, y2, zx, zy, weight: SldWeight.medium, role: role));
      if (label != null) {
        final w = helveticaTextWidth(label, _polEdgeLabelSize);
        placeLabel(
            label,
            [
              for (var yy = y1 + 12; yy < y2; yy += 9)
                (rightSide ? laneX + 3 : laneX - 3 - w, yy),
              (rightSide ? laneX + 3 : laneX - 3 - w, y1 - 3),
            ],
            role);
      }
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
