/// Plan-accurate ELECTRICAL LAYOUT export (denah instalasi listrik) — the
/// electrical mirror of `plan_pdf_export.dart` (`planToPdf`) / `dxf_export.dart`
/// (`networkToDxf`). Every other electrical export is SCHEMATIC (single-line,
/// overview, riser, power one-line); this one reads each panel / load's REAL
/// sheet-pixel position on the calibrated floor plan (the placement the unified
/// Layout electrical layer already renders — `ElectricalPanel.layoutPos` /
/// `ElectricalCircuit.loadPos`) and draws them where they actually sit, over the
/// same floor-plan underlay + `drawing_chrome` frame / title block that the
/// mechanical plan carries (H1).
///
/// The geometry model is deliberately an HONEST v1: the app has no routed cable
/// geometry, so a feeder / drop is a STRAIGHT panel→sub-panel (or panel→load)
/// polyline, its length label the SAME §10 geo length `computeSystem` sizes the
/// cable with (`electricalCableLength`). Placements that don't land on the
/// exported sheet+floor are never invented a position — they are LISTED in a
/// corner "Unplaced" note so the omission is visible, not silent.
///
/// Split cleanly: [buildElectricalPlanData] is the pure builder (project + result
/// → the drawable node/route/unplaced lists for one sheet+floor); the two
/// renderers ([electricalPlanToPdf] / [electricalPlanToDxf]) draw that data. So
/// the two formats agree (one geometry) and the builder is unit-testable without
/// touching a byte of PDF/DXF.
///
/// Zero Flutter imports. PDF space is y-up, so screen-space (y-down) coordinates
/// are flipped during the fit; DXF Y is up, so screen Y is negated.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../electrical/genset_backup.dart' show isEssentialByName;
import '../electrical/geo_length.dart';
import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import '../geometry/building.dart';
import '../geometry/scale_calibration.dart';
import 'drawing_chrome.dart';
import 'electrical_dxf_export.dart' show SldDxfLayers;
import 'electrical_sld_drawing.dart' show essentialPanelIds;
import 'plan_annotation_layout.dart' show planOverlapWarning;
import 'plan_symbols.dart'
    show
        LeaderedLabelPlacement,
        PlanLabelLayout,
        placePlanLabel,
        planLengthLabel,
        riserUpDown;

/// Whether a plan node is a distribution panel (a stroked box) or a load / meter
/// (a small circle) — drives the glyph the renderers draw.
enum ElectricalPlanNodeKind { panel, load }

/// One drawable item on the electrical layout plan — a panel or a load, at its
/// real sheet-pixel position ([x] / [y], y-down). [tag] is the identifier drawn
/// beside the glyph (`MDP`, `W3`); [sub] an optional second line (a panel's
/// incomer rating, a load's breaker). [essential] flags an emergency-supply item
/// so the renderers colour it red (the normal/essential split the single-lines
/// use).
class ElectricalPlanNode {
  final double x;
  final double y;
  final String tag;
  final String? sub;
  final ElectricalPlanNodeKind kind;
  final bool essential;

  const ElectricalPlanNode({
    required this.x,
    required this.y,
    required this.tag,
    this.sub,
    required this.kind,
    this.essential = false,
  });
}

/// A straight cable route between two placed items ([x1]/[y1] → [x2]/[y2],
/// sheet pixels, y-down), with an optional length [label] (`8.4 m`) at its
/// midpoint. [essential] colours it red.
class ElectricalPlanRoute {
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final String? label;
  final bool essential;

  const ElectricalPlanRoute({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    this.label,
    this.essential = false,
  });
}

/// Round 24 — a feeder whose far board sits on ANOTHER sheet / floor: drawn
/// at the on-sheet board ([x] / [y], sheet pixels) as a riser mark + a short
/// home-run stub with its [text] (`ke LP-1 (L1) - 12.0 m` / `dari MDP (L0)`)
/// and the vertical [sense] (`UP` / `DN`, null on the same floor). Never
/// dropped: the main vertical feeders are what the foreman pulls cable for.
class ElectricalPlanRiser {
  final double x;
  final double y;
  final String text;
  final String? sense;
  final bool essential;

  const ElectricalPlanRiser({
    required this.x,
    required this.y,
    required this.text,
    this.sense,
    this.essential = false,
  });
}

/// The drawable content of one electrical layout sheet — placed [nodes], their
/// [routes], the off-sheet feeder [risers], and the honest [unplaced] note
/// lines (items with no placement on this sheet+floor, plus every off-sheet
/// feeder by name). Pure data, format-agnostic.
class ElectricalPlanData {
  final List<ElectricalPlanNode> nodes;
  final List<ElectricalPlanRoute> routes;
  final List<ElectricalPlanRiser> risers;
  final List<String> unplaced;

  const ElectricalPlanData({
    this.nodes = const [],
    this.routes = const [],
    this.risers = const [],
    this.unplaced = const [],
  });

  /// True when nothing would be drawn (an empty sheet — a blank export).
  bool get isEmpty => nodes.isEmpty && routes.isEmpty && risers.isEmpty;
}

/// Build the drawable [ElectricalPlanData] for the [sheetId] / [floorIndex]
/// slice of [project]. Pure — reads only the model + the (optional) solved
/// [result] (for panel/load rating labels) + the (optional) [building] /
/// [calibrations] (for the §10 route length labels).
///
/// A panel is drawn where its [ElectricalPanel.layoutPos] lands on this sheet +
/// floor; a load where its [ElectricalCircuit.loadPos] does. A cable route is
/// drawn only when BOTH ends are on this sheet+floor. Round 24 — a FEEDER whose
/// other board is placed on another sheet / floor is drawn at the on-sheet
/// board as an [ElectricalPlanRiser] (`ke LP-1 (L1) - 12.0 m` with the §10
/// length, `UP`/`DN`) AND listed in [ElectricalPlanData.unplaced] — never given
/// a fabricated on-sheet position, never silently dropped. A panel / load with
/// no placement AT ALL is likewise listed, not invented.
/// The essential board set over the MODEL alone (no solved result): a board
/// is essential when it, or any board feeding it, carries the explicit
/// `essential` flag or an emergency name — the [essentialPanelIds] rule.
Set<String> _modelEssentialPanelIds(ElectricalProject project) {
  final byId = {for (final p in project.panels) p.id: p};
  final parentOf = <String, String>{};
  for (final p in project.panels) {
    for (final c in p.circuits) {
      final f = c.feedsPanelId;
      if (f != null && byId.containsKey(f)) parentOf[f] = p.id;
    }
  }
  final out = <String>{};
  for (final p in project.panels) {
    final seen = <String>{};
    String? cur = p.id;
    while (cur != null && seen.add(cur)) {
      final b = byId[cur];
      if (b != null && (b.essential || isEssentialByName(b.name))) {
        out.add(p.id);
        break;
      }
      cur = parentOf[cur];
    }
  }
  return out;
}

