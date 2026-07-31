/// ASCII DXF (R12) export of the electrical single-line — a real CAD-importable
/// drawing deliverable. The electrical mirror of `dxf_export.dart`
/// (`networkToDxf`). Pure: builds a string from the sized system; the app
/// handles file IO. Zero Flutter imports.
///
/// [electricalSldToDxf] renders the SAME professional single-line built in
/// `electrical_sld_drawing.dart` as the PDF — every panel a distribution-board
/// single-line (incomer breaker → busbar → one row per outgoing way with
/// breaker / cable / load / phase / Ib, feeders routed to the sub-panel they
/// supply) — preceded by a TABLES section (CONTINUOUS/DASHED line-types + the
/// class layers) and followed by a model-space title block + device legend.
/// Prims route to CLASS layers a CAD reviewer expects: busbars (thick lines)
/// on `E-BUS`, feeder routing (medium) on `E-FEEDER`, device/way graphics
/// (thin lines, blocks, meter circles) on `E-BREAKER`, labels on `E-TEXT`,
/// the frame/legend on `E-FRAME`, and essential-role graphics on
/// `E-ESSENTIAL` (ACI red) — an explicit `SldLine.layer` wins, used as-is.
/// [powerOneLineToDxf] renders the hybrid power one-line (utility / genset / PV
/// / battery) as boxed nodes joined by feeder LINEs (unchanged — no TABLES).
/// DXF Y is up, so screen Y is negated.
library;

import 'dart:math' as math;

import '../electrical/model.dart';
import '../electrical/panel_results.dart';
import '../electrical/power_oneline.dart';
import 'drawing_chrome.dart' show DrawingChrome, dxfTablesSection;
import 'electrical_sld_drawing.dart';

/// Box footprint (DXF units) for an auto-laid panel / node.
const double _boxW = 200;
const double _boxH = 90;
const double _gapX = 120;
const double _gapY = 80;

// ── Electrical class layers (drafting-style CAD conventions, no `// VERIFY`) ──

/// Busbars — the thick vertical bus lines.
const kDxfLayerEBus = 'E-BUS';

/// Feeder routing runs (medium-weight lines).
const kDxfLayerEFeeder = 'E-FEEDER';

/// Device / board graphics — thin lines, block outlines, meter circles.
const kDxfLayerEBreaker = 'E-BREAKER';

/// All annotation text.
const kDxfLayerEText = 'E-TEXT';

/// Sheet frame: title block + legend.
const kDxfLayerEFrame = 'E-FRAME';

/// Essential (emergency-supply) graphics — ACI red, toggleable as one layer.
const kDxfLayerEEssential = 'E-ESSENTIAL';

// ── Mechanical class layers (N15 — a plumbing riser must NEVER land on E-*) ──

/// Mechanical annotation text.
const kDxfLayerMText = 'M-TEXT';

/// Mechanical sheet frame: title block + legend.
const kDxfLayerMFrame = 'M-FRAME';

/// Mechanical device / detail graphics — glyphs, node boxes, callouts, datum
/// lines. Pipe runs keep their explicit per-service `SldLine.layer` (a service
/// code like `CW`/`V`/`D`); everything else that has no explicit layer lands
/// here instead of the electrical `E-BREAKER`.
const kDxfLayerMDetail = 'M-DETAIL';

/// The DXF layer NAMESPACE an SLD render routes its prims onto. The electrical
/// default is the `E-*` distribution-board set; the MECHANICAL riser (routed
/// here via `sld_export.dart`) passes [mechanical] so a plumbing riser's text /
/// frame / device graphics land on `M-TEXT` / `M-FRAME` / `M-DETAIL` and never
/// on `E-BREAKER` / `E-TEXT` / `E-FRAME` (N15). A pipe LINE carrying an explicit
/// `SldLine.layer` (a service code) still wins under either namespace. A pure
/// drafting-office naming convention, no `// VERIFY`.
class SldDxfLayers {
  /// Thick bus lines (electrical busbars). Mechanical has no bus ⇒ [device].
  final String bus;

