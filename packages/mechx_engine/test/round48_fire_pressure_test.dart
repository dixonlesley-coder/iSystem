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

  test('the calc report prints one over-pressure line per over system', () {
    // Round 49 (regression-report-churn-not-per-system) — the report renders
    // the app's per-system judgement (each sprinkler-bearing system on its
    // OWN pump); it never re-judges the governing rating. For a 123 m rated
    // head: churn = 1.4 x 123 x 9.81 = 1689 kPa; friction 57.6 / 123 = 47 %.
    const profile = SniProfile();
    String md(List<FireOverPressureReportLine> over) =>
        buildCalcReportMarkdown(CalcReportData(
          projectName: 'P',
          date: 'd',
          standardsName: profile.name,
          standardsRevision: profile.revision,
          verifyItems: const [],
          building: const BuildingLevels([Floor('L0', Length(3))]),
          feedStrategy: 'Upfeed pump',
          targetResidual: const Pressure(225000),
          sprinkler: designSprinklerSystem(hazard: FireHazardClass.lightHazard),
          firePumpRating: checkFirePumpRating(
              ratedFlow: FlowRate.litersPerSecond(6), ratedHead: const Head(123)),
          fireOverPressure: over,
        ));
    final c = fireOverPressureCheck(
        rating: checkFirePumpRating(
            ratedFlow: FlowRate.litersPerSecond(6), ratedHead: const Head(123)),
        indexFrictionM: 57.6);
    final one = md([
      FireOverPressureReportLine(
          tag: 'FP-02', churnKpa: c.churnKpa, frictionShare: c.frictionShare),
    ]);
    expect(one, contains('Component pressure (churn)'));
    expect(one, contains('1689 kPa at churn exceeds the 1210 kPa'));
    expect(one, contains('friction 47 % of the rated head'));
    // No over system (e.g. only a hydrant-only system is over, which the
    // app never lists) ⇒ no line, whatever the governing rating's churn.
    expect(md(const []), isNot(contains('Component pressure (churn)')));
    // Two over systems ⇒ one line each, under its own pump tag.
    final two = md(const [
      FireOverPressureReportLine(tag: 'FP-01', churnKpa: 1300),
      FireOverPressureReportLine(tag: 'FP-03', churnKpa: 1400),
    ]);
    expect(two, contains('Component pressure (churn), FP-01'));
    expect(two, contains('Component pressure (churn), FP-03'));
    expect(two, contains('1300 kPa at churn'));
    expect(two, contains('1400 kPa at churn'));
  });
}
