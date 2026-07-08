/// Pure generator for the SUBMITTAL FRONT MATTER — the cover sheet, the
/// Daftar Gambar (drawing list / index) and the general-notes + MASTER-LEGEND
/// sheet that open an Indonesian PBG/permit submittal (WORKFLOW-GOLDENS-REVIEW
/// N21 + N24). Each is emitted as an [SldSheet] of the same neutral drawing
/// primitives the riser / electrical single-lines use, so the existing
/// `sldSheetsToPdf` (and DXF) path renders them with the shared title-block
/// chrome — the front matter becomes the first sheets of the issued DRAWING set,
/// not a separate document.
///
/// The MASTER LEGEND (N24) is the ONE shared symbol dictionary for the whole
/// set: service line conventions, the equipment/fitting glyphs the plans draw
/// (via [planComponentPrims]), the riser UP/DN markers, the flow chevron, the
/// fixture-terminal triangle (via [planFixturePrims]), and the cable-family
/// constructions — so a reviewer moving between sheets reads ONE symbol
/// language. A per-sheet plan legend is a SUBSET of this dictionary
/// ([planLegendSubset]).
///
/// PURE (Flutter-free): builds drawing-space primitives (y-DOWN, like the other
/// `SldSheet` builders); the renderers own colour/weight and the y-flip. The
/// engine never reads the clock — dates/numbers are caller-supplied strings.
library;

import '../electrical/cable_family.dart' show cableFamilyDescription;
import '../network/network.dart';
import 'drawing_chrome.dart'
    show DrawingChrome, serviceChromeLabel, serviceDashPatternPdf;
import 'plan_symbols.dart' show planComponentPrims, planFixturePrims;
import 'riser_tags.dart' show riserServiceCode;
import 'sld_sheet.dart';

// ── Public model: one drawing-list row ──────────────────────────────────────

/// A single row of the Daftar Gambar (drawing list): the sheet's drawing
/// [number], its [title], [revision] and issue [date]. Built directly or from a
/// sheet's [DrawingChrome] via [DrawingListEntry.fromChrome], so the index reads
/// from the SAME chrome objects the drawings stamp (N21).
class DrawingListEntry {
  final String number;
  final String title;
  final String revision;
  final String date;

  const DrawingListEntry({
    required this.number,
    required this.title,
    this.revision = '',
    this.date = '',
  });

  /// Read a list row off a sheet's [chrome]: DWG NO / TITLE / REV / DATE. When
  /// the chrome carries no [DrawingChrome.drawingTitle], [fallbackTitle] names
  /// the sheet (e.g. the discipline diagram title).
  factory DrawingListEntry.fromChrome(
    DrawingChrome chrome, {
    String fallbackTitle = '',
  }) {
    final title = (chrome.drawingTitle != null &&
            chrome.drawingTitle!.trim().isNotEmpty)
        ? chrome.drawingTitle!.trim()
        : fallbackTitle;
    return DrawingListEntry(
      number: chrome.drawingNumber?.trim() ?? '',
      title: title,
      revision: chrome.revisionNumber?.trim() ?? '',
      date: chrome.dateString?.trim() ?? '',
    );
  }
}

// ── Master legend model (the ONE shared symbol dictionary, N24) ─────────────

/// How a master-legend row draws its SYMBOL cell. Mirrors what the plan/riser
/// exporters actually put on paper, so the legend is honest by construction.
enum LegendGlyphKind {
  /// A short solid line sample (a piped/ducted run).
  line,

  /// A short dashed line sample (vent / return-air / fire conventions).
  lineDashed,

  /// An equipment/fitting glyph drawn by [planComponentPrims].
  component,

  /// The fixture-terminal drop triangle drawn by [planFixturePrims].
  fixtureTriangle,

  /// A riser marker with an UP sense (circle + upward tick).
  riserUp,

  /// A riser marker with a DN sense (circle + downward tick).
  riserDown,

  /// A flow-direction chevron.
  flowChevron,

