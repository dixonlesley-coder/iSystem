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
import 'electrical_pdf_export.dart' show electricalSldToPdf;
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

/// Render a prebuilt [sheet] to a model-space DXF (R12).
String sldSheetToDxf({
  required SldSheet sheet,
  String diagramTitle = 'SINGLE-LINE DIAGRAM',
}) =>
    electricalSldToDxf(sheet: sheet, diagramTitle: diagramTitle);
