// Round 48 — a forced PRIME genset is judged on the same 1.25× prime
// headroom the engine sizes it on (regression-forced-prime-genset-judged-
// without-prime-uplift).
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

/// 3 × [heaterW] 3φ heaters at cos φ 1 on one MDP (default 90 kW / 90 kVA).
ElectricalProject _proj(
        {double? forcedKva,
        GeneratorMode mode = GeneratorMode.prime,
        double heaterW = 30000}) =>
    ElectricalProject(
      id: 'g',
      name: 'g',
      sources: ElectricalSources(
          generator: GeneratorSource(
              kva: forcedKva == null ? null : ApparentPower(forcedKva * 1000),
              mode: mode)),
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          circuits: [
            for (var i = 0; i < 3; i++)
              ElectricalCircuit(
                id: 'h$i',
                name: 'Heater $i',
                loadKind: LoadKind.general,
                loadW: heaterW,
                cosPhi: 1,
                phases: 3,
                length: const Length(10),
              ),
          ],
        ),
      ],
    );

Set<String> _codes(ElectricalProject pr) {
  final sys = computeSystem(_p, pr);
  return {for (final w in gensetBackupWarnings(pr, sys)) w.code};
}

void main() {
  test('requiredGeneratorKva: max(S, P/0.8) × 1.25 for prime', () {
    // 90 kVA / 90 kW: governing = 90 / 0.8 = 112.5 kVA; prime × 1.25 =
    // 140.625 kVA; standby 112.5 kVA.
    const s = ApparentPower(90000);
    const p = Power(90000);
    expect(requiredGeneratorKva(s, backupPower: p, mode: GeneratorMode.prime),
        closeTo(140.625, 1e-9));
    expect(requiredGeneratorKva(s, backupPower: p, mode: GeneratorMode.standby),
        closeTo(112.5, 1e-9));
    // sizeGenerator selects its rung on that same figure (≥ 140.625 kVA).
    final r = sizeGenerator(s, backupPower: p, mode: GeneratorMode.prime);
    expect(r.ratingKva.inKilovoltAmperes, greaterThanOrEqualTo(140.625));
  });

  test('forced 115 / 120 / 140 kVA PRIME sets are no longer silent', () {
    for (final kva in [115.0, 120.0, 140.0]) {
      final codes = _codes(_proj(forcedKva: kva));
      // 0.8 × kva kW < 1.25 × 90 kW = 112.5 kW for every kva < 140.625.
      expect(codes, contains('genset-below-essential-power'),
          reason: '$kva kVA prime');
    }
    // The kVA test alone: 1.25 × 90 kVA = 112.5 kVA; 110 kVA fails it.
    expect(_codes(_proj(forcedKva: 110)),
        contains('genset-below-essential-demand'));
    final pr = _proj(forcedKva: 115);
    final w = gensetBackupWarnings(pr, computeSystem(_p, pr))
        .firstWhere((w) => w.code == 'genset-below-essential-power');
    expect(w.message, contains('prime duty needs 25 % headroom'));
    expect(w.message, contains('112.5 kW'));
  });

  test('standby is unchanged: a 115 kVA standby set backs 90 kW', () {
    // 0.8 × 115 = 92 kW ≥ 90 kW; 115 kVA ≥ 90 kVA.
    expect(_codes(_proj(forcedKva: 115, mode: GeneratorMode.standby)), isEmpty);
  });

  test(
      'seeded property: forced ≥ the engine-selected rung is silent; just '
      'below the unsnapped requirement raises', () {
    for (final mode in GeneratorMode.values) {
      for (var i = 0; i < 25; i++) {
        final w = 8000.0 + 3711.0 * i; // per heater
        final auto = _proj(mode: mode, heaterW: w);
        final sys = computeSystem(_p, auto);
        final basisVa = gensetBackupDemandVa(auto, sys);
        final basisW = gensetBackupDemandW(auto, sys);
        final required =
            requiredGeneratorKva(basisVa, backupPower: basisW, mode: mode);
        final sel = sizeGenerator(basisVa, backupPower: basisW, mode: mode);
        final rung = sel.ratingKva.inKilovoltAmperes * sel.units;
        expect(_codes(_proj(forcedKva: rung, mode: mode, heaterW: w)), isEmpty,
            reason: '$mode $w W: the selected rung $rung kVA');
        final below =
            _codes(_proj(forcedKva: required * 0.995, mode: mode, heaterW: w));
        expect(
            below.contains('genset-below-essential-demand') ||
                below.contains('genset-below-essential-power'),
            isTrue,
            reason: '$mode $w W: ${required * 0.995} kVA < $required kVA');
      }
    }
  });
}