  /// No glyph — a text-only row (cable families, abbreviations).
  none,
}

/// One row of the master legend: the [kind] of symbol to draw, the (optional)
/// [component] it draws when [kind] is [LegendGlyphKind.component], the short
/// [code] and its [meaning].
class MasterLegendEntry {
  final LegendGlyphKind kind;
  final NodeComponent? component;
  final String code;
  final String meaning;
  const MasterLegendEntry({
    required this.kind,
    required this.code,
    required this.meaning,
    this.component,
  });
}

/// A titled group of [MasterLegendEntry] rows (SERVICES / EQUIPMENT / MARKERS /
/// CABLES).
class MasterLegendSection {
  final String title;
  final List<MasterLegendEntry> entries;
  const MasterLegendSection(this.title, this.entries);
}

/// The default general-notes block (drafting-office standard notes, ASCII,
/// EN + short Bahasa gloss). Not engineering values, so no `// VERIFY`.
const List<String> kDefaultGeneralNotes = [
  'All dimensions are in millimetres (mm) unless noted otherwise.',
  'Do not scale off this drawing; verify all dimensions on site.',
  'Design is to SNI / PUIL standards; see the calculation report.',
  'Pipe / duct / cable sizes are nominal; confirm vs the equipment schedule.',
  'Coordinate all MEP routes with architectural + structural drawings.',
  'Report any discrepancy to the engineer before construction begins.',
  'Refer to the Daftar Gambar (drawing list) for the complete issued set.',
];

/// The title-block TITLE row per front-matter page (kept short for the small
/// title-block cell; the full bilingual heading is drawn large in each sheet's
/// own body).
const List<String> kFrontMatterDiagramTitles = [
  'COVER SHEET',
  'DRAWING LIST / DAFTAR GAMBAR',
  'GENERAL NOTES & LEGEND',
];

// ── Master legend builder ────────────────────────────────────────────────────

/// Build the master symbol dictionary for the set: a SERVICES section (one row
/// per [services] present, dashed sample where the service draws dashed), an
/// EQUIPMENT & FITTINGS section (one row per [components] present, drawn with
/// its real plan glyph), a MARKERS section (riser UP/DN, flow chevron, fixture
/// terminal — the symbols the plan draws but never keys), and — when
/// [cableFamilies] is non-empty — a CABLES section (each family's distinct
/// construction). Sections with no rows are omitted.
List<MasterLegendSection> buildMasterLegendSections({
  Iterable<ServiceType> services = const [],
  Iterable<NodeComponent> components = const [],
  Iterable<String> cableFamilies = const [],
}) {
  final out = <MasterLegendSection>[];

  // SERVICES — one row per service present, ordered by the enum.
  final svc = services.toSet();
  final svcRows = <MasterLegendEntry>[
    for (final s in ServiceType.values)
      if (svc.contains(s))
        MasterLegendEntry(
          kind: serviceDashPatternPdf(s) != null
              ? LegendGlyphKind.lineDashed
              : LegendGlyphKind.line,
          code: riserServiceCode(s),
          meaning: serviceChromeLabel(s),
        ),
  ];
  if (svcRows.isNotEmpty) {
    out.add(MasterLegendSection('SISTEM / SERVICES', svcRows));
  }

  // EQUIPMENT & FITTINGS — one row per component present, ordered by the enum.
  final comp = components.toSet();
  final compRows = <MasterLegendEntry>[
    for (final c in NodeComponent.values)
      if (comp.contains(c))
        MasterLegendEntry(
          kind: LegendGlyphKind.component,
          component: c,
          code: componentLegendCode(c),
          meaning: componentLegendName(c),
        ),
  ];
  if (compRows.isNotEmpty) {
    out.add(MasterLegendSection('PERALATAN & FITTING / EQUIPMENT', compRows));
  }

  // MARKERS — the plan symbols keyed nowhere on the plan today (N24).
  out.add(const MasterLegendSection('PENANDA / MARKERS', [
    MasterLegendEntry(
        kind: LegendGlyphKind.riserUp, code: 'UP', meaning: 'Riser up (naik)'),
    MasterLegendEntry(
        kind: LegendGlyphKind.riserDown,
        code: 'DN',
        meaning: 'Riser down (turun)'),
    MasterLegendEntry(
        kind: LegendGlyphKind.flowChevron,
        code: '>',
        meaning: 'Flow direction (arah aliran)'),
    MasterLegendEntry(
        kind: LegendGlyphKind.fixtureTriangle,
        code: 'FIX',
        meaning: 'Fixture terminal (titik alat)'),
  ]));

  // CABLES — one row per family, each its own construction (N24).
  final fams = cableFamilies.toSet().toList()..sort();
  if (fams.isNotEmpty) {
    out.add(MasterLegendSection('KABEL / CABLES', [
      for (final f in fams)
        MasterLegendEntry(
            kind: LegendGlyphKind.none,
            code: f,
            meaning: cableFamilyDescription(f)),
    ]));
  }
  return out;
}

