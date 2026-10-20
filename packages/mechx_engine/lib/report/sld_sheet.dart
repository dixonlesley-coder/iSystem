/// Discipline-neutral single-line DRAWING primitives — the one geometry both the
/// PDF and DXF exporters render, and the live Flutter canvas paints. Pure
/// (Flutter-free). Originally lived in `electrical_sld_drawing.dart`; lifted here
/// so the MECHANICAL riser single-line (`mechanical_sld_drawing.dart`) can build
/// the same [SldSheet] without depending on the electrical model.
///
/// A renderer switches EXHAUSTIVELY over the sealed [SldPrim] set, so adding a
/// new subtype forces every format (PDF / DXF / canvas) to handle it (golden
/// rule 5 — one solve, generated renders).
library;

/// Stroke weight buckets (mapped to real widths by each renderer).
enum SldWeight { thin, medium, thick }

/// Drafting role of a primitive — drives its COLOUR (mirroring the reference
/// drawings' cyan-normal / red-essential split). `source` is the utility / MV /
/// transformer supply chain (electrical) or, on the mechanical riser, the
/// plant / supply-tank head.
///
/// `phaseR` / `phaseS` / `phaseT` mark PHASE-BEARING content (the R/S/T column
/// headers, per-way line-current cells and phase totals on a board schedule) so
/// every renderer can colour the three phases apart — the Indonesian
/// panel-builder red / yellow / blue R-S-T convention. A UI/drawing legend
/// only, deliberately NOT the PUIL/IEC conductor colours (brown/black/grey are
/// indistinguishable on screen); it claims no wiring-colour clause.
enum SldRole { normal, essential, source, phaseR, phaseS, phaseT }

/// A drawing primitive in y-down drawing space. Sealed so renderers switch
/// exhaustively over the small closed set.
sealed class SldPrim {
  const SldPrim();
}

class SldLine extends SldPrim {
  final double x1, y1, x2, y2;
  final SldWeight weight;
  final SldRole role;

  /// Optional explicit CAD layer name (e.g. `E-BUS`). When set, the DXF
  /// renderer places the entity on this layer AS-IS (the builder namespaces
  /// it); null ⇒ the renderer routes by class/weight. PDF + canvas ignore it
  /// (they have no layer concept). Default null ⇒ byte-identical.
  final String? layer;

  /// True ⇒ render as a DASHED line (PDF dash pattern, DXF `DASHED` linetype,
  /// canvas walked dash segments). Default false ⇒ solid, byte-identical.
  final bool dashed;

  const SldLine(this.x1, this.y1, this.x2, this.y2,
      {this.weight = SldWeight.thin,
      this.role = SldRole.normal,
      this.layer,
      this.dashed = false});
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

class SldCircle extends SldPrim {
  final double cx, cy, r;
  final SldWeight weight;
  final SldRole role;
  const SldCircle(this.cx, this.cy, this.r,
      {this.weight = SldWeight.thin, this.role = SldRole.normal});
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

  /// Round 29 (drawings-3-1) — annotations the builder could only place FUSED
  /// into another label. Non-zero ⇒ the PDF / DXF renderers print the plan
  /// pipeline's overlap warning ([planOverlapWarning]) so an illegible sheet
  /// is never issued as if clean. 0 (the default) ⇒ byte-identical.
  final int overlapCount;

  /// Round 43 (electrical-sim-8-riser-floor-band-illegible) — the label size
  /// (pt) this sheet prints at when its pagination could NOT reach
  /// `kMinPlotLabelPt` (a width-bound band no floor split can shrink). Non-null
  /// ⇒ the PDF / DXF renderers print [sldLegibilityWarning] on the sheet, so an
  /// illegible page is never issued silently. Null (the default) ⇒
  /// byte-identical.
  final double? belowMinLabelPt;

  const SldSheet({
    required this.prims,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    required this.legend,
    required this.supplyNote,
    this.overlapCount = 0,
    this.belowMinLabelPt,
  });

  /// This sheet flagged as printing at [pt] (below the plotted floor).
  SldSheet withBelowMinLabelPt(double pt) => SldSheet(
        prims: prims,
        minX: minX,
        minY: minY,
        maxX: maxX,
        maxY: maxY,
        legend: legend,
        supplyNote: supplyNote,
        overlapCount: overlapCount,
        belowMinLabelPt: pt,
      );

  bool get isEmpty => prims.isEmpty;
}

/// Round 43 — the legibility warning a sheet carrying
/// [SldSheet.belowMinLabelPt] prints (EN + ID, ASCII). Null ⇒ nothing.
String? sldLegibilityWarning(double? pt, {double minPt = 7}) => pt == null
    ? null
    : 'PERHATIAN: label tercetak ${pt.toStringAsFixed(1)} pt (< ${minPt.toStringAsFixed(0)} pt) / '
        'labels print below ${minPt.toStringAsFixed(0)} pt - gunakan kertas lebih besar '
        'atau pecah lembar / use a larger sheet or split';
