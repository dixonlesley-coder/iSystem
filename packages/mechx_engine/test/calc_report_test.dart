import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/hot_water.dart';
import 'package:mechx_engine/sizing/network_sizing.dart' show EdgeSizing;
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
    // The provenance TIER is surfaced, not just a flat "unverified". The live
    // SNI profile's currently-unverified items are all `notAnSniClause`
    // (the secondary-source constants were promoted to sniVerbatim in the
    // 2026-06 provenance pass), so the real report surfaces that tier.
    expect(md, contains('not an SNI clause'));
    // The `secondarySource` tier is still surfaced verbatim when a value carries
    // it — pin that render path directly with a synthetic item so the contract
    // holds independently of the profile's current tier mix (N25 dropped the
    // revision blob from the standards-basis line, which used to carry the
    // words "secondary sources" incidentally).
    final withSecondary = buildCalcReportMarkdown(CalcReportData(
      projectName: 'X',
      date: 'd',
      standardsName: profile.name,
      standardsRevision: profile.revision,
      verifyItems: const [
        StandardValue<Object?>(
          1.0,
          unit: 'm/s',
          citation: 'synthetic secondary-source value',
          verified: false,
          status: VerificationStatus.secondarySource,
          note: 'A pending-confirmation figure.',
        ),
      ],
      building: const BuildingLevels([Floor('G', Length(3))]),
      feedStrategy: 'Upfeed pump',
      targetResidual: const Pressure(200000),
    ));
    expect(withSecondary, contains('secondary source'));
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

  // ── N14/N16/N18: BOM material + one size notation + run schedule ───────────
  group('BOM material / notation + run schedule', () {
    const net = Network(
      nodes: [
        NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
        NetNode(id: 'b', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
      ],
      edges: [
        NetEdge(
            id: 'cw1', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      ],
    );
    const sizing = <String, EdgeSizing>{
      'cw1': EdgeSizing(
        edgeId: 'cw1',
        service: ServiceType.coldWater,
        flow: FlowRate(0.0025), // 2.5 L/s
        diameter: Diameter(0.032), // DN32
        velocity: Velocity(1.8),
      ),
    };

    CalcReportData data({bool withSchedule = true}) => CalcReportData(
          projectName: 'X',
          date: 'd',
          standardsName: profile.name,
          standardsRevision: profile.revision,
          verifyItems: const [],
          building: const BuildingLevels([Floor('G', Length(3))]),
          feedStrategy: 'Upfeed pump',
          targetResidual: const Pressure(200000),
          bom: const [
            BomLine(
                service: ServiceType.coldWater,
                kind: EdgeKind.run,
                diameterMm: 32,
                material: 'PPR',
                totalLength: Length(6.0),
                segmentCount: 1),
            BomLine(
                service: ServiceType.duct,
                kind: EdgeKind.run,
                diameterMm: 200,
                material: 'PU',
                totalLength: Length(4.0),
                segmentCount: 1),
          ],
          fittings: const [
            FittingLine(
                service: ServiceType.duct,
                type: FittingType.elbow,
                diameterMm: 200,
                count: 2),
          ],
          runSchedule: withSchedule
              ? buildRunSchedule(
                  net: net,
                  sizing: sizing,
                  edgeLengths: const {'cw1': Length(6.0)},
                  edgeFixtureUnits: const {'cw1': 12.0},
                )
              : const [],
        );

    test('BOM table gains a Material column; Ø for round duct, DN for pipe', () {
      final md = buildCalcReportMarkdown(data());
      // N13: the BOM table also gains a Tag column (right after Type).
      expect(
          md,
          contains('| Service | Type | Tag | Size | Material | Length (m) | '
              'Segments |'));
      expect(md, contains('| DN32 | PPR |')); // pipe: DN + PPR
      expect(md, contains('| Ø200 | PU |')); // round duct: Ø + PU
    });

    test('fittings table quotes Ø for an air fitting (no DN-for-air)', () {
      final md = buildCalcReportMarkdown(data());
      expect(md, contains('| Ø200 | 2 |'));
      expect(md, isNot(contains('| DN200 | 2 |')));
    });

    test('I5: an all-auto BOM has no * marker and no manual footnote', () {
      final md = buildCalcReportMarkdown(data());
      expect(md, isNot(contains(' * |')));
      expect(md, isNot(contains('manually overridden')));
    });

    test('I5: a manually-overridden BOM line prints a * marker + a footnote', () {
      final md = buildCalcReportMarkdown(CalcReportData(
        projectName: 'X',
        date: 'd',
        standardsName: profile.name,
        standardsRevision: profile.revision,
        verifyItems: const [],
        building: const BuildingLevels([Floor('G', Length(3))]),
        feedStrategy: 'Upfeed pump',
        targetResidual: const Pressure(200000),
        bom: const [
          BomLine(
              service: ServiceType.coldWater,
              kind: EdgeKind.run,
              diameterMm: 32,
              material: 'PPR',
              manual: true,
              totalLength: Length(6.0),
              segmentCount: 1),
        ],
        fittings: const [],
      ));
      // The overridden line's size cell carries the * marker.
      expect(md, contains('| DN32 * | PPR |'));
      // A footnote resolves the marker (EN).
      expect(md, contains('Sizes marked * were manually overridden.'));
    });

    test('run schedule renders per-edge tag/size/FU/flow/velocity/length', () {
      final md = buildCalcReportMarkdown(data());
      expect(md, contains('## Run / riser schedule'));
      expect(
          md,
          contains('| Service | Type | Tag | Size | FU | Flow (L/s) | '
              'Vel (m/s) | Length (m) |'));
      // N13: the run's stable element tag is the service code + 1-based floor.
      // CW-F1 · DN32 · FU 12.0 · 2.50 L/s · 1.80 m/s · 6.0 m.
      expect(md, contains('| CW-F1 | DN32 | 12.0 | 2.50 | 1.80 | 6.0 |'));
    });

    test('empty run schedule renders NO section (back-compat)', () {
      expect(buildCalcReportMarkdown(data(withSchedule: false)),
          isNot(contains('Run / riser schedule')));
    });
  });
}