ElectricalPlanData buildElectricalPlanData({
  required ElectricalProject project,
  ElectricalSystemResult? result,
  required String sheetId,
  required int floorIndex,
  Map<String, ScaleCalibration> calibrations = const {},
  BuildingLevels? building,
}) {
  final panelById = {for (final p in project.panels) p.id: p};
  bool onSheet(LayoutPos? pos) =>
      pos != null && pos.sheetId == sheetId && pos.floorIndex == floorIndex;

  String? routeLabel(LayoutPos a, LayoutPos b) {
    if (building == null) return null;
    final l = electricalCableLength(a, b,
        calibrationBySheet: calibrations, building: building);
    // Round 21 — the ONE 0.1 m length format the board schedule, riser and
    // report print ('6.0 m', never '6 m'; float noise rounds away first).
    return l.meters > 0 ? planLengthLabel(l) : null;
  }

  // Round 38 (elec-ui-drawings-3) — ONE essential set with the overview /
  // riser / schedule: the explicit flag, an emergency NAME (DARURAT /
  // EMERGENCY …) and every board fed from an essential one. Without a solved
  // result the same rule runs over the model's feeder tree.
  final ess = result != null
      ? essentialPanelIds(project, result)
      : _modelEssentialPanelIds(project);
  final nodes = <ElectricalPlanNode>[];
  final routes = <ElectricalPlanRoute>[];
  final risers = <ElectricalPlanRiser>[];
  final offSheetFeeders = <String>[];
  final unplacedPanels = <String>[];
  var unplacedLoads = 0;

  String tagOf(ElectricalPanel p) =>
      (p.tag != null && p.tag!.isNotEmpty) ? p.tag! : p.name;
  String floorName(int i) {
    final fl = building?.floors;
    return (fl != null && i >= 0 && i < fl.length && fl[i].name.isNotEmpty)
        ? fl[i].name
        : 'Lt.$i';
  }

  // Round 24 — the off-sheet feeder mark at the on-sheet board [here]:
  // `ke`/`dari` <other board> (<its floor>) + the §10 length when both ends
  // are placed.
  // Round 39 (elec-reports-parity-1) — the length is ALWAYS measured from
  // the FEEDING board to the fed one ([from] → [to]), the direction the solve
  // (`resolveCircuitLengthDetailed`) measures on (the feeding board's sheet
  // scale), so the 'ke' mark on the parent's layout and the 'dari' mark on
  // the child's print one figure for one cable.
  void offSheetRiser(LayoutPos here, LayoutPos? there, String verb,
      String otherTag, bool essential,
      {required LayoutPos? from, required LayoutPos? to}) {
    final where = there != null ? ' (${floorName(there.floorIndex)})' : '';
    final len = (from != null && to != null) ? routeLabel(from, to) : null;
    final text = '$verb $otherTag$where${len != null ? ' - $len' : ''}';
    risers.add(ElectricalPlanRiser(
      x: here.x,
      y: here.y,
      text: text,
      sense: there == null
          ? null
          : riserUpDown(
              hereFloor: here.floorIndex, otherFloor: there.floorIndex),
      essential: essential,
    ));
    offSheetFeeders.add(text);
  }

  for (final p in project.panels) {
    final rp = result?.panels[p.id];
    final pos = p.layoutPos;
    final tag = tagOf(p);

    if (onSheet(pos)) {
      final sub = rp != null
          ? '${rp.incomer.breaker.ratingA.amperes.round()}A '
              '${rp.system.isThreePhase ? '3ph' : '1ph'}'
              '${incomerOverRangeSuffix(rp.incomer, withNeeds: false)}'
          : null;
      nodes.add(ElectricalPlanNode(
        x: pos!.x,
        y: pos.y,
        tag: tag,
        sub: sub,
        kind: ElectricalPlanNodeKind.panel,
        essential: ess.contains(p.id),
      ));
    } else if (pos == null) {
      unplacedPanels.add(tag);
    }

    // Circuits: feeders route to a sub-panel; loads route to their loadPos.
    for (final c in p.circuits) {
      if (c.feedsPanelId != null) {
        // A feeder route is drawn when both boards are on this sheet+floor;
        // when only ONE end is here it becomes an off-sheet riser mark there.
        final target = panelById[c.feedsPanelId];
        final tpos = target?.layoutPos;
        final routeEss = ess.contains(p.id) ||
            (target != null && ess.contains(target.id));
        if (onSheet(pos) && onSheet(tpos)) {
          routes.add(ElectricalPlanRoute(
            x1: pos!.x,
            y1: pos.y,
            x2: tpos!.x,
            y2: tpos.y,
            label: routeLabel(pos, tpos),
            essential: routeEss,
          ));
        } else if (onSheet(pos) && target != null && tpos != null) {
          offSheetRiser(pos!, tpos, 'ke', tagOf(target), routeEss,
              from: pos, to: tpos);
        } else if (onSheet(tpos) && target != null) {
          offSheetRiser(tpos!, pos, 'dari', tag, routeEss,
              from: pos, to: tpos);
        }
        continue;
      }
      // A normal load.
      final lp = c.loadPos;
      if (onSheet(lp)) {
        final cr = _circuitResult(rp, c.id);
        nodes.add(ElectricalPlanNode(
          x: lp!.x,
          y: lp.y,
          tag: c.name,
          sub: cr != null
              ? '${cr.breaker.deviceClass.name.toUpperCase()} '
                  '${cr.breaker.ratingA.amperes.round()}A'
              : null,
          kind: ElectricalPlanNodeKind.load,
          essential: ess.contains(p.id) || c.lifeSafety,
        ));
        // The drop from its panel (drawn only when the panel is on-sheet too).
        if (onSheet(pos)) {
          routes.add(ElectricalPlanRoute(
            x1: pos!.x,
            y1: pos.y,
            x2: lp.x,
            y2: lp.y,
            label: routeLabel(pos, lp),
            essential: ess.contains(p.id) || c.lifeSafety,
          ));
        }
      } else if (lp == null) {
        unplacedLoads++;
      }
    }
  }

  final unplaced = <String>[
    for (final name in unplacedPanels) 'Panel $name (belum ditempatkan)',
    if (unplacedLoads > 0) '$unplacedLoads beban belum ditempatkan',
    for (final f in offSheetFeeders) 'Feeder $f (lembar lain)',
  ];

  return ElectricalPlanData(
      nodes: nodes, routes: routes, risers: risers, unplaced: unplaced);
}

