// Round 48 — the fire pump's churn pressure is judged against the standard
// component rating (mech-convergence-3-fire-pressure-rating-unjudged).
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  test('20-storey sprinkler pump: 6 L/s @ 123 m churns at 16.9 bar > 12.1', () {
    final r = checkFirePumpRating(
        ratedFlow: FlowRate.litersPerSecond(6), ratedHead: const Head(123));
    final c = fireOverPressureCheck(rating: r, indexFrictionM: 57.6);
    // churn = 1.4 × 123 = 172.2 m; ρg·H = 1000 × 9.81 × 172.2 = 1689 kPa.
    expect(r.churn.head.meters, closeTo(1.4 * 123, 1e-9));
    expect(c.churnKpa,
        closeTo(defaultWaterDensity * standardGravity * 172.2 / 1000, 1e-6));
    expect(c.churnKpa, greaterThan(kFireComponentMaxPressureKpa));
    expect(c.over, isTrue);
    // 57.6 m of the 123 m rated head is pipe friction (47 %).
    expect(c.frictionShare, closeTo(57.6 / 123, 1e-12));
  });

  test('a 3-storey system (40 m rated, churn 549 kPa) is not over', () {
    final r = checkFirePumpRating(
        ratedFlow: FlowRate.litersPerSecond(6), ratedHead: const Head(40));
    final c = fireOverPressureCheck(rating: r);
    expect(c.churnKpa, closeTo(9.81 * 1.4 * 40, 1e-6));
    expect(c.over, isFalse);
    expect(c.frictionShare, isNull);
  });

  test('the limit is the 175 psi listing (1207 kPa) and is on the checklist',
      () {
    // 175 psi × 6.894757 kPa/psi = 1206.6 kPa ⇒ 1210 kPa.
    expect((175 * 6.894757 - kFireComponentMaxPressureKpa).abs(), lessThan(5));
    expect(const SniProfile().verifyChecklist.map((v) => v.value),
        contains(kFireComponentMaxPressureKpa));
  });

  test('the calc report prints the over-pressure line only when exceeded', () {
    const profile = SniProfile();
    String md(double head, {bool sprinkler = true}) =>
        buildCalcReportMarkdown(CalcReportData(
          projectName: 'P',
          date: 'd',
          standardsName: profile.name,
          standardsRevision: profile.revision,
          verifyItems: const [],
          building: const BuildingLevels([Floor('L0', Length(3))]),
          feedStrategy: 'Upfeed pump',
          targetResidual: const Pressure(225000),
          sprinkler: sprinkler
              ? designSprinklerSystem(hazard: FireHazardClass.lightHazard)
              : null,
          firePumpRating: checkFirePumpRating(
              ratedFlow: FlowRate.litersPerSecond(6), ratedHead: Head(head)),
          fireIndexFrictionM: 57.6,
        ));
    expect(md(123), contains('Component pressure (churn)'));
    expect(md(123), contains('1689 kPa at churn exceeds the 1210 kPa'));
    expect(md(123), contains('friction 47 % of the rated head'));
    expect(md(40), isNot(contains('Component pressure (churn)')));
    // A hydrant-only design is not judged on the sprinkler listing.
    expect(md(123, sprinkler: false),
        isNot(contains('Component pressure (churn)')));
  });
}
