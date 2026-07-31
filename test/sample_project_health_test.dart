import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart' show SelectivityResult;
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
    // Re-derived 2026-07-30 (audit E3+E4). The feeder floor is now DEVICE-ONLY
    // and capped at the largest rung the LOAD-sized cable protects (In <= Iz) —
    // conductor copper is never inflated to buy discrimination. The sample's one
    // feeder carries LP-1's whole demand, so it and LP-1's incomer size from the
    // SAME load:
    //   Ib 23.8 A -> load rung 25 A; cable 4 mm2 (Iz 34.0 A);
    //   floor target 1.6 x 25 = 40 A, cap = largest rung <= 34.0 = 32 A
    //   => the device lifts one rung (25 -> 32 A) and stops at 1.28x.
    // Reaching 1.6x here would mean fitting 6 mm2 for a 23.8 A run purely for
    // discrimination — exactly the trade the policy refuses. So the residual is
    // REPORTED (never suppressed: a capped floor is not in
    // `feederFloorsApplied`), and the guard below pins that it is the AMPACITY
    // CAP holding the device back, not an undersized pick.
    expect(result.feederFloorsApplied, isEmpty);
    // G3 (2026-07-31): the solve now RECORDS where the cap bit, so the residual
    // can explain itself. Floor target 1.6 x 25 = 40 A -> rung 40 A; cap =
    // largest rung <= Iz 34.0 = 32 A; 40 > 34.0 ⇒ mdp-f1 is capped.
    expect(result.feederFloorsCapped, {'mdp-f1'});
    final ladder = profile.standardBreakerRatingsA;
    for (final pair in advanced.fault.selectivity) {
      if (!pair.nonSelective) continue;
      final feeder = result.panels[pair.upstreamPanelIdOrNull(result)]
          ?.circuits
          .where((c) => c.circuitId == pair.upstreamCircuitId)
          .firstOrNull;
      expect(feeder, isNotNull, reason: pair.upstreamCircuitId);
      final izA = feeder!.cable.deratedIz.amperes;
      expect(feeder.breaker.ratingA.amperes, ladder.where((r) => r <= izA).last,
          reason: 'feeder ${pair.upstreamCircuitId} vs '
              '${pair.downstreamPanelId}: ${pair.upstreamRatingA} A over '
              '${pair.downstreamRatingA} A is NOT explained by the ampacity cap '
              '(Iz $izA A) — the sizer picked the wrong rung');
    }
    // And the residual is exactly the one known pair, still surfaced.
    expect(
      advanced.fault.selectivity
          .where((p) => p.nonSelective)
          .map((p) => p.upstreamCircuitId),
      ['mdp-f1'],
    );
    expect(advanced.fault.warnings.where((w) => w.code == 'non-selective'),
        hasLength(1));
  });

  test('and the sample\'s residual pair SAYS the cable is the lever', () {
    // G3 (2026-07-31), re-derived from the sample: 'Feeder to LP-1' is the one
    // capped feeder, so its `non-selective` message must not send the engineer
    // after a bigger breaker (In <= Iz forbids it). Hand-derived numbers:
    //   feeder Ib 23.8 A -> load rung 25 A; cable 4 mm2, KHA B1 = 34 A at
    //   derating 1.00 -> Iz 34.0 A; the 40 A floor rung is above 34.0, so the
    //   device stops at 32 A (the largest rung <= Iz) at 32/25 = 1.28x.
    //   Target 1.6 x 25 = 40 A is well inside the 1600 A ladder, so the advice
    //   is the "increase the cable" variant, not the ladder-top one.
    final feeder = result.panels['mdp']!.circuits
        .firstWhere((c) => c.circuitId == 'mdp-f1');
    expect(feeder.cable.csaMm2, 4);
    expect(feeder.cable.deratedIz.amperes, closeTo(34.0, 1e-9));
    expect(feeder.breaker.ratingA.amperes, 32);

    final w = advanced.fault.warnings
        .singleWhere((x) => x.code == 'non-selective');
    expect(
      w.message,
      'Feeder to LP-1 (32 A) may not discriminate with Lighting Panel incomer '
      '(25 A): the device is already at the largest rung the 4 mm2 feeder '
      'cable protects (Iz 34.0 A). To reach the 1.6x target, increase the '
      'feeder cable (then the device can rise); verify against manufacturer '
      'curves otherwise.',
    );
    expect(w.severity, WarningSeverity.warning);
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

extension on SelectivityResult {
  /// The panel a feeder way lives on (the study keys pairs by the FED panel).
  String? upstreamPanelIdOrNull(ElectricalSystemResult sys) {
    for (final entry in sys.panels.entries) {
      if (entry.value.circuits.any((c) => c.circuitId == upstreamCircuitId)) {
        return entry.key;
      }
    }
    return null;
  }
}
