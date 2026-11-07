// Round 71 r2 — the genset start-dip message names a failing LIFE-SAFETY
// motor even when it shares the limiting motor's NAME (the limiting motor
// is excluded by identity, never by a name match).
//
// Two motors named 'Pump' on a 20 kVA genset (Xd'' = 0.15): the limiting
// 75 kW DOL duty pump (not life-safety) and a 15 kW DOL fire pump. The fire
// pump's own dip is 100·z/(20 + z), z = startKva·0.15 — above 25 % once
// z > 20/3, i.e. startKva > 44.4 kVA, which a 15 kW DOL start (several ×
// its running kVA) exceeds — so it must be named and the warning graded an
// ERROR.
library;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  test('a failing life-safety motor sharing the limiting name is named', () {
    final duty = GensetMotor(
        name: 'Pump', shaftPower: Power.kiloWatts(75), circuitId: 'duty');
    final fire = GensetMotor(
        name: 'Pump',
        shaftPower: Power.kiloWatts(15),
        circuitId: 'fp',
        lifeSafety: true);
    final st = assessGensetStart(ApparentPower.kilovoltAmperes(20),
        motors: [duty, fire]);
    expect(st.acceptable, isFalse);
    expect(identical(st.limitingMotor, duty), isTrue);
    expect(st.failingLifeSafetyMotors.map((m) => m.circuitId), ['fp']);
    final w = gensetStartDipWarnings(
        const ElectricalProject(id: 'p', name: 'p', panels: []),
        PowerOneLine(
            nodes: const [],
            edges: const [],
            interlocks: const [],
            gensetStart: st));
    expect(w, hasLength(1));
    expect(w.single.severity, WarningSeverity.error);
    expect(w.single.message, contains('Life-safety motor Pump also fails'));
  });
}
