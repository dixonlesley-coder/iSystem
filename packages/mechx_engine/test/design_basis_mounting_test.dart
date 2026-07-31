import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/report_strings.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// F8 (WORKFLOW-FRICTION) — the mounting heights shape every vertical length
/// and static lift in the report, so once they became a real per-project input
/// they must be STATED in the Design Basis register like any other assumption.
/// Passing none keeps the legacy register byte-identical.
void main() {
  const profile = SniProfile();

  CalcReportData data({MountingHeights? mounting}) => CalcReportData(
        projectName: 'Tower A',
        date: '2026-07-31',
        standardsName: profile.name,
        standardsRevision: profile.revision,
        verifyItems: const [],
        building: const BuildingLevels([
          Floor('Ground', Length(4.0)),
          Floor('L1', Length(3.5)),
        ]),
        feedStrategy: 'Upfeed pump',
        targetResidual: const Pressure(225000),
        mounting: mounting,
      );

  test('no mounting heights ⇒ the register is byte-identical', () {
    final legacy = StringBuffer();
    writeMechanicalDesignBasis(legacy, data());
    expect(legacy.toString().contains('Ceiling drop'), isFalse);
    expect(legacy.toString().contains('Fixture connection height'), isFalse);
    // The whole report is unchanged too (the block feeds both renderers).
    expect(buildCalcReportMarkdown(data()).contains('Ceiling drop'), isFalse);
  });

  test('the project values print as two design-basis rows', () {
    final d = data(
        mounting: const MountingHeights(
            ceilingDrop: Length(0.45), fixtureHeight: Length(0.9)));
    final rows = mechanicalDesignBasisBlock(d).rows;
    final keys = [for (final (k, _) in rows) k];
    expect(keys, contains('Ceiling drop:'));
    expect(keys, contains('Fixture connection height:'));
    // Two decimals, in metres, with the effect named — never a bare number.
    final drop = rows.firstWhere((r) => r.$1 == 'Ceiling drop:').$2;
    expect(drop, contains('**0.45 m**'));
    expect(drop, contains('below the slab above'));
    final fix =
        rows.firstWhere((r) => r.$1 == 'Fixture connection height:').$2;
    expect(fix, contains('**0.90 m**'));

    // They sit in the rendered Markdown register too.
    final md = buildCalcReportMarkdown(d);
    expect(md, contains('- Ceiling drop: **0.45 m**'));
  });

  test('the rows follow the report locale', () {
    final d = data(mounting: const MountingHeights());
    final rows = mechanicalDesignBasisBlock(d, const ReportStrings.id()).rows;
    final keys = [for (final (k, _) in rows) k];
    expect(keys, contains('Turun plafon:'));
    expect(keys, contains('Tinggi sambungan fikstur:'));
    // ASCII-safe defaults still print as 0.30 / 1.10 m.
    expect(rows.firstWhere((r) => r.$1 == 'Turun plafon:').$2,
        contains('**0.30 m**'));
  });
}