ElectricalCircuitResult? _circuitResult(
    ElectricalPanelResult? rp, String circuitId) {
  if (rp == null) return null;
  for (final c in rp.circuits) {
    if (c.circuitId == circuitId) return c;
  }
  return null;
}

// ── Shared annotation layout (Round 24) ─────────────────────────────────────

/// The renderer-specific glyph / text sizes the annotation layout places
/// around (all in the renderer's OUTPUT units, y-up). Each renderer keeps its
/// own historic glyph sizes; the layout only needs them as obstacles.
typedef ElectricalPlanSizes = ({
  double panelW,
  double panelH,
  double panelTagSize,
  double panelSubSize,
  double panelTagGap,
  double panelTagDy,
  double panelSubDy,
  double loadR,
  double loadTagSize,
  double loadSubSize,
  double loadTagGap,
  double loadTagDy,
  double loadSubDy,
  double routeTextSize,
  double riserStub,
  double riserR,
});

/// One off-sheet feeder mark as laid out: the stub from the board to the
/// riser marker, the marker, and its placed label.
class ElectricalPlanRiserLayout {
  final ElectricalPlanRiser riser;
  final double x1, y1, x2, y2; // stub, board -> marker (output units)
  final LeaderedLabelPlacement label;
  const ElectricalPlanRiserLayout(
      this.riser, this.x1, this.y1, this.x2, this.y2, this.label);
}

/// The placed annotations of one electrical layout sheet (output units).
class ElectricalPlanAnnotations {
  /// Route index -> its placed length label (absent = unlabelled route).
  final Map<int, LeaderedLabelPlacement> routeLabels;
  final List<ElectricalPlanRiserLayout> risers;

  /// Annotations that could only be placed overprinting something.
  final int overlapCount;
  const ElectricalPlanAnnotations(
      this.routeLabels, this.risers, this.overlapCount);
}

/// Round 24 — lay out the electrical plan's route length labels and the
/// off-sheet feeder marks through the SHARED plan label placer
/// ([placePlanLabel]): every route is a run obstacle, every glyph + fixed
/// node tag an occupied box, so a home-run line never strikes through its own
/// figure and two figures never stack (a label sits along its route, offset
/// off the line, leadered back when crowded). [map] takes a sheet-pixel
/// point to the y-up output space. Pure; both renderers call it.
ElectricalPlanAnnotations layoutElectricalPlanAnnotations(
  ElectricalPlanData data, {
  required ({double x, double y}) Function(double xPx, double yPx) map,
  required ElectricalPlanSizes sizes,
}) {
  final z = sizes;
  final layout = PlanLabelLayout();
  for (var i = 0; i < data.routes.length; i++) {
    final r = data.routes[i];
    final a = map(r.x1, r.y1), b = map(r.x2, r.y2);
    layout.addRun('r$i', a.x, a.y, b.x, b.y);
  }
  void textBox(double x, double y, String t, double size) => layout.addBox((
        minX: x,
        minY: y - 0.25 * size,
        maxX: x + t.length * size * 0.55,
        maxY: y + size,
      ));
  for (final nd in data.nodes) {
    final p = map(nd.x, nd.y);
    if (nd.kind == ElectricalPlanNodeKind.panel) {
      layout.addBox((
        minX: p.x - z.panelW / 2,
        minY: p.y - z.panelH / 2,
        maxX: p.x + z.panelW / 2,
        maxY: p.y + z.panelH / 2,
      ));
      final tx = p.x + z.panelW / 2 + z.panelTagGap;
      textBox(tx, p.y + z.panelTagDy, nd.tag, z.panelTagSize);
      if (nd.sub != null) {
        textBox(tx, p.y + z.panelSubDy, nd.sub!, z.panelSubSize);
      }
    } else {
      layout.addBox((
        minX: p.x - z.loadR,
        minY: p.y - z.loadR,
        maxX: p.x + z.loadR,
        maxY: p.y + z.loadR,
      ));
      final tx = p.x + z.loadTagGap;
      textBox(tx, p.y + z.loadTagDy, nd.tag, z.loadTagSize);
      if (nd.sub != null) {
        textBox(tx, p.y + z.loadSubDy, nd.sub!, z.loadSubSize);
      }
    }
  }

  // Off-sheet feeder stubs first (they are linework): the k-th mark at one
  // board fans out at its own bearing so two never coincide.
  // Round 29 (drawings-3-6) — fanned in 45° steps ALTERNATING sides (was 30°
  // steps all to one side: two marks ~11 pt apart competed for one tag slot
  // and the second tag's leader struck the first), the first still straight
  // down, so each tag sits beside its own mark.
  const bearings = [90.0, 135.0, 45.0, 180.0, 0.0, 270.0, 225.0, 315.0];
  final perBoard = <String, int>{};
  final stubs = <(ElectricalPlanRiser, double, double, double, double)>[];
  for (final rs in data.risers) {
    final p = map(rs.x, rs.y);
    final key = '${rs.x},${rs.y}';
    final k = perBoard.update(key, (v) => v + 1, ifAbsent: () => 0);
    // Round 40 (elec-drawings-5-layout-riser-markers-coincide) — a board
    // with more than 8 off-sheet risers used to repeat the 8 bearings at one
    // stub length, so the 9th marker sat ON the 1st (21 risers drew 10
    // marks). Each further LAP of eight rotates between the earlier rays
    // (+22.5 deg on odd laps, +11.25 deg on the next pair) and reaches one
    // stub further out, so every mark — and the ray to it — is its own.
    final lap = k ~/ bearings.length;
    final deg = bearings[k % bearings.length] +
        22.5 * (lap % 2) +
        11.25 * ((lap ~/ 2) % 2);
    final rad = deg * math.pi / 180;
    final start = z.panelH / 2;
    final reach = start + z.riserStub * (1 + lap);
    final x1 = p.x + math.cos(rad) * start, y1 = p.y + math.sin(rad) * start;
    final x2 = p.x + math.cos(rad) * reach;
    final y2 = p.y + math.sin(rad) * reach;
    layout.addRun(null, x1, y1, x2, y2);
    layout.addBox((
      minX: x2 - z.riserR,
      minY: y2 - z.riserR,
      maxX: x2 + z.riserR,
      maxY: y2 + z.riserR,
    ));
    stubs.add((rs, x1, y1, x2, y2));
  }

  final routeLabels = <int, LeaderedLabelPlacement>{};
  for (var i = 0; i < data.routes.length; i++) {
    final r = data.routes[i];
    final text = r.label;
    if (text == null || text.isEmpty) continue;
    final a = map(r.x1, r.y1), b = map(r.x2, r.y2);
    routeLabels[i] = placePlanLabel(
        ax: a.x,
        ay: a.y,
        bx: b.x,
        by: b.y,
        text: text,
        textSize: z.routeTextSize,
        layout: layout,
        ownRunId: 'r$i');
  }
  final risers = <ElectricalPlanRiserLayout>[];
  for (final (rs, x1, y1, x2, y2) in stubs) {
    final text = rs.sense != null ? '${rs.sense} ${rs.text}' : rs.text;
    final gap = z.riserR * 1.5;
    final w = text.length * z.routeTextSize * 0.55;
    // Round 29 (drawings-3-6) — the tag's horizontal pseudo-run leaves the
    // marker on the SIDE its stub points to (a stub fanned left tags to the
    // left), so the tags of a fan never queue for one slot on the right; a
    // vertical stub keeps the right-hand slot (byte-identical first mark).
    final dirX = x2 - x1;
    final stubLen = math.sqrt(dirX * dirX + (y2 - y1) * (y2 - y1));
    final left = stubLen > 0 && dirX / stubLen < -0.2;
    final label = placePlanLabel(
        ax: left ? x2 - gap : x2 + gap,
        ay: y2,
        bx: left ? x2 - gap - w : x2 + gap + w,
        by: y2,
        text: text,
        textSize: z.routeTextSize,
        layout: layout,
        anchorPoint: (x: x2, y: y2));
    risers.add(ElectricalPlanRiserLayout(rs, x1, y1, x2, y2, label));
  }
  return ElectricalPlanAnnotations(
      routeLabels, risers, layout.unresolvedCount);
}

