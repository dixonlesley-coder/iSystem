/// Drawing backlog I-1 (2026-11-13) — ONE issued single-line-family drawing
/// (mechanical riser, electrical SLD / overview / riser, power one-line): its
/// PAGE list plus the stamps every page carries, rendered to the PDF and the
/// DXF from that one list.
///
/// The submittal package and every standalone export build their drawing
/// through this value, so a standalone PDF / DXF pair is the package's pair:
/// the same pages, the same `SHEET i of n`, the same LANJUT KE marks and the
/// same drawing number. A one-page drawing renders through the single-sheet
/// writers (the chrome's own counter); a multi-page one through the set
/// writers (`SHEET i of n` re-stamped per page). Pure.
library;

import 'dart:typed_data';

import 'drawing_chrome.dart' show DrawingChrome;
import 'electrical_dxf_export.dart' show SldDxfLayers, sldSheetsToDxfSet;
import 'electrical_pdf_export.dart'
    show electricalSldSheetsToPdf, electricalSldToPdf;
import 'sld_sheet.dart';

/// One issued SLD-family drawing (see the library doc).
class IssuedSldDrawing {
  /// The issued pages, in sheet order (never empty for a drawn project; an
  /// empty list renders one blank page in both formats).
  final List<SldSheet> pages;

  /// The PDF document title (metadata).
  final String title;

  /// The title-block heading every page stamps.
  final String diagramTitle;

  /// The document-control chrome (drawing number, revision, sign-off, date);
  /// its sheet counter is re-stamped per page on a multi-page drawing.
  final DrawingChrome? chrome;

  /// The title-block PROJECT row; null ⇒ the writers' placeholder.
  final String? projectName;

  /// The DXF layer namespace (`E-*`, `M-*`, `F-*`).
  final SldDxfLayers layers;

  const IssuedSldDrawing({
    required this.pages,
    required this.title,
    required this.diagramTitle,
    this.chrome,
    this.projectName,
    this.layers = SldDxfLayers.electrical,
  });

  /// The number of issued sheets (an empty drawing still issues one page).
  int get pageCount => pages.isEmpty ? 1 : pages.length;

  /// The vector PDF: one page per entry of [pages].
  Uint8List toPdf() => pages.length == 1
      ? electricalSldToPdf(
          sheet: pages.single,
          title: title,
          diagramTitle: diagramTitle,
          chrome: chrome,
          projectName: projectName,
        )
      : electricalSldSheetsToPdf(
          sheets: pages,
          title: title,
          diagramTitle: diagramTitle,
          chrome: chrome,
          projectName: projectName ?? 'Untitled project',
        );

  /// The DXF twin: one model-space frame per entry of [pages], each with the
  /// PDF page's `SHEET i of n`.
  String toDxf() => sldSheetsToDxfSet(
        pages,
        diagramTitle: diagramTitle,
        chrome: chrome,
        projectName: projectName,
        layers: layers,
      );
}