/// The PLAN-legend SUBSET of the master dictionary (N24): the service line
/// conventions + the plan markers (riser UP/DN, flow chevron, fixture triangle)
/// + the equipment glyphs — i.e. every symbol a plan sheet actually draws,
/// which the per-sheet colour legend abbreviates. A proper subset of
/// [buildMasterLegendSections] (same rows, minus the electrical CABLES section).
List<MasterLegendEntry> planLegendSubset({
  Iterable<ServiceType> services = const [],
  Iterable<NodeComponent> components = const [],
}) =>
    [
      for (final s in buildMasterLegendSections(
          services: services, components: components))
        if (s.title != 'KABEL / CABLES') ...s.entries,
    ];

// ── Sheet builders ───────────────────────────────────────────────────────────

// Nominal drawing-space box the front-matter sheets are authored into (y-DOWN).
// Chosen close to the A3 drawing-area aspect so the renderer's fit keeps text at
// a legible size.
const double _sheetW = 1120;
const double _sheetH = 800;
const double _marginL = 40;

/// Approx. baseline-start X to CENTRE [text] at [cx] for a label of [size]
/// (the same 0.55 average-glyph-width heuristic the exporters use).
double _centeredX(String text, double size, double cx) =>
    cx - text.length * size * 0.55 / 2;

