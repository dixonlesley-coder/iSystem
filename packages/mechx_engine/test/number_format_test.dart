import 'package:mechx_engine/report/number_format.dart';
import 'package:test/test.dart';

void main() {
  group('groupThousands', () {
    test('Indonesian dot grouping of the integer part', () {
      expect(groupThousands(190), '190');
      expect(groupThousands(1100), '1.100');
      expect(groupThousands(4400), '4.400');
      expect(groupThousands(52871), '52.871');
      expect(groupThousands(1181250), '1.181.250');
    });

    test('rounds to the nearest whole number (the _wattsId contract)', () {
      expect(groupThousands(4399.6), '4.400');
      expect(groupThousands(190.2), '190');
    });

    test('negatives keep a single leading sign', () {
      expect(groupThousands(-1234), '-1.234');
    });

    test('custom separator', () {
      expect(groupThousands(1181250, separator: ','), '1,181,250');
    });
  });

  group('money', () {
    test('dp 0 ⇒ grouped whole number', () {
      expect(money(1181250), '1.181.250');
      expect(money(3703.68), '3.704'); // rounds
    });

    test('dp 2 ⇒ grouped integer + comma decimal (Indonesian)', () {
      expect(money(3703.68, dp: 2), '3.703,68');
      expect(money(1181250, dp: 2), '1.181.250,00');
      expect(money(1000, dp: 2), '1.000,00');
      expect(money(0, dp: 2), '0,00');
    });

    test('negative money keeps one leading sign', () {
      expect(money(-1234.5, dp: 2), '-1.234,50');
    });

    test('a value that rounds to zero prints unsigned (no negative zero)', () {
      // -0.004 -> toStringAsFixed(2) "-0.00": no non-zero digit, so unsigned,
      // matching groupThousands(-0.4) which rounds to int 0 first.
      expect(money(-0.004, dp: 2), '0,00');
      expect(money(-0.4), '0');
      expect(groupThousands(-0.4), '0');
      expect(money(-12.5, dp: 2), '-12,50'); // a real negative keeps its sign
      expect(money(-0.005, dp: 2), '-0,01'); // rounds AWAY from zero: non-zero
    });
  });

  group('non-finite input degrades instead of throwing', () {
    test('NaN / ±Infinity print the no-value mark', () {
      for (final v in [double.nan, double.infinity, double.negativeInfinity]) {
        expect(money(v), kNonFiniteNumber);
        expect(money(v, dp: 2), kNonFiniteNumber);
        expect(groupThousands(v), kNonFiniteNumber);
      }
      expect(kNonFiniteNumber, '-');
    });
  });
}
