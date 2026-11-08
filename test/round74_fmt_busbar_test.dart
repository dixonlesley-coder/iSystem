// Round 74 r2 — `fmtBusbar` (the single-line summary card 'bus' stat and the
// inspector bus row) names a parallel-bar set's count: a 2-bar 100×10 set is
// 2000 mm², so printing `100×10 mm` alone understated the bar by n.
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/electrical/electrical_format.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/units.dart';

void main() {
  test('a parallel-bar set prints n × (W×H mm)', () {
    const b = BusbarResult(
      widthMm: 100,
      thicknessMm: 10,
      csaMm2: 2000,
      ampacityA: Current(2860),
      totalCurrentA: Current(2500),
      parallelBars: 2,
    );
    expect(fmtBusbar(b), '2 × (100×10 mm)');
  });

  test('one bar keeps the bare geometry', () {
    const b = BusbarResult(
      widthMm: 100,
      thicknessMm: 10,
      csaMm2: 1000,
      ampacityA: Current(1430),
      totalCurrentA: Current(1200),
    );
    expect(fmtBusbar(b), '100×10 mm');
  });
}