  /// Medium feeder-routing lines. Mechanical has no feeder ⇒ [device].
  final String feeder;

  /// Thin device / detail graphics (block outlines, meter circles, glyphs).
  final String device;

  /// All annotation TEXT.
  final String text;

  /// Sheet frame: title block + legend.
  final String frame;

  /// Essential (emergency-supply) graphics. Mechanical has no essential ⇒
  /// [device].
  final String essential;

  final int busAci;
  final int feederAci;
  final int deviceAci;
  final int textAci;
  final int frameAci;
  final int essentialAci;

  const SldDxfLayers({
    required this.bus,
    required this.feeder,
    required this.device,
    required this.text,
    required this.frame,
    required this.essential,
    required this.busAci,
    required this.feederAci,
    required this.deviceAci,
    required this.textAci,
    required this.frameAci,
    required this.essentialAci,
  });

  /// The electrical `E-*` distribution-board namespace (the default — keeps
  /// every electrical export byte-identical, including the ACI table order).
  static const electrical = SldDxfLayers(
    bus: kDxfLayerEBus,
    feeder: kDxfLayerEFeeder,
    device: kDxfLayerEBreaker,
    text: kDxfLayerEText,
    frame: kDxfLayerEFrame,
    essential: kDxfLayerEEssential,
    busAci: 7,
    feederAci: 4,
    deviceAci: 7,
    textAci: 7,
    frameAci: 8,
    essentialAci: 1,
  );

  /// The mechanical `M-*` namespace — bus / feeder / essential collapse onto
  /// `M-DETAIL` (a plumbing riser has neither).
  static const mechanical = SldDxfLayers(
    bus: kDxfLayerMDetail,
    feeder: kDxfLayerMDetail,
    device: kDxfLayerMDetail,
    text: kDxfLayerMText,
    frame: kDxfLayerMFrame,
    essential: kDxfLayerMDetail,
    busAci: 7,
    feederAci: 7,
    deviceAci: 7,
    textAci: 7,
    frameAci: 8,
    essentialAci: 7,
  );

  /// The de-duplicated class-layer table rows `(name, aci)` in a stable order
  /// (bus, feeder, device, text, frame, essential) — the first ACI seen for a
  /// name wins, so the collapsed mechanical set lists `M-DETAIL` once. For the
  /// electrical namespace this reproduces the original six-row order verbatim.
  List<(String, int)> classLayers() {
    final byName = <String, int>{};
    for (final (name, aci) in [
      (bus, busAci),
      (feeder, feederAci),
      (device, deviceAci),
      (text, textAci),
      (frame, frameAci),
      (essential, essentialAci),
    ]) {
      byName.putIfAbsent(name, () => aci);
    }
    return [for (final e in byName.entries) (e.key, e.value)];
  }
}

/// DXF group-370 lineweight (1/100 mm) per [SldWeight] bucket.
int _lineweightFor(SldWeight w) => switch (w) {
      SldWeight.thin => 13,
      SldWeight.medium => 25,
      SldWeight.thick => 50,
    };

class _Dxf {
  final StringBuffer b = StringBuffer();

  void g(int code, Object value) {
    b.writeln(code);
    b.writeln(value);
  }

  void begin() {
    g(0, 'SECTION');
    g(2, 'ENTITIES');
  }

  void end() {
    g(0, 'ENDSEC');
    g(0, 'EOF');
  }

