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

import '../electrical/geo_length.dart';
import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import '../geometry/building.dart';
import '../geometry/scale_calibration.dart';
import '../units.dart';
import 'drawing_chrome.dart';
import 'electrical_dxf_export.dart' show SldDxfLayers;

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

/// The drawable content of one electrical layout sheet — placed [nodes], their
/// [routes], and the honest [unplaced] note lines (items with no placement on
/// this sheet+floor). Pure data, format-agnostic.
class ElectricalPlanData {
  final List<ElectricalPlanNode> nodes;
  final List<ElectricalPlanRoute> routes;
  final List<String> unplaced;

  const ElectricalPlanData({
    this.nodes = const [],
    this.routes = const [],
    this.unplaced = const [],
  });

  /// True when nothing would be drawn (an empty sheet — a blank export).
  bool get isEmpty => nodes.isEmpty && routes.isEmpty;
}

String _lenLabel(Length l) {
  final m = l.meters;
  return m == m.roundToDouble()
      ? '${m.toInt()} m'
      : '${m.toStringAsFixed(1)} m';
}

/// Build the drawable [ElectricalPlanData] for the [sheetId] / [floorIndex]
/// slice of [project]. Pure — reads only the model + the (optional) solved
/// [result] (for panel/load rating labels) + the (optional) [building] /
/// [calibrations] (for the §10 route length labels).
///
/// A panel is drawn where its [ElectricalPanel.layoutPos] lands on this sheet +
/// floor; a load where its [ElectricalCircuit.loadPos] does. A cable route is
/// drawn only when BOTH ends are on this sheet+floor (a feeder to an off-sheet
/// sub-panel, or a load on another floor, is listed in [ElectricalPlanData.unplaced]
/// instead — never given a fabricated on-sheet position). A panel / load with no
/// placement AT ALL is likewise listed, not invented.
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
    return l.meters > 0 ? _lenLabel(l) : null;
  }

  final nodes = <ElectricalPlanNode>[];
  final routes = <ElectricalPlanRoute>[];
  final unplacedPanels = <String>[];
  var unplacedLoads = 0;

  for (final p in project.panels) {
    final rp = result?.panels[p.id];
    final pos = p.layoutPos;
    final tag = (p.tag != null && p.tag!.isNotEmpty) ? p.tag! : p.name;

    if (onSheet(pos)) {
      final sub = rp != null
          ? '${rp.incomer.breaker.ratingA.amperes.round()}A '
              '${rp.system.isThreePhase ? '3ph' : '1ph'}'
          : null;
      nodes.add(ElectricalPlanNode(
        x: pos!.x,
        y: pos.y,
        tag: tag,
        sub: sub,
        kind: ElectricalPlanNodeKind.panel,
        essential: p.essential,
      ));
    } else if (pos == null) {
      unplacedPanels.add(tag);
    }

    // Circuits: feeders route to a sub-panel; loads route to their loadPos.
    for (final c in p.circuits) {
      if (c.feedsPanelId != null) {
        // A feeder route is drawn only when both boards are on this sheet+floor.
        if (onSheet(pos)) {
          final target = panelById[c.feedsPanelId];
          final tpos = target?.layoutPos;
          if (onSheet(tpos)) {
            routes.add(ElectricalPlanRoute(
              x1: pos!.x,
              y1: pos.y,
              x2: tpos!.x,
              y2: tpos.y,
              label: routeLabel(pos, tpos),
              essential: p.essential || (target?.essential ?? false),
            ));
          }
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
          essential: p.essential || c.lifeSafety,
        ));
        // The drop from its panel (drawn only when the panel is on-sheet too).
        if (onSheet(pos)) {
          routes.add(ElectricalPlanRoute(
            x1: pos!.x,
            y1: pos.y,
            x2: lp.x,
            y2: lp.y,
            label: routeLabel(pos, lp),
            essential: p.essential || c.lifeSafety,
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
  ];

  return ElectricalPlanData(
      nodes: nodes, routes: routes, unplaced: unplaced);
}

ElectricalCircuitResult? _circuitResult(
    ElectricalPanelResult? rp, String circuitId) {
  if (rp == null) return null;
  for (final c in rp.circuits) {
    if (c.circuitId == circuitId) return c;
  }
  return null;
}

// ── PDF renderer ─────────────────────────────────────────────────────────────

String _n(double v) => v.toStringAsFixed(2);

/// WinAnsi (Latin-1) code points the labels legitimately emit, passed through so
/// a `/WinAnsiEncoding` Helvetica renders the real glyph, not `?` (middle dot).
const _winAnsiPassThrough = {0xB0, 0xB1, 0xB2, 0xB3, 0xB7, 0xD8, 0xF8};

String _pdfText(String raw) {
  final b = StringBuffer();
  for (final code in raw.runes) {
    final c =
        (code >= 0x20 && code <= 0x7e) || _winAnsiPassThrough.contains(code)
            ? code
            : 0x3f /* ? */;
    if (c == 0x28 || c == 0x29 || c == 0x5c) b.writeCharCode(0x5c);
    b.writeCharCode(c);
  }
  return b.toString();
}

/// The essential (emergency-supply) red vs the normal dark ink — the same
/// normal/essential colour split the electrical single-lines use.
const _kNormalInk = (0.10, 0.10, 0.10);
const _kEssentialInk = (0.80, 0.12, 0.12);

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
  const margin = 48.0;

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
  scale = snap.scale;
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

  // Routes (beneath the glyphs).
  for (final r in data.routes) {
    setInk(r.essential ? _kEssentialInk : _kNormalInk);
    cs.writeln('1.0 w');
    final ax = tx(r.x1), ay = ty(r.y1), bx = tx(r.x2), by = ty(r.y2);
    cs.writeln('${_n(ax)} ${_n(ay)} m ${_n(bx)} ${_n(by)} l S');
    if (r.label != null && r.label!.isNotEmpty) {
      label((ax + bx) / 2 + 3, (ay + by) / 2 + 2, r.label!, size: 7);
    }
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
      if (nd.sub != null) label(px + w / 2 + 4, py - 8, nd.sub!, size: 6);
    } else {
      // A load / outlet: a small circle.
      circle(px, py, 5);
      label(px + 8, py + 1, nd.tag, size: 7);
      if (nd.sub != null) label(px + 8, py - 7, nd.sub!, size: 6);
    }
  }

  // Corner "Unplaced" note — honest visibility of items with no on-sheet
  // position (never invented). Top-left, below the loose title line.
  if (data.unplaced.isNotEmpty) {
    var ny = pageH - margin - (hasChrome ? 14.0 : 30.0);
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
    cs.write(pdfScaleBarReal(
        pointsPerMeter: pointsPerMeter, centerX: pageW / 2, baseY: margin));
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
String electricalPlanToDxf({
  required ElectricalPlanData data,
  required String projectName,
  required String sheetName,
  DrawingChrome? chrome,
  SldDxfLayers layers = SldDxfLayers.electrical,
}) {
  final b = StringBuffer();
  void g(int code, Object v) {
    b.writeln(code);
    b.writeln(v);
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

  // Routes.
  for (final r in data.routes) {
    line(layers.feeder, r.x1, r.y1, r.x2, r.y2, color: redIf(r.essential));
    if (r.label != null && r.label!.isNotEmpty) {
      text(layers.text, (r.x1 + r.x2) / 2 + 4, (r.y1 + r.y2) / 2, r.label!,
          size: 9);
    }
  }

  // Nodes.
  for (final nd in data.nodes) {
    final col = redIf(nd.essential);
    if (nd.kind == ElectricalPlanNodeKind.panel) {
      const w = 40.0, h = 24.0;
      box(layers.device, nd.x - w / 2, nd.y - h / 2, w, h, color: col);
      line(layers.device, nd.x - w / 2, nd.y - h / 2, nd.x + w / 2, nd.y + h / 2,
          color: col);
      text(layers.text, nd.x + w / 2 + 6, nd.y, nd.tag, size: 12, color: col);
      if (nd.sub != null) {
        text(layers.text, nd.x + w / 2 + 6, nd.y + 16, nd.sub!, size: 8);
      }
    } else {
      dxfCircle(layers.device, nd.x, nd.y, 10, color: col);
      text(layers.text, nd.x + 14, nd.y, nd.tag, size: 9, color: col);
      if (nd.sub != null) {
        text(layers.text, nd.x + 14, nd.y + 12, nd.sub!, size: 7);
      }
    }
  }

  // Corner "Unplaced" note (below the drawing extent — use a fixed origin so it
  // never overprints placed items; DXF has no page, so anchor it above origin).
  var noteY = -40.0;
  if (data.unplaced.isNotEmpty) {
    text(layers.text, 0, noteY, 'BELUM DITEMPATKAN:', size: 10, color: 1);
    for (final u in data.unplaced) {
      noteY -= 16;
      text(layers.text, 0, noteY, '- $u', size: 8);
    }
  }

  // Title block below everything.
  final rows = _dxfChromeRows(chrome);
  final frameTop = noteY - 60;
  final pname = projectName.isNotEmpty ? projectName : 'Untitled project';
  box(layers.frame, 0, frameTop, 360, rows.isEmpty ? 96 : 60.0 + rows.length * 18);
  text(layers.frame, 8, frameTop + 22, pname, size: 16);
  text(layers.frame, 8, frameTop + 44, 'DENAH INSTALASI LISTRIK - $sheetName',
      size: 10);
  if (rows.isNotEmpty) {
    const rowH = 18.0;
    const labelW = 88.0;
    final bandTop = frameTop + 56;
    for (var i = 0; i < rows.length; i++) {
      final (l, v) = rows[i];
      final rowTop = bandTop + i * rowH;
      text(layers.frame, 8, rowTop + 13, l, size: 7);
      text(layers.frame, labelW + 8, rowTop + 13, v, size: 10);
    }
  }

  g(0, 'ENDSEC');
  g(0, 'EOF');

  final classLayers = layers.classLayers();
  final tables = dxfTablesSection(layers: [
    for (final (name, aci) in classLayers) (name, aci, 'CONTINUOUS'),
  ]);
  return tables + b.toString();
}

List<(String, String)> _dxfChromeRows(DrawingChrome? chrome) {
  if (chrome == null || chrome.isEmpty) return const [];
  bool has(String? s) => s != null && s.isNotEmpty;
  return [
    if (has(chrome.clientName)) ('CLIENT', chrome.clientName!),
    if (has(chrome.drawingNumber)) ('DWG NO', chrome.drawingNumber!),
    if (has(chrome.revisionNumber)) ('REV', chrome.revisionNumber!),
    ('SCALE', has(chrome.scaleText) ? chrome.scaleText! : 'NTS'),
    if (has(chrome.dateString)) ('DATE', chrome.dateString!),
    if (has(chrome.drawnBy)) ('DRAWN', chrome.drawnBy!),
    if (has(chrome.checkedBy)) ('CHECKED', chrome.checkedBy!),
    if (has(chrome.approvedBy)) ('APPROVED', chrome.approvedBy!),
    if (chrome.sheetCounter != null) ('SHEET', chrome.sheetCounter!),
  ];
}