// ── PDF renderer ─────────────────────────────────────────────────────────────

String _n(double v) => v.toStringAsFixed(2);

/// One WinAnsi text rule for every vector PDF (Round 13): see
/// [pdfWinAnsiText] in `drawing_chrome.dart`.
String _pdfText(String raw) => pdfWinAnsiText(raw);

/// The essential (emergency-supply) red vs the normal dark ink — the same
/// normal/essential colour split the electrical single-lines use.
const _kNormalInk = (0.10, 0.10, 0.10);
const _kEssentialInk = (0.80, 0.12, 0.12);

const double _kElecPlanMargin = 48.0;

/// The PDF renderer's glyph / text sizes (points) for the annotation layout.
const ElectricalPlanSizes kElectricalPlanPdfSizes = (
  panelW: 20.0,
  panelH: 12.0,
  panelTagSize: 9.0,
  panelSubSize: kMinPlotLabelPt,
  panelTagGap: 4.0,
  panelTagDy: 1.0,
  panelSubDy: -9.0,
  loadR: 5.0,
  loadTagSize: 7.0,
  loadSubSize: kMinPlotLabelPt,
  loadTagGap: 8.0,
  loadTagDy: 1.0,
  loadSubDy: -8.0,
  routeTextSize: 7.0,
  riserStub: 16.0,
  riserR: 3.0,
);

typedef _ElecPlanFit = ({
  double minX,
  double minY,
  double spanX,
  double spanY,
  double availW,
  double availH,
  String blockTitle,
  String blockDate,
  PlottedScale snap,
});

/// The ONE fit / snap computation of the electrical layout PDF — bounds over
/// every node, route endpoint AND the underlay frame, the real page less its
/// margins and the ACTUAL title-block height, snapped to the plan scale
/// ladder. Shared by [electricalPlanToPdf] and (via
/// [electricalPlanPlottedScaleDenominator]) the DXF twin, so both stamp the
/// same `1 : N` (Round 23 r2, elec-drafting-2-3 parity).
_ElecPlanFit _electricalPlanFit({
  required ElectricalPlanData data,
  required String projectName,
  required String sheetName,
  required String dateString,
  DrawingChrome? chrome,
  double? metersPerPixel,
  PlanUnderlay? underlay,
  PaperSize paper = PaperSize.a3Landscape,
}) {
  final pageW = paper.widthPt;
  final pageH = paper.heightPt;
  const margin = _kElecPlanMargin;

  // ── Bounds (sheet pixels) over every node + route endpoint + underlay frame ──
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  void grow(double x, double y) {
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
  }

  for (final nd in data.nodes) {
    grow(nd.x, nd.y);
  }
  for (final r in data.routes) {
    grow(r.x1, r.y1);
    grow(r.x2, r.y2);
  }
  if (underlay != null) {
    grow(0, 0);
    grow(underlay.sheetWidthPx, underlay.sheetHeightPx);
  }
  final hasContent = minX.isFinite;
  if (!hasContent) {
    minX = 0;
    minY = 0;
    maxX = 100;
    maxY = 100;
  }

  final hasChrome = chrome != null && !chrome.isEmpty;
  final blockTitle = hasChrome ? (chrome.drawingTitle ?? sheetName) : sheetName;
  final blockDate = hasChrome ? (chrome.dateString ?? dateString) : dateString;
  final blockH = hasChrome
      ? pdfTitleBlock(chrome,
              pageW: pageW,
              pageH: pageH,
              margin: margin,
              projectName: projectName,
              scaleTextOverride: 'NTS',
              titleTextOverride: blockTitle,
              dateTextOverride: blockDate)
          .height
      : 0.0;

  final spanX = maxX - minX;
  final spanY = maxY - minY;
  final availW = pageW - 2 * margin;
  final availH = pageH - 2 * margin - (hasChrome ? blockH : 24.0);
  var scale = 1.0;
  if (spanX > 0 || spanY > 0) {
    final sx = spanX > 0 ? availW / spanX : double.infinity;
    final sy = spanY > 0 ? availH / spanY : double.infinity;
    scale = math.min(sx, sy);
    if (!scale.isFinite || scale <= 0) scale = 1.0;
  }

  final snap = snapPlottedScale(
      rawScale: scale,
      metersPerPixel: metersPerPixel,
      hasContent: hasContent,
      paperLabel: paper.label);
  return (
    minX: minX,
    minY: minY,
    spanX: spanX,
    spanY: spanY,
    availW: availW,
    availH: availH,
    blockTitle: blockTitle,
    blockDate: blockDate,
    snap: snap,
  );
}