/// The submittal COVER SHEET: the project name, the document title, the
/// discipline, and a framed identity block (client / drawing no / rev / date /
/// sheet count / prepared-by), all as centred drawing primitives.
SldSheet buildCoverSheet({
  required String projectName,
  String? clientName,
  String? drawingNumber,
  String? revision,
  String? date,
  String discipline = 'MEP (Mekanikal - Elektrikal - Plambing)',
  String documentTitle = 'DESIGN SUBMITTAL / DOKUMEN PERENCANAAN',
  int? sheetCount,
  String? preparedBy,
}) {
  const cx = _sheetW / 2;
  final prims = <SldPrim>[];
  void label(double x, double y, String t, double size, {bool bold = false}) =>
      prims.add(SldLabel(x, y, t, size: size, bold: bold));
  void centre(double y, String t, double size, {bool bold = false}) =>
      label(_centeredX(t, size, cx), y, t, size, bold: bold);

  // Top rule + a small discipline tag.
  prims.add(const SldLine(_marginL, 60, _sheetW - _marginL, 60,
      weight: SldWeight.medium));
  centre(110, documentTitle, 20, bold: true);
  centre(150, discipline, 13);

  // Project name — the hero line, boxed.
  const boxTop = 220.0, boxBot = 330.0, boxL = 120.0, boxR = _sheetW - 120;
  prims.add(const SldRect(boxL, boxTop, boxR - boxL, boxBot - boxTop,
      weight: SldWeight.medium));
  centre(275, projectName, 26, bold: true);
  centre(310, 'PROYEK / PROJECT', 11);

  // Identity register — label/value rows, ruled.
  final rows = <(String, String)>[
    if (clientName != null && clientName.trim().isNotEmpty)
      ('PEMBERI TUGAS / CLIENT', clientName.trim()),
    if (drawingNumber != null && drawingNumber.trim().isNotEmpty)
      ('NO. GAMBAR / DRAWING NO.', drawingNumber.trim()),
    if (revision != null && revision.trim().isNotEmpty)
      ('REVISI / REVISION', revision.trim()),
    if (date != null && date.trim().isNotEmpty) ('TANGGAL / DATE', date.trim()),
    if (sheetCount != null)
      ('JUMLAH LEMBAR / SHEETS', sheetCount.toString()),
    if (preparedBy != null && preparedBy.trim().isNotEmpty)
      ('DIGAMBAR / PREPARED BY', preparedBy.trim()),
  ];
  const regL = 260.0, regR = _sheetW - 260, regTop = 400.0, rowH = 40.0;
  const labelColW = 300.0;
  for (var i = 0; i < rows.length; i++) {
    final (k, v) = rows[i];
    final yTop = regTop + i * rowH;
    final yMid = yTop + rowH * 0.62;
    // Row separators.
    prims.add(SldLine(regL, yTop, regR, yTop));
    label(regL + 10, yMid, k, 11);
    label(regL + labelColW, yMid, v, 13, bold: true);
  }
  if (rows.isNotEmpty) {
    final yBot = regTop + rows.length * rowH;
    prims
      ..add(SldLine(regL, yBot, regR, yBot))
      ..add(SldLine(regL, regTop, regL, yBot))
      ..add(SldLine(regR, regTop, regR, yBot))
      ..add(SldLine(regL + labelColW - 12, regTop, regL + labelColW - 12, yBot));
  }

  // Footer tagline.
  centre(_sheetH - 30, 'Digenerasi oleh iSystem / Generated by iSystem', 10);

  return SldSheet(
    prims: prims,
    minX: 0,
    minY: 0,
    maxX: _sheetW,
    maxY: _sheetH,
    legend: const [],
    supplyNote: '',
  );
}

/// The DAFTAR GAMBAR (drawing list / index): a ruled table — No. / DWG NO /
/// TITLE / REV / DATE — one row per [drawings] entry. Empty list ⇒ a titled
/// sheet with the header row only (honest: nothing to enumerate).
SldSheet buildDrawingListSheet(
  List<DrawingListEntry> drawings, {
  String projectName = '',
}) {
  final prims = <SldPrim>[];
  void label(double x, double y, String t, double size, {bool bold = false}) =>
      prims.add(SldLabel(x, y, t, size: size, bold: bold));

  label(_centeredX('DAFTAR GAMBAR / DRAWING LIST', 20, _sheetW / 2), 70,
      'DAFTAR GAMBAR / DRAWING LIST', 20, bold: true);
  if (projectName.trim().isNotEmpty) {
    label(_centeredX(projectName, 12, _sheetW / 2), 100, projectName, 12);
  }

  // Column X starts (drawing space): No. | DWG NO | TITLE | REV | DATE.
  const cNo = _marginL + 10.0;
  const cNum = _marginL + 70.0;
  const cTitle = _marginL + 230.0;
  const cRev = _sheetW - 260.0;
  const cDate = _sheetW - 190.0;
  const tableL = _marginL, tableR = _sheetW - _marginL;
  const headTop = 140.0, rowH = 34.0;

  void rowRule(double y) => prims.add(SldLine(tableL, y, tableR, y));

  // Header.
  rowRule(headTop);
  const headMid = headTop + rowH * 0.62;
  label(cNo, headMid, 'NO.', 11, bold: true);
  label(cNum, headMid, 'NO. GAMBAR', 11, bold: true);
  label(cTitle, headMid, 'JUDUL / TITLE', 11, bold: true);
  label(cRev, headMid, 'REV', 11, bold: true);
  label(cDate, headMid, 'TANGGAL', 11, bold: true);
  rowRule(headTop + rowH);

  for (var i = 0; i < drawings.length; i++) {
    final d = drawings[i];
    final yTop = headTop + (i + 1) * rowH;
    final yMid = yTop + rowH * 0.62;
    label(cNo, yMid, (i + 1).toString(), 11);
    label(cNum, yMid, d.number.isEmpty ? '-' : d.number, 11, bold: true);
    label(cTitle, yMid, d.title.isEmpty ? '-' : d.title, 11);
    label(cRev, yMid, d.revision.isEmpty ? '-' : d.revision, 11);
    label(cDate, yMid, d.date.isEmpty ? '-' : d.date, 11);
    rowRule(yTop + rowH);
  }

  // Vertical column rules spanning the whole table.
  final bottom = headTop + (drawings.length + 1) * rowH;
  for (final x in const [tableL, cNum - 12, cTitle - 12, cRev - 12,
    cDate - 12, tableR]) {
    prims.add(SldLine(x, headTop, x, bottom));
  }

  return SldSheet(
    prims: prims,
    minX: 0,
    minY: 0,
    maxX: _sheetW,
    maxY: (bottom + 60).clamp(_sheetH, double.infinity).toDouble(),
    legend: const [],
    supplyNote: '',
  );
}

