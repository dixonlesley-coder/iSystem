/// Drawing review R1 (2026-11-13) — the DETAIL sheet of a plan: every detail
/// callout of one plan sheet drawn again at an enlarged standard scale, ONE
/// geometry for the PDF and the DXF (golden rule 5).
///
/// The sheet is laid out in PAPER millimetres: each detail gets a viewport
/// ([planDetailPack]: one scale per sheet, frames packed in rows), a frame, its
/// caption (`DETAIL A` + `SKALA 1 : 20`) and a divided scale bar. The floor's
/// elements inside each detail are re-plotted into a synthetic network whose
/// "pixels" ARE paper millimetres (a run crossing the frame is cut at it), and
/// that network goes through the SAME plan exporters ([planToPdf] /
/// [networkToDxf]) at a fixed 1-px-per-paper-mm map ([PlanFixedFit]) — so the
/// symbols, the line styles, the label placement rule (legal slot or key tag +
/// PIPE KEY table) and the overlap honesty are the plan's own. Labels keep the
/// REAL lengths (the caller's §10 map, re-keyed), never a length measured on
/// the enlarged drawing. Pure.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../network/network.dart';
import '../sizing/network_sizing.dart';
import '../units.dart';
import 'drawing_chrome.dart';
import 'dxf_export.dart';
import 'plan_annotation_layout.dart' show kPlanLabelTextMm;
import 'plan_detail.dart';
import 'plan_pdf_export.dart';

/// One detail as plotted on its sheet.
class PlanDetailPlot {
  final PlanDetailCallout callout;
  final int scaleDenominator;

  /// The frame (paper mm, y-down from the page top-left).
  final LabelBox frameMm;

  /// The area of the plan the frame shows (sheet px).
  final LabelBox clipPx;
  const PlanDetailPlot(
      this.callout, this.scaleDenominator, this.frameMm, this.clipPx);
}

/// The detail sheet's synthetic plot: the re-plotted network + the re-keyed
/// maps the plan exporters read, the frames / captions / scale bars as marks,
/// and the area outside the frames as occupied (labels stay in their detail).
class PlanDetailSheetPlot {
  final List<PlanDetailPlot> details;
  final Network net;
  final Map<String, EdgeSizing> sizing;
  final Map<String, Length> edgeLengths;
  final Map<String, String> edgeTags;
  final Map<String, String> edgeElevationLabels;
  final Set<String> hiddenNodeIds;

  /// Elements drawn for context whose anchor lies OUTSIDE their callout's
  /// box: labelled on the plan, so left unlabelled here (the complement of
  /// the plan's suppression — every element is labelled exactly once).
  final Set<String> unlabelledIds;
  final PlanMarks marks;
  final List<LabelBox> occupiedMm;
  const PlanDetailSheetPlot({
    required this.details,
    required this.net,
    required this.sizing,
    required this.edgeLengths,
    required this.edgeTags,
    required this.edgeElevationLabels,
    required this.hiddenNodeIds,
    required this.unlabelledIds,
    required this.marks,
    required this.occupiedMm,
  });
}

/// Clip segment a→b to [r] (Liang–Barsky); null when it misses.
(double, double, double, double)? _clip(
    double ax, double ay, double bx, double by, LabelBox r) {
  var t0 = 0.0, t1 = 1.0;
  final dx = bx - ax, dy = by - ay;
  for (final (p, q) in [
    (-dx, ax - r.minX),
    (dx, r.maxX - ax),
    (-dy, ay - r.minY),
    (dy, r.maxY - ay),
  ]) {
    if (p == 0) {
      if (q < 0) return null;
      continue;
    }
    final t = q / p;
    if (p < 0) {
      if (t > t1) return null;
      if (t > t0) t0 = t;
    } else {
      if (t < t0) return null;
      if (t < t1) t1 = t;
    }
  }
  return (ax + t0 * dx, ay + t0 * dy, ax + t1 * dx, ay + t1 * dy);
}

bool _inside(double x, double y, LabelBox r) =>
    x >= r.minX && x <= r.maxX && y >= r.minY && y <= r.maxY;

