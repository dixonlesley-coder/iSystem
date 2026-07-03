import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/format/scale_format.dart';

/// D1 — the shared PDF-scale math + the one human readout formatter.
void main() {
  group('PDF 1:N ↔ metersPerPixel', () {
    test('1:100 on a plotted PDF (72 pt/inch) → 0.0254*100/72 m/px', () {
      // A PDF pixel is a point (1/72 inch); at 1:100 it represents 100× the
      // paper distance on the real building.
      final mpp = metersPerPixelForPdfScale(100);
      expect(mpp, closeTo(0.0254 * 100 / 72, 1e-12)); // ≈ 0.035278
    });

    test('the two directions are exact inverses over the common ladder', () {
      for (final n in kCommonPdfScaleDenominators) {
        final mpp = metersPerPixelForPdfScale(n.toDouble());
        expect(pdfScaleDenominatorFor(mpp), closeTo(n.toDouble(), 1e-9));
      }
    });

    test('pixelsPerMetre is 1/metersPerPixel rounded', () {
      // 1:100 → ≈28.35 px/m → 28.
      expect(pixelsPerMetreFor(metersPerPixelForPdfScale(100)), 28);
      // 0.01 m/px → 100 px/m exactly.
      expect(pixelsPerMetreFor(0.01), 100);
    });
  });

  group('formatScaleReadout', () {
    test('a PDF sheet leads with the plotted 1 : N (+ the px/m aside)', () {
      final mpp = metersPerPixelForPdfScale(100);
      expect(formatScaleReadout(mpp, isPdf: true), '1 : 100  (1 m = 28 px)');
    });

    test('a normalized DXF/DWG sheet only gets the paper-unit-free readout', () {
      expect(formatScaleReadout(0.01, isPdf: false), '1 m = 100 px');
    });

    test('a non-PDF pixel scale that happens to equal 1:100 still reads px/m',
        () {
      // 0.025 m/px = 40 px/m (a two-point calibration result).
      expect(formatScaleReadout(0.025, isPdf: false), '1 m = 40 px');
    });

    test('a non-positive scale renders a dash, never a divide-by-zero', () {
      expect(formatScaleReadout(0, isPdf: true), '—');
      expect(formatScaleReadout(-1, isPdf: false), '—');
    });
  });
}