/// The GENERAL NOTES + MASTER LEGEND sheet (N21 + N24): numbered general notes
/// in the left column and the master symbol dictionary (drawn with the REAL
/// plan glyphs) in the right column. [services] / [components] / [cableFamilies]
/// scope the legend to what the set actually uses.
SldSheet buildGeneralNotesSheet({
  Iterable<ServiceType> services = const [],
  Iterable<NodeComponent> components = const [],
  Iterable<String> cableFamilies = const [],
  List<String> notes = kDefaultGeneralNotes,
}) {
  final prims = <SldPrim>[];
  void label(double x, double y, String t, double size, {bool bold = false}) =>
      prims.add(SldLabel(x, y, t, size: size, bold: bold));

  label(_centeredX('GENERAL NOTES & LEGEND / CATATAN UMUM & KETERANGAN', 18,
          _sheetW / 2), 60,
      'GENERAL NOTES & LEGEND / CATATAN UMUM & KETERANGAN', 18, bold: true);

  // ── Left column: general notes ────────────────────────────────────────────
  const notesL = _marginL + 6.0;
  label(notesL, 108, 'CATATAN UMUM / GENERAL NOTES', 13, bold: true);
  var ny = 138.0;
  for (var i = 0; i < notes.length; i++) {
    label(notesL, ny, '${i + 1}.  ${notes[i]}', 10);
    ny += 26;
  }
  final leftBottom = ny;

  // ── Right column: the master legend, drawn with real glyphs ───────────────
  const legendL = _sheetW / 2 + 20; // section/heading + glyph column left
  const glyphCx = legendL + 22;
  const codeX = legendL + 52;
  const meaningX = legendL + 128;
  label(legendL, 108, 'KETERANGAN / LEGEND', 13, bold: true);
  var ry = 140.0;
  final sections = buildMasterLegendSections(
    services: services,
    components: components,
    cableFamilies: cableFamilies,
  );
  for (final section in sections) {
    label(legendL, ry, section.title, 11, bold: true);
    ry += 22;
    for (final e in section.entries) {
      _addLegendGlyph(prims, e, cx: glyphCx, cy: ry - 3);
      label(codeX, ry, e.code, 10, bold: true);
      label(meaningX, ry, e.meaning, 10);
      ry += 22;
    }
    ry += 8; // gap between sections
  }
  final rightBottom = ry;

  final bottom = leftBottom > rightBottom ? leftBottom : rightBottom;
  return SldSheet(
    prims: prims,
    minX: 0,
    minY: 0,
    maxX: _sheetW,
    maxY: (bottom + 40).clamp(_sheetH, double.infinity).toDouble(),
    legend: const [],
    supplyNote: '',
  );
}