  /// A box (4 LINEs) with top-left at ([x],[y]) in screen space (Y negated).
  /// [color] is an optional ACI override (62) — null = inherit the layer colour.
  /// [lineweight] is an optional group-370 width (1/100 mm).
  void box(String layer, double x, double y, double w, double h,
      {int? color, int? lineweight}) {
    void line(double x1, double y1, double x2, double y2) {
      g(0, 'LINE');
      g(8, layer);
      if (color != null) g(62, color);
      if (lineweight != null) g(370, lineweight);
      g(10, x1);
      g(20, -y1);
      g(11, x2);
      g(21, -y2);
    }

    line(x, y, x + w, y);
    line(x + w, y, x + w, y + h);
    line(x + w, y + h, x, y + h);
    line(x, y + h, x, y);
  }

  void text(String layer, double x, double y, String value,
      {double size = 12, int? color}) {
    g(0, 'TEXT');
    g(8, layer);
    if (color != null) g(62, color);
    g(10, x);
    g(20, -y);
    g(40, size);
    g(1, value);
  }

  void circle(String layer, double cx, double cy, double r,
      {int? color, int? lineweight}) {
    g(0, 'CIRCLE');
    g(8, layer);
    if (color != null) g(62, color);
    if (lineweight != null) g(370, lineweight);
    g(10, cx);
    g(20, -cy); // DXF Y negated, like box/text/connector
    g(40, r);
  }

  void connector(String layer, double x1, double y1, double x2, double y2,
      {int? color, int? lineweight, String? linetype}) {
    g(0, 'LINE');
    g(8, layer);
    if (linetype != null) g(6, linetype);
    if (color != null) g(62, color);
    if (lineweight != null) g(370, lineweight);
    g(10, x1);
    g(20, -y1);
    g(11, x2);
    g(21, -y2);
  }

  @override
  String toString() => b.toString();
}