/// The area of [area] (paper mm) NOT covered by [frames], as boxes: vertical
/// slabs between every frame x-edge, each split around the frames spanning
/// it. Pure.
List<LabelBox> planDetailOutsideFrames(List<LabelBox> frames, LabelBox area) {
  final xs = <double>{area.minX, area.maxX};
  for (final f in frames) {
    xs
      ..add(f.minX.clamp(area.minX, area.maxX))
      ..add(f.maxX.clamp(area.minX, area.maxX));
  }
  final sx = xs.toList()..sort();
  final out = <LabelBox>[];
  for (var i = 0; i + 1 < sx.length; i++) {
    final x0 = sx[i], x1 = sx[i + 1];
    if (x1 - x0 <= 1e-9) continue;
    final covering = [
      for (final f in frames)
        if (f.minX <= x0 + 1e-9 && f.maxX >= x1 - 1e-9) f
    ]..sort((p, q) => p.minY.compareTo(q.minY));
    var y = area.minY;
    for (final f in covering) {
      if (f.minY > y) out.add((minX: x0, minY: y, maxX: x1, maxY: f.minY));
      y = math.max(y, f.maxY);
    }
    if (y < area.maxY) out.add((minX: x0, minY: y, maxX: x1, maxY: area.maxY));
  }
  return out;
}

/// The caption strip under each frame: title + scale (16 mm), plus one line
/// per distinct MATCH LINE neighbour of a split piece (S1).
double _captionMm(List<PlanDetailCallout> details) {
  var k = 0;
  for (final d in details) {
    k = math.max(k, {for (final m in d.matches) m.caption}.length);
  }
  return k == 0 ? 16 : 16 + 1.6 * kPlanLabelTextMm * k + 2;
}

