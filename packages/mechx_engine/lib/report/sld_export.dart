/// Discipline-neutral entry points for rendering ANY prebuilt [SldSheet] to a
/// vector PDF or DXF — used by the MECHANICAL riser single-line
/// (`mechanical_sld_drawing.dart`). The actual renderers live in
/// `electrical_pdf_export.dart` / `electrical_dxf_export.dart` (they already
/// accept a prebuilt `sheet`); these thin wrappers just give the mechanical side
/// a name that isn't "electrical" and a mechanical default diagram title. Pure.
library;

import 'dart:typed_data';

import 'drawing_chrome.dart' show DrawingChrome;
import 'electrical_dxf_export.dart' show electricalSldToDxf;
import 'electrical_pdf_export.dart'
    show electricalSldSheetsToPdf, electricalSldToPdf;
import 'sld_sheet.dart';

/// Render a prebuilt [sheet] to a single-page vector PDF. [diagramTitle] is the
/// title-block heading (e.g. `SINGLE-LINE DIAGRAM` / `DIAGRAM SISTEM AIR BERSIH`).
Uint8List sldSheetToPdf({
  required SldSheet sheet,
  String title = 'iSystem single-line',
  String diagramTitle = 'SINGLE-LINE DIAGRAM',
  DrawingChrome? chrome,
}) =>
    electricalSldToPdf(
      sheet: sheet,
      title: title,
      diagramTitle: diagramTitle,
      chrome: chrome,
    );

/// Render N prebuilt [sheets] as ONE multi-page vector PDF — a numbered
/// drawing SET (e.g. per-service riser sheets + a combined sheet). Page i
/// stamps a real `Sheet i of N` counter; [diagramTitles] (when given) supplies
/// the per-page title-block heading, else every page carries [diagramTitle].
/// The optional [chrome]'s other fields (drawing number, client, date, scale…)
/// stamp every page; its own sheet counter is superseded page-by-page.
Uint8List sldSheetsToPdf(
  List<SldSheet> sheets, {
  String title = 'iSystem single-line',
  String diagramTitle = 'SINGLE-LINE DIAGRAM',
  List<String>? diagramTitles,
  DrawingChrome? chrome,
}) =>
    electricalSldSheetsToPdf(
      sheets: sheets,
      title: title,
      diagramTitle: diagramTitle,
      diagramTitles: diagramTitles,
      chrome: chrome,
    );

/// Render a prebuilt [sheet] to a model-space DXF (R12). The optional [chrome]
/// extends the frame title block (client / date / scale / drawn / checked /
/// approved rows); null ⇒ byte-identical.
String sldSheetToDxf({
  required SldSheet sheet,
  String diagramTitle = 'SINGLE-LINE DIAGRAM',
  DrawingChrome? chrome,
}) =>
    electricalSldToDxf(sheet: sheet, diagramTitle: diagramTitle, chrome: chrome);