/// Render the sized electrical single-line as a DXF document, drawing the SAME
/// professional content as the PDF (`buildElectricalSld`) on the class layers
/// (see the library doc), preceded by a TABLES section defining the line-types
/// + layers so a CAD app resolves colour and dash without guessing. The
/// drawing is model-space (DXF Y up, so screen-space y-down is negated).
///
/// [chrome], when present, extends the frame's title block with the CLIENT /
/// DWG NO / REV / SCALE (`NTS` when unset — a single-line is schematic) /
/// DATE / DRAWN / CHECKED / APPROVED / SHEET rows as a ruled label|value band;
/// null ⇒ the original 96-tall block, byte-identical.
String electricalSldToDxf({
  ElectricalProject? project,
  ElectricalSystemResult? result,
  SldSheet? sheet,
  String diagramTitle = 'ELECTRICAL SINGLE-LINE DIAGRAM',
  bool overview = false,
  bool sourceChain = false,
  DrawingChrome? chrome,
  String? projectName,
  SldDxfLayers layers = SldDxfLayers.electrical,
}) {
  assert(sheet != null || (project != null && result != null),
      'electricalSldToDxf needs either a prebuilt sheet or project+result');
  final d = _Dxf()..begin();
  // A prebuilt [sheet] wins; else `overview` = the ZOOMED-OUT building
  // single-line (compact panel tree, optional source spine); default = the
  // per-panel detail single-line.
  final sheetResolved = sheet ??
      (overview
          ? buildElectricalOverview(
              project: project!, result: result!, sourceChain: sourceChain)
          : buildElectricalSld(project: project!, result: result!));

  // Essential prims are drawn ACI red (1); source MV-chain blue (5); normal
  // inherits the layer colour (null). Phase-bearing schedule cells carry the
  // Indonesian R/S/T = red/yellow/blue CAD convention (ACI 1 / 2 / 5 — yellow
  // reads on the CAD model-space background; the PDF prints it as dark amber).
  int? colorFor(SldRole r) => switch (r) {
        SldRole.normal => null,
        SldRole.essential => 1,
        SldRole.source => 5,
        SldRole.phaseR => 1,
        SldRole.phaseS => 2,
        SldRole.phaseT => 5,
      };

  // Class-layer routing (within the active [layers] namespace): an explicit
  // [SldLine.layer] WINS (used as-is); the essential role isolates onto the
  // essential layer (one CAD toggle for the emergency sub-tree); else a line
  // routes by weight — thick busbars → bus, medium feeder runs → feeder, thin
  // device/way graphics → device. Under the mechanical namespace bus/feeder/
  // device all collapse to M-DETAIL, so a plumbing riser never emits E-*.
  String lineLayer(SldLine l) =>
      l.layer ??
      (l.role == SldRole.essential
          ? layers.essential
          : switch (l.weight) {
              SldWeight.thick => layers.bus,
              SldWeight.medium => layers.feeder,
              SldWeight.thin => layers.device,
            });
  String shapeLayer(SldRole role) =>
      role == SldRole.essential ? layers.essential : layers.device;

  // Drawing-space primitives (panels / busbars / ways / feeders).
  for (final p in sheetResolved.prims) {
    switch (p) {
      case SldLine():
        d.connector(lineLayer(p), p.x1, p.y1, p.x2, p.y2,
            color: colorFor(p.role),
            lineweight: _lineweightFor(p.weight),
            linetype: p.dashed ? 'DASHED' : null);
      case SldRect():
        d.box(shapeLayer(p.role), p.x, p.y, p.w, p.h,
            color: colorFor(p.role), lineweight: _lineweightFor(p.weight));
      case SldLabel():
        d.text(layers.text, p.x, p.y, p.text,
            size: p.size * 1.3, color: colorFor(p.role));
      case SldCircle():
        d.circle(shapeLayer(p.role), p.cx, p.cy, p.r,
            color: colorFor(p.role), lineweight: _lineweightFor(p.weight));
    }
  }

  // ── Model-space title block + legend, laid out below the drawing ────────────
  // The chrome's extra rows grow the block below the supply note; absent
  // chrome ⇒ the original 96-tall block (byte-identical bar the layer names).
  final rows = _chromeFrameRows(chrome);
  const rowH = 18.0;
  const tbW = 360.0;
  const labelW = 88.0;
  final tbH = rows.isEmpty ? 96.0 : 84.0 + rows.length * rowH + 6.0;
  final frameTop = sheetResolved.maxY + 60;
  // [projectName] overrides the derived name — a prebuilt sheet (mechanical
  // riser) carries no [project], so the app passes the live name to avoid the
  // `Untitled project` placeholder (N2). Null / empty ⇒ the derived name.
  final pname = (projectName != null && projectName.isNotEmpty)
      ? projectName
      : (project?.name.isNotEmpty ?? false)
          ? project!.name
          : 'Untitled project';
  d.box(layers.frame, sheetResolved.minX, frameTop, tbW, tbH);
  d.text(layers.frame, sheetResolved.minX + 8, frameTop + 22, pname, size: 16);
  d.text(layers.frame, sheetResolved.minX + 8, frameTop + 44, diagramTitle,
      size: 12);
  d.text(layers.frame, sheetResolved.minX + 8, frameTop + 66,
      sheetResolved.supplyNote,
      size: 10);
  if (rows.isNotEmpty) {
    final x0 = sheetResolved.minX;
    const bandPad = 84.0; // band top, below the supply-note line
    final bandTop = frameTop + bandPad;
    final bandBot = bandTop + rows.length * rowH;
    // Band top rule + full-height label|value divider (the box bottom closes
    // the band 6 units below).
    d.connector(layers.frame, x0, bandTop, x0 + tbW, bandTop);
    d.connector(layers.frame, x0 + labelW, bandTop, x0 + labelW, bandBot);
    for (var i = 0; i < rows.length; i++) {
      final (label, value) = rows[i];
      final rowTop = bandTop + i * rowH;
      if (i > 0) d.connector(layers.frame, x0, rowTop, x0 + tbW, rowTop);
      d.text(layers.frame, x0 + 8, rowTop + 13, label, size: 7);
      d.text(layers.frame, x0 + labelW + 8, rowTop + 13, value, size: 10);
    }
    d.connector(layers.frame, x0, bandBot, x0 + tbW, bandBot);
  }

  if (sheetResolved.legend.isNotEmpty) {
    final lx = sheetResolved.minX + 400;
    d.box(layers.frame, lx, frameTop, 300,
        math.max(96, 22.0 + sheetResolved.legend.length * 14));
    d.text(layers.frame, lx + 8, frameTop + 16, 'LEGEND', size: 11);
    var row = 0;
    for (final e in sheetResolved.legend) {
      d.text(layers.frame, lx + 8, frameTop + 32 + row * 14,
          '${e.code}  -  ${e.meaning}',
          size: 9);
      row++;
    }
  }

  d.end();

  // TABLES precede ENTITIES: the shared CONTINUOUS/DASHED/DASHDOT line-types
  // + one LAYER record per class layer of the ACTIVE namespace (electrical:
  // E-ESSENTIAL red, feeder cyan mirroring the reference drawings' cyan-normal,
  // frame grey, 7 elsewhere; mechanical: M-DETAIL / M-TEXT / M-FRAME), plus any
  // explicit per-prim layer name (colour 7, CONTINUOUS) so nothing references
  // an undefined layer.
  final classLayers = layers.classLayers();
  final classNames = {for (final (name, _) in classLayers) name};
  final explicit = <String>{
    for (final p in sheetResolved.prims)
      if (p is SldLine && p.layer != null && !classNames.contains(p.layer))
        p.layer!,
  }.toList()
    ..sort();
  final tables = dxfTablesSection(layers: [
    for (final (name, aci) in classLayers) (name, aci, 'CONTINUOUS'),
    for (final name in explicit) (name, 7, 'CONTINUOUS'),
  ]);
  return tables + d.toString();
}

