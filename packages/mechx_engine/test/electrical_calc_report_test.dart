import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart' show Revision;
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const profile = PuilProfile();

  const project = ElectricalProject(
    id: 'p1',
    name: 'Test building',
    panels: [
      ElectricalPanel(
        id: 'MDP',
        name: 'MDP',
        tag: 'MDP',
        circuits: [
          ElectricalCircuit(
            id: 'c1',
            name: 'Lighting',
            loadKind: LoadKind.lighting,
            isLighting: true,
            loadW: 1800,
            length: Length(20),
          ),
          ElectricalCircuit(
            id: 'c2',
            name: 'Sockets',
            loadKind: LoadKind.socket,
            loadW: 3000,
            length: Length(20),
          ),
        ],
      ),
    ],
  );

  final result = computeSystem(profile, project);

  test('report carries the header, supply and every panel + circuit', () {
    final md = buildElectricalCalcReport(ElectricalCalcReportData(
      projectName: 'Test building',
      date: '2026-06-24',
      standardsName: profile.name,
      standardsRevision: profile.revision,
      project: project,
      result: result,
    ));
    expect(md, contains('# Electrical calculation report — Test building'));
    expect(md, contains('## Supply summary'));
    expect(md, contains('## Panels'));
    expect(md, contains('MDP'));
    expect(md, contains('Lighting'));
    expect(md, contains('Sockets'));
    expect(md, contains('## Earthing'));
    // The circuits table header.
    expect(md, contains('| Way | Type | Ib |'));
  });

  test('verify items surface in the Unverified values section', () {
    final md = buildElectricalCalcReport(ElectricalCalcReportData(
      projectName: 'Test building',
      date: '2026-06-24',
      standardsName: profile.name,
      standardsRevision: profile.revision,
      project: project,
      result: result,
      verifyItems: const ['Busbar Icw — confirm against the assembly rating'],
    ));
    expect(md, contains('## Unverified values'));
    expect(md, contains('Busbar Icw — confirm against the assembly rating'));
  });

  test('no Unverified section when there is nothing to verify', () {
    final md = buildElectricalCalcReport(ElectricalCalcReportData(
      projectName: 'Test building',
      date: '2026-06-24',
      standardsName: profile.name,
      standardsRevision: profile.revision,
      project: project,
      result: result,
    ));
    expect(md, isNot(contains('## Unverified values')));
  });

  test('renders a Design basis register with supply, load and fault target', () {
    final md = buildElectricalCalcReport(ElectricalCalcReportData(
      projectName: 'Test building',
      date: '2026-06-24',
      standardsName: profile.name,
      standardsRevision: profile.revision,
      project: project,
      result: result,
      originFaultLevelA: 16000, // 16 kA
      busbarClearingTimeS: 0.1,
    ));
    expect(md, contains('## Design basis'));
    expect(md, contains('Supply:'));
    expect(md, contains('Connected load:'));
    expect(md, contains('Earthing system:'));
    // 16000 A => 16 kA, 0.10 s.
    expect(md, contains('16 kA'));
    expect(md, contains('0.10 s'));
  });

  test('renders a Revision history table when revisions are provided', () {
    final md = buildElectricalCalcReport(ElectricalCalcReportData(
      projectName: 'Test building',
      date: '2026-06-24',
      standardsName: profile.name,
      standardsRevision: profile.revision,
      project: project,
      result: result,
      revisions: const [Revision('2026-06-10', 'Issued for construction')],
    ));
    expect(md, contains('## Revision history'));
    expect(md, contains('| 2026-06-10 | Issued for construction |'));
  });

  test('empty revisions render NO Revision-history table (back-compat)', () {
    final md = buildElectricalCalcReport(ElectricalCalcReportData(
      projectName: 'Test building',
      date: '2026-06-24',
      standardsName: profile.name,
      standardsRevision: profile.revision,
      project: project,
      result: result,
    ));
    expect(md, isNot(contains('## Revision history')));
  });
}
