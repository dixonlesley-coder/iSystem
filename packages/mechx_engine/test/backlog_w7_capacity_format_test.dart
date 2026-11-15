// Backlog W-7 (2026-11-14) — the ONE tank-capacity formatter: whole litres
// below 1000 L, else m3 to 3 decimals with trailing zeros trimmed, so a
// printed capacity never misstates the stored one (the old one-decimal m3
// printed 250 L as '0.3 m3', +20 %).
import 'package:mechx_engine/report/number_format.dart';
import 'package:test/test.dart';

void main() {
  test('litres below 1 m3, m3 to 3 decimals from 1 m3', () {
    final cases = {
      250.0: '250 L',
      650.0: '650 L',
      999.0: '999 L',
      1000.0: '1 m3',
      1200.0: '1.2 m3',
      2250.0: '2.25 m3',
      10000.0: '10 m3',
      85172.0: '85.172 m3',
      150000.0: '150 m3',
    };
    for (final e in cases.entries) {
      expect(formatTankCapacity(e.key), e.value, reason: '${e.key}');
    }
  });

  test('never more than 0.5 % off the stored value', () {
    for (var l = 1.0; l < 300000; l *= 1.37) {
      final s = formatTankCapacity(l);
      final v = s.endsWith(' L')
          ? double.parse(s.substring(0, s.length - 2))
          : double.parse(s.substring(0, s.length - 3)) * 1000;
      expect((v - l).abs() <= 0.005 * l + 0.5, isTrue, reason: '$l -> $s');
    }
  });
}
