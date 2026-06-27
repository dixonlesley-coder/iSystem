import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/hot_water.dart';
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
    // The provenance TIER is surfaced, not just a flat "unverified".
    expect(md, contains('secondary source'));
    expect(md, contains('not an SNI clause'));
  });

  test('building + BOM rows appear', () {
    final md = buildCalcReportMarkdown(data());
    expect(md, contains('Ground'));
    expect(md, contains('DN50'));
    expect(md, contains('12.5'));
  });

  test('storm section surfaces rainfall intensity AND runoff coefficient', () {
    final md = buildCalcReportMarkdown(CalcReportData(
      projectName: 'X',
      date: '2026-06-27',
      standardsName: profile.name,
      standardsRevision: profile.revision,
      verifyItems: profile.verifyChecklist,
      building: const BuildingLevels([Floor('G', Length(3))]),
      feedStrategy: 'Roof-tank downfeed',
      targetResidual: const Pressure(200000),
      rainfallMmPerHr: 250,
      runoffCoefficient: 0.75,
    ));
    expect(md, contains('## Storm / rainwater'));
    expect(md, contains('250 mm/hr'));
    expect(md, contains('Runoff coefficient C'));
    expect(md, contains('0.75'));
  });

  test('renders a Design basis register echoing project inputs', () {
    final md = buildCalcReportMarkdown(CalcReportData(
      projectName: 'Tower A',
      date: '2026-06-27',
      standardsName: profile.name,
      standardsRevision: profile.revision,
      verifyItems: profile.verifyChecklist,
      // 2 floors: 4.0 + 3.5 = 7.5 m total.
      building: const BuildingLevels([
        Floor('G', Length(4.0)),
        Floor('L1', Length(3.5)),
      ]),
      feedStrategy: 'Upfeed pump',
      targetResidual: const Pressure(225000),
      occupancy: Occupancy.public,
      rainfallMmPerHr: 200,
      runoffCoefficient: 0.9,
    ));
    expect(md, contains('## Design basis'));
    // Level count + total height (4.0 + 3.5 = 7.50 m) appear.
    expect(md, contains('Levels: **2**'));
    expect(md, contains('7.50 m'));
    // Occupancy class is echoed.
    expect(md, contains('Occupancy class: **Public**'));
    // Feed strategy + target residual (225000 Pa = 225 kPa).
    expect(md, contains('Water feed strategy: **Upfeed pump**'));
    expect(md, contains('225 kPa'));
    // Rainfall + runoff C.
    expect(md, contains('200 mm/hr'));
    expect(md, contains('0.90'));
  });

  test('renders a Revision history table when revisions are provided', () {
    final md = buildCalcReportMarkdown(CalcReportData(
      projectName: 'Tower A',
      date: '2026-06-27',
      standardsName: profile.name,
      standardsRevision: profile.revision,
      verifyItems: profile.verifyChecklist,
      building: const BuildingLevels([Floor('G', Length(3))]),
      feedStrategy: 'Upfeed pump',
      targetResidual: const Pressure(200000),
      revisions: const [
        Revision('2026-06-01', 'Issued for tender'),
        Revision('2026-06-20', 'Updated pump duty'),
      ],
    ));
    expect(md, contains('## Revision history'));
    expect(md, contains('| Date | Description |'));
    expect(md, contains('| 2026-06-01 | Issued for tender |'));
    expect(md, contains('Updated pump duty'));
  });

  test('empty revisions render NO Revision-history table (back-compat)', () {
    final md = buildCalcReportMarkdown(data());
    expect(md, isNot(contains('## Revision history')));
  });

  test('citations appear inline next to each unverified value', () {
    final md = buildCalcReportMarkdown(data());
    // Every unverified item prints its citation on its own bullet line.
    for (final v in profile.verifyChecklist.where((v) => v.isUnverified)) {
      expect(md, contains('**${v.citation}**'));
    }
  });

  test('a Legionella-risk hot-water return is flagged in the report', () {
    // ΔT = 8 K ⇒ return = 60 − 8 = 52 °C < 55 ⇒ legionellaRisk ⇒ advisory line.
    final hwr = sizeHotWaterRecirculation(
      heatLoss: const Power(4186),
      loopLength: const Length(30),
      returnDiameter: Diameter.mm(25),
      allowableDropK: 8.0,
    );
    expect(hwr.legionellaRisk, isTrue);
    final md = buildCalcReportMarkdown(CalcReportData(
      projectName: 'X',
      date: '2026-06-27',
      standardsName: profile.name,
      standardsRevision: profile.revision,
      verifyItems: profile.verifyChecklist,
      building: const BuildingLevels([Floor('G', Length(3))]),
      feedStrategy: 'Upfeed pump',
      targetResidual: const Pressure(200000),
      hotWaterRecirc: hwr,
    ));
    expect(md, contains('return 52 °C'));
    expect(md, contains('anti-Legionella'));
  });
}
