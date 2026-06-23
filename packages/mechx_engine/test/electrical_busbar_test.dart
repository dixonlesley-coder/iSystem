import 'package:mechx_engine/electrical/busbar.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Seed tests for busbar sizing (A3 ▸2). Expected bars are read by hand off the
/// PUIL/IEC 61439-1 copper-bar table.
void main() {
  const p = PuilProfile();

  group('sizeBusbar', () {
    test('200 A → first bar with ampacity ≥ 200 = 20×3 (60 mm², 200 A)', () {
      final b = sizeBusbar(p, const Current(200));
      expect(b.csaMm2, 60);
      expect(b.ampacityA.amperes, 200);
      expect(b.widthMm, 20);
      expect(b.thicknessMm, 3);
      expect(b.totalCurrentA.amperes, 200);
    });

    test('1000 A → 80×10 (800 mm², 1180 A)', () {
      final b = sizeBusbar(p, const Current(1000));
      expect(b.csaMm2, 800);
      expect(b.ampacityA.amperes, 1180);
    });

    test('minAmpacity floors the rating to In', () {
      // 100 A demand but a 250 A incomer → bus must hold ≥ 250 A.
      final b = sizeBusbar(p, const Current(100), minAmpacityA: const Current(250));
      expect(b.csaMm2, 100); // 20×5, 270 A
      expect(b.ampacityA.amperes, 270);
    });

    test('minCsa floors the section for short-circuit withstand', () {
      // 200 A would pick 60 mm², but a 150 mm² withstand floor forces 30×5.
      final b = sizeBusbar(p, const Current(200), minCsaMm2: 150);
      expect(b.csaMm2, 150);
      expect(b.ampacityA.amperes, 370);
    });

    test('beyond the table → density estimate (1.3 A/mm²), bar dims 0', () {
      final b = sizeBusbar(p, const Current(2000));
      expect(b.widthMm, 0);
      expect(b.thicknessMm, 0);
      // csa = ceil(2000/1.3) = 1539; ampacity = round(1539·1.3) = 2001
      expect(b.csaMm2, 1539);
      expect(b.ampacityA.amperes, 2001);
    });
  });

  group('sizeNeutralPeBars (IEC 60364-5-54 §543)', () {
    test('50 mm² phase → full neutral 50, PE 25 (S/2)', () {
      final n = sizeNeutralPeBars(50, const Current(160));
      expect(n.neutralCsaMm2, 50);
      expect(n.neutralAmpacityA.amperes, 160);
      expect(n.peCsaMm2, 25);
    });

    test('S ≤ 16 → PE = S', () {
      expect(sizeNeutralPeBars(16, const Current(80)).peCsaMm2, 16);
    });

    test('16 < S ≤ 35 → PE = 16', () {
      expect(sizeNeutralPeBars(25, const Current(105)).peCsaMm2, 16);
    });

    test('small phase → PE floored at 6 mm²', () {
      expect(sizeNeutralPeBars(4, const Current(34)).peCsaMm2, 6);
    });
  });
}