/// Plot the [details] of the plan sheet ([sheetId], [floorIndex]) into the
/// paper-mm drawing [areaMm] of a detail sheet (see the library note).
PlanDetailSheetPlot planDetailSheetPlot({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required Map<String, Length> edgeLengths,
  required String sheetId,
  required int floorIndex,
  required double metersPerPixel,
  required List<PlanDetailCallout> details,
  required LabelBox areaMm,
  Map<String, String>? edgeTags,
  Map<String, String>? edgeElevationLabels,
}) {
  bool onFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;
  const ts = kPlanLabelTextMm;
  final pack = planDetailPack(
      sizesM: [
        for (final d in details)
          (
            w: (d.rectPx.maxX - d.rectPx.minX) * metersPerPixel,
            h: (d.rectPx.maxY - d.rectPx.minY) * metersPerPixel,
          ),
      ],
      area: areaMm,
      // S1 — a split piece's MATCH LINE caption takes a third caption line.
      captionMm: _captionMm(details));
  final plots = <PlanDetailPlot>[];
  final nodes = <NetNode>[];
  final edges = <NetEdge>[];
  final used = <String>{};
  final hidden = <String>{};
  final unlabelled = <String>{};
  final sz = <String, EdgeSizing>{};
  final lens = <String, Length>{};
  final tags = <String, String>{};
  final elev = <String, String>{};
  final lines = <PlanMarkLine>[];
  final texts = <PlanMarkText>[];

  for (var i = 0; i < details.length; i++) {
    final d = details[i];
    final r = d.rectPx;
    final n = pack.n;
    final k = metersPerPixel * 1000 / n; // paper mm per sheet px
    final frame = pack.frames[i];
    final fw = frame.maxX - frame.minX, fh = frame.maxY - frame.minY;
    final vcx = (frame.minX + frame.maxX) / 2;
    final vcy = (frame.minY + frame.maxY) / 2;
    final rcx = (r.minX + r.maxX) / 2, rcy = (r.minY + r.maxY) / 2;
    final clip = (
      minX: rcx - fw / 2 / k,
      minY: rcy - fh / 2 / k,
      maxX: rcx + fw / 2 / k,
      maxY: rcy + fh / 2 / k,
    );
    plots.add(PlanDetailPlot(d, n, frame, clip));
    double mx(double x) => vcx + (x - rcx) * k;
    double my(double y) => vcy + (y - rcy) * k;

    String fresh(String base) {
      var id = base;
      var j = 0;
      while (used.contains(id)) {
        id = '$base#${d.letter}${j == 0 ? '' : j}';
        j++;
      }
      used.add(id);
      return id;
    }

    // The real nodes inside the clip, at their own ids where free.
    final idOf = <String, String>{};
    for (final nd in net.nodes) {
      if (!onFloor(nd) || !_inside(nd.x, nd.y, clip)) continue;
      if (used.contains(nd.id)) continue;
      used.add(nd.id);
      idOf[nd.id] = nd.id;
      if (!d.containsPx(nd.x, nd.y)) unlabelled.add(nd.id);
      nodes.add(nd.copyWith(x: mx(nd.x), y: my(nd.y)));
    }
    String bare(String baseId, double x, double y, int fl) {
      final id = fresh(baseId);
      nodes.add(NetNode(id: id, sheetId: sheetId, x: x, y: y, floorIndex: fl));
      hidden.add(id);
      return id;
    }

    void carry(NetEdge e, String newId) {
      final s = sizing[e.id];
      if (s != null) sz[newId] = s;
      // The REAL length: the caller's §10 map, else (a run) the calibrated
      // plan length — never a length measured on the enlarged drawing.
      var l = edgeLengths[e.id];
      if (l == null && e.kind == EdgeKind.run) {
        final a = net.nodeById(e.fromId)!, c = net.nodeById(e.toId)!;
        final px =
            math.sqrt((c.x - a.x) * (c.x - a.x) + (c.y - a.y) * (c.y - a.y));
        if (px > 0) l = Length(px * metersPerPixel);
      }
      if (l != null) lens[newId] = l;
      final t = edgeTags?[e.id];
      if (t != null) tags[newId] = t;
      final el = edgeElevationLabels?[e.id];
      if (el != null) elev[newId] = el;
    }

    for (final e in net.edges) {
      final a = net.nodeById(e.fromId);
      final c = net.nodeById(e.toId);
      if (a == null || c == null) continue;
      if (e.kind == EdgeKind.run) {
        if (!onFloor(a) || !onFloor(c)) continue;
        final seg = _clip(a.x, a.y, c.x, c.y, clip);
        if (seg == null) continue;
        final (x1, y1, x2, y2) = seg;
        if ((x2 - x1).abs() + (y2 - y1).abs() < 1e-9) continue;
        final fromId = idOf[a.id] ?? bare(a.id, mx(x1), my(y1), floorIndex);
        final toId = idOf[c.id] ?? bare(c.id, mx(x2), my(y2), floorIndex);
        final id = fresh('${e.id}#${d.letter}');
        if (!d.containsPx((a.x + c.x) / 2, (a.y + c.y) / 2)) unlabelled.add(id);
        edges.add(NetEdge(
            id: id,
            fromId: fromId,
            toId: toId,
            service: e.service,
            kind: e.kind,
            pipeProduct: e.pipeProduct,
            ductProduct: e.ductProduct,
            sizeOverride: e.sizeOverride));
        carry(e, id);
      } else {
        final here = onFloor(a) ? a : (onFloor(c) ? c : null);
        if (here == null || idOf[here.id] == null) continue;
        final other = here.id == a.id ? c : a;
        final otherId =
            bare(other.id, mx(here.x), my(here.y), other.floorIndex);
        final id = fresh('${e.id}#${d.letter}');
        if (!d.containsPx(here.x, here.y)) unlabelled.add(id);
        edges.add(NetEdge(
            id: id,
            fromId: here.id == a.id ? here.id : otherId,
            toId: here.id == a.id ? otherId : here.id,
            service: e.service,
            kind: e.kind,
            pipeProduct: e.pipeProduct,
            ductProduct: e.ductProduct,
            sizeOverride: e.sizeOverride));
        carry(e, id);
      }
    }

    // Frame, caption, scale bar.
    for (final (ax, ay, bx, by) in [
      (frame.minX, frame.minY, frame.maxX, frame.minY),
      (frame.maxX, frame.minY, frame.maxX, frame.maxY),
      (frame.maxX, frame.maxY, frame.minX, frame.maxY),
      (frame.minX, frame.maxY, frame.minX, frame.minY),
    ]) {
      lines.add(PlanMarkLine(ax, ay, bx, by));
    }
    final capY = frame.maxY + 6.5;
    final title = 'DETAIL ${d.letter}';
    texts.add(PlanMarkText(frame.minX, capY, 5, title));
    final scaleText = 'SKALA 1 : $n';
    texts.add(PlanMarkText(frame.minX, capY + 1.6 * ts, ts, scaleText));
    final barX = frame.minX +
        math.max(title.length * 5 * 0.55, scaleText.length * ts * 0.55) +
        8;
    final bar = planDetailScaleBar(
        n: n, x0: barX, y0: capY - 1.5, textMm: kMinPlotTextMm);
    lines.addAll(bar.lines);
    texts.addAll(bar.texts);
    // Drawing review S1 — the cut shared with the neighbouring piece of a
    // split detail: a dashed match line across the frame at the cut, and its
    // caption ('MATCH LINE - LIHAT DETAIL B (M-5nn)') under the scale text.
    var my0 = capY + 3.2 * ts;
    final captioned = <String>{};
    for (final m in d.matches) {
      final seg = _clip(mx(m.x1), my(m.y1), mx(m.x2), my(m.y2), frame);
      if (seg != null) {
        final (x1, y1, x2, y2) = seg;
        lines.add(PlanMarkLine(x1, y1, x2, y2, dashed: true, heavy: true));
      }
      if (captioned.add(m.caption)) {
        texts.add(PlanMarkText(frame.minX, my0, ts, m.caption));
        my0 += 1.6 * ts;
      }
    }
  }
  return PlanDetailSheetPlot(
    details: plots,
    net: Network(nodes: nodes, edges: edges),
    sizing: sz,
    edgeLengths: lens,
    edgeTags: tags,
    edgeElevationLabels: elev,
    hiddenNodeIds: hidden,
    unlabelledIds: unlabelled,
    marks: PlanMarks(lines: lines, texts: texts),
    occupiedMm:
        planDetailOutsideFrames([for (final p in plots) p.frameMm], areaMm),
  );
}

