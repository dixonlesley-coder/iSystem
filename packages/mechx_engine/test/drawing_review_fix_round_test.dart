// Drawing review fix round (2026-11-13) — F1..F7 from
// docs/DRAWING-REVIEW-RECORD.md, each pinned to the pure rule it broke.
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:test/test.dart';

void main() {
  group('F3 legibility stamp fires only below the printed floor', () {
    test('a page fitted to 6.9995 pt prints 7.0 pt: no stamp', () {
      expect(sldPrintsBelowMinPt(6.9995), isFalse);
      expect(sldLegibilityWarning(6.9995), isNull);
      expect(sldLegibilityWarning(7.0), isNull);
    });
    test('a page at 6.9 pt (prints 6.9) is stamped with that size', () {
      expect(sldPrintsBelowMinPt(6.9), isTrue);
      expect(sldLegibilityWarning(6.9), contains('6.9 pt (< 7 pt)'));
      // The printed number is always strictly below the printed floor.
      for (var t = 1.0; t < 7.2; t += 0.013) {
        final w = sldLegibilityWarning(t);
        if (w == null) continue;
        final shown =
            double.parse(RegExp(r'tercetak ([\d.]+) pt').firstMatch(w)!.group(1)!);
        expect(shown, lessThan(7.0), reason: 'pt=$t');
      }
    });
  });
}
