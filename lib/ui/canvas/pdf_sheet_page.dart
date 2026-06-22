import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../store/models/sheet.dart';

/// Renders a single PDF page as a static raster that fills its box.
///
/// The parent [SheetCanvas] wraps this in a fixed-size SizedBox whose
/// dimensions match [Sheet.sizePx]; the [CanvasView] then handles all
/// pan/zoom. This widget must NOT add its own interactive viewer.
///
/// Errors during load are caught and shown as an inline text label so
/// build never throws.
class PdfSheetPage extends StatelessWidget {
  final Sheet sheet;

  const PdfSheetPage({super.key, required this.sheet});

  @override
  Widget build(BuildContext context) {
    assert(sheet.pdfPath != null, 'PdfSheetPage requires a sheet with a pdfPath');

    final path = sheet.pdfPath;
    if (path == null) {
      return const _ErrorPage('No PDF path on sheet.');
    }

    return PdfDocumentViewBuilder.file(
      path,
      errorBuilder: (context, error, _) =>
          _ErrorPage('Could not load PDF:\n$error'),
      builder: (context, document) {
        if (document == null) {
          // Still loading — show a neutral white placeholder.
          return const ColoredBox(color: Color(0xFFFFFFFF));
        }
        // pageNumber is 1-based in pdfrx; Sheet.pageIndex is 0-based.
        return PdfPageView(
          document: document,
          pageNumber: sheet.pageIndex + 1,
          // No drop shadow — SheetCanvas/CanvasView owns the visual frame.
          decoration: const BoxDecoration(color: Color(0xFFFFFFFF)),
        );
      },
    );
  }
}

class _ErrorPage extends StatelessWidget {
  final String message;
  const _ErrorPage(this.message);

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFFFF3F3),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            message,
            style: const TextStyle(
              fontFamily: 'Roboto',
              fontSize: 14,
              color: Color(0xFFB00020),
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
