import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import '../store/models/sheet.dart';

/// Opens the PDF at [filePath], reads every page's point dimensions, and
/// returns a [Sheet] per page.
///
/// Page sizes are in PDF points (1/72 inch). We store them directly in
/// [Sheet.sizePx] — "px" here means "natural content units"; calibration
/// (pt → real-world length) is deferred to a later phase.
///
/// Throws if the file cannot be opened or has zero pages.
Future<List<Sheet>> importPdf(String filePath) async {
  final file = File(filePath);
  final basename = file.uri.pathSegments.last;
  // Strip extension for display name (e.g. "FloorPlan.pdf" → "FloorPlan").
  final stem = basename.endsWith('.pdf') || basename.endsWith('.PDF')
      ? basename.substring(0, basename.length - 4)
      : basename;

  final doc = await PdfDocument.openFile(filePath);
  try {
    final pages = doc.pages;
    if (pages.isEmpty) {
      throw StateError('PDF "$basename" has no pages.');
    }
    return [
      for (var i = 0; i < pages.length; i++)
        Sheet(
          id: '$stem#$i',
          name: '$stem p${i + 1}',
          pdfPath: filePath,
          pageIndex: i,
          // PdfPage.width / .height are in PDF points (72 dpi).
          sizePx: Size(pages[i].width, pages[i].height),
        ),
    ];
  } finally {
    await doc.dispose();
  }
}
