import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/mep_report.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const sni = SniProfile();
  const puil = PuilProfile();

  // ── Mechanical fixture ──────────────────────────────────────────────────────
  CalcReportData mech({List<Revision> revisions = const []}) => CalcReportData(
        projectName: 'Tower A',
        date: '2026-06-27',
        standardsName: sni.name,
        standardsRevision: sni.revision,
        verifyItems: sni.verifyChecklist,
        building: const BuildingLevels([
          Floor('G', Length(4.0)),
          Floor('L1', Length(3.5)),
        ]),
        feedStrategy: 'Upfeed pump',
        targetResidual: const Pressure(225000),
        occupancy: Occupancy.public,
        rainfallMmPerHr: 200,
        revisions: revisions,
      );

  // ── Electrical fixture ──────────────────────────────────────────────────────
  const project = ElectricalProject(
    id: 'p1',
    name: 'Tower A',
    panels: [
      ElectricalPanel(
        id: 'MDP',
        name: 'MDP',
        circuits: [
          ElectricalCircuit(
            id: 'c1',
            name: 'Lighting',
            loadKind: LoadKind.lighting,
            isLighting: true,
            loadW: 1800,
            length: Length(20),
          ),
        ],
      ),
    ],
  );
  final elecResult = computeSystem(puil, project);

  ElectricalCalcReportData elec({List<Revision> revisions = const []}) =>
      ElectricalCalcReportData(
        projectName: 'Tower A',
        date: '2026-06-27',
        standardsName: puil.name,
        standardsRevision: puil.revision,
        project: project,
        result: elecResult,
        originFaultLevelA: 16000,
        busbarClearingTimeS: 0.1,
        revisions: revisions,
      );

  test('unified report composes mechanical AND electrical sections', () {
    final md = buildMepUnifiedReport(
      mechanical: mech(),
      electrical: elec(),
      compliance: const ComplianceSummary(date: '2026-06-27'),
    );
    // One unified title, then both discipline sections.
    expect(md, contains('# MEP Building-Services Report — Tower A'));
    expect(md, contains('# Mechanical & plumbing'));
    expect(md, contains('# Electrical'));
    // Mechanical body content survives (Water supply, Building).
    expect(md, contains('## Water supply'));
    // Electrical body content survives (Supply summary, Panels, the MDP panel).
    expect(md, contains('## Supply summary'));
    expect(md, contains('MDP'));
    // A single unified Design basis with both sub-registers.
    expect(md, contains('### Mechanical / plumbing'));
    expect(md, contains('### Electrical'));
    // The embedded mechanical report's own H1 is stripped (no duplicate).
    expect(md, isNot(contains('# MEP Calculation Report')));
    expect(md, isNot(contains('# Electrical calculation report')));
  });

  test('compliance section renders the pass/fail summary table', () {
    final md = buildMepUnifiedReport(
      mechanical: mech(),
      electrical: elec(),
      compliance: const ComplianceSummary(
        date: '2026-06-27',
        items: [
          ComplianceItem('Air velocities within band',
              pass: true, detail: 'all within band'),
          ComplianceItem('Standards verification',
              pass: false, detail: '7 unverified values'),
          ComplianceItem('Sheet calibration', pass: true, detail: 'all sheets'),
        ],
      ),
    );
    expect(md, contains('## Compliance summary'));
    expect(md, contains('| Check | Verdict | Detail |'));
    expect(md, contains('| Air velocities within band | PASS | all within band |'));
    expect(md, contains('| Standards verification | REVIEW | 7 unverified values |'));
    // One failing item ⇒ overall verdict is REVIEW REQUIRED.
    expect(md, contains('REVIEW REQUIRED'));
  });

  test('all-pass compliance reports an overall PASS verdict', () {
    final md = buildMepUnifiedReport(
      mechanical: mech(),
      electrical: elec(),
      compliance: const ComplianceSummary(
        date: '2026-06-27',
        items: [
          ComplianceItem('Air velocities within band', pass: true),
          ComplianceItem('Sheet calibration', pass: true),
        ],
      ),
    );
    expect(md, contains('overall: **PASS**'));
  });

  test('merged revision history combines both disciplines', () {
    final md = buildMepUnifiedReport(
      mechanical: mech(revisions: const [Revision('2026-06-01', 'Mech rev A')]),
      electrical: elec(revisions: const [Revision('2026-06-02', 'Elec rev B')]),
      compliance: const ComplianceSummary(date: '2026-06-27'),
    );
    expect(md, contains('# Revision history'));
    expect(md, contains('Mech rev A'));
    expect(md, contains('Elec rev B'));
  });

  test('empty revisions render NO merged Revision-history (back-compat)', () {
    final md = buildMepUnifiedReport(
      mechanical: mech(),
      electrical: elec(),
      compliance: const ComplianceSummary(date: '2026-06-27'),
    );
    expect(md, isNot(contains('# Revision history')));
  });
}