/// One paper mm per synthetic pixel, in metres per pixel at "1 : 1".
const double _kMmPerPx = 0.001;

/// Fix round F6 (2026-11-13) — the detail sheet's chrome with its legend
/// narrowed to what [plot] DRAWS inside its windows: the services of its
/// (clipped) runs and the component glyphs of its visible nodes. The plan's
/// legend lists the whole floor; a detail never keys a service or symbol it
/// does not show. Null / empty chrome passes through. Pure.
DrawingChrome? planDetailLegendChrome(
    DrawingChrome? chrome, PlanDetailSheetPlot plot) {
  if (chrome == null || chrome.isEmpty) return chrome;
  final services = {for (final e in plot.net.edges) e.service};
  final symbols = {
    for (final n in plot.net.nodes)
      if (n.component != null && !plot.hiddenNodeIds.contains(n.id))
        n.component!,
  };
  return chrome.withLegendNarrowedTo(
      keepService: services.contains, keepSymbol: symbols.contains);
}

/// The detail plot + the chrome it is issued with (F6: the legend narrowed
/// to the plot's own content). Plotted twice: the first pass finds what the
/// windows draw, the second lays the sheet out with the narrowed legend's
/// reserve — the windows' content is the callouts' own either way, so the
/// legend keys exactly what the issued plot draws.
(PlanDetailSheetPlot, DrawingChrome?) _plotFor({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required Map<String, Length> edgeLengths,
  required String sheetId,
  required int floorIndex,
  required String projectName,
  required String sheetName,
  required String dateString,
  required double metersPerPixel,
  required List<PlanDetailCallout> details,
  DrawingChrome? chrome,
  Map<String, String>? edgeTags,
  Map<String, String>? edgeElevationLabels,
}) {
  PlanDetailSheetPlot plot(DrawingChrome? c) => _plotOnce(
      net: net,
      sizing: sizing,
      edgeLengths: edgeLengths,
      sheetId: sheetId,
      floorIndex: floorIndex,
      projectName: projectName,
      sheetName: sheetName,
      dateString: dateString,
      metersPerPixel: metersPerPixel,
      details: details,
      chrome: c,
      edgeTags: edgeTags,
      edgeElevationLabels: edgeElevationLabels);
  final narrowed = planDetailLegendChrome(chrome, plot(chrome));
  return (plot(narrowed), narrowed);
}

PlanDetailSheetPlot _plotOnce({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required Map<String, Length> edgeLengths,
  required String sheetId,
  required int floorIndex,
  required String projectName,
  required String sheetName,
  required String dateString,
  required double metersPerPixel,
  required List<PlanDetailCallout> details,
  DrawingChrome? chrome,
  Map<String, String>? edgeTags,
  Map<String, String>? edgeElevationLabels,
}) =>
    planDetailSheetPlot(
      net: net,
      sizing: sizing,
      edgeLengths: edgeLengths,
      sheetId: sheetId,
      floorIndex: floorIndex,
      metersPerPixel: metersPerPixel,
      details: details,
      areaMm: planDetailDrawingAreaMm(
          projectName: projectName,
          sheetName: sheetName,
          dateString: dateString,
          chrome: chrome),
      edgeTags: edgeTags,
      edgeElevationLabels: edgeElevationLabels,
    );