/// The chrome's title-block rows for the DXF frame — CLIENT / DWG NO / REV /
/// SCALE / DATE / DRAWN / CHECKED / APPROVED / SHEET, filtered present. SCALE
/// defaults `NTS` whenever the chrome is non-empty (a single-line is
/// schematic); null / empty chrome ⇒ no rows.
List<(String, String)> _chromeFrameRows(DrawingChrome? chrome) {
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

/// Render a [PowerOneLine] as a DXF document — each node a labelled box, each
/// edge a LINE. Nodes are auto-laid in insertion order into a grid (no node
/// coordinates exist in the model).
String powerOneLineToDxf(PowerOneLine oneLine) {
  final d = _Dxf()..begin();
  const cols = 3;

  final pos = <String, ({double x, double y})>{};
  for (var i = 0; i < oneLine.nodes.length; i++) {
    final col = i % cols;
    final row = i ~/ cols;
    pos[oneLine.nodes[i].id] =
        (x: col * (_boxW + _gapX), y: row * (_boxH + _gapY));
  }

  ({double x, double y}) centre(String id) {
    final p = pos[id]!;
    return (x: p.x + _boxW / 2, y: p.y + _boxH / 2);
  }

  for (final edge in oneLine.edges) {
    if (!pos.containsKey(edge.from) || !pos.containsKey(edge.to)) continue;
    final a = centre(edge.from);
    final z = centre(edge.to);
    d.connector('oneline', a.x, a.y, z.x, z.y);
    if (edge.label != null) {
      d.text('oneline', (a.x + z.x) / 2, (a.y + z.y) / 2, edge.label!, size: 10);
    }
  }

  for (final node in oneLine.nodes) {
    final at = pos[node.id]!;
    d.box('oneline', at.x, at.y, _boxW, _boxH);
    d.text('oneline', at.x + 8, at.y + 28, node.label, size: 14);
    if (node.sub != null) {
      d.text('oneline', at.x + 8, at.y + 56, node.sub!);
    }
  }

  d.end();
  return d.toString();
}
