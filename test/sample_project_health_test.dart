import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart'
    show buildElectricalPanelDetail;
import 'package:mechx_engine/report/sld_sheet.dart' show SldLabel;
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

  test('the sample feeder is lifted as far as its conductor allows', () {
    // Re-derived 2026-07-30 (audit E3+E4): the feeder floor is DEVICE-ONLY and
    // capped at the largest rung the cable protects (In <= Iz) — conductor
    // copper is never inflated to buy discrimination.
    // Reference tower T3 (2026-11-13): the LOAD-sized 6 mm² feeder (Iz 36 A)
    // left LP-1's lighting ways over their 3 % limit CUMULATIVELY (own drops
    // 2.32 / 2.47 % within it), so the auto-sized feeder is raised for that
    // DOWNSTREAM drop: 6 ⇒ 10 ⇒ 16 ⇒ 25 mm² (0.37 %; lighting 2.69 / 2.84 %).
    // Copper grows for voltage drop, never for discrimination; the device
    // floor then follows the larger Iz 89 A to the 1.6 x 25 = 40 A target, so
    // the sample's one residual `non-selective` pair is gone.
    final feeder = result.panels['mdp']!.circuits
        .firstWhere((c) => c.circuitId == 'mdp-f1');
    expect(feeder.cable.csaMm2, 25);
    expect(feeder.cableRaisedForDownstreamVd, isTrue);
    expect(feeder.voltageDrop.dropPercent, 0.37);
    expect(feeder.breaker.ratingA.amperes, 40);
    for (final c in result.panels['lp1']!.circuits) {
      expect(c.cumulativeDropPercent,
          lessThanOrEqualTo(c.voltageDrop.limitPercent),
          reason: c.circuitId);
    }
    expect(result.feederFloorsCapped, isEmpty);
    expect(advanced.fault.selectivity.where((p) => p.nonSelective), isEmpty);
    expect(advanced.fault.warnings.where((w) => w.code == 'non-selective'),
        isEmpty);
  });

  test('and the sample has no cumulative voltage-drop finding (T3)', () {
    expect(
        result.warnings
            .where((w) => w.code == 'cumulative-voltage-drop-exceeded'),
        isEmpty);
  });

  test('the sample fire pump carries the fire-duty token on its schedule row',
      () {
    // G5 (2026-07-31): the `fire-pump-protection` INFO note is now a SPEC
    // instruction, and the MDP board schedule the panel builder reads prints
    // the matching KETERANGAN token on the same way. (This is why the golden
    // `11_electrical_schedule.png` — which frames the MDP schedule — shifts.)
    final note = result.warnings
        .singleWhere((w) => w.code == 'fire-pump-protection');
    expect(note.circuitId, 'mdp-c5');
    expect(note.severity, WarningSeverity.info);
    expect(
        note.message,
        contains('specify overload-trip-disabled protection on the schedule '
            '(fire duty runs to destruction - NFPA 20 practice)'));

    final sheet = buildElectricalPanelDetail(
        project: project, result: result, panelId: 'mdp');
    expect(sheet.prims.whereType<SldLabel>().map((l) => l.text),
        contains('Fire pump · no-OL trip (fire)'));
  });
}