/// The snapped plotted-scale denominator ([kPlanScaleLadder]) the electrical
/// layout PDF prints for these inputs (`1 : N @ A3`), or null when it prints
/// NTS (uncalibrated, empty, or too large even for 1 : 1000). Pass the SAME
/// arguments as the [electricalPlanToPdf] call so the DXF twin
/// ([electricalPlanToDxf] `plottedScaleDenominator`) stamps the identical
/// scale. Pure.
int? electricalPlanPlottedScaleDenominator({
  required ElectricalPlanData data,
  required String projectName,
  required String sheetName,
  required String dateString,
  DrawingChrome? chrome,
  double? metersPerPixel,
  PlanUnderlay? underlay,
  PaperSize paper = PaperSize.a3Landscape,
}) {
  final snap = _electricalPlanFit(
          data: data,
          projectName: projectName,
          sheetName: sheetName,
          dateString: dateString,
          chrome: chrome,
          metersPerPixel: metersPerPixel,
          underlay: underlay,
          paper: paper)
      .snap;
  final m = RegExp(r'^1 : (\d+) @').firstMatch(snap.scaleRow);
  return m == null ? null : int.parse(m.group(1)!);
}

/// Render the [data] for one sheet+floor as a single-page ANNOTATED electrical
/// layout PDF and return its bytes. Mirrors [planToPdf]'s fit / snap / chrome
/// pipeline: the drawing auto-fits (centred, uniform scale) into [paper],
/// SNAPS to a standard plotted scale when [metersPerPixel] is given, paints an
/// optional floor-plan [underlay] beneath, and stamps the [chrome] frame /
/// title block / scale bar / north arrow. [projectName] / [sheetName] /
/// [dateString] populate the title block (the engine never reads the clock).
Uint8List electricalPlanToPdf({
  required ElectricalPlanData data,
  required String projectName,
  required String sheetName,
  required String dateString,
  DrawingChrome? chrome,
  double? metersPerPixel,
  PlanUnderlay? underlay,
  PaperSize paper = PaperSize.a3Landscape,
}) {
  final pageW = paper.widthPt;
  final pageH = paper.heightPt;
  const margin = _kElecPlanMargin;
  final fit = _electricalPlanFit(
      data: data,
      projectName: projectName,
      sheetName: sheetName,
      dateString: dateString,
      chrome: chrome,
      metersPerPixel: metersPerPixel,
      underlay: underlay,
      paper: paper);
  final minX = fit.minX, minY = fit.minY;
  final spanX = fit.spanX, spanY = fit.spanY;
  final availW = fit.availW, availH = fit.availH;
  final hasChrome = chrome != null && !chrome.isEmpty;
  final blockTitle = fit.blockTitle, blockDate = fit.blockDate;
  final snap = fit.snap;
  final scale = snap.scale;
  final scaleRow = snap.scaleRow;
  final pointsPerMeter = snap.pointsPerMeter;

  final drawnW = spanX * scale;
  final drawnH = spanY * scale;
  final offX = margin + (availW - drawnW) / 2;
  final offY = margin + (availH - drawnH) / 2;
  double tx(double x) => offX + (x - minX) * scale;
  double ty(double y) => (pageH - offY) - (y - minY) * scale; // flip y

  final cs = StringBuffer();

  // Underlay first (pale plan beneath every stroke).
  switch (underlay) {
    case final VectorPlanUnderlay v:
      cs.write(pdfVectorUnderlayOps(v, tx: tx, ty: ty, pageScale: scale));
    case final RasterPlanUnderlay r:
      cs.write(pdfRasterUnderlayOps(
          x: tx(0),
          y: ty(r.sheetHeightPx),
          w: r.sheetWidthPx * scale,
          h: r.sheetHeightPx * scale));
    case null:
      break;
  }

  if (!hasChrome) {
    cs.writeln('BT /F1 16 Tf 0 0 0 rg '
        '${_n(margin)} ${_n(pageH - margin + 6)} Td '
        '(${_pdfText(projectName)}) Tj ET');
    cs.writeln('BT /F1 10 Tf 0.25 0.25 0.25 rg '
        '${_n(margin)} ${_n(pageH - margin - 9)} Td '
        '(${_pdfText('$sheetName   -   $dateString')}) Tj ET');
  }

  void setInk((double, double, double) col) {
    final (r, g, b) = col;
    cs.writeln('${_n(r)} ${_n(g)} ${_n(b)} RG');
    cs.writeln('${_n(r)} ${_n(g)} ${_n(b)} rg');
  }

  void label(double px, double py, String text, {double size = 8}) {
    cs.writeln('BT /F1 ${size.toStringAsFixed(0)} Tf 0 0 0 rg '
        '${_n(px)} ${_n(py)} Td (${_pdfText(text)}) Tj ET');
  }

  void circle(double cx, double cy, double r, {bool fill = false}) {
    const k = 0.5523;
    cs.writeln('${_n(cx + r)} ${_n(cy)} m');
    cs.writeln('${_n(cx + r)} ${_n(cy + k * r)} ${_n(cx + k * r)} ${_n(cy + r)} '
        '${_n(cx)} ${_n(cy + r)} c');
    cs.writeln('${_n(cx - k * r)} ${_n(cy + r)} ${_n(cx - r)} ${_n(cy + k * r)} '
        '${_n(cx - r)} ${_n(cy)} c');
    cs.writeln('${_n(cx - r)} ${_n(cy - k * r)} ${_n(cx - k * r)} ${_n(cy - r)} '
        '${_n(cx)} ${_n(cy - r)} c');
    cs.writeln('${_n(cx + k * r)} ${_n(cy - r)} ${_n(cx + r)} ${_n(cy - k * r)} '
        '${_n(cx + r)} ${_n(cy)} c');
    cs.writeln(fill ? 'f' : 'S');
  }

  // Round 24 — the route figures + off-sheet feeder marks are placed by the
  // shared plan label placer (along the route, clear of every line / glyph).
  final ann = layoutElectricalPlanAnnotations(data,
      map: (x, y) => (x: tx(x), y: ty(y)), sizes: kElectricalPlanPdfSizes);
  void placedLabel(LeaderedLabelPlacement p, double size) {
    final lead = p.leaderAnchor, end = p.leaderEnd;
    if (lead != null && end != null) {
      cs.writeln('0.30 0.30 0.30 RG 0.5 w');
      cs.writeln('${_n(lead.x)} ${_n(lead.y)} m ${_n(end.x)} ${_n(end.y)} l S');
    }
    final rad = p.angleDeg * math.pi / 180;
    final pc = math.cos(rad), ps = math.sin(rad);
    for (final line in p.lines) {
      cs.writeln('BT /F1 ${size.toStringAsFixed(0)} Tf 0 0 0 rg '
          '${_n(pc)} ${_n(ps)} ${_n(-ps)} ${_n(pc)} '
          '${_n(line.x)} ${_n(line.y)} Tm (${_pdfText(line.text)}) Tj ET');
    }
  }

  // Routes (beneath the glyphs).
  for (final r in data.routes) {
    setInk(r.essential ? _kEssentialInk : _kNormalInk);
    cs.writeln('1.0 w');
    final ax = tx(r.x1), ay = ty(r.y1), bx = tx(r.x2), by = ty(r.y2);
    cs.writeln('${_n(ax)} ${_n(ay)} m ${_n(bx)} ${_n(by)} l S');
  }
  // Off-sheet feeder marks: stub + riser circle.
  for (final rl in ann.risers) {
    setInk(rl.riser.essential ? _kEssentialInk : _kNormalInk);
    cs.writeln('1.0 w');
    cs.writeln('${_n(rl.x1)} ${_n(rl.y1)} m ${_n(rl.x2)} ${_n(rl.y2)} l S');
    circle(rl.x2, rl.y2, kElectricalPlanPdfSizes.riserR);
  }

  // Nodes on top.
  for (final nd in data.nodes) {
    final px = tx(nd.x), py = ty(nd.y);
    setInk(nd.essential ? _kEssentialInk : _kNormalInk);
    cs.writeln('1.4 w');
    if (nd.kind == ElectricalPlanNodeKind.panel) {
      // A panel: a small stroked box with a diagonal (distribution-board glyph).
      const w = 20.0, h = 12.0;
      cs.writeln('${_n(px - w / 2)} ${_n(py - h / 2)} ${_n(w)} ${_n(h)} re S');
      cs.writeln('${_n(px - w / 2)} ${_n(py - h / 2)} m '
          '${_n(px + w / 2)} ${_n(py + h / 2)} l S');
      label(px + w / 2 + 4, py + 1, nd.tag, size: 9);
      // drafting-6: sub-labels at the minimum plotted size.
      if (nd.sub != null) {
        label(px + w / 2 + 4, py - 9, nd.sub!, size: kMinPlotLabelPt);
      }
    } else {
      // A load / outlet: a small circle.
      circle(px, py, 5);
      label(px + 8, py + 1, nd.tag, size: 7);
      if (nd.sub != null) label(px + 8, py - 8, nd.sub!, size: kMinPlotLabelPt);
    }
  }

  // Every placed figure LAST, over all the linework.
  for (final e in ann.routeLabels.entries) {
    placedLabel(e.value, kElectricalPlanPdfSizes.routeTextSize);
  }
  for (final rl in ann.risers) {
    placedLabel(rl.label, kElectricalPlanPdfSizes.routeTextSize);
  }

  // Corner "Unplaced" note — honest visibility of items with no on-sheet
  // position (never invented). Top-left, below the loose title line.
  // Round 24 — preceded by the overlap warning when labels had to overprint.
  final overlapNote = planOverlapWarning(ann.overlapCount);
  var notesTop = pageH - margin - (hasChrome ? 14.0 : 30.0);
  if (overlapNote != null) {
    cs.writeln('BT /F1 8 Tf 0.75 0.10 0.10 rg '
        '${_n(margin + 4)} ${_n(notesTop)} Td (${_pdfText(overlapNote)}) Tj ET');
    notesTop -= 13;
  }
  if (data.unplaced.isNotEmpty) {
    var ny = notesTop;
    cs.writeln('BT /F1 8 Tf 0.55 0.12 0.12 rg '
        '${_n(margin + 4)} ${_n(ny)} Td (${_pdfText('BELUM DITEMPATKAN:')}) Tj ET');
    for (final u in data.unplaced) {
      ny -= 11;
      cs.writeln('BT /F1 7 Tf 0.30 0.30 0.30 rg '
          '${_n(margin + 4)} ${_n(ny)} Td (${_pdfText('- $u')}) Tj ET');
    }
  }

  // A compact device legend (bottom-left): Panel / Load / Feeder — a plan
  // carries its own symbol key (the mechanical service legend doesn't apply to
  // an electrical layout).
  {
    const lx = margin + 6;
    var ly = margin + 44;
    cs.writeln('BT /F1 9 Tf 0 0 0 rg '
        '${_n(lx)} ${_n(ly + 14)} Td (${_pdfText('LEGENDA')}) Tj ET');
    setInk(_kNormalInk);
    cs.writeln('1.4 w');
    // Panel swatch.
    cs.writeln('${_n(lx)} ${_n(ly + 2)} 12 8 re S');
    label(lx + 18, ly + 2, 'Panel', size: 8);
    ly -= 13;
    circle(lx + 6, ly + 6, 4);
    label(lx + 18, ly + 2, 'Beban / titik', size: 8);
    ly -= 13;
    cs.writeln('${_n(lx)} ${_n(ly + 6)} m ${_n(lx + 12)} ${_n(ly + 6)} l S');
    label(lx + 18, ly + 2, 'Kabel', size: 8);
  }

  // Chrome (opt-in; byte-identical when null).
  if (hasChrome) {
    cs.write(pdfSheetFrame(pageW: pageW, pageH: pageH, margin: margin));
    cs.write(pdfTitleBlock(chrome,
            pageW: pageW,
            pageH: pageH,
            margin: margin,
            projectName: projectName,
            scaleTextOverride: scaleRow,
            titleTextOverride: blockTitle,
            dateTextOverride: blockDate)
        .ops);
    cs.write(
        pdfNorthArrow(chrome, cx: pageW - margin - 18, cy: pageH - margin - 40));
  }
  if (pointsPerMeter != null) {
    // drafting-9: on a framed (chrome) sheet the bar sits kScaleBarFrameInset
    // above the frame line so its figures print INSIDE the frame.
    cs.write(pdfScaleBarReal(
        pointsPerMeter: pointsPerMeter,
        centerX: pageW / 2,
        baseY: hasChrome ? margin + kScaleBarFrameInset : margin));
  }

  return assemblePlanPdfDocument(
    content: cs.toString(),
    pageW: pageW,
    pageH: pageH,
    raster: underlay is RasterPlanUnderlay ? underlay : null,
  );
}

