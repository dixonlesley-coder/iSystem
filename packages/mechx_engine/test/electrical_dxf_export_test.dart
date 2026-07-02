import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
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

    test('every panel is drawn as a labelled box on the class layers', () {
      // C4: block outlines route to E-BREAKER, labels to E-TEXT.
      expect(dxf, contains('E-BREAKER'));
      expect(dxf, contains('E-TEXT'));
      expect(dxf, contains('MDP'));
      expect(dxf, contains('LP-1'));
      // Box = LINE entities; at least the four sides of one panel.
      expect('LINE'.allMatches(dxf).length, greaterThanOrEqualTo(8));
    });

    test('busbars and feeder routing land on E-BUS / E-FEEDER by weight', () {
      // C4 weight routing: thick bus verticals → E-BUS, medium feeder runs →
      // E-FEEDER.
      expect(dxf, contains('E-BUS'));
      expect(dxf, contains('E-FEEDER'));
    });

    test('the 3-phase MDP incomer metering draws as CIRCLE entities', () {
      // The V/A/Hz meters on a 3-phase board emit CIRCLE entities (code 40 =
      // radius) on the device layer.
      expect(dxf, contains('CIRCLE'));
      expect('CIRCLE'.allMatches(dxf).length, greaterThanOrEqualTo(3));
    });

    test('renders the professional single-line content as TEXT', () {
      expect(dxf, contains('TEXT'));
      // The incomer breaker, a way row + Ib, and the title-block / legend frame.
      expect(dxf, contains('Incomer'));
      expect(dxf, contains('Ib '));
      expect(dxf, contains('ELECTRICAL SINGLE-LINE DIAGRAM'));
      expect(dxf, contains('LEGEND'));
      expect(dxf, contains('E-FRAME'));
    });

    test('a TABLES section defines the line-types + class layers up front', () {
      // C4: TABLES precede ENTITIES so a CAD app resolves layer colour + dash.
      final tablesAt = dxf.indexOf('TABLES');
      final entitiesAt = dxf.indexOf('ENTITIES');
      expect(tablesAt, greaterThanOrEqualTo(0));
      expect(tablesAt, lessThan(entitiesAt));
      // The two required line-types.
      expect(dxf, contains('\nCONTINUOUS\n'));
      expect(dxf, contains('\nDASHED\n'));
      // One LAYER record per class layer; E-ESSENTIAL is ACI red (62 / 1).
      for (final layer in const [
        'E-BUS',
        'E-FEEDER',
        'E-BREAKER',
        'E-TEXT',
        'E-FRAME',
        'E-ESSENTIAL',
      ]) {
        expect(dxf, contains('LAYER\n2\n$layer\n'), reason: 'layer $layer');
      }
      expect(dxf, contains('2\nE-ESSENTIAL\n70\n0\n62\n1\n'));
    });

    test('prims carry group-370 lineweights from their SldWeight', () {
      // thick 50 (busbars), medium 25 (feeders), thin 13 (device graphics).
      expect(dxf, contains('370\n50\n'));
      expect(dxf, contains('370\n25\n'));
      expect(dxf, contains('370\n13\n'));
    });

    test('a dashed SldLine emits group 6 DASHED; an explicit layer wins', () {
      const sheet = SldSheet(
        prims: [
          SldLine(0, 0, 100, 0, dashed: true),
          SldLine(0, 20, 100, 20, layer: 'E-CUSTOM'),
        ],
        minX: 0,
        minY: 0,
        maxX: 100,
        maxY: 20,
        legend: [],
        supplyNote: '',
      );
      final out = electricalSldToDxf(sheet: sheet);
      // The dashed prim's linetype override rides the entity.
      expect(out, contains('6\nDASHED\n'));
      // The explicit layer is used as-is AND declared in the LAYER table.
      expect(out, contains('LINE\n8\nE-CUSTOM\n'));
      expect(out, contains('LAYER\n2\nE-CUSTOM\n'));
      // The solid prim carries no linetype override (exactly one group 6 among
      // the LINE entities; the LTYPE table's own DASHED record is group 2).
      final entities = out.substring(out.indexOf('ENTITIES'));
      expect('6\nDASHED\n'.allMatches(entities).length, 1);
    });

    test('chrome extends the frame block with the C3 rows; null is unchanged',
        () {
      final plain = electricalSldToDxf(project: project, result: result);
      // No chrome ⇒ none of the new rows (pins the default frame).
      expect(plain, isNot(contains('CLIENT')));
      expect(plain, isNot(contains('NTS')));
      final chromed = electricalSldToDxf(
        project: project,
        result: result,
        chrome: const DrawingChrome(
          clientName: 'PT Contoh',
          dateString: '2026-07-02',
          drawnBy: 'DL',
          checkedBy: 'AB',
          approvedBy: 'CD',
          sheetIndex: 1,
          sheetTotal: 1,
        ),
      );
      expect(chromed, contains('CLIENT'));
      expect(chromed, contains('PT Contoh'));
      expect(chromed, contains('DATE'));
      expect(chromed, contains('2026-07-02'));
      expect(chromed, contains('DRAWN'));
      expect(chromed, contains('CHECKED'));
      expect(chromed, contains('APPROVED'));
      // A single-line is schematic: SCALE defaults NTS when no scale is given.
      expect(chromed, contains('SCALE'));
      expect(chromed, contains('NTS'));
      expect(chromed, contains('1 of 1'));
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

    test('stays on the legacy shape — no TABLES section, no class layers', () {
      // Behaviour pin: the C4 TABLES/E-* work touches electricalSldToDxf only.
      expect(dxf, isNot(contains('TABLES')));
      expect(dxf, isNot(contains('E-BUS')));
      expect(dxf, isNot(contains('370')));
      expect(dxf.startsWith('0\nSECTION\n2\nENTITIES\n'), isTrue);
    });
  });
}
