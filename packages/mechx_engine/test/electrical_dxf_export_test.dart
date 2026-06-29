import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const profile = PuilProfile();

  // A two-panel project: an MDP (utility-fed) feeding a lighting sub-panel via a
  // feeder way. The sub-panel is placed on the schematic canvas (x/y), the MDP
  // is not (auto-laid) — exercises both placement paths.
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
          ElectricalCircuit(
            id: 'm1',
            name: 'Chiller',
            loadKind: LoadKind.motor,
            motorKw: 11,
            length: Length(25),
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
        y: 200,
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

  group('electricalSldToDxf', () {
    final dxf = electricalSldToDxf(project: project, result: result);

    test('emits a valid DXF skeleton', () {
      expect(dxf, contains('SECTION'));
      expect(dxf, contains('ENTITIES'));
      expect(dxf, contains('ENDSEC'));
      expect(dxf.trimRight(), endsWith('EOF'));
    });

    test('every panel is drawn as a labelled box on the panels layer', () {
      expect(dxf, contains('panels'));
      expect(dxf, contains('MDP'));
      expect(dxf, contains('LP-1'));
      // Box = LINE entities; at least the four sides of one panel.
      expect('LINE'.allMatches(dxf).length, greaterThanOrEqualTo(8));
    });

    test('a feeder is wired between the parent and the sub-panel', () {
      expect(dxf, contains('feeders'));
    });

    test('renders the professional single-line content as TEXT', () {
      expect(dxf, contains('TEXT'));
      // The incomer breaker, a way row + Ib, and the title-block / legend frame.
      expect(dxf, contains('Incomer'));
      expect(dxf, contains('Ib '));
      expect(dxf, contains('ELECTRICAL SINGLE-LINE DIAGRAM'));
      expect(dxf, contains('LEGEND'));
      expect(dxf, contains('frame'));
    });
  });

  group('powerOneLineToDxf', () {
    const oneLine = PowerOneLine(
      nodes: [
        PowerNode(id: 'utility', kind: PowerNodeKind.utility, label: 'PLN'),
        PowerNode(id: 'bus', kind: PowerNodeKind.bus, label: 'Main LV bus'),
        PowerNode(id: 'gen', kind: PowerNodeKind.generator, label: 'Genset'),
      ],
      edges: [
        PowerEdge(id: 'e0', from: 'utility', to: 'bus', label: 'mains'),
        PowerEdge(id: 'e1', from: 'gen', to: 'bus', label: 'standby'),
      ],
      interlocks: [],
    );

    final dxf = powerOneLineToDxf(oneLine);

    test('emits a valid DXF skeleton with one box per node', () {
      expect(dxf, contains('SECTION'));
      expect(dxf.trimRight(), endsWith('EOF'));
      expect(dxf, contains('PLN'));
      expect(dxf, contains('Main LV bus'));
      expect(dxf, contains('Genset'));
    });

    test('edges become LINEs with labels', () {
      expect(dxf, contains('oneline'));
      expect(dxf, contains('mains'));
      expect(dxf, contains('standby'));
    });
  });
}
