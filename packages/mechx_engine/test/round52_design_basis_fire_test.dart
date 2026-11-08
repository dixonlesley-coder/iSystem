// Round 52 follow-up — the Design-basis register must not print
// 'Fire protection: none modelled' above a Fire section that prints a drawn
// fire system (a transfer pump filling a tank: no pumped standpipe basis).
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  CalcReportData data(List<FireSystemReportLine> systems) => CalcReportData(
        projectName: 'P',
        date: '2026-10-21',
        standardsName: 'SNI',
        standardsRevision: 'r',
        verifyItems: const [],
        building: BuildingLevels(
            [for (var i = 0; i < 3; i++) Floor('L$i', const Length(3.5))]),
        feedStrategy: 'Upfeed pump',
        targetResidual: const Pressure(225000),
        fireSystems: systems,
      );

  String basis(CalcReportData d) =>
      mechanicalDesignBasisBlock(d).rows.map((p) => '${p.$1}: ${p.$2}').join('\n');

  final rating = checkFirePumpRating(
      ratedFlow: FlowRate.litersPerSecond(5), ratedHead: const Head(30));

  test('no fire system drawn: none modelled', () {
    expect(basis(data(const [])), contains('none modelled'));
  });

  test('a transfer-only hydrant system is modelled, not none', () {
    final b = basis(data([
      FireSystemReportLine(
          tag: 'P-01', sprinklerOnly: false, rating: rating, transfer: true),
    ]));
    expect(b, isNot(contains('none modelled')));
  });
}
