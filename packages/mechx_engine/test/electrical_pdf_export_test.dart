import 'dart:convert';

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart';
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
            id: 'f1',
            name: 'Feeder to LP-1',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'LP1',
            length: Length(15),
          ),
        ],
      ),
      ElectricalPanel(
        id: 'LP1',
        name: 'LP-1',
        tag: 'LP-1',
        system: ElectricalSystem.singlePhase,
        voltage: Voltage(220),
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'f1',
        x: 400,
        y: 220,
        circuits: [
          ElectricalCircuit(
            id: 'c1',
            name: 'Lighting',
            loadKind: LoadKind.lighting,
            isLighting: true,
            loadW: 1500,
            length: Length(18),
          ),
        ],
      ),
    ],
  );

  final result = computeSystem(profile, project);

  test('emits a well-formed single-page PDF', () {
    final s = latin1.decode(
        electricalSldToPdf(project: project, result: result, title: 'SLD'));
    expect(s.startsWith('%PDF-1.4'), isTrue);
    expect(s.trimRight().endsWith('%%EOF'), isTrue);
    expect(s, contains('/Type /Catalog'));
    expect(s, contains('/Type /Page'));
    expect(s, contains('/BaseFont /Helvetica'));
    expect(s, contains('stream'));
    expect(s, contains('endstream'));
    expect(s, contains('trailer'));
  });

  test('draws panel boxes (rect) + feeder line + labels', () {
    final s = latin1.decode(
        electricalSldToPdf(project: project, result: result, title: 'SLD'));
    expect(s, contains(' re S')); // a stroked rectangle (panel box)
    expect(s, contains(' l S')); // the feeder line
    expect(s, contains('MDP')); // a panel label
    expect(s, contains('LP-1'));
  });

  test('the cross-reference offsets actually point at their objects', () {
    final s = latin1.decode(
        electricalSldToPdf(project: project, result: result));
    final sx = s.lastIndexOf('startxref');
    final xrefOffset = int.parse(
        s.substring(sx + 'startxref'.length, s.indexOf('%%EOF', sx)).trim());
    expect(s.substring(xrefOffset, xrefOffset + 4), 'xref');
    final lines = s.substring(xrefOffset).split('\n');
    final obj1Offset = int.parse(lines[3].substring(0, 10));
    expect(s.substring(obj1Offset).startsWith('1 0 obj'), isTrue);
  });

  test('an empty project still produces a valid (title-only) page', () {
    const empty = ElectricalProject(id: 'e', name: 'Empty');
    final emptyResult = computeSystem(profile, empty);
    final s = latin1.decode(electricalSldToPdf(
        project: empty, result: emptyResult, title: 'Empty SLD'));
    expect(s.startsWith('%PDF-1.4'), isTrue);
    expect(s, contains('(Empty SLD) Tj'));
    expect(s.trimRight().endsWith('%%EOF'), isTrue);
  });
}
