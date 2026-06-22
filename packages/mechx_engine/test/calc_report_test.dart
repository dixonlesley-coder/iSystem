import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const profile = SniProfile();

  CalcReportData data() => CalcReportData(
        projectName: 'Tower A',
        date: '2026-06-22',
        standardsName: profile.name,
        standardsRevision: profile.revision,
        verifyItems: profile.verifyChecklist,
        building: const BuildingLevels([
          Floor('Ground', Length(4.0)),
          Floor('L1', Length(3.5)),
        ]),
        feedStrategy: 'Upfeed pump',
        targetResidual: const Pressure(225000),
        pump: sizePump(flow: const FlowRate(0.005), head: const Head(30)),
        bom: const [
          BomLine(
            service: ServiceType.coldWater,
            kind: EdgeKind.run,
            diameterMm: 50,
            totalLength: Length(12.5),
            segmentCount: 3,
          ),
        ],
        fittings: const [
          FittingLine(
            service: ServiceType.coldWater,
            type: FittingType.elbow,
            diameterMm: 50,
            count: 4,
          ),
        ],
      );

  test('renders the headline sections', () {
    final md = buildCalcReportMarkdown(data());
    expect(md, contains('# MEP Calculation Report — Tower A'));
    expect(md, contains('## Building'));
    expect(md, contains('## Water supply'));
    expect(md, contains('## Bill of materials'));
    expect(md, contains('Fittings (estimated)'));
    expect(md, contains('Pump head'));
  });

  test('surfaces unverified standard values (provenance)', () {
    final md = buildCalcReportMarkdown(data());
    expect(md, contains('Unverified values'));
    // The SNI profile has unverified items (e.g. max fixture pressure).
    expect(profile.verifyChecklist.where((v) => v.isUnverified), isNotEmpty);
    // ...and at least one citation appears in the report.
    final firstUnverified =
        profile.verifyChecklist.firstWhere((v) => v.isUnverified);
    expect(md, contains(firstUnverified.citation));
  });

  test('building + BOM rows appear', () {
    final md = buildCalcReportMarkdown(data());
    expect(md, contains('Ground'));
    expect(md, contains('DN50'));
    expect(md, contains('12.5'));
  });
}