/// The full submittal FRONT MATTER as an ordered sheet list —
/// [cover, drawing list, general notes + master legend] — ready for
/// `sldSheetsToPdf` (titles from [kFrontMatterDiagramTitles]).
List<SldSheet> buildSubmittalFrontMatter({
  required String projectName,
  required List<DrawingListEntry> drawings,
  String? clientName,
  String? coverDrawingNumber,
  String? revision,
  String? date,
  String? preparedBy,
  Iterable<ServiceType> services = const [],
  Iterable<NodeComponent> components = const [],
  Iterable<String> cableFamilies = const [],
  List<String> notes = kDefaultGeneralNotes,
}) =>
    [
      buildCoverSheet(
        projectName: projectName,
        clientName: clientName,
        drawingNumber: coverDrawingNumber,
        revision: revision,
        date: date,
        preparedBy: preparedBy,
        sheetCount: drawings.isEmpty ? null : drawings.length,
      ),
      buildDrawingListSheet(drawings, projectName: projectName),
      buildGeneralNotesSheet(
        services: services,
        components: components,
        cableFamilies: cableFamilies,
        notes: notes,
      ),
    ];

// ── Glyph rendering for a legend row ─────────────────────────────────────────

/// Draw the SYMBOL cell for legend entry [e], centred on ([cx], [cy]) in the
/// sheet's y-DOWN drawing space, mirroring what the plan/riser exporters draw.
void _addLegendGlyph(
  List<SldPrim> prims,
  MasterLegendEntry e, {
  required double cx,
  required double cy,
}) {
  switch (e.kind) {
    case LegendGlyphKind.line:
      prims.add(SldLine(cx - 16, cy, cx + 16, cy, weight: SldWeight.medium));
    case LegendGlyphKind.lineDashed:
      prims.add(SldLine(cx - 16, cy, cx + 16, cy,
          weight: SldWeight.medium, dashed: true));
    case LegendGlyphKind.component:
      if (e.component != null) {
        prims.addAll(planComponentPrims(e.component!, cx: cx, cy: cy, size: 15));
      }
    case LegendGlyphKind.fixtureTriangle:
      prims.addAll(planFixturePrims(cx: cx, cy: cy, size: 14));
    case LegendGlyphKind.riserUp:
      // A riser marker (circle) + an upward tick — the plan's UP sense.
      prims
        ..add(SldCircle(cx, cy, 5))
        ..add(SldLine(cx, cy - 5, cx, cy - 12))
        ..add(SldLine(cx, cy - 12, cx - 4, cy - 7))
        ..add(SldLine(cx, cy - 12, cx + 4, cy - 7));
    case LegendGlyphKind.riserDown:
      prims
        ..add(SldCircle(cx, cy, 5))
        ..add(SldLine(cx, cy + 5, cx, cy + 12))
        ..add(SldLine(cx, cy + 12, cx - 4, cy + 7))
        ..add(SldLine(cx, cy + 12, cx + 4, cy + 7));
    case LegendGlyphKind.flowChevron:
      // A short shaft + an open chevron pointing right (flow direction).
      prims
        ..add(SldLine(cx - 14, cy, cx + 10, cy, weight: SldWeight.medium))
        ..add(SldLine(cx + 10, cy, cx + 3, cy - 5))
        ..add(SldLine(cx + 10, cy, cx + 3, cy + 5));
    case LegendGlyphKind.none:
      break;
  }
}

// ── Drawing-office component abbreviations + names (not engineering values) ──

