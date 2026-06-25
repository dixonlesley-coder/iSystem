import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../store/models/sheet.dart';

/// Renders a single PDF page as a static raster that fills its box.
///
/// The parent [SheetCanvas] wraps this in a fixed-size SizedBox whose
/// dimensions match [Sheet.sizePx]; the [CanvasView] then handles all
/// pan/zoom. This widget must NOT add its own interactive viewer.
///
/// **Resolution:** [PdfPageView] rasterises at its layout-box size, which here
/// is the page's ~72-DPI point size. With the canvas zoom applied as an OUTER
/// transform, that low-res raster is simply magnified — blurry when you zoom in
/// to place nodes precisely. To fix it we **supersample**: lay the page out at
/// [_superSample]× its natural size (so pdfrx renders that many more pixels,
/// capped by [PdfPageView.maximumDpi]), then scale the high-res raster back
/// down with a [FittedBox] so it still occupies exactly [Sheet.sizePx] in canvas
/// coordinates. The extra detail stays crisp until roughly [_superSample]× zoom.
///
/// Errors during load are caught and shown as an inline text label so
/// build never throws.
class PdfSheetPage extends StatelessWidget {
  final Sheet sheet;

  /// How many times the page's native point resolution to rasterise at. 3×
  /// (≈216 DPI) keeps node placement crisp at deep zoom while staying well
  /// under pdfrx's 300-DPI cap; only the on-screen page(s) pay the memory.
  static const double _superSample = 3.0;

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
        final page = PdfPageView(
          document: document,
          pageNumber: sheet.pageIndex + 1,
          // No drop shadow — SheetCanvas/CanvasView owns the visual frame.
          decoration: const BoxDecoration(color: Color(0xFFFFFFFF)),
        );
        final size = sheet.sizePx;
        // Lay the page out at _superSample× its natural size so pdfrx renders
        // that many more pixels, then FittedBox scales the high-res raster down
        // to the canvas slot (Sheet.sizePx). Net display size is unchanged; only
        // the raster density rises, so a zoomed-in plan stays sharp.
        return FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(
            width: size.width * _superSample,
            height: size.height * _superSample,
            child: page,
          ),
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