// ── DXF renderer ─────────────────────────────────────────────────────────────

/// Render the [data] for one sheet+floor as an ASCII R12 DXF electrical layout
/// (E-* class layers), preceded by a TABLES section. Panels are boxes, loads
/// circles, cable routes LINEs (on `E-FEEDER`); labels TEXT on `E-TEXT`;
/// essential items ACI red. DXF Y is up, so screen Y is negated. The [chrome]'s
/// title-block rows are stamped below the drawing (mirroring [electricalSldToDxf]).
///
/// Round 23 (elec-drafting-2-3) — with the sheet's calibration
/// ([metersPerPixel]) the DXF is written in WORLD MILLIMETRES (1 unit = 1 mm;
/// Round 27 — no R2000 `$INSUNITS` in the R12 header), like the mechanical
/// plan DXF: a 15.0 m route measures
/// 15000 units, so the denah xrefs onto the architect's mm DWG at 1:1, and
/// the SCALE row stamps the same snapped `1 : N @ A3` the PDF twin prints
/// (annotation sized for that plot, symbols in paper mm). Pass
/// [plottedScaleDenominator] = [electricalPlanPlottedScaleDenominator] over
/// the PDF call's own arguments (underlay frame + real title block) so the
/// two stamp the identical rung; null falls back to the A3 extent estimate. Uncalibrated (null)
/// keeps the legacy sheet-pixel drawing with SCALE NTS, byte-identical.
String electricalPlanToDxf({
  required ElectricalPlanData data,
  required String projectName,
  required String sheetName,
  DrawingChrome? chrome,
  SldDxfLayers layers = SldDxfLayers.electrical,
  double? metersPerPixel,
  int? plottedScaleDenominator,
}) {
  final world = metersPerPixel != null &&
      metersPerPixel.isFinite &&
      metersPerPixel > 0;
  final mmPerPx = world ? metersPerPixel * 1000 : 1.0;
  // Paper-mm → model units: the plotted-scale denominator of the drawing's mm
  // extent on A3 (the ladder the plan PDF snaps to). Legacy annotation sizes
  // are quarter-millimetres of paper (10 → 2.5 mm text), so [a] scales them.
  int? plotN;
  double u = 1;
  if (world) {
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = double.negativeInfinity, y1 = double.negativeInfinity;
    void grow(double x, double y) {
      x0 = math.min(x0, x * mmPerPx);
      y0 = math.min(y0, y * mmPerPx);
      x1 = math.max(x1, x * mmPerPx);
      y1 = math.max(y1, y * mmPerPx);
    }

    for (final nd in data.nodes) {
      grow(nd.x, nd.y);
    }
    for (final r in data.routes) {
      grow(r.x1, r.y1);
      grow(r.x2, r.y2);
    }
    if (x0.isFinite) {
      plotN = plottedScaleDenominator ??
          a3PlottedScaleDenominatorFor(x1 - x0, y1 - y0);
      final span = math.max(x1 - x0, y1 - y0);
      u = plotN != null
          ? plotN.toDouble()
          : (span > 0 ? span / 80 / kMinPlotTextMm : 1.0);
    }
  }
  double a(double v) => world ? v * u / 4 : v; // annotation (paper) size
  double gx(double x) => x * mmPerPx; // geometry (world) coordinate
  final b = StringBuffer();
  void g(int code, Object v) {
    b.writeln(code);
    // drafting-5: every string value is code-page-safe ASCII (no raw `·`).
    b.writeln(v is String ? dxfText(v) : v);
  }

  void line(String layer, double x1, double y1, double x2, double y2,
      {int? color}) {
    g(0, 'LINE');
    g(8, layer);
    if (color != null) g(62, color);
    g(10, x1);
    g(20, -y1);
    g(11, x2);
    g(21, -y2);
  }

  void box(String layer, double x, double y, double w, double h, {int? color}) {
    line(layer, x, y, x + w, y, color: color);
    line(layer, x + w, y, x + w, y + h, color: color);
    line(layer, x + w, y + h, x, y + h, color: color);
    line(layer, x, y + h, x, y, color: color);
  }

  void dxfCircle(String layer, double cx, double cy, double r, {int? color}) {
    g(0, 'CIRCLE');
    g(8, layer);
    if (color != null) g(62, color);
    g(10, cx);
    g(20, -cy);
    g(40, r);
  }

  void text(String layer, double x, double y, String value,
      {double size = 10, int? color}) {
    g(0, 'TEXT');
    g(8, layer);
    if (color != null) g(62, color);
    g(10, x);
    g(20, -y);
    g(40, size);
    g(1, value);
  }

  g(0, 'SECTION');
  g(2, 'ENTITIES');

  int? redIf(bool essential) => essential ? 1 : null;

  // Round 24 — the same shared annotation layout as the PDF, in this
  // drawing's y-up output space (screen y negated) at its own glyph sizes.
  final sizes = (
    panelW: a(40),
    panelH: a(24),
    panelTagSize: a(12),
    panelSubSize: a(8),
    panelTagGap: a(6),
    panelTagDy: 0.0,
    panelSubDy: -a(16),
    loadR: a(10),
    loadTagSize: a(9),
    loadSubSize: a(7),
    loadTagGap: a(14),
    loadTagDy: 0.0,
    loadSubDy: -a(12),
    routeTextSize: a(9),
    riserStub: a(32),
    riserR: a(6),
  );
  final ann = layoutElectricalPlanAnnotations(data,
      map: (x, y) => (x: gx(x), y: -gx(y)), sizes: sizes);
  // A placed label in the y-up layout space (TEXT rotation group 50).
  void placedText(LeaderedLabelPlacement p, double size, int? color) {
    for (final ln in p.lines) {
      g(0, 'TEXT');
      g(8, layers.text);
      if (color != null) g(62, color);
      g(10, ln.x);
      g(20, ln.y);
      g(40, size);
      g(1, ln.text);
      g(50, p.angleDeg.toStringAsFixed(1));
    }
    final lead = p.leaderAnchor, end = p.leaderEnd;
    if (lead != null && end != null) {
      line(layers.text, lead.x, -lead.y, end.x, -end.y);
    }
  }

  // Routes.
  for (final r in data.routes) {
    line(layers.feeder, gx(r.x1), gx(r.y1), gx(r.x2), gx(r.y2),
        color: redIf(r.essential));
  }
  for (final e in ann.routeLabels.entries) {
    placedText(e.value, sizes.routeTextSize, null);
  }
  // Off-sheet feeder marks: stub + riser circle + placed label.
  for (final rl in ann.risers) {
    final col = redIf(rl.riser.essential);
    line(layers.feeder, rl.x1, -rl.y1, rl.x2, -rl.y2, color: col);
    dxfCircle(layers.feeder, rl.x2, -rl.y2, sizes.riserR, color: col);
    placedText(rl.label, sizes.routeTextSize, col);
  }

  // Nodes (symbols are paper-sized annotation, placed at world positions).
  for (final nd in data.nodes) {
    final col = redIf(nd.essential);
    final nx = gx(nd.x), ny = gx(nd.y);
    if (nd.kind == ElectricalPlanNodeKind.panel) {
      final w = a(40.0), h = a(24.0);
      box(layers.device, nx - w / 2, ny - h / 2, w, h, color: col);
      line(layers.device, nx - w / 2, ny - h / 2, nx + w / 2, ny + h / 2,
          color: col);
      text(layers.text, nx + w / 2 + a(6), ny, nd.tag,
          size: a(12), color: col);
      if (nd.sub != null) {
        text(layers.text, nx + w / 2 + a(6), ny + a(16), nd.sub!, size: a(8));
      }
    } else {
      dxfCircle(layers.device, nx, ny, a(10), color: col);
      text(layers.text, nx + a(14), ny, nd.tag, size: a(9), color: col);
      if (nd.sub != null) {
        text(layers.text, nx + a(14), ny + a(12), nd.sub!, size: a(7));
      }
    }
  }

  // Corner "Unplaced" note (below the drawing extent — use a fixed origin so it
  // never overprints placed items; DXF has no page, so anchor it above origin).
  var noteY = a(-40.0);
  // Round 24 — the overlap warning (same text as the PDF) heads the notes.
  final overlapNote = planOverlapWarning(ann.overlapCount);
  if (overlapNote != null) {
    text(layers.text, 0, noteY, overlapNote, size: a(10), color: 1);
    noteY -= a(16);
  }
  if (data.unplaced.isNotEmpty) {
    text(layers.text, 0, noteY, 'BELUM DITEMPATKAN:', size: a(10), color: 1);
    for (final un in data.unplaced) {
      noteY -= a(16);
      text(layers.text, 0, noteY, '- $un', size: a(8));
    }
  }

  // Title block ABOVE the topmost note (screen y grows downward, so the
  // block sits at more-negative y). Round 27 (export-files-2-1) — the block
  // used to start a(60) above the top note and grow DOWN through every note
  // (REV over 'BELUM DITEMPATKAN:'); its height is now computed first and the
  // whole box ends a(24) above the top note's baseline (its a(10) text
  // rises a(10) above that, leaving a clear a(14) gap).
  final scaleText = world && plotN != null ? '1 : $plotN @ A3' : null;
  final rows = _dxfChromeRows(chrome, scaleOverride: scaleText);
  final frameH = rows.isEmpty ? a(96) : a(60.0 + rows.length * 18);
  final frameTop = noteY - a(24) - frameH;
  final pname = projectName.isNotEmpty ? projectName : 'Untitled project';
  box(layers.frame, 0, frameTop, a(360), frameH);
  text(layers.frame, a(8), frameTop + a(22), pname, size: a(16));
  text(layers.frame, a(8), frameTop + a(44),
      'DENAH INSTALASI LISTRIK - $sheetName',
      size: a(10));
  if (rows.isNotEmpty) {
    final rowH = a(18.0);
    final labelW = a(88.0);
    final bandTop = frameTop + a(56);
    for (var i = 0; i < rows.length; i++) {
      final (l, v) = rows[i];
      final rowTop = bandTop + i * rowH;
      text(layers.frame, a(8), rowTop + a(13), l, size: a(7));
      text(layers.frame, labelW + a(8), rowTop + a(13), v, size: a(10));
    }
  }

  g(0, 'ENDSEC');
  g(0, 'EOF');

  final classLayers = layers.classLayers();
  final tables = dxfTablesSection(layers: [
    for (final (name, aci) in classLayers) (name, aci, 'CONTINUOUS'),
  ]);
  // drafting-5: a minimal HEADER declaring the R12 format.
  // Round 27 (export-files-2-4) — no R2000 $INSUNITS / R14 $MEASUREMENT in
  // an AC1009 file: the world-mm drawing states its plotted 1 : N on the
  // title block's SCALE row instead.
  const header =
      '0\nSECTION\n2\nHEADER\n9\n\$ACADVER\n1\nAC1009\n0\nENDSEC\n';
  return header + tables + b.toString();
}

List<(String, String)> _dxfChromeRows(DrawingChrome? chrome,
    {String? scaleOverride}) {
  if (chrome == null || chrome.isEmpty) return const [];
  bool has(String? s) => s != null && s.isNotEmpty;
  return [
    if (has(chrome.clientName)) ('CLIENT', chrome.clientName!),
    if (has(chrome.drawingNumber)) ('DWG NO', chrome.drawingNumber!),
    if (has(chrome.revisionNumber)) ('REV', chrome.revisionNumber!),
    ('SCALE',
        scaleOverride ?? (has(chrome.scaleText) ? chrome.scaleText! : 'NTS')),
    if (has(chrome.dateString)) ('DATE', chrome.dateString!),
    if (has(chrome.drawnBy)) ('DRAWN', chrome.drawnBy!),
    if (has(chrome.checkedBy)) ('CHECKED', chrome.checkedBy!),
    if (has(chrome.approvedBy)) ('APPROVED', chrome.approvedBy!),
    if (chrome.sheetCounter != null) ('SHEET', chrome.sheetCounter!),
  ];
}