/// Short legend CODE for a component — the drafting abbreviation a KETERANGAN
/// keys. Exhaustive so a new [NodeComponent] forces a code.
String componentLegendCode(NodeComponent c) => switch (c) {
      NodeComponent.pump => 'P',
      NodeComponent.roofTank => 'RT',
      NodeComponent.groundTank => 'GT',
      NodeComponent.boosterSet => 'BP',
      NodeComponent.gateValve => 'GV',
      NodeComponent.checkValve => 'CV',
      NodeComponent.prv => 'PRV',
      NodeComponent.balancingValve => 'BV',
      NodeComponent.roofDrain => 'RD',
      NodeComponent.floorDrain => 'FD',
      NodeComponent.cleanout => 'CO',
      NodeComponent.riser => 'R',
      NodeComponent.waterMeter => 'WM',
      NodeComponent.strainer => 'STR',
      NodeComponent.expansionTank => 'ET',
      NodeComponent.airVent => 'AAV',
      NodeComponent.waterOutlet => 'WO',
      NodeComponent.sprinklerHead => 'SPR',
      NodeComponent.fireExtinguisher => 'APAR',
      NodeComponent.hydrantBox => 'HB',
      NodeComponent.hoseReel => 'HR',
      NodeComponent.fireDeptConnection => 'FDC',
      NodeComponent.supplyDiffuser => 'SD',
      NodeComponent.returnGrille => 'RG',
      NodeComponent.exhaustGrille => 'EG',
      NodeComponent.linearDiffuser => 'LD',
      NodeComponent.volumeDamper => 'VCD',
      NodeComponent.fireDamper => 'FDMP',
      NodeComponent.motorizedDamper => 'MD',
      NodeComponent.vavBox => 'VAV',
      NodeComponent.ahu => 'AHU',
      NodeComponent.fcu => 'FCU',
      NodeComponent.supplyFan => 'SF',
      NodeComponent.exhaustFan => 'EF',
      NodeComponent.acCassette => 'AC-C',
      NodeComponent.acSplitWall => 'AC-W',
      NodeComponent.acDucted => 'AC-D',
    };

/// The human name for a component's legend row (EN, ASCII). Exhaustive.
String componentLegendName(NodeComponent c) => switch (c) {
      NodeComponent.pump => 'Pump',
      NodeComponent.roofTank => 'Roof tank',
      NodeComponent.groundTank => 'Ground tank',
      NodeComponent.boosterSet => 'Booster pump set',
      NodeComponent.gateValve => 'Gate valve',
      NodeComponent.checkValve => 'Check valve',
      NodeComponent.prv => 'Pressure-reducing valve',
      NodeComponent.balancingValve => 'Balancing valve',
      NodeComponent.roofDrain => 'Roof drain',
      NodeComponent.floorDrain => 'Floor drain',
      NodeComponent.cleanout => 'Cleanout',
      NodeComponent.riser => 'Riser / vertical pipe',
      NodeComponent.waterMeter => 'Water meter',
      NodeComponent.strainer => 'Strainer',
      NodeComponent.expansionTank => 'Expansion tank',
      NodeComponent.airVent => 'Automatic air vent',
      NodeComponent.waterOutlet => 'Clean-water outlet',
      NodeComponent.sprinklerHead => 'Sprinkler head',
      NodeComponent.fireExtinguisher => 'Fire extinguisher (APAR)',
      NodeComponent.hydrantBox => 'Hydrant box',
      NodeComponent.hoseReel => 'Hose reel',
      NodeComponent.fireDeptConnection => 'Fire dept. connection',
      NodeComponent.supplyDiffuser => 'Supply air diffuser',
      NodeComponent.returnGrille => 'Return air grille',
      NodeComponent.exhaustGrille => 'Exhaust air grille',
      NodeComponent.linearDiffuser => 'Linear slot diffuser',
      NodeComponent.volumeDamper => 'Volume control damper',
      NodeComponent.fireDamper => 'Fire damper',
      NodeComponent.motorizedDamper => 'Motorized damper',
      NodeComponent.vavBox => 'VAV terminal box',
      NodeComponent.ahu => 'Air-handling unit',
      NodeComponent.fcu => 'Fan-coil unit',
      NodeComponent.supplyFan => 'Supply fan',
      NodeComponent.exhaustFan => 'Exhaust fan',
      NodeComponent.acCassette => 'AC cassette unit',
      NodeComponent.acSplitWall => 'AC split (wall)',
      NodeComponent.acDucted => 'AC ducted unit',
    };
