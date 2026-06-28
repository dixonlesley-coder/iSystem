/// Tests for the AC cooling-load estimate (BTU/h · kW · PK).
///
/// Hand-computed expected values; arithmetic shown in comments.
library;

import 'package:mechx_engine/sizing/cooling_load.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('conversions', () {
    test('1 PK = 9000 BTU/h (convention)', () {
      expect(pkToBtuPerHr(1.0), closeTo(9000.0, 1e-9));
      expect(btuPerHrToPk(9000.0), closeTo(1.0, 1e-9));
    });

    test('1000 W = 3412.14 BTU/h', () {
      expect(wattsToBtuPerHr(1000.0), closeTo(3412.14, 0.01));
      expect(btuPerHrToWatts(3412.141633), closeTo(1000.0, 1e-6));
    });
  });

  group('coolingLoadBtuPerHr', () {
    test('20 m² × 3 m × 600 BTU/h·m² = 12 000 BTU/h', () {
      // heightFactor = 3/3 = 1 ⇒ 20 × 600 × 1 = 12 000.
      expect(
        coolingLoadBtuPerHr(
          floorArea: const Area(20.0),
          ceilingHeight: const Length(3.0),
          densityBtuPerHrPerM2: 600.0,
        ),
        closeTo(12000.0, 1e-9),
      );
    });

    test('a taller ceiling scales the load linearly', () {
      // 3.6 m ⇒ factor 1.2 ⇒ 20 × 600 × 1.2 = 14 400.
      expect(
        coolingLoadBtuPerHr(
          floorArea: const Area(20.0),
          ceilingHeight: const Length(3.6),
          densityBtuPerHrPerM2: 600.0,
        ),
        closeTo(14400.0, 1e-9),
      );
    });
  });

  group('selectAc', () {
    test('12 000 BTU/h selects exactly 1.5 PK', () {
      final s = selectAc(12000.0);
      expect(s.pk, 1.5);
      expect(s.nominalBtuPerHr, 12000.0);
      expect(s.exceedsRange, isFalse);
    });

    test('just over 1.5 PK rounds up to 2.0 PK', () {
      final s = selectAc(12001.0);
      expect(s.pk, 2.0);
      expect(s.nominalBtuPerHr, 18000.0);
    });

    test('a load beyond the largest size flags exceedsRange', () {
      final s = selectAc(100000.0);
      expect(s.pk, 3.0);
      expect(s.exceedsRange, isTrue);
    });
  });

  group('ladderPk', () {
    test('ladderPk equals selectAc.pk and differs from the raw load PK', () {
      // 13 000 BTU/h: raw load PK = 13000/9000 = 1.4444… (continuous), while
      // the market ladder rounds UP to the next standard unit ≥ 13 000 — the
      // 1.5 PK size is only 12 000 BTU/h (< 13 000), so the next rung is 2.0 PK
      // (18 000 BTU/h). The two figures are distinct but each correct.
      expect(btuPerHrToPk(13000.0), closeTo(13000.0 / 9000.0, 1e-9)); // 1.444…
      expect(ladderPk(13000.0), 2.0);
      expect(ladderPk(13000.0), selectAc(13000.0).pk);
    });

    test('an exact standard size maps to its own PK', () {
      // 12 000 BTU/h is exactly the 1.5 PK rung.
      expect(ladderPk(12000.0), 1.5);
      expect(ladderPk(12000.0), selectAc(12000.0).pk);
    });
  });

  group('acInputPowerW', () {
    test('1 PK (9000 BTU/h) at COP 3 ≈ 879 W input', () {
      // 9000 BTU/h = 9000/3.412141633 = 2637.6 W cooling; ÷ 3 = 879.2 W input.
      expect(acInputPowerW(coolingBtuPerHr: 9000.0), closeTo(879.2, 0.2));
    });

    test('input power scales inversely with COP', () {
      final cop3 = acInputPowerW(coolingBtuPerHr: 12000.0, cop: 3.0);
      final cop4 = acInputPowerW(coolingBtuPerHr: 12000.0, cop: 4.0);
      expect(cop4, closeTo(cop3 * 3.0 / 4.0, 1e-9));
    });
  });

  group('estimateCoolingLoad', () {
    test('integrates load → watts → PK → recommended AC', () {
      final r = estimateCoolingLoad(
        floorArea: const Area(20.0),
        ceilingHeight: const Length(3.0),
        densityBtuPerHrPerM2: 600.0,
      );
      expect(r.btuPerHr, closeTo(12000.0, 1e-9));
      expect(r.pk, closeTo(12000.0 / 9000.0, 1e-9)); // 1.333 PK raw
      expect(r.watts, closeTo(12000.0 / 3.412141633, 1e-3));
      expect(r.recommended.pk, 1.5); // rounded up to a real unit
    });
  });
}
