import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';

/// The BUNDLED SAMPLE ('Load sample project') is the first thing a new user
/// opens, so it must solve clean: advisory findings are fine (they demonstrate
/// the Review surface), but an ERROR-severity finding in the demo would teach
/// that errors are normal — and the fault-study surfacing pass proved this can
/// regress silently (the sample shipped for months with a fire-pump run that
/// failed ADS, computed but shown nowhere).
void main() {
  const profile = PuilProfile();
  final project = sampleElectricalProject();
  final result = computeSystem(profile, project);
  final advanced = computeAdvancedStudy(profile, project, result);

  test('the sample switchboard has no error-severity finding on ANY surface',
      () {
    final all = [...result.warnings, ...advanced.fault.warnings];
    final errors =
        all.where((w) => w.severity == WarningSeverity.error).toList();
    expect(errors, isEmpty,
        reason: 'error-severity findings in the bundled sample:\n'
            '${errors.map((w) => '  ${w.code}: ${w.message}').join('\n')}');
  });

  test('the fire pump run passes ADS with the pinned 6 mm2 cable', () {
    final firePump = advanced.fault.circuits['mdp-c5']!;
    expect(firePump.adsOk, isTrue,
        reason: 'Zs ${firePump.zsOhm} must be <= ${firePump.zsMaxOhm}');
    final sized = result.panels['mdp']!.circuits
        .firstWhere((c) => c.circuitId == 'mdp-c5');
    expect(sized.cable.csaMm2, 6);
    expect(sized.cable.ampacityReached, isTrue);
  });

  test('every feeder pair in the sample is at least partially selective', () {
    for (final pair in advanced.fault.selectivity) {
      expect(pair.nonSelective, isFalse,
          reason: 'feeder ${pair.upstreamCircuitId} vs '
              '${pair.downstreamPanelId}: ${pair.upstreamRatingA} A over '
              '${pair.downstreamRatingA} A');
    }
  });
}