/// The plan sheet's DETAIL sheet as a single-page PDF (see the library note).
/// [chrome] is the detail sheet's own (its `M-5nn` number + `DETAIL - <floor>`
/// title); the rest are the plan's own inputs.
Uint8List planDetailSheetToPdf({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required Map<String, Length> edgeLengths,
  required String sheetId,
  required int floorIndex,
  required String projectName,
  required String sheetName,
  required String dateString,
  required double metersPerPixel,
  required List<PlanDetailCallout> details,
  DrawingChrome? chrome,
  Map<String, String>? edgeElevationLabels,
  Map<String, String>? edgeTags,
  Map<String, String>? nodeTags,
  double? gravitySlope,
}) {
  final (p, detailChrome) = _plotFor(
      net: net,
      sizing: sizing,
      edgeLengths: edgeLengths,
      sheetId: sheetId,
      floorIndex: floorIndex,
      projectName: projectName,
      sheetName: sheetName,
      dateString: dateString,
      metersPerPixel: metersPerPixel,
      details: details,
      chrome: chrome,
      edgeTags: edgeTags,
      edgeElevationLabels: edgeElevationLabels);
  return planToPdf(
    net: p.net,
    sizing: p.sizing,
    edgeLengths: p.edgeLengths,
    sheetId: sheetId,
    floorIndex: floorIndex,
    projectName: projectName,
    sheetName: sheetName,
    dateString: dateString,
    chrome: detailChrome,
    metersPerPixel: _kMmPerPx,
    edgeElevationLabels: p.edgeElevationLabels,
    edgeTags: p.edgeTags,
    nodeTags: nodeTags,
    gravitySlope: gravitySlope,
    extraMarks: p.marks,
    extraOccupiedPx: p.occupiedMm,
    hiddenNodeIds: p.hiddenNodeIds,
    fixedFit: const PlanFixedFit(),
    unlabelledIds: p.unlabelledIds,
  );
}

/// The DXF twin of [planDetailSheetToPdf]: the same synthetic plot in model
/// units of one PAPER millimetre (a flattened paper-space layout — each
/// detail states its own scale), through [networkToDxf].
String planDetailSheetToDxf({
  required Network net,
  required Map<String, EdgeSizing> sizing,
  required Map<String, Length> edgeLengths,
  required String sheetId,
  required int floorIndex,
  required String projectName,
  required String sheetName,
  required String dateString,
  required double metersPerPixel,
  required List<PlanDetailCallout> details,
  DrawingChrome? chrome,
  Map<String, String>? edgeElevationLabels,
  Map<String, String>? edgeTags,
  Map<String, String>? nodeTags,
  double? gravitySlope,
}) {
  final (p, detailChrome) = _plotFor(
      net: net,
      sizing: sizing,
      edgeLengths: edgeLengths,
      sheetId: sheetId,
      floorIndex: floorIndex,
      projectName: projectName,
      sheetName: sheetName,
      dateString: dateString,
      metersPerPixel: metersPerPixel,
      details: details,
      chrome: chrome,
      edgeTags: edgeTags,
      edgeElevationLabels: edgeElevationLabels);
  return networkToDxf(
    net: p.net,
    sizing: p.sizing,
    sheetId: sheetId,
    floorIndex: floorIndex,
    chrome: detailChrome,
    metersPerPixel: _kMmPerPx,
    edgeElevationLabels: p.edgeElevationLabels,
    edgeTags: p.edgeTags,
    nodeTags: nodeTags,
    gravitySlope: gravitySlope,
    edgeLengths: p.edgeLengths,
    projectName: projectName,
    extraMarks: p.marks,
    scaleRowOverride: kPlanDetailScaleRow,
    unlabelledIds: p.unlabelledIds,
    sheetPlot: planSheetPlot(
      net: p.net,
      sheetId: sheetId,
      floorIndex: floorIndex,
      projectName: projectName,
      sheetName: sheetName,
      dateString: dateString,
      chrome: detailChrome,
      metersPerPixel: _kMmPerPx,
      fixedFit: const PlanFixedFit(),
      extraOccupiedPx: p.occupiedMm,
    ),
  );
}
