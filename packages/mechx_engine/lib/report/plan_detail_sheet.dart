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
import 'plan_symbols.dart' show fixturePlanCode, kFixturePlanCodeNames;

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
double planDetailCaptionMm(List<PlanDetailCallout> details) {
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
  final sizesM = [
    for (final d in details)
      (
        w: (d.rectPx.maxX - d.rectPx.minX) * metersPerPixel,
        h: (d.rectPx.maxY - d.rectPx.minY) * metersPerPixel,
      ),
  ];
  // S1 — a split piece's MATCH LINE caption takes a third caption line.
  final capMm = planDetailCaptionMm(details);
  // Drawing backlog I-3 (b) — several details on one sheet each at its OWN
  // scale (the one it was laid out and checked at,
  // [PlanDetailCallout.scale]) when every detail carries one and they all
  // fit ([planDetailBins] fills sheets so they do); else one shared scale —
  // a lone detail takes the largest its sheet allows, as before.
  final own = details.length > 1 && details.every((d) => d.scale != null)
      ? [for (final d in details) d.scale!]
      : null;
  final mixed = own == null
      ? null
      : planDetailMixedPack(
          sizesM: sizesM, scales: own, area: areaMm, captionMm: capMm);
  final shared = mixed != null
      ? null
      : planDetailPack(sizesM: sizesM, area: areaMm, captionMm: capMm);
  final pack = (
    ns: mixed != null ? own! : [for (final _ in details) shared!.n],
    frames: mixed ?? shared!.frames,
  );
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
    final n = pack.ns[i];
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

    // The real nodes inside the clip, at their own ids where free. Fix round
    // 3 — a node inside ANOTHER detail's boundary belongs to that detail (it
    // is labelled there): drawn here under its own id first, it was left
    // unlabelled here and skipped there, so its tag printed nowhere.
    final idOf = <String, String>{};
    for (final nd in net.nodes) {
      if (!onFloor(nd) || !_inside(nd.x, nd.y, clip)) continue;
      if (used.contains(nd.id)) continue;
      if (!d.containsPx(nd.x, nd.y) &&
          details.any((o) => !identical(o, d) && o.containsPx(nd.x, nd.y))) {
        continue;
      }
      used.add(nd.id);
      idOf[nd.id] = nd.id;
      if (!d.containsPx(nd.x, nd.y)) unlabelled.add(nd.id);
      nodes.add(nd.copyWith(x: mx(nd.x), y: my(nd.y)));
    }
    String bare(String baseId, double x, double y, int fl) {
      // Fix round 3 — a cut stub never takes a REAL node's id: a stub
      // 'Da11' in detail A used to claim the drain-stack node detail B owns,
      // so B dropped the stack and its D-R tag printed nowhere.
      final id = fresh('$baseId~${d.letter}');
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
    // Fix round 3 — measured (Helvetica) caption widths, and a bar that
    // would run past its frame's right edge (out of the sheet) is
    // right-aligned to the frame when that still clears the caption.
    final capEnd = frame.minX +
        math.max(helveticaTextWidth(title, 5) * 1.06,
            helveticaTextWidth(scaleText, ts));
    var barX = capEnd + 8;
    final barLen = planDetailScaleBarLength(n);
    if (barX + barLen > frame.maxX && frame.maxX - barLen >= capEnd + 4) {
      barX = frame.maxX - barLen;
    }
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
  // Drawing backlog C-5 (iv) — the fixture-code note keys only the fixture
  // codes drawn inside the windows.
  final codes = {
    for (final n in plot.net.nodes)
      if (!plot.hiddenNodeIds.contains(n.id)) fixturePlanCode(n),
  }..remove(null);
  return chrome.withLegendNarrowedTo(
      keepService: services.contains,
      keepSymbol: symbols.contains,
      narrowNotes: (notes) => planDetailNarrowCodeNotes(notes, codes));
}

/// Drawing backlog C-5 (iv) — [notes] with the fixture-code note
/// (`WC water closet - LAV lavatory - ...`, [kFixturePlanCodeNames]) cut to
/// the [codes] present; a code note left empty is dropped, every other note
/// kept verbatim. Pure.
List<String> planDetailNarrowCodeNotes(
    List<String> notes, Set<String?> codes) {
  final out = <String>[];
  for (final note in notes) {
    final parts = note.split(' - ');
    final isCodeNote = parts.every((p) {
      final sp = p.indexOf(' ');
      if (sp <= 0) return false;
      final c = p.substring(0, sp);
      return kFixturePlanCodeNames[c] == p.substring(sp + 1);
    });
    if (!isCodeNote) {
      out.add(note);
      continue;
    }
    final kept = [
      for (final p in parts)
        if (codes.contains(p.substring(0, p.indexOf(' ')))) p,
    ];
    if (kept.isNotEmpty) out.add(kept.join(' - '));
  }
  return out;
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

/// Drawing backlog I-3 (c) — a level code in a tag (`CW-L12`, `D-GF`,
/// `SP-B1`, `RW-RF`) masked, so two typical floors' tags compare equal.
String planDetailMaskLevel(String s) => s.replaceAll(
    RegExp(r'(?<=[A-Z]-)(L\d+|GF|B\d+|RF)(?![0-9A-Za-z])'), '#');

/// Drawing backlog I-3 (c) — the CONTENT of a detail sheet's [plot] as a
/// string: every detail's scale and frame, every drawn node (paper-mm
/// position, role, component, fixture, tag) and every drawn edge (ends,
/// service, kind, size, real length, tag, level label), with level codes
/// masked ([planDetailMaskLevel]) and element ids left out. Two typical
/// floors whose detail sheets draw the same thing get the same string.
/// Pure, order-independent.
String planDetailContentSignature(PlanDetailSheetPlot plot,
    {Map<String, String>? nodeTags}) {
  String r(double v) => v.toStringAsFixed(2);
  final pos = {
    for (final n in plot.net.nodes) n.id: '${r(n.x)},${r(n.y)}',
  };
  final nodes = [
    for (final n in plot.net.nodes)
      if (!plot.hiddenNodeIds.contains(n.id))
        '${pos[n.id]}|${n.role.name}|${n.component?.name}|'
            '${n.fixture?.name}|'
            '${planDetailMaskLevel(nodeTags?[n.id] ?? '')}|'
            '${plot.unlabelledIds.contains(n.id)}',
  ]..sort();
  final edges = <String>[];
  for (final e in plot.net.edges) {
    final s = plot.sizing[e.id];
    final ends = [pos[e.fromId] ?? '?', pos[e.toId] ?? '?']..sort();
    // A riser's storey length is not printed on a plan or detail (its tag
    // names the stack), so floors of different heights still match.
    final len = e.kind == EdgeKind.riser ? null : plot.edgeLengths[e.id];
    edges.add('${ends.join('>')}|${e.service.name}|${e.kind.name}|'
        '${s == null ? '-' : r(s.diameter.inMillimeters)}|'
        '${s?.width == null ? '-' : r(s!.width!.inMillimeters)}x'
        '${s?.height == null ? '-' : r(s!.height!.inMillimeters)}|'
        '${len == null ? '-' : r(len.meters)}|'
        '${planDetailMaskLevel(plot.edgeTags[e.id] ?? '')}|'
        '${plot.edgeElevationLabels[e.id] ?? ''}|'
        '${plot.unlabelledIds.contains(e.id)}');
  }
  edges.sort();
  final frames = [
    for (final d in plot.details)
      '${d.callout.letter}@${d.scaleDenominator}:'
          '${r(d.frameMm.minX)},${r(d.frameMm.minY)},'
          '${r(d.frameMm.maxX)},${r(d.frameMm.maxY)}|'
          '${[for (final m in d.callout.matches) m.letter].join(',')}',
  ];
  return [...frames, '#N', ...nodes, '#E', ...edges].join('\n');
}

/// Fix round 3 (O1, 2026-11-13) — a TYPICAL detail sheet (issued once for
/// several floors) prints no floor-specific level code: `CW-L7` reads
/// `CW-Ln`, `n` keyed by [kPlanTypicalDetailNote]. Riser / plant tags (no
/// level code) are unchanged. Pure.
String planTypicalTag(String s) => s.replaceAll(
    RegExp(r'(?<=[A-Z]-)(L\d+|GF|B\d+|RF)(?![0-9A-Za-z])'), 'Ln');

/// Fix round 3 (O1) — the one note a typical detail sheet carries in place
/// of the single-floor CL datum (`CL = ... (Lantai 7 FFL +24.00)`): the
/// level code `n` is each listed floor and every CL is above THAT floor's
/// own FFL, so no one floor's FFL figure is printed.
const String kPlanTypicalDetailNote =
    'TIPIKAL: n = lantai yang tercantum / typical: n = each listed floor; '
    "CL above each floor's own FFL";

/// Fix round 3 (O1) — a typical detail sheet's legend notes: the plan's
/// notes with the single-floor CL datum note dropped and
/// [kPlanTypicalDetailNote] added (once). Pure.
List<String> planTypicalDetailNotes(List<String> notes) => [
      for (final n in notes)
        if (!n.startsWith('CL = pipe centreline above')) n,
      kPlanTypicalDetailNote,
    ];

/// Drawing backlog I-3 (c) — the sheet name of a TYPICAL detail issued once
/// for the floors [floorNames]: `TIPIKAL - Lantai 2..29` for a consecutive
/// run of `Lantai N`, else the runs comma-joined (`TIPIKAL - Lantai 2..5,
/// 7..9`), or the names themselves. Pure.
String planDetailTypicalName(List<String> floorNames) {
  final re = RegExp(r'^Lantai (\d+)$');
  final nums = [
    for (final f in floorNames) int.tryParse(re.firstMatch(f)?.group(1) ?? '')
  ];
  if (nums.isEmpty || nums.any((n) => n == null)) {
    return 'TIPIKAL - ${floorNames.join(', ')}';
  }
  final ns = [for (final n in nums) n!]..sort();
  final runs = <String>[];
  var a = ns.first, b = ns.first;
  for (final n in ns.skip(1)) {
    if (n == b + 1) {
      b = n;
      continue;
    }
    runs.add(a == b ? '$a' : '$a..$b');
    a = b = n;
  }
  runs.add(a == b ? '$a' : '$a..$b');
  return 'TIPIKAL - Lantai ${runs.join(', ')}';
}
