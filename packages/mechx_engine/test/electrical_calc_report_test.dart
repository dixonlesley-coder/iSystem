import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/standards/puil.dart';
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
}
