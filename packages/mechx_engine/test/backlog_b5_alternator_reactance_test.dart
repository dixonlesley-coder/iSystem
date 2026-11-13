/// Backlog B-5 (2026-11-13) — ONE named alternator reactance pair.
///
/// The genset fault level (breaking capacity, busbar withstand, ADS on the
/// genset) read X''d 0.12 pu (`kAlternatorXdPu`) while the motor-start dip and
/// the genset start floor read 0.15 pu (`kGensetSubtransientReactancePu`, mis-
/// named), for the same machine. There IS a physical reason for two figures:
/// the first-cycles fault is limited by the SUB-TRANSIENT reactance X''d, the
/// motor-start dip (hundreds of ms to seconds) by the TRANSIENT reactance X'd,
/// and X''d < X'd on every machine. So both now read one named pair in
/// `sources.dart`; no figure changed.
library;

import 'package:mechx_engine/electrical/advanced_study.dart'
    show gensetMaxFaultVerifyItem, gensetStartDipVerifyItem;
import 'package:mechx_engine/electrical/fault.dart'
    show kAlternatorXdPu, onSiteSourceFaultA;
import 'package:mechx_engine/electrical/model.dart' show SupplyKind;
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  test('the pair: X\'\'d 0.12 < X\'d 0.15, the fault alias is X\'\'d', () {
    expect(kAlternatorSubtransientXdPu, 0.12);
    expect(kAlternatorTransientXdPu, 0.15);
    expect(kAlternatorSubtransientXdPu, lessThan(kAlternatorTransientXdPu));
    expect(kAlternatorXdPu, kAlternatorSubtransientXdPu);
  });

  test('the fault level reads X\'\'d: 300 kVA ⇒ 300 000 / (√3 × 400 × 0.12)',
      () {
    // 300 000 / (692.82 × 0.12) = 3608.4 A.
    expect(onSiteSourceFaultA(SupplyKind.generator, 300000),
        closeTo(3608.4, 0.05));
  });

  test('the start dip reads X\'d: 100 kVA start on 300 kVA ⇒ 4.76 %', () {
    // z = 100 × 0.15 = 15; dip = 100 × 15 / (300 + 15) = 4.76 %.
    final r = assessGensetStart(
      ApparentPower.kilovoltAmperes(300),
      motors: const [
        GensetMotor(shaftPower: Power(1000), startKva: ApparentPower(100000)),
      ],
    );
    expect(r.estimatedDipPct, closeTo(4.76, 0.005));
  });

  test('both verify items name both reactances', () {
    for (final s in [gensetStartDipVerifyItem, gensetMaxFaultVerifyItem]) {
      expect(s, contains("X''d"));
      expect(s, contains("X'd"));
      expect(s, contains('0.12'));
      expect(s, contains('0.15'));
    }
  });
}
