/// Human-readable scale readouts + the PDF `1 : N` scale ↔ metres-per-pixel
/// maths, shared by the Scale inspector section and the on-canvas calibration
/// overlay so every place the scale is shown speaks ONE language (D1) instead of
/// the three exponential dialects the app used to (`1 px = 3.53e-2 m`,
/// `Scale approx 3.53e-2 m/px`, `1 m = 28 px`).
///
/// No Flutter imports — pure formatting / maths so it unit-tests trivially.
library;

/// Metres per inch (a plotted PDF pixel is a PDF *point*, 72 to the inch).
const double _metresPerInch = 0.0254;

/// PDF points per inch — a plotted PDF's `Sheet.sizePx` is in points at this DPI
/// (see `data/pdf_import.dart`, which stores `PdfPage.width/.height` verbatim).
const double _pdfPointsPerInch = 72.0;

/// The metres-per-pixel a PDF sheet plotted at `1 : [denominator]` implies. One
/// point on the paper is `_metresPerInch / _pdfPointsPerInch` metres; at 1:N that
/// paper distance stands for N times as much on the real building, so
/// `metersPerPixel = N × 0.0254 / 72`.
double metersPerPixelForPdfScale(double denominator) =>
    denominator * _metresPerInch / _pdfPointsPerInch;

/// The inverse: the `1 : N` denominator a PDF sheet's [metersPerPixel] implies.
/// Meaningful ONLY for PDF sheets, whose pixel is a physical paper point (a
/// normalized DXF/DWG pixel has no paper-unit basis).
double pdfScaleDenominatorFor(double metersPerPixel) =>
    metersPerPixel * _pdfPointsPerInch / _metresPerInch;

/// A few common architectural plot scales offered as one-tap presets beside the
/// `1 : N` type-in.
const List<int> kCommonPdfScaleDenominators = <int>[50, 100, 150, 200, 250, 500];

/// The pixels-per-metre implied by [metersPerPixel] (the universally-honest
/// readout, independent of any paper-unit assumption).
int pixelsPerMetreFor(double metersPerPixel) => (1 / metersPerPixel).round();

/// One shared human-readable scale readout, replacing the three exponential
/// dialects the app used to speak. For a PDF sheet ([isPdf] true) the pixel is a
/// physical paper point, so the plotted `1 : N` ratio is meaningful and leads;
/// otherwise (a normalized DXF/DWG or placeholder sheet) only the
/// paper-unit-free `1 m = N px` is honest. Plain ASCII — nothing that tofus in
/// Roboto.
String formatScaleReadout(double metersPerPixel, {required bool isPdf}) {
  if (metersPerPixel <= 0) return '—';
  final pxPerMetre = pixelsPerMetreFor(metersPerPixel);
  if (isPdf) {
    final n = pdfScaleDenominatorFor(metersPerPixel).round();
    return '1 : $n  (1 m = $pxPerMetre px)';
  }
  return '1 m = $pxPerMetre px';
}
